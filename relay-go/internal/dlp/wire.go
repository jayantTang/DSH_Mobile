package dlp

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"unicode/utf8"
)

// Wire 是转发路径上的一帧：原始 JSON 字节 + 一个可选的所有者缓冲。
//
// 中转不需要理解帧的语义，只需要回答四个问题：是什么帧（`t`）、发往哪台设备
// （`deviceId`）、有没有 `id`、是不是 `_link/hello`。M2 的做法是把整帧解成
// `map[string]any`、加/删一个键、再重新编码——一帧 48 字节却要付 1.8 KiB 分配与
// 两次 JSON 编解码（M2.5 的 pprof 证据）。这里改成在原始字节上做字段扫描与就地
// 改写：热路径零解析、零复制。
//
// 两条出口必须给出**同样的答案**，所以形状超出扫描器能力时（转义键、极端嵌套）
// Scan 会退回全量解析，并把 Frame 挂在这里；两类访问器共用同一组口径，差分测试
// 见 wire_test.go 的 TestWireMatchesParse。
//
// 所有权：从读循环拿到的 Wire 持有 Buffer；一路转发到写循环后由写循环归还。
// 丢弃一帧时必须调用 Release——否则池里的缓冲会被 GC 收走（不泄漏，但失去复用）。
type Wire struct {
	raw []byte
	// kind 是顶层 `t` 的原始字节（零拷贝）；扫描器不认识形状时为空，改由 frame 提供。
	kind []byte
	buf  *Buffer
	// frame 非空表示这一帧走了全量解析（不常见形状，或调用方要语义）。
	frame Frame
}

// errWireFallback 表示"这个形状扫描器不处理，请走全量解析"。
var errWireFallback = errors.New("dlp: frame shape needs full decode")

// Scan 校验一帧并把转发需要的字段留在原始字节上。
//
// 校验口径与 Parse 完全一致：合法 UTF-8、不超过 MaxFrameBytes、是 JSON 对象、
// `t` 是非空字符串。形状不认识时退回 Parse，因此**不会**比 M2 更严格。
//
// "形状不认识"除了嵌套过深，还包括两种"字节扫描与 map 语义对不上"的输入：
// 顶层键名带转义（`"\u0069d"` 解码后就是 `id`）与顶层重复键（map 最后一个生效，
// 字节扫描看到第一个）。这两种输入必须退回全量解析：否则同一帧会因为键名写法
// 不同而被结构校验误拒、或按不同的 deviceId/类型路由。转义键还会让就地剥离后的
// 帧里残留一个解码后重复的内部键——那是 Python 版不会交给设备的东西
// （差分 fuzz 与回归用例见 fuzz_test.go）。
func Scan(raw []byte) (Wire, *SurrogateDamage, error) {
	if !utf8.Valid(raw) {
		return Wire{}, nil, &FrameError{Reason: "frame is not valid UTF-8"}
	}
	if len(raw) > MaxFrameBytes {
		return Wire{}, nil, &FrameError{Reason: fmt.Sprintf("frame exceeds %d bytes", MaxFrameBytes)}
	}
	// 与 Python 的 prepare_outbound 同策略：落单代理项在**转发前**换成 U+FFFD。
	// Go 的 encoding/json 只会在全量 Parse 时修复；快路径若不修，原样转发
	// `\ud83d` 这类非法转义，iOS 解码失败后会丢 socket 重连。
	damage := RepairSurrogates(raw)
	// json.Valid 是完整的结构校验（一次扫描、零分配）。有了它，下面的字段扫描
	// 才能提前退出：合法性已经由这里判定过，不需要再看后半段。
	if json.Valid(raw) {
		if kind, ok := scanFastPath(raw); ok {
			wire := Wire{raw: raw, kind: kind}
			return wire, damage, nil
		}
	}
	// 退回全量解析：这里同时负责"不是 JSON / 不是对象 / 缺 t"三种错误文案。
	frame, parsedDamage, err := Parse(raw)
	if err != nil {
		return Wire{}, nil, err
	}
	if damage == nil {
		damage = parsedDamage
	}
	return Wire{raw: raw, frame: frame}, damage, nil
}

// Bytes 是原始字节（未解码）。
func (w Wire) Bytes() []byte { return w.raw }

