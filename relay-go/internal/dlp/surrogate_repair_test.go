package dlp

import (
	"bytes"
	"encoding/json"
	"testing"
)

// TestScanRepairsLoneSurrogateBeforeForwarding 钉住 Go 快路径与 Python 的
// prepare_outbound 同策略：落单代理项必须在转发前换成 U+FFFD，而不是只记日志。
func TestScanRepairsLoneSurrogateBeforeForwarding(t *testing.T) {
	raw := []byte(`{"t":"item","deviceId":"dev_1","value":"a\ud83db"}`)
	wire, damage, err := Scan(raw)
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if damage == nil || damage.Count != 1 {
		t.Fatalf("damage = %+v，期望 1 个落单代理项", damage)
	}
	if bytes.Contains(wire.Bytes(), []byte(`\ud83d`)) {
		t.Fatalf("转发字节仍含落单代理项：%q", wire.Bytes())
	}
	if !bytes.Contains(wire.Bytes(), []byte(`\ufffd`)) {
		t.Fatalf("转发字节未替换成 U+FFFD：%q", wire.Bytes())
	}
	if !json.Valid(wire.Bytes()) {
		t.Fatalf("修复后不是合法 JSON：%q", wire.Bytes())
	}
	var frame map[string]any
	if err := json.Unmarshal(wire.Bytes(), &frame); err != nil {
		t.Fatalf("修复后解码失败：%v", err)
	}
	if got := frame["value"]; got != "a\ufffdb" {
		t.Fatalf("value = %q，期望 a\\ufffdb", got)
	}
	// 转发路径随后会剥掉 relay 自己的 deviceId，剥离后仍须合法且不含坏代理项。
	stripped, err := wire.WithoutDeviceID()
	if err != nil {
		t.Fatalf("WithoutDeviceID: %v", err)
	}
	if !json.Valid(stripped.Bytes()) || bytes.Contains(stripped.Bytes(), []byte(`\ud83d`)) {
		t.Fatalf("剥离后字节不合法或仍含坏代理项：%q", stripped.Bytes())
	}
}

func TestScanLeavesValidSurrogatePair(t *testing.T) {
	raw := []byte(`{"t":"item","value":"\ud83d\ude00"}`)
	wire, damage, err := Scan(raw)
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if damage != nil {
		t.Fatalf("合法代理对不应报 damage：%+v", damage)
	}
	if !bytes.Equal(wire.Bytes(), raw) {
		t.Fatalf("合法代理对被改写：%q", wire.Bytes())
	}
	var frame map[string]any
	if err := json.Unmarshal(wire.Bytes(), &frame); err != nil {
		t.Fatalf("解码失败：%v", err)
	}
	if got := frame["value"]; got != "😀" {
		t.Fatalf("value = %q，期望 emoji", got)
	}
}

func TestScanLeavesEscapedBackslashLiteral(t *testing.T) {
	raw := []byte(`{"t":"item","value":"\\ud83d"}`)
	wire, damage, err := Scan(raw)
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if damage != nil {
		t.Fatalf("字面量反斜杠不应报 damage：%+v", damage)
	}
	if !bytes.Equal(wire.Bytes(), raw) {
		t.Fatalf("字面量被改写：%q", wire.Bytes())
	}
}

func TestRepairSurrogatesHandlesLowAndMixed(t *testing.T) {
	raw := []byte(`{"t":"item","a":"\udc00","b":"x\ud83dy","c":"\ud83d\ude00"}`)
	damage := RepairSurrogates(raw)
	if damage == nil || damage.Count != 2 {
		t.Fatalf("damage = %+v，期望 2 个落单代理项", damage)
	}
	if !json.Valid(raw) {
		t.Fatalf("修复后不是合法 JSON：%q", raw)
	}
	if still := ScanSurrogates(raw); still != nil {
		t.Fatalf("仍含落单代理项：%+v", still)
	}
	if !bytes.Contains(raw, []byte(`\ud83d\ude00`)) {
		t.Fatalf("合法代理对被改写：%q", raw)
	}
}
