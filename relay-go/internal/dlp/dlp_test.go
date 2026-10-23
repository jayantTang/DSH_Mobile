package dlp

import (
	"encoding/json"
	"errors"
	"testing"
	"unicode/utf8"
)

// TestEncodingJSONRepairsLoneSurrogates 钉住**实测**出来的 Go 行为。
//
// 这不是"顺手测一下标准库"，而是 M2 的一个设计依据：Python 版必须在发送前显式把
// 落单代理项换成 U+FFFD（否则 `text.encode("utf-8")` 抛异常、整条链路死掉）；Go 的
// encoding/json 在解码阶段就替换了，所以 Go 版**不需要**修复步骤。这条用例一旦变红，
// 说明行为变了，必须重新评估出站路径。
func TestEncodingJSONRepairsLoneSurrogates(t *testing.T) {
	cases := []struct {
		name     string
		raw      string
		wantText string
		wantLone int
	}{
		{"落单高代理项", `{"a":"\ud83d"}`, "\ufffd", 1},
		{"落单低代理项", `{"a":"\udc00"}`, "\ufffd", 1},
		{"合法配对", `{"a":"\ud83d\ude00"}`, "\U0001F600", 0},
		{"转义成字面量的反斜杠", `{"a":"\\ud83d"}`, `\ud83d`, 0},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			var value map[string]any
			if err := json.Unmarshal([]byte(testCase.raw), &value); err != nil {
				t.Fatalf("Unmarshal: %v", err)
			}
			text, _ := value["a"].(string)
			if text != testCase.wantText {
				t.Fatalf("解码结果 = %q，期望 %q", text, testCase.wantText)
			}
			if !utf8.ValidString(text) {
				t.Fatalf("解码结果不是合法 UTF-8：%q", text)
			}
			// 再编码必须成功（Python 版当年就是死在这一步之后）。
			if _, err := json.Marshal(value); err != nil {
				t.Fatalf("重新编码失败：%v", err)
			}
			damage := ScanSurrogates([]byte(testCase.raw))
			if testCase.wantLone == 0 {
				if damage != nil {
					t.Fatalf("不该报损伤：%+v", damage)
				}
				return
			}
			if damage == nil || damage.Count != testCase.wantLone {
				t.Fatalf("损伤计数 = %+v，期望 %d", damage, testCase.wantLone)
			}
		})
	}
}

// TestParseRepairsSurrogatesAndReportsDamage 确认解析路径的两个结果同时成立：
// 帧可用（内容已被换成 U+FFFD）、损伤被告知（供 hub 记日志）。
func TestParseRepairsSurrogatesAndReportsDamage(t *testing.T) {
	frame, damage, err := Parse([]byte(`{"t":"res","id":"r1","value":{"text":"a\ud83db"}}`))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	text := frame["value"].(map[string]any)["text"].(string)
	if text != "a\ufffdb" {
		t.Fatalf("文本 = %q，期望 U+FFFD 替换", text)
	}
	if damage == nil || damage.Count != 1 || damage.Kinds != "high" {
		t.Fatalf("damage = %+v", damage)
	}
	encoded, err := Encode(frame)
	if err != nil {
		t.Fatalf("Encode: %v", err)
	}
	if !utf8.Valid(encoded) {
		t.Fatalf("出站帧不是合法 UTF-8：%q", encoded)
	}
}

// TestParseRejectsInvalidUTF8 是 Go 与 Python 的一处**必须显式补齐**的差异：
// encoding/json 会把非法字节静默替换成 U+FFFD，而 Python 的 json.loads 前的 decode
// 直接报错。中转必须与 Python 一样回 protocol/bad-frame。
func TestParseRejectsInvalidUTF8(t *testing.T) {
	raw := []byte("{\"t\":\"res\",\"id\":\"r1\",\"value\":\"\xff\xfe\"}")
	if _, _, err := Parse(raw); !errors.Is(err, ErrInvalidFrame) {
		t.Fatalf("非法 UTF-8 应被拒，实际 err=%v", err)
	}
}

func TestParseRejectsNonObjectAndMissingType(t *testing.T) {
	cases := map[string]string{
		"不是 JSON":     `not json`,
		"不是对象":        `[1,2,3]`,
		"缺 t":         `{"id":"r1"}`,
		"t 不是字符串":     `{"t":1}`,
		"t 是空字符串":     `{"t":""}`,
		"JSON 之后还有内容": `{"t":"res"}{"t":"res"}`,
	}
	for name, raw := range cases {
		if _, _, err := Parse([]byte(raw)); !errors.Is(err, ErrInvalidFrame) {
			t.Fatalf("%s：应被拒，实际 err=%v", name, err)
		}
	}
}