// Buffer 是这一帧的缓冲所有者；中继自己拼的帧为 nil。
func (w Wire) Buffer() *Buffer { return w.buf }

// WithBuffer 把读缓冲的所有权交给这一帧（读循环读完就调用）。
func (w Wire) WithBuffer(buffer *Buffer) Wire {
	w.buf = buffer
	if buffer != nil {
		w.raw = buffer.Bytes()
	}
	return w
}

// Release 归还这一帧占用的缓冲；可重复调用。
func (w Wire) Release() {
	if w.buf != nil {
		w.buf.Release()
	}
}

// decoded 返回全量解析结果（必要时解析并把结果缓存在副本里）。
//
// Wire 是值类型：调用方拿到的缓存不会回写到原值，所以这里只保证"同一次调用里
// 只解析一次"，不做跨调用缓存。需要多次读语义的路径自己 Decode 一次。
func (w Wire) decoded() (Frame, error) {
	if w.frame != nil {
		return w.frame, nil
	}
	frame, _, err := Parse(w.raw)
	if err != nil {
		return nil, err
	}
	return frame, nil
}

// Decode 把整帧解析成 Frame。控制帧与需要 args/info/ts 的路径用它。
func (w Wire) Decode() (Frame, error) { return w.decoded() }

// Is 判断帧类型是否是 kind；零分配，热路径用它而不是 Type。
func (w Wire) Is(kind string) bool {
	if w.frame != nil {
		return w.frame.Type() == kind
	}
	return sameBytes(w.kind, kind)
}

// Kind 返回 `t` 的原始字节（零拷贝）；形状不认识时为空。
func (w Wire) Kind() []byte {
	if w.frame != nil {
		return []byte(w.frame.Type())
	}
	return w.kind
}

// Type 返回帧类型；形状不认识时为空串。
func (w Wire) Type() string {
	if w.frame != nil {
		return w.frame.Type()
	}
	return textOf(w.kind)
}

// Field 返回顶层字符串字段的值；缺失或不是字符串时返回 nil。
//
// 返回值可能是转义形态（含反斜杠）。要拿"解码后的字符串"请用 FieldText。
func (w Wire) Field(key string) []byte {
	if w.frame != nil {
		value, ok := w.frame[key].(string)
		if !ok {
			return nil
		}
		return []byte(value)
	}
	value, ok := w.member(key)
	if !ok || value.kind != jsonString {
		return nil
	}
	return value.content()
}

// FieldText 返回顶层字符串字段的解码值；缺失或不是字符串时返回空串。
//
// 只有值里真的带转义时才走 json.Unmarshal，普通帧零分配。
func (w Wire) FieldText(key string) string {
	if w.frame != nil {
		value, _ := w.frame[key].(string)
		return value
	}
	value, ok := w.member(key)
	if !ok || value.kind != jsonString {
		return ""
	}
	return textOf(value.content())
}

// FieldEquals 比较顶层字符串字段与期望值；缺失或不是字符串时为 false。
//
// 无转义时走原始字节，热路径零分配；有转义时用 FieldText 解码后再比。iOS 的
// JSONEncoder 会把 `session/prompt` 写成 `session\/prompt`，按原始字节比较会把
// 真实设备的请求全部漏掉——这一条是真实线上路径，不是理论边角。
func (w Wire) FieldEquals(key, value string) bool {
	raw := w.Field(key)
	if bytes.IndexByte(raw, '\\') < 0 {
		return sameBytes(raw, value)
	}
	return w.FieldText(key) == value
}

