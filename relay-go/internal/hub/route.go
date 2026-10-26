package hub

import (
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
)

// 路由决策（DESIGN-20261023 §2.3 / §3.6 的 router 单元）。
//
// 本单元无状态：不持有 map、计数器或定时器。它只读连接图（registry）、日额度
// （quota.Ledger）、推送登记（push）与文件桥登记（bridge），决定一帧去哪、
// 是否由中转本地回答、是否要断开某条连接。连接与状态的所有权都在各自单元：
//
//	registry  谁在线、谁挂在谁身上（唯一写者）
//	quota     日额度、令牌桶与用量账本
//	bridge    文件桥状态机与 bid 登记
//	push      APNs 投递面
//	Link      每条连接的队列、心跳与关闭握手
//
// RouteFromDevice / RouteFromAgent 是仅有的两个入口（Hub 的公开方法即门面）；
// 路由热路径只经过具体类型，不新增接口派发。

// ── 路由 ─────────────────────────────────────────────────────────────────────

// routePing 回答 DLP ping，两个方向共用同一条规则。
//
// 这是原先 RouteFromDevice 与 RouteFromAgent 各写一份的重复分支：两处都是
// "解码成功才回 pong，失败就静默丢弃"，行为不变；合并后只有一处需要维护。
// 它刻意不是 Hub 的方法：这是无状态的帧处理助手，不增加 Hub 的私有编排面。
func routePing(h *Hub, link Target, wire dlp.Wire) {
	if frame, err := wire.Decode(); err == nil {
		h.SendControl(link, dlp.Pong(frame.Ts()))
	}
}

// RouteFromDevice 处理一条结构校验通过的设备帧。
//
// 转发路径直接在原始字节上盖 deviceId（见 dlp.Wire）：M2 这里是"全量解析 + 克隆 +
// 重编码"，一帧 48 字节要付 1.8 KiB 分配（M2.5 报告 §3）。缓冲的归属在这里唯一：
// 成功入队才把所有权交给写循环，其余每个出口都由 defer 归还。
func (h *Hub) RouteFromDevice(link *DeviceLink, wire dlp.Wire) {
	// 任意一帧都算"对端还活着"：设备链路的心跳走 WS ping/pong，这份记录只用于
	// 诊断与后续统一两套心跳口径。
	link.NoteInbound()
	owned := wire.Buffer()
	defer func() {
		if owned != nil {
			owned.Release()
		}
	}()

	switch {
	case wire.Is("ping"):
		routePing(h, link, wire)
		return
	case wire.Is("hello"):
		wanted := wire.FieldText("agentId")
		if wanted != "" && wanted != link.AgentID {
			h.SendControl(link, dlp.ErrorFrame("auth/agent-mismatch",
				"hello names a different agent", true, nil))
			h.detachDevice(link, "agent mismatch", 1001)
		}
		return
	case wire.IsHello():
		// 手机的构建号就搭在这条调用上：记下来，运维"那台手机升级了吗"
		// 才不用去翻配对当时的版本。
		h.noteClientBuild(link, wire)
	}

	// 操作统计只观察，不参与路由：分类与指纹在帧缓冲归还前算完。
	operation := classifyDeviceOperation(wire)

	agent := link.agent.Load()
	if agent == nil || agent.Closed() {
		h.SendControl(link, dlp.ErrorFrame("host/offline",
			"the PC connector is not connected", false, nil))
		h.SendControl(link, dlp.HostStatus(false, link.AgentID, "", "", nil))
		return
	}

	stamped, err := wire.WithDeviceIDMember(link.idMember)
	payload := []byte(nil)
	var payloadOwner *dlp.Buffer
	if err == nil {
		payload, payloadOwner = stamped.Bytes(), stamped.Buffer()
		wire = stamped
	} else {
		// 设备自己带了 deviceId（覆盖语义）等不常见形状：走全量解析，与 M2 一致。
		frame, decodeErr := wire.Decode()
		if decodeErr != nil {
			h.log.Warn("relay: could not decode a device frame",
				"deviceId", link.DeviceID, "error", decodeErr)
			return
		}
		payload, err = dlp.Encode(dlp.WithDeviceID(frame, link.DeviceID))
		if err != nil {
			h.log.Warn("relay: could not encode a device frame",
				"deviceId", link.DeviceID, "error", err)
			return
		}
	}
	switch agent.Enqueue(payload, classOf(wire.Kind()), payloadOwner) {
	case Enqueued:
		if payloadOwner != nil && payloadOwner == owned {
			owned = nil // 所有权已交给写循环
		}
		if operation.relevant {
			switch {
			case !operation.keyed:
				h.opUncounted.Add(1)
			case !h.usage.NoteOpOnce(link.ref(), operation.op, operation.fingerprint):
				h.opDeduped.Add(1)
			}
		}
	case FrameDropped:
		h.log.Warn("relay: dropped a stream frame for a saturated agent link",
			"agentId", link.AgentID, "deviceId", link.DeviceID, "frame", wire.Type())
	case Overloaded:
		// 电脑不在（或已经被自己那批帧堵死）：设备不能继续站着等，给 4010。
		h.log.Warn("relay: agent link is saturated; dropping the device",
			"deviceId", link.DeviceID, "agentId", link.AgentID)
		h.detachDevice(link, "agent unavailable", dlp.CloseAgentOffline)
	}
}

