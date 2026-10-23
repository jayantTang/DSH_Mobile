package hub

import (
	"testing"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
)

// TestTruncateReasonKeepsUTF8：关闭原因上限 120 字节，且不能把一个汉字切成半个。
func TestTruncateReasonKeepsUTF8(t *testing.T) {
	reason := ""
	for index := 0; index < 100; index++ {
		reason += "中转"
	}
	truncated := truncateReason(reason)
	if len(truncated) > maxCloseReason {
		t.Fatalf("截断后仍然超长：%d", len(truncated))
	}
	if !utf8Valid(truncated) {
		t.Fatal("截断切坏了 UTF-8")
	}
	if short := "short"; truncateReason(short) != short {
		t.Fatal("短原因不该被改")
	}
}

// TestLimitsDescribeUsesNullForUnlimited：0 = 不限 → JSON null（Python 口径）。
func TestLimitsDescribeUsesNullForUnlimited(t *testing.T) {
	described := DefaultLimits().Describe()
	if described.MaxDevicesPerAgent != nil || described.DeviceDailyBytes != nil ||
		described.DeviceBytesPerSecond != nil {
		t.Fatalf("默认不限的项应为 null：%+v", described)
	}
	if described.MaxFrameBytes != dlp.MaxFrameBytes || described.QueueDepth != 512 ||
		described.AgentQueueDepth != 4096 {
		t.Fatalf("默认限额 = %+v", described)
	}
	if described.DeadDeviceWarnThreshold == nil || *described.DeadDeviceWarnThreshold != 200 {
		t.Fatalf("deadDeviceWarnThreshold = %v", described.DeadDeviceWarnThreshold)
	}

	limits := Limits{MaxDevicesPerAgent: 2, DeviceDailyBytes: 1024, QueueDepth: 8,
		AgentQueueDepth: 16, MaxFrameBytes: 4096, DeviceBytesPerSecond: 250}
	described = limits.Describe()
	if described.MaxDevicesPerAgent == nil || *described.MaxDevicesPerAgent != 2 {
		t.Fatalf("maxDevicesPerAgent = %v", described.MaxDevicesPerAgent)
	}
	if described.DeviceDailyBytes == nil || *described.DeviceDailyBytes != 1024 {
		t.Fatalf("deviceDailyBytes = %v", described.DeviceDailyBytes)
	}
	if described.DeviceBytesPerSecond == nil || *described.DeviceBytesPerSecond != 250 {
		t.Fatalf("deviceBytesPerSecond = %v", described.DeviceBytesPerSecond)
	}
}

// utf8Valid 只在用例里用：避免为了一个断言再引入 unicode/utf8 的别名。
func utf8Valid(text string) bool {
	return string([]rune(text)) == text
}
