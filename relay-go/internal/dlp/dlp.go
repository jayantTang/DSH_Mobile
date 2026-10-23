// Package dlp 是 DLP v1 的帧层：解析、编码、结构校验、错误帧与关闭码。
//
// 中转是**透明转发器**：它不解释 DSH 语义，只需要知道一帧往哪个方向走、属于哪台
// 设备。其余内容原样穿过，包括这个版本不认识的帧类型（`t` 按设计向前兼容）。
// 口径逐项对齐 relay/dlp.py。
//
// 线上形状（docs/RELAY-PROTOCOL.md §3）：
//
//	设备 → 电脑   req / open / cancel / eventResult / ping / hello
//	电脑 → 设备   res / item / end / streamError / event / hostStatus / pong / error /
//	              accountState（最后一条由中转自己发出）
//
// 两个中转内部的控制帧族永远不跨到另一侧：deviceAttach / deviceDetach（中转 → 电脑）
// 描述一台设备的生命周期。中转还会给每条转发帧盖上 deviceId，因为电脑只有一条
// WebSocket，多台设备都复用它。
package dlp

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"unicode/utf8"
)

// ProtocolVersion 是 DLP 协议版本（relay/dlp.py 的 PROTOCOL_VERSION）。
const ProtocolVersion = 1

// MaxFrameBytes 是单帧硬上限，与 DSH 的图片附件上限一致（dlp.MAX_FRAME_BYTES）。
const MaxFrameBytes = 32 * 1024 * 1024

// 中转使用的关闭码。1001 是标准的"对端走开了"，其余是应用层关闭码（4000-4999）。
const (
	// CloseGoingAway：正常拆除（对端关闭、撤销、接管）。
	CloseGoingAway = 1001
	// CloseSuperseded：同一 agent 又连了一条，旧 socket 被顶替。
	CloseSuperseded = 4001
	// CloseBackpressure：对端读得太慢，队列塞满。
	CloseBackpressure = 4008
	// CloseRateLimited：限流拒绝（留给后续里程碑，当前没有触发点）。
	CloseRateLimited = 4009
	// CloseAgentOffline：设备有帧要发给电脑，但电脑不可用或已饱和。
	CloseAgentOffline = 4010
	// CloseQuotaExceeded：设备当日出口额度用尽。
	CloseQuotaExceeded = 4011
	// CloseDeviceLimit：这台电脑的在线设备数已达上限。
	CloseDeviceLimit = 4012
)

// 帧类型集合，与 dlp.py 的同名集合逐项一致。
var (
	deviceToAgent = map[string]struct{}{
		"req": {}, "open": {}, "cancel": {}, "eventResult": {}, "ping": {}, "hello": {},
	}
	agentToDevice = map[string]struct{}{
		"res": {}, "item": {}, "end": {}, "streamError": {}, "event": {},
		"hostStatus": {}, "pong": {}, "error": {}, "accountState": {},
	}
	relayToAgent = map[string]struct{}{"deviceAttach": {}, "deviceDetach": {}}
	// agentControl 是连接器发来的控制帧：永远不转发给设备（它们不是 DLP）。
	agentControl = map[string]struct{}{
		"notify":     {},
		"fsPutBegin": {}, "fsPutChunk": {}, "fsPutEnd": {}, "fsPutAck": {}, "fsPutDone": {},
		"fsGetBegin": {}, "fsGetChunk": {}, "fsGetEnd": {}, "fsGetAck": {},
		"fsErr": {},
	}
	// relayToAgentControl 是中转发给连接器的控制帧（下载被放弃时叫停）。
	// 与 Python 的 RELAY_TO_AGENT_CONTROL 同一口径：它只出现在出站方向，不在
	// agentControl 里（那一组是"从连接器收下、不跨到设备"的帧）。
	relayToAgentControl = map[string]struct{}{"fsGetCancel": {}}
	// idFrames 是携带一元请求、因此必须有 `id` 的帧类型。
	idFrames = map[string]struct{}{
		"req": {}, "open": {}, "cancel": {}, "res": {}, "item": {},
		"end": {}, "streamError": {}, "eventResult": {},
	}
)

// Frame 是一帧已解析的 JSON 对象。
//
// 用 map 而不是结构体：中转不认识的帧类型也要能原样穿过，结构体会把未知字段丢掉。
// 数字以 json.Number 保留原文（`json.Decoder.UseNumber`），重编码后字节与 Python 的
// `json.loads` + `json.dumps` 口径一致，不会把大整数变成 float64。
type Frame map[string]any

// ErrInvalidFrame 是"这帧没法路由"的根错误（不是 JSON、不是对象、没有可用的 t）。
var ErrInvalidFrame = errors.New("protocol/bad-frame")

// FrameError 是一帧被拒的原因。Error() 只给原因本身（"frame is not JSON"），
// 因为这句话会原样进 `protocol/bad-frame` 错误帧的 message；用 errors.Is 判类型时
// 它仍然是 ErrInvalidFrame。
type FrameError struct {
	Reason string
}

func (e *FrameError) Error() string { return e.Reason }

