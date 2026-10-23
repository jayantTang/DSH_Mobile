package dlp

import (
	"bytes"
	"strconv"
	"strings"
	"unicode/utf8"
)

// UTF-16 代理项处理（Python 版 dlp.prepare_outbound 的对应物）。
//
// 2026-10-17 的生产事故：JSON 允许 `"\ud83d"` 这种**没有配对**的转义，Python 的
// json.loads 会原样交出一个落单的代理项字符，它没法按 UTF-8 编码，中转算流量的那句
// `text.encode("utf-8")` 抛 UnicodeEncodeError，整条 agent 链路被带崩，手机卡在
// "连接中"。Python 版因此在发送前显式把落单代理项换成 U+FFFD。
//
// **Go 不需要显式修复，这一点是实测出来的**（本机 go1.27.1，见 dlp_test.go 的
// TestEncodingJSONRepairsLoneSurrogates）：
//
//	输入                       Unmarshal 结果       再编码
//	{"a":"\ud83d"}             "�" (U+FFFD)         合法 UTF-8
//	{"a":"\udc00"}             "�" (U+FFFD)         合法 UTF-8
//	{"a":"\ud83d\ude00"}       "😀" (U+1F600)       合法 UTF-8
//
// 原因：Go 的 string 本身不能保存代理项码点（`string(rune(0xD83D))` 直接得到 U+FFFD），
// 所以 encoding/json 在解码阶段就替换掉了；重编码出来的字节**与 Python 修复后的结果
// 相同**。因此转发出站路径不需要第二遍修复，也就不会因为一个坏字符丢掉链路。
//
// 但"静默修好了"会丢掉定位上游根因的唯一线索（Python 版会记 `_note_surrogate`）。
// 所以这里在解析时扫一遍**原始字节**里的落单 `\uD800`-`\uDFFF` 转义，把它们交给
// hub 记一条告警。扫描有廉价前置判断：帧里连 `\ud`/`\uD` 都没有时直接返回 nil，
// 正常帧只多两次 bytes.Contains。

// SurrogateDamage 描述一处（或几处）落单代理项的形态与位置，**只用于排障**。
//
// 字段刻意多是"位置"而不是"内容"：它进的是运维告警，不把用户正文写进日志。
// FirstIndex / TrailingChars 在 Go 版是**字节**偏移（Python 版是字符偏移）：这里
// 扫的是原始 JSON 字节，字节偏移对定位"是不是卡在帧尾"同样直接。
type SurrogateDamage struct {
	Count         int    `json:"count"`
	TotalChars    int    `json:"totalChars"`
	FirstIndex    int    `json:"firstIndex"`
	TrailingChars int    `json:"trailingChars"`
	Kinds         string `json:"kinds"`
	Context       string `json:"context"`
}

// contextBytes 是诊断记录里保留多长的上下文：够看出被切开的是什么（emoji、中文、
// JSON 转义），又不至于把用户内容写进日志。
const contextBytes = 48

// AsDetails 把损伤形态摊成告警详情。
//
// 监控模块的摘要与详情都从这一份数据里取，所以两处**不可能各说各话**（Python 版
// 同名方法的存在理由）。键名与 Python 的 `as_details()` 一致；FirstIndex /
// TrailingChars 在 Go 版是**字节**偏移（扫的是原始 JSON 字节）。
func (d SurrogateDamage) AsDetails() map[string]any {
	return map[string]any{
		"count":         d.Count,
		"totalChars":    d.TotalChars,
		"firstIndex":    d.FirstIndex,
		"trailingChars": d.TrailingChars,
		"kinds":         d.Kinds,
		"context":       d.Context,
	}
}

// ScanSurrogates 扫描一帧的原始字节，返回落单代理项的形态；没有时返回 nil。
//
// 只认**真正的转义**：`\\ud83d` 是一个反斜杠加字面量 "ud83d"，不是代理项，
// 因此统计前先数连续反斜杠的个数，奇数表示这个反斜杠本身被转义了。
func ScanSurrogates(raw []byte) *SurrogateDamage {
	// 所有代理项码点的四位十六进制都以 D 开头（D800–DFFF）。大小写都认。
	if !bytes.Contains(raw, []byte(`\ud`)) && !bytes.Contains(raw, []byte(`\uD`)) {
		return nil
	}

	var (
		count    int
		first    = -1
		firstEnd int
		high     int
		low      int
	)
	for index := 0; index+5 < len(raw); index++ {
		if raw[index] != '\\' {
			continue
		}
		if isEscapedBackslash(raw, index) {
			continue // 这个反斜杠是 `\\` 的后半段，后面跟的是字面量
		}
		if raw[index+1] != 'u' {
			continue
		}
		unit, ok := hexUnit(raw[index+2 : index+6])
		if !ok {
			continue
		}
		switch {
		case unit >= 0xD800 && unit <= 0xDBFF: // 高代理项
			if next, paired := lowEscapeAt(raw, index+6); paired && next >= 0xDC00 && next <= 0xDFFF {
				index += 11 // 跳过 `\uXXXX\uXXXX`，合法配对不损伤
				continue
			}
			high++
		case unit >= 0xDC00 && unit <= 0xDFFF: // 低代理项：只有前面刚配过才合法
			low++
		default:
			continue
		}
		if first < 0 {
			first, firstEnd = index, index+6
		}
		count++
	}
	if count == 0 {
		return nil
	}

	kinds := "mixed"
	switch {
	case high == 0:
		kinds = "low"
	case low == 0:
		kinds = "high"
	}
	start := max(0, first-contextBytes)
	end := min(len(raw), firstEnd+contextBytes)
	return &SurrogateDamage{
		Count:         count,
		TotalChars:    utf8.RuneCount(raw),
		FirstIndex:    first,
		TrailingChars: len(raw) - firstEnd,
		Kinds:         kinds,
		Context:       strings.ToValidUTF8(string(raw[start:end]), "\ufffd"),
	}
}

// isEscapedBackslash 判断 raw[index] 这个反斜杠是否被前一个反斜杠转义。
func isEscapedBackslash(raw []byte, index int) bool {
	run := 0
	for back := index - 1; back >= 0 && raw[back] == '\\'; back-- {
		run++
	}
	return run%2 == 1
}

// lowEscapeAt 读取 index 处的 `\uXXXX`；不是合法转义时 ok=false。
func lowEscapeAt(raw []byte, index int) (rune, bool) {
	if index+5 >= len(raw) || raw[index] != '\\' || raw[index+1] != 'u' {
		return 0, false
	}
	return hexUnit(raw[index+2 : index+6])
}

// hexUnit 把 4 位十六进制解析成码元。
func hexUnit(digits []byte) (rune, bool) {
	if len(digits) != 4 {
		return 0, false
	}
	value, err := strconv.ParseUint(string(digits), 16, 32)
	if err != nil {
		return 0, false
	}
	return rune(value), true
}