// RouteFromAgent 处理一条结构校验通过的电脑帧。
func (h *Hub) RouteFromAgent(link *AgentLink, wire dlp.Wire) {
	// 读循环在这里记下"最后收到对端一帧的时刻"：DLP 心跳的 watchdog 用它区分
	// "真断网"（什么都收不到）与"旧连接器不回答中转 ping"（还在发业务帧）。
	link.NoteInbound()
	// 与设备侧同一条所有权规则：默认在本函数返回时归还，入队成功才转移。
	owned := wire.Buffer()
	defer func() {
		if owned != nil {
			owned.Release()
		}
	}()
	if link.superseded.Load() {
		// 旧连接正在退场（新连接已经或即将登记）：它读循环里残留的帧不能再认领设备、
		// 记账或发推送，否则新旧两条连接会同时改写同一份世界状态。
		return
	}

	var hostStatus dlp.Frame
	switch {
	case wire.Is("hostStatus"):
		if frame, err := wire.Decode(); err == nil {
			hostStatus = frame
			h.noteAgentVersions(link, frame)
		}
	case wire.Is("ping"):
		routePing(h, link, wire)
		return
	case wire.Is("pong"):
		// 这是中转自己 DLP ping 的回答：心跳 watchdog 用它清掉截止时间。
		link.NotePong()
		return
	case wire.Is("notify"):
		// `notify` 是 agent 侧控制帧：**不跨到设备**，只在"手机此刻不在线"时
		// 转成一条 APNs 提醒（见 deliverNotify）。
		if frame, err := wire.Decode(); err == nil {
			h.deliverNotify(link, frame)
		}
		return
	}
	kind := wire.Kind()
	if dlp.IsAgentControlKind(kind) {
		// fs* 帧不是 DLP，永远不跨到设备；它们只属于某一次等待中的 /files/* 请求。
		h.routeBridgeFrame(link, wire)
		return
	}

	deviceID := wire.Field("deviceId")
	if len(deviceID) == 0 {
		if hostStatus != nil {
			h.broadcast(link, hostStatus)
			return
		}
		h.log.Debug("relay: dropping an unaddressed frame from the agent",
			"agentId", link.AgentID, "frame", wire.Type())
		return
	}

	device := h.registry.deviceOfAgent(link, deviceID)
	if device == nil {
		h.log.Debug("relay: agent sent a frame for an unknown device",
			"agentId", link.AgentID, "deviceId", string(deviceID), "frame", wire.Type())
		return
	}

	// 类别要在就地改写**之前**算：改写会移动字节，指向原数组的切片会失效
	// （Wire 自己会刷新 kind，但调用方手里的副本不会）。
	class := classOf(kind)
	stripped, err := wire.WithoutDeviceID()
	payload := []byte(nil)
	var payloadOwner *dlp.Buffer
	if err == nil {
		payload, payloadOwner = stripped.Bytes(), stripped.Buffer()
		wire = stripped
	} else {
		frame, decodeErr := wire.Decode()
		if decodeErr != nil {
			h.log.Warn("relay: could not decode an agent frame",
				"agentId", link.AgentID, "deviceId", device.DeviceID, "error", decodeErr)
			return
		}
		payload, err = dlp.Encode(dlp.WithoutDeviceID(frame))
		if err != nil {
			h.log.Warn("relay: could not encode an agent frame",
				"agentId", link.AgentID, "deviceId", device.DeviceID, "error", err)
			return
		}
	}

	// 额度按"真正发往手机的字节"记账，超限时先告诉手机为什么，再以 4011 关闭：
	// 一个不断重连进已经用光额度的客户端，比一个显示"今天的流量用完了"的更糟。
	if allowed, _ := h.quota.Charge(device.DeviceID, len(payload)); !allowed {
		h.log.Warn("relay: device exceeded its daily allowance",
			"deviceId", device.DeviceID, "limitBytes", h.limits.DeviceDailyBytes)
		h.SendControl(device, dlp.ErrorFrame("quota/device-daily",
			"this device reached its daily traffic allowance", false,
			map[string]any{"limitBytes": h.limits.DeviceDailyBytes}))
		h.detachDevice(device, "daily quota", dlp.CloseQuotaExceeded)
		return
	}

	switch device.Enqueue(payload, class, payloadOwner) {
	case Enqueued:
		if payloadOwner != nil && payloadOwner == owned {
			owned = nil
		}
	case FrameDropped:
		h.log.Debug("relay: dropped a stream frame for a slow device",
			"deviceId", device.DeviceID, "frame", wire.Type())
	case Overloaded:
		h.log.Warn("relay: device send queue is full; dropping the device",
			"deviceId", device.DeviceID)
		h.detachDevice(device, "backpressure", dlp.CloseBackpressure)
	}
}