// FieldPath 读取嵌套对象里的字符串字段（例如 args.request.requestId）。
//
// 只接受“每一层都是对象、最后一项是字符串”的形状；任一层缺失、类型不对或
// 最后的值带转义时返回 nil。返回的是原始字节切片，不复制、不分配；调用方必须
// 在帧缓冲归还前使用它（统计在入队前算指纹，满足这个前提）。
//
// 带转义的字符串不返回原文，是因为同一 ID 的转义写法与普通写法字节不同，
// 直接比较会把重试当成两个键；调用方拿到 nil 时按“未计数”处理，不做猜测。
func (w Wire) FieldPath(path ...string) []byte {
	if len(path) == 0 {
		return nil
	}
	if w.frame != nil {
		var current any = map[string]any(w.frame)
		for index, key := range path {
			object, ok := current.(map[string]any)
			if !ok {
				return nil
			}
			value, found := object[key]
			if !found {
				return nil
			}
			if index == len(path)-1 {
				text, ok := value.(string)
				if !ok {
					return nil
				}
				return []byte(text)
			}
			current = value
		}
		return nil
	}

	raw := w.raw
	for index, key := range path {
		target, found, ok := findMember(raw, key)
		if !ok || !found {
			return nil
		}
		if index == len(path)-1 {
			if target.kind != jsonString {
				return nil
			}
			content := target.content()
			if bytes.IndexByte(content, '\\') >= 0 {
				return nil
			}
			return content
		}
		if len(target.value) == 0 || target.value[0] != '{' {
			return nil
		}
		raw = target.value
	}
	return nil
}

// Has 判断顶层是否存在该键（值类型不限）。
func (w Wire) Has(key string) bool {
	if w.frame != nil {
		_, ok := w.frame[key]
		return ok
	}
	_, ok := w.member(key)
	return ok
}

// WithDeviceIDMember 把 `"deviceId":"<id>"` 写进顶层：没有该键时就地追加。
//
// 已有 deviceId 时返回错误，由调用方走全量解析（设备不该自己带这个键，那条路径
// 一年也走不到一次；为它写一套就地替换不值得）。
//
// 返回值可能指向同一块底层数组（就地追加），调用方不得再使用旧的 raw。
func (w Wire) WithDeviceIDMember(member []byte) (Wire, error) {
	if w.frame != nil {
		return Wire{}, errWireFallback
	}
	if _, hasExisting, ok := findMember(w.raw, "deviceId"); !ok || hasExisting {
		return Wire{}, errWireFallback
	}
	// '}' 是最后一个非空白字节；它之后可能还有空白（合法 JSON）。
	end := len(w.raw)
	for end > 0 && isJSONSpace(w.raw[end-1]) {
		end--
	}
	if end == 0 || w.raw[end-1] != '}' {
		return Wire{}, errWireFallback
	}
	closeIndex := end - 1
	// 空对象 `{}` 不要前导逗号。
	empty := true
	for index := 0; index < closeIndex; index++ {
		if !isJSONSpace(w.raw[index]) {
			empty = false
			break
		}
	}
	comma := 0
	if !empty {
		comma = 1
	}
	need := comma + len(member)
	out := w.raw
	if cap(out) < len(out)+need {
		grown := make([]byte, len(out), growCapacity(len(out)+need))
		copy(grown, out)
		out = grown
	}
	out = out[:len(out)+need]
	// 先把 '}' 及其后的尾巴整体右移，再在腾出的位置写成员。
	copy(out[closeIndex+need:], out[closeIndex:])
	position := closeIndex
	if comma == 1 {
		out[position] = ','
		position++
	}
	copy(out[position:], member)
	stamped := Wire{raw: out, buf: w.buf}
	stamped.refreshKind()
	return stamped, nil
}

// WithoutDeviceID 摘掉顶层 deviceId（就地）；没有该键时原样返回。
func (w Wire) WithoutDeviceID() (Wire, error) {
	if w.frame != nil {
		return Wire{}, errWireFallback
	}
	target, found, ok := findMember(w.raw, "deviceId")
	if !ok {
		return Wire{}, errWireFallback
	}
	if !found {
		return w, nil
	}
	// 优先连后面的逗号一起删；它是最后一个成员时改删前面的逗号。
	after := skipJSONSpace(w.raw, target.valEnd)
	if after < len(w.raw) && w.raw[after] == ',' {
		removed := after + 1 - target.keyStart
		copy(w.raw[target.keyStart:], w.raw[after+1:])
		w.raw = w.raw[:len(w.raw)-removed]
		return w.finishStripping()
	}
	before := target.keyStart - 1
	for before >= 0 && isJSONSpace(w.raw[before]) {
		before--
	}
	if before < 0 {
		return Wire{}, errWireFallback
	}
	switch w.raw[before] {
	case ',':
		removed := target.valEnd - before
		copy(w.raw[before:], w.raw[target.valEnd:])
		w.raw = w.raw[:len(w.raw)-removed]
	case '{':
		// `{"deviceId":"x"}` → `{}`
		removed := target.valEnd - target.keyStart
		copy(w.raw[target.keyStart:], w.raw[target.valEnd:])
		w.raw = w.raw[:len(w.raw)-removed]
	default:
		return Wire{}, errWireFallback
	}
	return w.finishStripping()
}

