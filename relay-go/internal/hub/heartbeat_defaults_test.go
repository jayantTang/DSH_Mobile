package hub

import (
	"testing"
	"time"
)

// TestHeartbeatDefaultsMatchPython 钉住与 Python aiohttp heartbeat=30.0 对齐的
// 默认值，防止再次无意改成更激进的 15 秒/10 秒。
//
// 截止时间 60 秒而不是 30 秒：连接器每 20 秒一次心跳，60 秒是 3 个周期，
// 与连接器 pongTimeoutMs=60s 同口径；Python 的实际容忍是 45 秒。
func TestHeartbeatDefaultsMatchPython(t *testing.T) {
	got := (linkOptions{}).withDefaults()
	if got.heartbeat != 30*time.Second {
		t.Fatalf("heartbeat = %v，期望 30s", got.heartbeat)
	}
	if got.heartbeatTimeout != 60*time.Second {
		t.Fatalf("heartbeatTimeout = %v，期望 60s", got.heartbeatTimeout)
	}
}