// TestParseKeepsUnknownTypes 钉住"未知 t 不是错误"：DLP 的 t 向前兼容。
func TestParseKeepsUnknownTypes(t *testing.T) {
	frame, _, err := Parse([]byte(`{"t":"futureFrame","id":"f1","extra":{"a":1}}`))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if frame.Type() != "futureFrame" {
		t.Fatalf("t = %q", frame.Type())
	}
}

// TestEncodeMatchesPythonShape 检查编码口径：紧凑、不转义 HTML、不带尾换行。
func TestEncodeMatchesPythonShape(t *testing.T) {
	frame := Frame{"t": "res", "id": "r1", "value": map[string]any{"text": "a<b>&c"}}
	encoded, err := Encode(frame)
	if err != nil {
		t.Fatalf("Encode: %v", err)
	}
	want := `{"id":"r1","t":"res","value":{"text":"a<b>&c"}}`
	if string(encoded) != want {
		t.Fatalf("编码 = %s，期望 %s", encoded, want)
	}
}

// TestEncodeKeepsNumberText 是大整数保真的依据：解析用 UseNumber，重编码不会变成
// 1.7e+12 那种科学计数法（Python 的 int 同样精确）。
func TestEncodeKeepsNumberText(t *testing.T) {
	frame, _, err := Parse([]byte(`{"t":"res","id":"r1","updatedAt":1761234567890123}`))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	encoded, err := Encode(frame)
	if err != nil {
		t.Fatalf("Encode: %v", err)
	}
	if string(encoded) != `{"id":"r1","t":"res","updatedAt":1761234567890123}` {
		t.Fatalf("大整数被改写：%s", encoded)
	}
}

func TestValidation(t *testing.T) {
	cases := []struct {
		name      string
		raw       string
		fromDeice string
		fromAgent string
	}{
		{"req 缺 id", `{"t":"req","method":"session/list"}`, "req: missing `id`", ""},
		{"req 缺 method", `{"t":"req","id":"r1"}`, "req: missing `method`", ""},
		{"open 缺 endpoint", `{"t":"open","id":"o1"}`, "open: missing `endpoint`", ""},
		{"ping 不需要 id", `{"t":"ping","ts":1}`, "", ""},
		{"hello 不需要 id", `{"t":"hello","agentId":"agt_x"}`, "", ""},
		{"res 缺 id", `{"t":"res","deviceId":"dev"}`, "", "res: missing `id`"},
		{"item 缺 id", `{"t":"item"}`, "", "item: missing `id`"},
		{"pong 不需要 id", `{"t":"pong","ts":1}`, "", ""},
		{"未知类型不校验", `{"t":"futureFrame"}`, "", ""},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			wire, _, err := Scan([]byte(testCase.raw))
			if err != nil {
				t.Fatalf("Scan: %v", err)
			}
			if got := ValidateFromDevice(wire); got != testCase.fromDeice {
				t.Fatalf("ValidateFromDevice = %q，期望 %q", got, testCase.fromDeice)
			}
			if got := ValidateFromAgent(wire); got != testCase.fromAgent {
				t.Fatalf("ValidateFromAgent = %q，期望 %q", got, testCase.fromAgent)
			}
			// 全量解析路径必须给出同一判定：扫描路径与兜底路径不能分叉。
			frame, _, err := Parse([]byte(testCase.raw))
			if err != nil {
				t.Fatalf("Parse: %v", err)
			}
			if got := ValidateFromDevice(Wire{frame: frame}); got != testCase.fromDeice {
				t.Fatalf("全量解析路径 ValidateFromDevice = %q，期望 %q", got, testCase.fromDeice)
			}
			if got := ValidateFromAgent(Wire{frame: frame}); got != testCase.fromAgent {
				t.Fatalf("全量解析路径 ValidateFromAgent = %q，期望 %q", got, testCase.fromAgent)
			}
		})
	}
}

func TestDeviceIDInjectionAndStripping(t *testing.T) {
	frame := Frame{"t": "req", "id": "r1", "method": "session/list"}
	addressed := WithDeviceID(frame, "dev_1")
	if addressed.DeviceID() != "dev_1" {
		t.Fatalf("deviceId = %q", addressed.DeviceID())
	}
	if _, leaked := frame["deviceId"]; leaked {
		t.Fatal("WithDeviceID 不能改到原帧")
	}

	stripped := WithoutDeviceID(addressed)
	if _, leaked := stripped["deviceId"]; leaked {
		t.Fatal("WithoutDeviceID 没摘掉 deviceId")
	}
	if stripped.ID() != "r1" {
		t.Fatalf("其余字段丢了：%v", stripped)
	}
	plain := Frame{"t": "ping"}
	if got := WithoutDeviceID(plain); len(got) != 1 {
		t.Fatalf("没有 deviceId 时应原样返回：%v", got)
	}
}