// finishStripping 是一次就地删除之后的收尾：查重复键、刷新缓存的类型。
//
// 重复键（`"deviceId"` 出现两次）是合法但病态的 JSON：map 路径按"最后一个生效
// 且整键删除"处理。就地路径只删第一个，会漏一个内部键给设备，所以这里退回全量
// 解析——宁可慢一次，也不能把中转内部键漏到手机上。
func (w Wire) finishStripping() (Wire, error) {
	if _, again, ok := findMember(w.raw, "deviceId"); !ok || again {
		return Wire{}, errWireFallback
	}
	w.refreshKind()
	return w, nil
}

// refreshKind 就地改写之后重新定位 `t`：改写会移动字节，缓存的切片必须跟着更新，
// 否则 Wire 会"类型读出来是正文"（这个 bug 在 TestWireStaysConsistentAfterMutation
// 里钉住）。
func (w *Wire) refreshKind() {
	if kind, ok := scanType(w.raw); ok {
		w.kind = kind
		return
	}
	w.kind = nil
}

// DeviceIDMember 构造 `"deviceId":"<id>"`（不含前导逗号）。
//
// 每台设备只需要算一次（AttachDevice 时），转发路径直接复用，不每帧编码。
func DeviceIDMember(deviceID string) []byte {
	quoted, err := json.Marshal(deviceID)
	if err != nil {
		// 字符串编码不会失败；真失败时给一个空值，路由层还有 deviceId 校验兜底。
		quoted = []byte(`""`)
	}
	member := make([]byte, 0, len(quoted)+13)
	member = append(member, `"deviceId":`...)
	member = append(member, quoted...)
	return member
}

// ── 结构校验 ────────────────────────────────────────────────────────────────

// ValidateFromDevice 检查设备帧的结构，返回错误说明；空串表示可用。
//
// 口径与 dlp.validate_from_device 一致：缺 id / 缺 method / 缺 endpoint。
// method/endpoint 必须是**字符串**（数字 5 不算有 method），与 M2 的 map 判定一致。
func ValidateFromDevice(w Wire) string {
	if w.kind == nil && w.frame == nil {
		return ""
	}
	kind := w.Kind()
	if len(kind) == 0 {
		return ""
	}
	if _, isDeviceFrame := deviceToAgent[string(kind)]; isDeviceFrame {
		if _, needsID := idFrames[string(kind)]; needsID && w.Field("id") == nil {
			return string(kind) + ": missing `id`"
		}
	}
	switch {
	case sameBytes(kind, "req"):
		if w.Field("method") == nil {
			return "req: missing `method`"
		}
	case sameBytes(kind, "open"):
		if w.Field("endpoint") == nil {
			return "open: missing `endpoint`"
		}
	}
	return ""
}

// ValidateFromAgent 检查电脑帧的结构，返回错误说明；空串表示可用。
func ValidateFromAgent(w Wire) string {
	kind := w.Kind()
	if len(kind) == 0 {
		return ""
	}
	if _, isDeviceFrame := agentToDevice[string(kind)]; !isDeviceFrame {
		return ""
	}
	if _, needsID := idFrames[string(kind)]; needsID && w.Field("id") == nil {
		return string(kind) + ": missing `id`"
	}
	return ""
}

// IsAgentControlKind 判断帧类型字节是否是连接器侧控制帧（不跨到设备）。
func IsAgentControlKind(kind []byte) bool {
	_, ok := agentControl[string(kind)]
	return ok
}

// HelloMethod 是手机每条连接调一次的保留方法（连接器负责回答，中转只读参数）。
const HelloMethod = "_link/hello"

// IsHello 判断这一帧是不是 `_link/hello` 调用；零分配。
func (w Wire) IsHello() bool {
	return w.Is("req") && sameBytes(w.Field("method"), HelloMethod)
}

