package hub

import (
	"testing"
	"time"
)

// TestHeartbeatDefaultsMatchPython 钉住与 Python aiohttp heartbeat=30.0 对齐的
// 默认值，防止再次无意改成更激进的 15 秒/10 秒。
func TestHeartbeatDefaultsMatchPython(t *testing.T) {
	got := (linkOptions{}).withDefaults()
	if got.heartbeat != 30*time.Second {
		t.Fatalf("heartbeat = %v，期望 30s", got.heartbeat)
	}
	if got.heartbeatTimeout != 30*time.Second {
		t.Fatalf("heartbeatTimeout = %v，期望 30s", got.heartbeatTimeout)
	}
}
