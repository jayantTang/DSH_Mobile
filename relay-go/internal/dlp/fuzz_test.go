package dlp

import (
	"errors"
	"reflect"
	"testing"
)

// fuzzScanSeeds 是 FuzzScan 的种子：现有对拍表 + 边界形状。
//
// 种子直接沿用 TestWireMatchesParse 的那张表（它是"两条出口同口径"的既有证明），
// 再补上转义键、重复键、空对象、非对象、非法 UTF-8 与 32 层嵌套附近的值。
// 种子越接近真实帧，fuzz 才越可能在 30 秒里走到深层分支。
var fuzzScanSeeds = []string{
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
	// 转义键：解码后就是 relay 读取的键名，扫描器不能当成"没有这个键"。
	`{"\u0074":"req","id":"r1","method":"m"}`,
	`{"t":"req","\u0069d":"r1","method":"m"}`,
	`{"t":"res","\u0064eviceId":"dev_7"}`,
	// 重复键：map 语义是"最后一个生效"，逐字节扫描看到的是第一个。
	`{"t":"req","t":"res"}`,
	`{"t":"req","id":"r1","id":"r2"}`,
	`{"t":"res","deviceId":"dev_a","deviceId":"dev_b"}`,
	// 边界形状。
	`{}`,
	`[]`,
	`null`,
	`123`,
	`"text"`,
	`{"t":""}`,
	`{"t":5}`,
	`{"t":"req"} trailing`,
	`{"t":"req",}`,
	`not json`,
	"{\"t\":\"req\",\"x\":\"\xff\"}",
	`{"t":"req","a":{"b":{"c":{"d":{"e":{"f":{"g":{"h":{"i":{"j":{}}}}}}}}}}}`,
	`{"t":"res","value":"` + repeatByte('x', 4096) + `"}`,
}

// repeatByte 只用于种子构造：拼一段重复字节，不需要可读性。
func repeatByte(value byte, count int) string {
	out := make([]byte, count)
	for index := range out {
		out[index] = value
	}
	return string(out)
}

// FuzzScan 证明两条出口对**同一份字节**给出同样的答案。
//
// "同样的答案"按运维与协议契约拆成六项，任何一项不一致都算 bug：
//  1. 成功/失败判定；
//  2. 失败时的错误类型（必须是 ErrInvalidFrame）与文案（原样进 protocol/bad-frame）；
//  3. Type（路由分流靠它）；
//  4. Decode 的完整结果（兜底路径与 map 语义）；
//  5. relay 读取的关键字段（id / deviceId / method / agentId / endpoint）与 Has；
//  6. 落单代理项的诊断（监控与告警的唯一线索）。
//
// 只比"不 panic"没有意义：两条出口分叉时，同一条帧会因为 `t` 的位置或键名转义
// 走到不同设备、或被结构校验误拒，那才是这次 fuzz 要找的东西。
func FuzzScan(f *testing.F) {
	for _, seed := range fuzzScanSeeds {
		f.Add([]byte(seed))
	}
	f.Fuzz(func(t *testing.T, raw []byte) {
		checkScanMatchesParse(t, raw)
	})
}

// checkScanMatchesParse 是 FuzzScan 的唯一断言体；表驱动用例也复用它。
//
// 单独抽出来是为了让"修复前失败的那条输入"能用普通测试复现，而不是只能靠
// `go test -fuzz` 的语料目录。
func checkScanMatchesParse(t *testing.T, raw []byte) {
	t.Helper()
	frame, parseDamage, parseErr := Parse(raw)
	wire, scanDamage, scanErr := Scan(raw)

	if (parseErr != nil) != (scanErr != nil) {
		t.Fatalf("Parse/Scan 判定不一致：Parse=%v Scan=%v\n输入：%q", parseErr, scanErr, raw)
	}
	if parseErr != nil {
		if !errors.Is(scanErr, ErrInvalidFrame) {
			t.Fatalf("Scan 错误类型 = %v，期望 ErrInvalidFrame\n输入：%q", scanErr, raw)
		}
		if parseErr.Error() != scanErr.Error() {
			t.Fatalf("错误文案不一致：Parse=%q Scan=%q\n输入：%q", parseErr, scanErr, raw)
		}
		return
	}

	if !reflect.DeepEqual(parseDamage, scanDamage) {
		t.Fatalf("代理项诊断不一致：Parse=%+v Scan=%+v\n输入：%q", parseDamage, scanDamage, raw)
	}
	if got, want := wire.Type(), frame.Type(); got != want {
		t.Fatalf("Type = %q，期望 %q\n输入：%q", got, want, raw)
	}
	if !wire.Is(frame.Type()) {
		t.Fatalf("Is(%q) = false\n输入：%q", frame.Type(), raw)
	}
	decoded, err := wire.Decode()
	if err != nil {
		t.Fatalf("Decode：%v\n输入：%q", err, raw)
	}
	if !reflect.DeepEqual(decoded, frame) {
		t.Fatalf("Decode 结果与 Parse 不同：%v vs %v\n输入：%q", decoded, frame, raw)
	}

	// 关键字段：relay 的路由与结构校验只读这一组。
	for _, key := range []string{"t", "id", "deviceId", "method", "endpoint", "agentId"} {
		value, isString := frame[key].(string)
		if !isString {
			if got := wire.Field(key); got != nil {
				t.Fatalf("Field(%q) = %q，期望 nil\n输入：%q", key, got, raw)
			}
			if got := wire.FieldText(key); got != "" {
				t.Fatalf("FieldText(%q) = %q，期望空串\n输入：%q", key, got, raw)
			}
			continue
		}
		if got := wire.FieldText(key); got != value {
			t.Fatalf("FieldText(%q) = %q，期望 %q\n输入：%q", key, got, value, raw)
		}
	}
	// Has 对帧里出现的每个键都必须为真；不存在的键必须为假（防止扫描器凭空造键）。
	for key := range frame {
		if !wire.Has(key) {
			t.Fatalf("Has(%q) = false，但 Parse 里有这个键\n输入：%q", key, raw)
		}
	}
	for _, key := range []string{"id", "deviceId", "method", "endpoint", "agentId", "value", "info", "args"} {
		if _, present := frame[key]; !present && wire.Has(key) {
			t.Fatalf("Has(%q) = true，但 Parse 里没有这个键\n输入：%q", key, raw)
		}
	}

	// 结构校验也走同一套字段口径：两条出口对同一帧的"能不能收"必须一致。
	// 兜底路径的等价形态是 `Wire{frame: frame}`（见 dlp_test.go 的同一写法）。
	mapped := Wire{frame: frame}
	if got, want := ValidateFromDevice(wire), ValidateFromDevice(mapped); got != want {
		t.Fatalf("ValidateFromDevice = %q，期望 %q\n输入：%q", got, want, raw)
	}
	if got, want := ValidateFromAgent(wire), ValidateFromAgent(mapped); got != want {
		t.Fatalf("ValidateFromAgent = %q，期望 %q\n输入：%q", got, want, raw)
	}
}