// classOf 把帧类型映射成背压类别。
func classOf(kind []byte) Class {
	if dlp.IsStreamingKind(kind) {
		return ClassStream
	}
	return ClassControl
}

// broadcast 把一条无寻址帧发给这台电脑的全部设备（hostStatus 的常规路径）。
//
// 走控制优先队列而不是流式大队列：hostStatus 是可丢的状态广播，不能因为某台手机
// 正在收一堆大帧就把它的连接按 4008 断掉，也不能排在那些大帧后面。
func (h *Hub) broadcast(link *AgentLink, frame dlp.Frame) {
	payload, err := dlp.Encode(frame)
	if err != nil {
		h.log.Warn("relay: could not encode a broadcast frame",
			"agentId", link.AgentID, "error", err)
		return
	}
	kind := frame.Type()
	droppable := dlp.IsDroppableControl(kind)
	for _, device := range h.registry.attachedDevices(link) {
		device.EnqueueControl(payload, kind, droppable)
	}
}

// Target 是 SendControl 需要的最小接口。*AgentLink / *DeviceLink 通过内嵌的
// *Link 满足它，所以调用方不必写两次类型转换。
type Target interface {
	Enqueue(payload []byte, class Class, owned *dlp.Buffer) EnqueueResult
	EnqueueControl(payload []byte, frameType string, droppable bool) EnqueueResult
	Label() string
	RequestClose(code int, reason string)
}

// SendControl 发一帧中转控制帧。
//
// 分级只看帧类型（dlp.IsDroppableControl）：
//   - 可丢（pong/ping/hostStatus/accountState）：队列满时丢弃并计数，不断链；
//   - 必达（deviceAttach/deviceDetach/error/fs*）：最多等 controlWait，仍发不进去
//     才以 4008 断开这条连接——必达帧静默丢失比断线更难排查。
//
// 走哪条通道由 dlp.IsOrderedControl 决定：心跳/生命周期/状态走优先队列，永远排在
// 流式帧之前；error/fs* 与它们所属的数据帧共用大队列以保序。这是 2026-10-23 故障
// 之后"pong 不再被流式帧挤掉"的落点。
func (h *Hub) SendControl(link Target, frame dlp.Frame) {
	payload, err := dlp.Encode(frame)
	if err != nil {
		h.log.Warn("relay: could not encode a control frame", "link", link.Label(), "error", err)
		return
	}
	kind := frame.Type()
	if link.EnqueueControl(payload, kind, dlp.IsDroppableControl(kind)) == Overloaded {
		h.log.Warn("relay: control frame could not be queued; closing the link",
			"link", link.Label(), "frame", kind)
		link.RequestClose(dlp.CloseBackpressure, "backpressure")
	}
}

// SendBridgeChunk 把一条上行分片交给连接器的发送队列，并把这笔桥字节额度转移过去。
//
// 额度的所有权在**入队成功时**归队列（帧写出去、被丢弃或随连接关闭清空时归还）；
// 失败（链路已关、队列满、编码失败）时立刻归还并返回 false——调用方据此结束这次
// 上传。两条路都只归还一次：额度不会因为一次失败的上传漏掉。
func (h *Hub) SendBridgeChunk(link *AgentLink, frame dlp.Frame, creditBytes int64) bool {
	if link == nil {
		return false
	}
	payload, err := dlp.Encode(frame)
	if err != nil {
		h.log.Warn("relay: could not encode an upload chunk", "link", link.Label(), "error", err)
		link.ReleaseBridgeBytes(creditBytes)
		return false
	}
	if link.EnqueueWithCredit(payload, ClassControl, link.credits, creditBytes) != Enqueued {
		h.log.Warn("relay: upload chunk could not be queued; closing the link",
			"link", link.Label())
		link.ReleaseBridgeBytes(creditBytes)
		link.RequestClose(dlp.CloseBackpressure, "backpressure")
		return false
	}
	return true
}
