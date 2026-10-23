//go:build !race

// 零分配断言只在普通构建里跑：-race 会给 sync.Pool 与接口装箱加上记账，
// 采样出来的分配数不再是生产口径（功能用例照常在 race 下跑）。
package dlp

import "testing"

// TestWireHotPathDoesNotAllocate 是这次优化的核心断言：48 字节的转发帧
// （扫类型 + 判字段 + 就地盖 deviceId / 摘 deviceId）不产生任何堆分配。
func TestWireHotPathDoesNotAllocate(t *testing.T) {
	pool := NewBufferPool()
	deviceMember := DeviceIDMember("dev_7")
	deviceFrame := []byte(`{"t":"req","id":"d7-33","method":"bench/echo"}`)
	agentFrame := []byte(`{"t":"res","id":"d7-33","ok":true,"value":{"echo":"d7-33"},"deviceId":"dev_7"}`)

	allocs := testing.AllocsPerRun(200, func() {
		buffer := pool.Get()
		buffer.SetBytes(append(buffer.Bytes()[:0], deviceFrame...))
		buffer.Headroom()
		wire, _, err := Scan(buffer.Bytes())
		if err != nil {
			t.Fatalf("Scan: %v", err)
		}
		if !wire.Is("req") || ValidateFromDevice(wire) != "" {
			t.Fatal("热路径判定错了")
		}
		stamped, err := wire.WithDeviceIDMember(deviceMember)
		if err != nil {
			t.Fatalf("WithDeviceIDMember: %v", err)
		}
		if len(stamped.Bytes()) == 0 {
			t.Fatal("空帧")
		}
		buffer.Release()

		buffer = pool.Get()
		buffer.SetBytes(append(buffer.Bytes()[:0], agentFrame...))
		wire, _, err = Scan(buffer.Bytes())
		if err != nil {
			t.Fatalf("Scan: %v", err)
		}
		if got := wire.Field("deviceId"); !sameBytes(got, "dev_7") {
			t.Fatalf("deviceId = %q", got)
		}
		if problem := ValidateFromAgent(wire); problem != "" {
			t.Fatalf("ValidateFromAgent = %q", problem)
		}
		stripped, err := wire.WithoutDeviceID()
		if err != nil {
			t.Fatalf("WithoutDeviceID: %v", err)
		}
		if len(stripped.Bytes()) == 0 {
			t.Fatal("空帧")
		}
		buffer.Release()
	})
	if allocs != 0 {
		t.Fatalf("热路径产生了 %.2f 次分配/帧", allocs)
	}
}

// TestBufferPoolDoesNotAllocateAfterWarmup 钉住"池复用之后不再分配"。
func TestBufferPoolDoesNotAllocateAfterWarmup(t *testing.T) {
	pool := NewBufferPool()
	warm := pool.Get()
	warm.Release()
	allocs := testing.AllocsPerRun(50, func() {
		buffer := pool.Get()
		buffer.Release()
	})
	if allocs != 0 {
		t.Fatalf("池 Get/Release 仍有 %.2f 次分配", allocs)
	}
}
