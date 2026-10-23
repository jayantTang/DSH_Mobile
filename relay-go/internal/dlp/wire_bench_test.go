package dlp

import "testing"

// 转发热路径的对照基准：M2 的"全量解析 + 克隆 + 重编码" vs M2.5 的"字段扫描 +
// 就地改写"。M2.5 报告里的每帧成本数字来自这两个基准。

var (
	benchDeviceFrame = []byte(`{"t":"req","id":"d7-33","method":"bench/echo"}`)
	benchAgentFrame  = []byte(`{"t":"res","id":"d7-33","ok":true,"value":{"echo":"d7-33"},"deviceId":"dev_7"}`)
	benchDeviceID    = DeviceIDMember("dev_7")
)

// BenchmarkForwardDeviceFrameM2 是 M2 的路径（保留这份基准，调优不能靠传说）。
func BenchmarkForwardDeviceFrameM2(b *testing.B) {
	b.ReportAllocs()
	for index := 0; index < b.N; index++ {
		frame, _, err := Parse(benchDeviceFrame)
		if err != nil {
			b.Fatal(err)
		}
		if _, err := Encode(WithDeviceID(frame, "dev_7")); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkForwardAgentFrameM2 是 M2 的电脑→设备路径。
func BenchmarkForwardAgentFrameM2(b *testing.B) {
	b.ReportAllocs()
	for index := 0; index < b.N; index++ {
		frame, _, err := Parse(benchAgentFrame)
		if err != nil {
			b.Fatal(err)
		}
		if _, err := Encode(WithoutDeviceID(frame)); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkForwardDeviceFrameM25 是 M2.5 的路径：读缓冲进池、就地盖 deviceId。
func BenchmarkForwardDeviceFrameM25(b *testing.B) {
	pool := NewBufferPool()
	b.ReportAllocs()
	for index := 0; index < b.N; index++ {
		buffer := pool.Get()
		buffer.SetBytes(append(buffer.Bytes()[:0], benchDeviceFrame...))
		buffer.Headroom()
		wire, _, err := Scan(buffer.Bytes())
		if err != nil {
			b.Fatal(err)
		}
		if ValidateFromDevice(wire) != "" {
			b.Fatal("校验失败")
		}
		if _, err := wire.WithDeviceIDMember(benchDeviceID); err != nil {
			b.Fatal(err)
		}
		buffer.Release()
	}
}

// BenchmarkForwardAgentFrameM25 是 M2.5 的电脑→设备路径（就地摘 deviceId）。
func BenchmarkForwardAgentFrameM25(b *testing.B) {
	pool := NewBufferPool()
	b.ReportAllocs()
	for index := 0; index < b.N; index++ {
		buffer := pool.Get()
		buffer.SetBytes(append(buffer.Bytes()[:0], benchAgentFrame...))
		wire, _, err := Scan(buffer.Bytes())
		if err != nil {
			b.Fatal(err)
		}
		if !IsStreamingKind(wire.Kind()) {
			b.Fatal("类型判定错了")
		}
		if _, err := wire.WithoutDeviceID(); err != nil {
			b.Fatal(err)
		}
		buffer.Release()
	}
}
