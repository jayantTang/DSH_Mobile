package dlp

import (
	"strings"
	"testing"
)

// TestFieldPathReadsNestedIDs 钉住统计键的读取口径：只认对象套对象、最后一项是
// 字符串；缺层、类型不对、带转义都返回 nil，由调用方按“未计数”处理。
func TestFieldPathReadsNestedIDs(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		path []string
		want string
	}{
		{
			name: "prompt requestId",
			raw:  `{"t":"req","id":"u1","method":"session/prompt","args":{"request":{"requestId":"6F1D0C7A-2E4B-4D6A-9C1E-8A2B7C3D4E5F"}}}`,
			path: []string{"args", "request", "requestId"},
			want: "6F1D0C7A-2E4B-4D6A-9C1E-8A2B7C3D4E5F",
		},
		{
			name: "event result eventId",
			raw:  `{"t":"eventResult","id":"u2","result":{"clientId":"c1","eventId":"evt_123","outcome":{"kind":"result"}}}`,
			path: []string{"result", "eventId"},
			want: "evt_123",
		},
		{
			name: "missing args",
			raw:  `{"t":"req","id":"u1","method":"session/prompt"}`,
			path: []string{"args", "request", "requestId"},
		},
		{
			name: "args is not object",
			raw:  `{"t":"req","id":"u1","method":"session/prompt","args":"x"}`,
			path: []string{"args", "request", "requestId"},
		},
		{
			name: "requestId is not string",
			raw:  `{"t":"req","id":"u1","method":"session/prompt","args":{"request":{"requestId":5}}}`,
			path: []string{"args", "request", "requestId"},
		},
		{
			name: "escaped requestId is not guessed",
			raw:  `{"t":"req","id":"u1","method":"session/prompt","args":{"request":{"requestId":"a\\/b"}}}`,
			path: []string{"args", "request", "requestId"},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			wire, _, err := Scan([]byte(test.raw))
			if err != nil {
				t.Fatalf("Scan: %v", err)
			}
			if got := string(wire.FieldPath(test.path...)); got != test.want {
				t.Fatalf("FieldPath = %q，期望 %q", got, test.want)
			}
		})
	}
}

// TestFieldEqualsHandlesSwiftSlashEscaping：Swift JSONEncoder 会把 `/` 写成 `\/`，
// 真实设备的 method 是 `session\/prompt`；按原始字节比较会把整条路径漏掉。
func TestFieldEqualsHandlesSwiftSlashEscaping(t *testing.T) {
	wire, _, err := Scan([]byte(`{"t":"req","id":"u1","method":"session\/prompt"}`))
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if !wire.FieldEquals("method", "session/prompt") {
		t.Fatal("转义斜杠的 method 应等于 session/prompt")
	}
	if wire.FieldEquals("method", "session/list") {
		t.Fatal("错误方法不应相等")
	}
}

// TestFieldPathWorksWhenContentComesFirst 钉住嵌套扫描不依赖字段顺序：
// requestId 放在大段正文之后也必须能取到，且不退回全量解析。
func TestFieldPathWorksWhenContentComesFirst(t *testing.T) {
	content := strings.Repeat("长正文", 2048)
	raw := `{"t":"req","id":"u1","method":"session/prompt","args":{"request":{"content":[{"text":"` +
		content + `"}],"requestId":"late-id"}}}`
	wire, _, err := Scan([]byte(raw))
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if got := string(wire.FieldPath("args", "request", "requestId")); got != "late-id" {
		t.Fatalf("FieldPath = %q", got)
	}
}

// TestFieldPathDoesNotAllocate 是热路径断言：已扫描的帧取嵌套键不产生堆分配。
func TestFieldPathDoesNotAllocate(t *testing.T) {
	raw := []byte(`{"t":"req","id":"u1","method":"session/prompt","args":{"request":{"requestId":"6F1D0C7A-2E4B-4D6A-9C1E-8A2B7C3D4E5F","content":[{"text":"` +
		strings.Repeat("x", 4096) + `"}]}}}`)
	wire, _, err := Scan(raw)
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	allocs := testing.AllocsPerRun(200, func() {
		if got := wire.FieldPath("args", "request", "requestId"); len(got) == 0 {
			t.Fatal("取不到 requestId")
		}
		if !wire.FieldEquals("method", "session/prompt") {
			t.Fatal("method 比较失败")
		}
	})
	if allocs != 0 {
		t.Fatalf("取键产生了 %.2f 次分配/次", allocs)
	}
}

// TestFieldPathDecodedWire 覆盖全量解析的帧（形状超出扫描器时才走这里）。
func TestFieldPathDecodedWire(t *testing.T) {
	frame, _, err := Parse([]byte(`{"t":"eventResult","id":"u2","result":{"eventId":"evt_9"}}`))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	wire := Wire{raw: []byte(`{}`), frame: frame}
	if got := string(wire.FieldPath("result", "eventId")); got != "evt_9" {
		t.Fatalf("解码帧 FieldPath = %q", got)
	}
	if got := wire.FieldPath("result", "missing"); got != nil {
		t.Fatalf("缺失路径 = %q，期望 nil", got)
	}
}