// IsStreamingKind 判断帧类型字节是否是流式帧（res / item）。
//
// 与 IsStreaming 同一口径，热路径传原始字节、不建字符串。
func IsStreamingKind(kind []byte) bool {
	return sameBytes(kind, "res") || sameBytes(kind, "item")
}

// ── 顶层扫描 ────────────────────────────────────────────────────────────────

// JSON 值的粗分类：只需要区分"是不是字符串"，其余按原样跳过。
const (
	jsonString = 's'
	jsonOther  = 'n'
)

// member 是一个顶层成员的原始区间。
type member struct {
	key      []byte
	value    []byte
	kind     byte
	keyStart int
	keyEnd   int
	valStart int
	valEnd   int
}

// member 返回顶层成员（形状不认识时 found=false）。
func (w Wire) member(key string) (member, bool) {
	target, found, ok := findMember(w.raw, key)
	if !ok || !found {
		return member{}, false
	}
	return target, true
}

// content 是字符串字面量的内容（去掉两侧引号）；非字符串成员返回原区间。
func (m member) content() []byte {
	if m.kind != jsonString || len(m.value) < 2 {
		return m.value
	}
	return m.value[1 : len(m.value)-1]
}

// findMember 找顶层成员；ok=false 表示形状不认识（调用方应退回全量解析）。
//
// 用直接循环而不是回调：闭包会让 member 里的切片逃逸到堆上，热路径上就是每帧
// 一次分配（实测 3 次/帧里的一次）。
func findMember(raw []byte, key string) (member, bool, bool) {
	index := skipJSONSpace(raw, 0)
	if index >= len(raw) || raw[index] != '{' {
		return member{}, false, false
	}
	index++
	for {
		index = skipJSONSpace(raw, index)
		if index >= len(raw) {
			return member{}, false, false
		}
		if raw[index] == '}' {
			return member{}, false, skipJSONSpace(raw, index+1) == len(raw)
		}
		if raw[index] != '"' {
			return member{}, false, false
		}
		keyStart := index
		keyEnd, ok := scanJSONString(raw, index)
		if !ok {
			return member{}, false, false
		}
		index = skipJSONSpace(raw, keyEnd)
		if index >= len(raw) || raw[index] != ':' {
			return member{}, false, false
		}
		index = skipJSONSpace(raw, index+1)
		valueStart := index
		kind, valueEnd, ok := scanJSONValue(raw, index)
		if !ok {
			return member{}, false, false
		}
		candidate := member{
			key:      raw[keyStart+1 : keyEnd-1],
			value:    raw[valueStart:valueEnd],
			kind:     kind,
			keyStart: keyStart,
			keyEnd:   keyEnd,
			valStart: valueStart,
			valEnd:   valueEnd,
		}
		if sameBytes(candidate.key, key) {
			return candidate, true, true
		}
		index = skipJSONSpace(raw, valueEnd)
		if index >= len(raw) {
			return member{}, false, false
		}
		switch raw[index] {
		case ',':
			index++
		case '}':
			return member{}, false, skipJSONSpace(raw, index+1) == len(raw)
		default:
			return member{}, false, false
		}
	}
}

// scanJSONString 跳过一段 JSON 字符串，返回结束引号之后的位置。
//
// 转义必须逐个校验：非法转义（`"\q"`）要让 Parse 去报 "frame is not JSON"，
// 不能在这里被当成合法字符串放过去。
func scanJSONString(raw []byte, start int) (int, bool) {
	if start >= len(raw) || raw[start] != '"' {
		return 0, false
	}
	for index := start + 1; index < len(raw); index++ {
		switch raw[index] {
		case '"':
			return index + 1, true
		case '\\':
			if index+1 >= len(raw) {
				return 0, false
			}
			index++
			switch raw[index] {
			case '"', '\\', '/', 'b', 'f', 'n', 'r', 't':
			case 'u':
				for offset := 1; offset <= 4; offset++ {
					if index+offset >= len(raw) || !isHexDigit(raw[index+offset]) {
						return 0, false
					}
				}
				index += 4
			default:
				return 0, false
			}
		}
	}
	return 0, false
}