// TestScanMatchesParseOnPathologicalKeys 是 fuzz 找到的两类真实分叉的回归用例：
//
//   - 转义键（`"\u0069d"` 解码后就是 `id`）：字节扫描按原样比较，看不见它，
//     于是 `req` 被判定为"缺 id"、`res` 的 deviceId 读成空；
//   - 重复键：map 语义最后一个生效，字节扫描取第一个。
//
// 清单与 TestWireMatchesParse 同源，但这里每条都要求 fuzz 断言体通过；修复前
// 前六条会失败（见报告里的失败输出）。
func TestScanMatchesParseOnPathologicalKeys(t *testing.T) {
	raws := []string{
		`{"\u0074":"req","id":"r1","method":"m"}`,
		`{"t":"req","\u0069d":"r1","method":"m"}`,
		`{"t":"req","id":"r1","\u006dethod":"m"}`,
		`{"t":"open","\u0065ndpoint":"/files/x"}`,
		`{"t":"res","\u0064eviceId":"dev_7"}`,
		// 字面键被剥离后，转义的那个仍在原始字节里：两条出口必须都按 map 语义
		// 认为"没有 deviceId"，否则设备侧会解码出一个 Python 不会给出的内部键。
		`{"t":"res","deviceId":"dev_b","\u0064eviceId":"dev_c"}`,
		`{"t":"hello","\u0061gentId":"agt_x"}`,
		`{"t":"req","t":"res"}`,
		`{"t":"res","t":5}`,
		`{"t":"req","id":"r1","id":"r2"}`,
		`{"t":"res","deviceId":"dev_a","deviceId":"dev_b"}`,
		`{"t":"req","method":"m","method":7}`,
		`{"t":"res","text":"a","text":"b"}`,
	}
	for _, raw := range raws {
		t.Run(raw, func(t *testing.T) {
			checkScanMatchesParse(t, []byte(raw))
		})
	}
}

// TestScanFallsBackOnPathologicalKeys 钉住修复方向：这些形状必须退回全量解析
// （Wire.frame 非空），而不是在字节扫描结果上继续走。
//
// 这不只是"实现细节"：WithDeviceIDMember / WithoutDeviceID 在兜底路径上按 map
// 语义处理；在字节路径上则必须保证键名没有转义、没有重复，否则就地剥离之后
// 帧里会残留一个解码后重复的内部键（设备侧因此看到 Python 不会给出的 deviceId）。
func TestScanFallsBackOnPathologicalKeys(t *testing.T) {
	cases := []struct {
		raw    string
		reason string
	}{
		{`{"t":"req","\u0069d":"r1","method":"m"}`, "转义键"},
		{`{"t":"req","id":"r1","id":"r2"}`, "重复键"},
		{`{"t":"res","deviceId":"dev_a","deviceId":"dev_b"}`, "重复 deviceId"},
		{`{"t":"req","x":1,"x":2}`, "重复的未知键"},
	}
	for _, testCase := range cases {
		t.Run(testCase.reason, func(t *testing.T) {
			wire, _, err := Scan([]byte(testCase.raw))
			if err != nil {
				t.Fatalf("Scan: %v", err)
			}
			if wire.frame == nil {
				t.Fatalf("%s 必须退回全量解析，实际走了字节扫描", testCase.reason)
			}
		})
	}
	// 正常帧不能被拖进兜底路径：否则"零解析转发"名存实亡。
	for _, raw := range []string{
		`{"t":"req","id":"r1","method":"m"}`,
		`{"t":"item","id":"i1","text":"中文 😀 \u4e2d"}`,
		`{ "t" : "ping" , "ts" : 1761234567890123 }`,
	} {
		wire, _, err := Scan([]byte(raw))
		if err != nil {
			t.Fatalf("Scan(%q): %v", raw, err)
		}
		if wire.frame != nil {
			t.Fatalf("正常帧 %q 不该退回全量解析", raw)
		}
	}
}