func TestErrorAndControlFrames(t *testing.T) {
	errorFrame := ErrorFrame("protocol/bad-frame", "req: missing `id`", false, nil)
	if errorFrame["t"] != "error" || errorFrame["code"] != "protocol/bad-frame" {
		t.Fatalf("错误帧 = %v", errorFrame)
	}
	if _, fatal := errorFrame["fatal"]; fatal {
		t.Fatal("非致命错误不该带 fatal")
	}
	fatal := ErrorFrame("limit/devices", "too many", true, map[string]any{"maxDevicesPerAgent": 1})
	if fatal["fatal"] != true {
		t.Fatalf("致命错误缺 fatal：%v", fatal)
	}
	details := fatal["details"].(map[string]any)
	if details["maxDevicesPerAgent"] != 1 {
		t.Fatalf("details = %v", details)
	}

	attach := DeviceAttachFrame("dev_1", "iPhone", "iPhone17,1", "agt_1")
	device := attach["device"].(map[string]any)
	if device["name"] != "iPhone" || device["agentId"] != "agt_1" {
		t.Fatalf("deviceAttach = %v", attach)
	}
	detach := DeviceDetachFrame("dev_1", "revoked")
	if detach["reason"] != "revoked" {
		t.Fatalf("deviceDetach = %v", detach)
	}
	if _, ok := DeviceDetachFrame("dev_1", "")["reason"]; ok {
		t.Fatal("空 reason 不该出现在帧里")
	}

	status := HostStatus(true, "agt_1", "mac", "", map[string]any{"relayVersion": "1.2"})
	info := status["info"].(map[string]any)
	if info["online"] != true || info["name"] != "mac" || info["relayVersion"] != "1.2" {
		t.Fatalf("hostStatus = %v", info)
	}
	if _, ok := info["version"]; ok {
		t.Fatal("空 version 不该出现")
	}

	pong := Pong(nil)
	if value, present := pong["ts"]; !present || value != nil {
		t.Fatalf("缺 ts 时应输出 null：%v", pong)
	}
	ping := Ping(123)
	if ping.Type() != "ping" || ping["ts"] != 123 {
		t.Fatalf("Ping = %v", ping)
	}
}

// TestControlFrameDropPolicy 钉住"哪些控制帧可以丢"的唯一口径：
// 心跳与状态广播可丢；生命周期、错误与文件通道必须等队列。
func TestControlFrameDropPolicy(t *testing.T) {
	for _, kind := range []string{"pong", "ping", "hostStatus", "accountState"} {
		if !IsDroppableControl(kind) {
			t.Fatalf("%s 应当可丢", kind)
		}
	}
	for _, kind := range []string{"deviceAttach", "deviceDetach", "error",
		"fsPutBegin", "fsPutEnd", "fsGetBegin", "fsGetCancel"} {
		if IsDroppableControl(kind) {
			t.Fatalf("%s 必须必达", kind)
		}
	}
	// 保序：error 与 fs* 必须排在它们所属的数据帧之后；心跳/生命周期/状态不用。
	for _, kind := range []string{"error", "fsPutBegin", "fsPutEnd", "fsGetBegin",
		"fsGetCancel"} {
		if !IsOrderedControl(kind) {
			t.Fatalf("%s 必须与数据帧保序", kind)
		}
	}
	for _, kind := range []string{"pong", "ping", "hostStatus", "accountState",
		"deviceAttach", "deviceDetach"} {
		if IsOrderedControl(kind) {
			t.Fatalf("%s 不依赖数据帧顺序，应走优先队列", kind)
		}
	}
}

func TestSurrogateDamageLocatesTheBreak(t *testing.T) {
	// 坏字符在帧尾：Python 的诊断里 trailingChars 接近 0，说明流式分片被截断。
	raw := []byte(`{"t":"res","id":"r1","value":{"text":"hello\ud83d"}}`)
	damage := ScanSurrogates(raw)
	if damage == nil {
		t.Fatal("没检出落单代理项")
	}
	if damage.Count != 1 || damage.Kinds != "high" {
		t.Fatalf("damage = %+v", damage)
	}
	if damage.FirstIndex <= 0 || damage.FirstIndex >= len(raw) {
		t.Fatalf("firstIndex = %d，越界", damage.FirstIndex)
	}
	if damage.TrailingChars != 3 { // 后面只剩 `"}}`
		t.Fatalf("trailingChars = %d，期望 3", damage.TrailingChars)
	}
	if damage.Context == "" {
		t.Fatal("缺上下文")
	}

	// 一处高、一处低 → mixed。
	mixed := ScanSurrogates([]byte(`{"a":"\ud800","b":"\udc00"}`))
	if mixed == nil || mixed.Kinds != "mixed" || mixed.Count != 2 {
		t.Fatalf("mixed = %+v", mixed)
	}
}