// scanJSONValue 跳过一个 JSON 值，返回粗分类与结束位置。
func scanJSONValue(raw []byte, start int) (byte, int, bool) {
	if start >= len(raw) {
		return 0, 0, false
	}
	switch raw[start] {
	case '"':
		end, ok := scanJSONString(raw, start)
		return jsonString, end, ok
	case '{', '[':
		end, ok := scanJSONNested(raw, start)
		return jsonOther, end, ok
	case 't':
		return jsonOther, start + 4, hasLiteralAt(raw, start, "true")
	case 'f':
		return jsonOther, start + 5, hasLiteralAt(raw, start, "false")
	case 'n':
		return jsonOther, start + 4, hasLiteralAt(raw, start, "null")
	default:
		end, ok := scanJSONNumber(raw, start)
		return jsonOther, end, ok
	}
}

// scanJSONNested 跳过一段对象/数组（含嵌套与其中字符串的转义）。
//
// 栈是定长数组：它在栈上分配，扫描热路径没有分配。超过 32 层就退回全量解析
// （中转的帧里没有这种形状，真的出现也不该由扫描器负责）。
func scanJSONNested(raw []byte, start int) (int, bool) {
	var stack [32]byte
	depth := 0
	for index := start; index < len(raw); index++ {
		switch raw[index] {
		case '"':
			end, ok := scanJSONString(raw, index)
			if !ok {
				return 0, false
			}
			index = end - 1
		case '{', '[':
			if depth >= len(stack) {
				return 0, false
			}
			stack[depth] = raw[index]
			depth++
		case '}', ']':
			if depth == 0 {
				return 0, false
			}
			open := stack[depth-1]
			if (open == '{' && raw[index] != '}') || (open == '[' && raw[index] != ']') {
				return 0, false
			}
			depth--
			if depth == 0 {
				return index + 1, true
			}
		}
	}
	return 0, false
}

// scanJSONNumber 跳过一个 JSON 数字（严格按 RFC 8259 的文法）。
func scanJSONNumber(raw []byte, start int) (int, bool) {
	index := start
	if index < len(raw) && raw[index] == '-' {
		index++
	}
	if index >= len(raw) {
		return 0, false
	}
	if raw[index] == '0' {
		index++
	} else if raw[index] >= '1' && raw[index] <= '9' {
		for index < len(raw) && isDigit(raw[index]) {
			index++
		}
	} else {
		return 0, false
	}
	if index < len(raw) && raw[index] == '.' {
		index++
		if index >= len(raw) || !isDigit(raw[index]) {
			return 0, false
		}
		for index < len(raw) && isDigit(raw[index]) {
			index++
		}
	}
	if index < len(raw) && (raw[index] == 'e' || raw[index] == 'E') {
		index++
		if index < len(raw) && (raw[index] == '+' || raw[index] == '-') {
			index++
		}
		if index >= len(raw) || !isDigit(raw[index]) {
			return 0, false
		}
		for index < len(raw) && isDigit(raw[index]) {
			index++
		}
	}
	return index, true
}

// maxScannedKeys 是字节扫描愿意处理的最大顶层键数。
//
// 正常 DLP 帧不超过 10 个顶层键；超过这个数的形状不像正常流量，交给全量解析
// 比在这里做 O(k²) 的重复键比较更划算（同时把比较次数钉在上界）。
const maxScannedKeys = 32

// span 是一段字节区间（键名在 raw 里的位置），只用于栈上的重复键检测。
type span struct {
	start int
	end   int
}

