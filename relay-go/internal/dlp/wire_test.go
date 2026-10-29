package dlp

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

// 扫描路径与全量解析路径必须给出同样的答案：这是"零解析转发"不改变协议行为的
// 唯一证明。表里刻意混入转义、空白、嵌套、unknown 帧与各种坏形状。
func TestWireMatchesParse(t *testing.T) {
	raws := []string{
		`{"t":"req","id":"r1","method":"session/list"}`,
		`{"t":"res","id":"r1","ok":true,"value":{"echo":"r1"},"deviceId":"dev_7"}`,
		`{"t":"item","id":"i1","text":"a\ud83db"}`,
		`{"t":"item","id":"i1","text":"中文 😀 \u4e2d"}`,
		`{"t":"item","id":"i1","text":"quote\" slash\\ tab\t"}`,
		`{ "t" : "ping" , "ts" : 1761234567890123 }`,
		"\n\t {\"t\":\"pong\",\"ts\":null}\r\n",
		`{"t":"hello","agentId":"agt_x","info":{"version":"1.2.3"}}`,
		`{"t":"hostStatus","info":{"online":true,"name":"MacBook"},"deviceId":"dev_7"}`,
		`{"t":"futureFrame","id":"f1","extra":{"a":[1,2,{"b":null}],"c":-1.5e-7}}`,
		`{"t":"res","id":"r1","value":{"deep":[[[[{"x":[true,false,null]}]]]]}}`,
		`{"t":"req","id":"r1","method":"_link/hello","args":{"clientBuild":"42"}}`,
		`{"t":"res","id":"r\u0031","text":"\u4e2d"}`,
		`{"t":"res","id":"r1","deviceId":123}`,
		`{"t":"res","id":"r1","deviceId":null}`,
		// 坏形状：解析必须失败，且两条路径的判定一致。
		`not json`,
		`[]`,
		`"text"`,
		`{}`,
		`{"t":""}`,
		`{"t":5}`,
		`{"t":"req"} trailing`,
		`{"t":"req",}`,
		`{"t":"req","id":"a\qb"}`,
		`{"t":"req","id":"r1"`,
		`{"t":"req","id":"r1"}{"t":"res"}`,
		` {"t" : "res" , "id" : "r1" } `,
	}
	for _, raw := range raws {
		t.Run(raw, func(t *testing.T) {
			frame, _, parseErr := Parse([]byte(raw))
			wire, _, scanErr := Scan([]byte(raw))
			if (parseErr != nil) != (scanErr != nil) {
				t.Fatalf("Parse/Scan 判定不一致：Parse=%v Scan=%v", parseErr, scanErr)
			}
			if parseErr != nil {
				if !errors.Is(scanErr, ErrInvalidFrame) {
					t.Fatalf("Scan 错误类型 = %v", scanErr)
				}
				if parseErr.Error() != scanErr.Error() {
					t.Fatalf("错误文案不一致：Parse=%q Scan=%q", parseErr, scanErr)
				}
				return
			}
			if got, want := wire.Type(), frame.Type(); got != want {
				t.Fatalf("Type = %q，期望 %q", got, want)
			}
			if got, want := wire.Is(frame.Type()), true; got != want {
				t.Fatalf("Is(%q) = %v", frame.Type(), got)
			}
			decoded, err := wire.Decode()
			if err != nil {
				t.Fatalf("Decode: %v", err)
			}
			if !sameJSON(t, decoded, frame) {
				t.Fatalf("Decode 结果与 Parse 不同：%v vs %v", decoded, frame)
			}
			for _, key := range []string{"t", "id", "deviceId", "method", "agentId", "endpoint"} {
				want, ok := frame[key].(string)
				if !ok {
					if got := wire.Field(key); got != nil {
						t.Fatalf("Field(%q) = %q，期望 nil", key, got)
					}
					continue
				}
				// Field 返回原始（可能带转义）形态，FieldText 返回解码后的值。
				if got := wire.FieldText(key); got != want {
					t.Fatalf("FieldText(%q) = %q，期望 %q", key, got, want)
				}
			}
			for _, key := range []string{"t", "id", "deviceId", "value", "info", "args"} {
				_, want := frame[key]
				if got := wire.Has(key); got != want {
					t.Fatalf("Has(%q) = %v，期望 %v", key, got, want)
				}
			}
		})
	}
}

// TestScanHandlesEscapedKeysByFallingBack 钉住"扫描器不认识就退回全量解析"：
// 转义键（`"\u0074"` 就是 t）不能被当成"没有 t"。
func TestScanHandlesEscapedKeysByFallingBack(t *testing.T) {
	wire, _, err := Scan([]byte(`{"\u0074":"req","id":"r1","method":"m"}`))
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if got := wire.Type(); got != "req" {
		t.Fatalf("Type = %q，期望 req（应走全量解析兜底）", got)
	}
	if problem := ValidateFromDevice(wire); problem != "" {
		t.Fatalf("ValidateFromDevice = %q", problem)
	}
}