// Unwrap 让 errors.Is(err, ErrInvalidFrame) 继续成立。
func (e *FrameError) Unwrap() error { return ErrInvalidFrame }

// Parse 把一条 WebSocket 文本消息解析成帧。
//
// 三种失败与 Python 的 FrameError 一一对应：不是合法 UTF-8、不是 JSON、不是带
// 非空字符串 `t` 的 JSON 对象。不认识的 `t` **不是**错误——调用方决定转发还是忽略。
//
// 第二条返回值只在帧里真的出现落单 UTF-16 代理项转义时非 nil（见 surrogate.go）。
// Go 的 encoding/json 会在解析阶段把落单代理项换成 U+FFFD，所以这里报的是"上游送来
// 了坏字符"，而不是"我们还需要修"。
func Parse(raw []byte) (Frame, *SurrogateDamage, error) {
	// 必须先查 UTF-8：encoding/json 会把非法字节**静默**换成 U+FFFD，而 Python 的
	// dlp.parse_frame 直接回 protocol/bad-frame。不查这一步，Go 版会放过坏帧。
	if !utf8.Valid(raw) {
		return nil, nil, &FrameError{Reason: "frame is not valid UTF-8"}
	}
	if len(raw) > MaxFrameBytes {
		return nil, nil, &FrameError{Reason: fmt.Sprintf("frame exceeds %d bytes", MaxFrameBytes)}
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil, nil, &FrameError{Reason: "frame is not JSON"}
	}
	// Python 的 json.loads 不接受正文之后还有别的内容。
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		return nil, nil, &FrameError{Reason: "frame is not JSON"}
	}
	object, ok := value.(map[string]any)
	if !ok {
		return nil, nil, &FrameError{Reason: "frame must be a JSON object"}
	}
	kind, ok := object["t"].(string)
	if !ok || kind == "" {
		return nil, nil, &FrameError{Reason: "frame is missing a non-empty string `t`"}
	}
	return Frame(object), ScanSurrogates(raw), nil
}

// Encode 把帧编码成紧凑 JSON，与 Python 的
// `json.dumps(frame, ensure_ascii=False, separators=(",", ":"))` 对齐。
//
// 两点必须与 Python 相同，否则同一帧在两版中转上字节不同：
//   - 不转义 HTML 字符（Go 默认把 <、>、& 写成 \u003c 之类）；
//   - 不追加换行（json.Encoder 会加，这里裁掉）。
func Encode(frame Frame) ([]byte, error) {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(map[string]any(frame)); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buffer.Bytes(), []byte("\n")), nil
}

// Type 返回帧的 `t`；缺失或不是字符串时返回空串。
func (f Frame) Type() string {
	value, _ := f["t"].(string)
	return value
}

// ID 返回帧的 `id`；缺失或不是非空字符串时返回空串。
func (f Frame) ID() string {
	value, _ := f["id"].(string)
	return value
}

// DeviceID 返回中转内部寻址键 `deviceId`；缺失时返回空串。
func (f Frame) DeviceID() string {
	value, _ := f["deviceId"].(string)
	return value
}

// Method 返回 `method`（只有 req 用），供 `_link/hello` 判定。
func (f Frame) Method() string {
	value, _ := f["method"].(string)
	return value
}

// AgentID 返回 `agentId`（hello 与 hostStatus 用）。
func (f Frame) AgentID() string {
	value, _ := f["agentId"].(string)
	return value
}

// Ts 原样返回 ping/pong 的时间戳（可能是 json.Number，也可能是 nil）。
func (f Frame) Ts() any { return f["ts"] }

// Clone 复制一层：中转要往上加/删键，不能改到调用方手里那份。
func (f Frame) Clone() Frame {
	out := make(Frame, len(f)+1)
	for key, value := range f {
		out[key] = value
	}
	return out
}

// IsDeviceToAgent 判断 `t` 是否属于设备发往电脑的帧族。
func IsDeviceToAgent(kind string) bool { _, ok := deviceToAgent[kind]; return ok }

// IsAgentToDevice 判断 `t` 是否属于电脑发往设备的帧族。
func IsAgentToDevice(kind string) bool { _, ok := agentToDevice[kind]; return ok }

// IsRelayToAgent 判断 `t` 是否属于中转发给电脑的控制帧。
func IsRelayToAgent(kind string) bool { _, ok := relayToAgent[kind]; return ok }

// IsRelayToAgentControl 判断 `t` 是否是中转发给连接器的控制帧。
func IsRelayToAgentControl(kind string) bool {
	_, ok := relayToAgentControl[kind]
	return ok
}

// IsAgentControl 判断 `t` 是否是连接器发来的、不跨到设备的控制帧。
func IsAgentControl(kind string) bool { _, ok := agentControl[kind]; return ok }

// IsStreaming 判断这一帧在背压下是否可以丢弃。
//
// 只有 `res` / `item` 是流式帧（DESIGN §5.1 的逐字口径）。它们丢掉之后调用方还能
// 重试或跳过；其余帧——包括 `req` 这种"发出去才有回答"的——丢了就是坏结果，所以
// 一律按控制帧处理：宁可断开慢连接，也不静默丢。
func IsStreaming(kind string) bool {
	return kind == "res" || kind == "item"
}