// scanFastPath 在"字节扫描与 map 语义一定一致"的帧上取顶层 `t` 的内容。
//
// 相比 scanType 多做两件事：拒绝键名带转义的帧、拒绝顶层键重复的帧。两者都是
// map 与字节两种读法的分叉点（见 Scan 的注释与 fuzz_test.go 的回归用例）。
//
// 成本是一次顶层遍历：json.Valid 已经校验过语法，这里只做"键名无转义 + 无重复 +
// 找到 t"，不再校验 JSON 文法。键区间存在定长栈数组里，热路径仍然零分配。
func scanFastPath(raw []byte) ([]byte, bool) {
	index := skipJSONSpace(raw, 0)
	if index >= len(raw) || raw[index] != '{' {
		return nil, false
	}
	index = skipJSONSpace(raw, index+1)
	// 空对象没有 t；交给 Parse 给出统一错误文案。
	if index < len(raw) && raw[index] == '}' {
		return nil, false
	}
	var (
		keys  [maxScannedKeys]span
		count int
	)
	var (
		kind    []byte
		foundT  bool
		stringT bool
	)
scan:
	for {
		if index >= len(raw) || raw[index] != '"' {
			return nil, false
		}
		keyStart := index
		keyEnd, ok := scanJSONString(raw, index)
		if !ok {
			return nil, false
		}
		key := raw[keyStart+1 : keyEnd-1]
		// 键名带转义时无法用字节比较判断它解码后是不是 `t`/`id`/`deviceId`。
		if bytes.IndexByte(key, '\\') >= 0 {
			return nil, false
		}
		if count >= len(keys) {
			return nil, false
		}
		for seen := 0; seen < count; seen++ {
			if bytes.Equal(raw[keys[seen].start:keys[seen].end], key) {
				// 重复键：map 语义最后一个生效，字节扫描只能看到第一个。
				return nil, false
			}
		}
		keys[count] = span{start: keyStart + 1, end: keyEnd - 1}
		count++

		index = skipJSONSpace(raw, keyEnd)
		if index >= len(raw) || raw[index] != ':' {
			return nil, false
		}
		index = skipJSONSpace(raw, index+1)
		valueStart := index
		valueKind, valueEnd, ok := scanJSONValue(raw, index)
		if !ok {
			return nil, false
		}
		if sameBytes(key, "t") {
			kind = raw[valueStart:valueEnd]
			foundT = true
			stringT = valueKind == jsonString
		}
		index = skipJSONSpace(raw, valueEnd)
		if index >= len(raw) {
			return nil, false
		}
		switch raw[index] {
		case ',':
			index = skipJSONSpace(raw, index+1)
		case '}':
			if skipJSONSpace(raw, index+1) != len(raw) {
				return nil, false
			}
			break scan
		default:
			return nil, false
		}
	}
	if !foundT || !stringT || len(kind) < 3 {
		return nil, false
	}
	content := kind[1 : len(kind)-1]
	// t 自己带转义时按解码值比较：`\u0072eq` 与 `req` 是同一个类型，但字节不等。
	if len(content) == 0 || bytes.IndexByte(content, '\\') >= 0 {
		return nil, false
	}
	return content, true
}

// scanType 取顶层 `t` 的值（字符串内容）；ok=false 表示形状不认识。
func scanType(raw []byte) ([]byte, bool) {
	value, found, ok := findMember(raw, "t")
	if !ok || !found || value.kind != jsonString {
		return nil, false
	}
	return value.content(), true
}

// textOf 把 JSON 字符串的内容转成解码后的文本；没有转义时零分配。
func textOf(content []byte) string {
	if !bytes.ContainsRune(content, '\\') {
		return string(content)
	}
	quoted := make([]byte, 0, len(content)+2)
	quoted = append(quoted, '"')
	quoted = append(quoted, content...)
	quoted = append(quoted, '"')
	var text string
	if err := json.Unmarshal(quoted, &text); err != nil {
		return ""
	}
	return text
}

// sameBytes 比较 JSON 字段原始字节与期望值，零分配。
//
// `string(b) == s` 是编译器认得的无分配比较（不建字符串头）。
func sameBytes(raw []byte, want string) bool {
	return len(raw) == len(want) && string(raw) == want
}

func isJSONSpace(char byte) bool {
	return char == ' ' || char == '\t' || char == '\n' || char == '\r'
}

func skipJSONSpace(raw []byte, index int) int {
	for index < len(raw) && isJSONSpace(raw[index]) {
		index++
	}
	return index
}

func isDigit(char byte) bool { return char >= '0' && char <= '9' }

func isHexDigit(char byte) bool {
	return isDigit(char) || (char >= 'a' && char <= 'f') || (char >= 'A' && char <= 'F')
}

func hasLiteralAt(raw []byte, start int, literal string) bool {
	if start+len(literal) > len(raw) {
		return false
	}
	return string(raw[start:start+len(literal)]) == literal
}

// growCapacity 给出扩容后的容量：至少 need，且按翻倍走，避免逐帧追加造成 O(n²)。
func growCapacity(need int) int {
	capacity := 256
	for capacity < need {
		capacity *= 2
	}
	return capacity
}