func TestWireWithDeviceIDMember(t *testing.T) {
	cases := []struct{ raw, want string }{
		{`{"t":"req","id":"r1","method":"m"}`, `{"t":"req","id":"r1","method":"m","deviceId":"dev_7"}`},
		{`{"t":"req"} `, `{"t":"req","deviceId":"dev_7"} `},
		{`{"t":"req"}`, `{"t":"req","deviceId":"dev_7"}`},
		{"{\n  \"t\": \"req\"\n}", "{\n  \"t\": \"req\"\n,\"deviceId\":\"dev_7\"}"},
	}
	member := DeviceIDMember("dev_7")
	for _, testCase := range cases {
		t.Run(testCase.raw, func(t *testing.T) {
			wire, _, err := Scan([]byte(testCase.raw))
			if err != nil {
				t.Fatalf("Scan: %v", err)
			}
			stamped, err := wire.WithDeviceIDMember(member)
			if err != nil {
				t.Fatalf("WithDeviceIDMember: %v", err)
			}
			if got := string(stamped.Bytes()); got != testCase.want {
				t.Fatalf("结果 = %s，期望 %s", got, testCase.want)
			}
			// 必须仍是合法 JSON，且 deviceId 只有一个。
			var value map[string]any
			if err := json.Unmarshal(stamped.Bytes(), &value); err != nil {
				t.Fatalf("结果不是合法 JSON：%v", err)
			}
			if value["deviceId"] != "dev_7" {
				t.Fatalf("deviceId = %v", value["deviceId"])
			}
			if count := strings.Count(string(stamped.Bytes()), `"deviceId"`); count != 1 {
				t.Fatalf("deviceId 出现 %d 次", count)
			}
		})
	}
}

// TestWireWithDeviceIDMemberFallsBackOnExistingKey：设备自己塞了 deviceId 时，
// 就地改写做不到"覆盖"，必须交回全量解析（覆盖语义由 WithDeviceID 保证）。
func TestWireWithDeviceIDMemberFallsBackOnExistingKey(t *testing.T) {
	wire, _, err := Scan([]byte(`{"t":"req","id":"r1","method":"m","deviceId":"evil"}`))
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if _, err := wire.WithDeviceIDMember(DeviceIDMember("dev_7")); !errors.Is(err, errWireFallback) {
		t.Fatalf("期望 errWireFallback，得到 %v", err)
	}
}

func TestWireWithoutDeviceID(t *testing.T) {
	cases := []struct{ raw, want string }{
		{`{"t":"res","id":"r1","deviceId":"dev_7"}`, `{"t":"res","id":"r1"}`},
		{`{"t":"res","deviceId":"dev_7","id":"r1"}`, `{"t":"res","id":"r1"}`},
		{`{"t":"res","deviceId":"dev_7"}`, `{"t":"res"}`},
		{`{ "t":"res", "deviceId" : "dev_7" , "id":"r1" }`, `{ "t":"res",  "id":"r1" }`},
		{`{"t":"res","deviceId":123,"id":"r1"}`, `{"t":"res","id":"r1"}`},
		{`{"t":"res","id":"r1"}`, `{"t":"res","id":"r1"}`},
	}
	for _, testCase := range cases {
		t.Run(testCase.raw, func(t *testing.T) {
			wire, _, err := Scan([]byte(testCase.raw))
			if err != nil {
				t.Fatalf("Scan: %v", err)
			}
			stripped, err := wire.WithoutDeviceID()
			if err != nil {
				t.Fatalf("WithoutDeviceID: %v", err)
			}
			if got := string(stripped.Bytes()); got != testCase.want {
				t.Fatalf("结果 = %s，期望 %s", got, testCase.want)
			}
			var value map[string]any
			if err := json.Unmarshal(stripped.Bytes(), &value); err != nil {
				t.Fatalf("结果不是合法 JSON：%v", err)
			}
			if _, leaked := value["deviceId"]; leaked {
				t.Fatal("deviceId 没摘掉")
			}
		})
	}
}

// TestDuplicateDeviceIDFallsBack：重复键必须退回全量解析，否则就地删除只去掉第一个，
// 第二个内部键会随帧到达手机（M2 的 map 路径是"最后一个生效、整键删除"）。
func TestDuplicateDeviceIDFallsBack(t *testing.T) {
	wire, _, err := Scan([]byte(`{"t":"res","id":"r1","deviceId":"dev_a","deviceId":"dev_b"}`))
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if _, err := wire.WithoutDeviceID(); !errors.Is(err, errWireFallback) {
		t.Fatalf("重复 deviceId 应退回全量解析，得到 %v", err)
	}
	// 兜底路径（map）的行为：最后一个生效、整键删除。
	frame, _, err := Parse([]byte(`{"t":"res","id":"r1","deviceId":"dev_a","deviceId":"dev_b"}`))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	stripped := WithoutDeviceID(frame)
	if _, leaked := stripped["deviceId"]; leaked {
		t.Fatal("兜底路径没把 deviceId 摘干净")
	}
}