// WithDeviceID 返回带上中转内部寻址键 `deviceId` 的副本。
func WithDeviceID(frame Frame, deviceID string) Frame {
	out := frame.Clone()
	out["deviceId"] = deviceID
	return out
}

// WithoutDeviceID 返回去掉 `deviceId` 的副本；本来就没有时原样返回。
//
// 中转内部键不许到达设备：设备只知道帧的内容，不知道自己在服务端的编号。
func WithoutDeviceID(frame Frame) Frame {
	if _, ok := frame["deviceId"]; !ok {
		return frame
	}
	out := frame.Clone()
	delete(out, "deviceId")
	return out
}

// ErrorFrame 构造错误帧 `{"t":"error","code","message"[,"fatal"][,"details"]}`。
func ErrorFrame(code, message string, fatal bool, details map[string]any) Frame {
	frame := Frame{"t": "error", "code": code, "message": message}
	if fatal {
		frame["fatal"] = true
	}
	if len(details) > 0 {
		frame["details"] = details
	}
	return frame
}

// Pong 构造 ping 的回答；`ts` 缺失时与 Python 一样输出 null。
func Pong(ts any) Frame {
	return Frame{"t": "pong", "ts": ts}
}

// Ping 构造中转自己的心跳帧；连接器把 `ts` 原样带回 `pong`。
//
// 协议里 ping 本来是设备发、agent 回 pong；中转对连接器复用同一个形状，连接器
// 的读循环已经把 `ping` 当成需要回 `pong` 的帧处理（plugins/mobile-link/lib/link.js）。
func Ping(ts any) Frame {
	return Frame{"t": "ping", "ts": ts}
}

// IsDroppableControl 判断中转**发出**的控制帧在拥塞时能不能丢。
//
// 可丢的是"再发一次或客户端自己会重查"的帧：心跳（pong/ping）、hostStatus 广播、
// accountState 通知。其余控制帧（deviceAttach/deviceDetach/error/文件通道 fs*）
// 丢了就是坏一次结果，必须等队列腾出位置。
func IsDroppableControl(kind string) bool {
	switch kind {
	case "pong", "ping", "hostStatus", "accountState":
		return true
	}
	return false
}

// IsOrderedControl 判断一帧控制帧必须与它所属的数据帧保持入队顺序。
//
// error 是一条流的结局，fs* 是文件通道的 begin/end：它们若走优先队列，会越过
// 先入队的 res/item/fsPutChunk，客户端就会先看到"结束/出错"再看到数据（实测
// fsPutEnd 越过两个 fsPutChunk 会让上传卡死在等待 fsPutDone）。
// 其余控制帧（心跳、生命周期、状态广播）不依赖任何数据帧，走优先队列。
func IsOrderedControl(kind string) bool {
	return kind == "error" || strings.HasPrefix(kind, "fs")
}

// HostStatus 构造推给设备/电脑的 hostStatus 帧。
//
// 空字符串表示"这一项不说"（Python 的 None），extra 里的键会并进 info，用于带上
// 中转自己的版本（手机「关于」页据此显示中转版本）。
func HostStatus(online bool, agentID, name, version string, extra map[string]any) Frame {
	info := map[string]any{"online": online}
	if agentID != "" {
		info["agentId"] = agentID
	}
	if name != "" {
		info["name"] = name
	}
	if version != "" {
		info["version"] = version
	}
	for key, value := range extra {
		info[key] = value
	}
	return Frame{"t": "hostStatus", "info": info}
}

// DeviceAttachFrame 构造"这台设备上线了"（中转 → 电脑）。
func DeviceAttachFrame(deviceID, name, model, agentID string) Frame {
	frame := Frame{"t": "deviceAttach", "deviceId": deviceID}
	device := map[string]any{}
	if name != "" {
		device["name"] = name
	}
	if model != "" {
		device["model"] = model
	}
	if agentID != "" {
		device["agentId"] = agentID
	}
	if len(device) > 0 {
		frame["device"] = device
	}
	return frame
}

// DeviceDetachFrame 构造"这台设备下线了"（中转 → 电脑）；reason 空则不带该键。
func DeviceDetachFrame(deviceID, reason string) Frame {
	frame := Frame{"t": "deviceDetach", "deviceId": deviceID}
	if reason != "" {
		frame["reason"] = reason
	}
	return frame
}

// FetchCancelFrame 构造"停止这次下载"（中转 → 连接器）。
//
// 连接器对不认识的 bid 是空操作，所以它可以被安全地重复发送；hub 仍然只发一次。
func FetchCancelFrame(bid string) Frame {
	return Frame{"t": "fsGetCancel", "bid": bid}
}

// AccountStateFrame 构造同账户设备的"状态变了"通知。
func AccountStateFrame(keys []string) Frame {
	return Frame{"t": "accountState", "keys": append([]string(nil), keys...)}
}