// TestWireStaysConsistentAfterMutation：就地改写会移动字节，改写之后的 Wire
// 必须仍然能正确读出类型（否则背压分流会把 res 当成控制帧）。
func TestWireStaysConsistentAfterMutation(t *testing.T) {
	// deviceId 放在最前面：删除它会把后面的字节整体左移，最容易暴露失效的切片。
	wire, _, err := Scan([]byte(`{"deviceId":"dev_7","t":"res","id":"r1","value":{"text":"xxxx"}}`))
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if !wire.Is("res") {
		t.Fatalf("改写前 Type = %q", wire.Type())
	}
	stripped, err := wire.WithoutDeviceID()
	if err != nil {
		t.Fatalf("WithoutDeviceID: %v", err)
	}
	if !stripped.Is("res") {
		t.Fatalf("改写后 Type = %q，期望 res", stripped.Type())
	}
	if !IsStreamingKind(stripped.Kind()) {
		t.Fatal("改写后不再被判定为流式帧")
	}
	decoded, err := stripped.Decode()
	if err != nil {
		t.Fatalf("Decode: %v", err)
	}
	value, ok := decoded["value"].(map[string]any)
	if !ok || value["text"] != "xxxx" {
		t.Fatalf("改写后 value = %v", decoded["value"])
	}

	// 追加方向同理：就地追加之后类型仍然要读得对。
	stamped, err := stripped.WithDeviceIDMember(DeviceIDMember("dev_8"))
	if err != nil {
		t.Fatalf("WithDeviceIDMember: %v", err)
	}
	if !stamped.Is("res") || stamped.FieldText("deviceId") != "dev_8" {
		t.Fatalf("追加后 Type = %q deviceId = %q", stamped.Type(), stamped.FieldText("deviceId"))
	}
}

func TestBufferPoolReuseAndOwnership(t *testing.T) {
	pool := NewBufferPool()
	first := pool.Get()
	if pool.Outstanding() != 1 {
		t.Fatalf("Outstanding = %d", pool.Outstanding())
	}
	first.SetBytes(append(first.Bytes(), `{"t":"ping"}`...))
	first.Release()
	first.Release() // 重复归还必须安全
	if pool.Outstanding() != 0 {
		t.Fatalf("重复 Release 之后 Outstanding = %d", pool.Outstanding())
	}
	second := pool.Get()
	if got := cap(second.Bytes()); got < initialBufferCapacity {
		t.Fatalf("复用的缓冲容量 = %d", got)
	}
	second.Release()

	// 大帧不回池：否则一张 32 MiB 的图片会常驻内存。
	large := pool.Get()
	large.SetBytes(make([]byte, maxPooledCapacity+1))
	large.Release()
	again := pool.Get()
	if cap(again.Bytes()) > maxPooledCapacity {
		t.Fatalf("大缓冲被复用了：cap = %d", cap(again.Bytes()))
	}
	again.Release()
	if pool.Outstanding() != 0 {
		t.Fatalf("Outstanding = %d", pool.Outstanding())
	}
}

// TestStreamingKindMatchesIsStreaming 钉住两条口径一致（背压分流依赖它）。
func TestStreamingKindMatchesIsStreaming(t *testing.T) {
	for _, kind := range []string{"res", "item", "req", "end", "hostStatus", ""} {
		if got, want := IsStreamingKind([]byte(kind)), IsStreaming(kind); got != want {
			t.Fatalf("IsStreamingKind(%q) = %v，IsStreaming = %v", kind, got, want)
		}
	}
}

func sameJSON(t *testing.T, left, right Frame) bool {
	t.Helper()
	leftJSON, err := json.Marshal(map[string]any(left))
	if err != nil {
		t.Fatalf("编码左值：%v", err)
	}
	rightJSON, err := json.Marshal(map[string]any(right))
	if err != nil {
		t.Fatalf("编码右值：%v", err)
	}
	return string(leftJSON) == string(rightJSON)
}

// TestIsHelloAcceptsTheEscapedSlash 钉住真实设备线上的写法：iOS 的 JSONEncoder
// 把 `_link/hello` 写成 `_link\/hello`。按原始字节比会漏掉每一条真实握手，
// 中转因此记不到手机构建号（2026-10-29 实测）。
func TestIsHelloAcceptsTheEscapedSlash(t *testing.T) {
	escaped := testWire(t, `{"t":"req","id":"h1","method":"_link\/hello","args":{}}`)
	if !escaped.IsHello() {
		t.Fatal("带转义的 _link\\/hello 应被认成握手")
	}
	plain := testWire(t, `{"t":"req","id":"h2","method":"_link/hello","args":{}}`)
	if !plain.IsHello() {
		t.Fatal("不转义的 _link/hello 也应被认成握手")
	}
	other := testWire(t, `{"t":"req","id":"h3","method":"_link/other","args":{}}`)
	if other.IsHello() {
		t.Fatal("别的方法不该认成握手")
	}
}

// testWire 把一段原始 JSON 扫成 Wire；坏帧直接失败。
func testWire(t *testing.T, raw string) Wire {
	t.Helper()
	wire, damage, err := Scan([]byte(raw))
	if err != nil {
		t.Fatalf("Scan(%s): %v", raw, err)
	}
	if damage != nil {
		t.Fatalf("用例里的帧不该带损伤：%s", raw)
	}
	return wire
}
