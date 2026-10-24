package opsreport

import (
	"testing"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// jsonJournal 是 Go 服务实际写出的那一种行：字段里才有 deviceId/agentId。
func jsonJournal(string, int64, int64) ([]string, bool) {
	// journalctl -o short-iso 的行首带时间戳与单元名，JSON 正文在冒号之后。
	return []string{
		`2026-10-24T14:10:00+0800 host dsh-relay[1]: {"time":"2026-10-24T14:10:00.123456789+08:00","level":"INFO","msg":"relay: device attached","deviceId":"dev_go1","agentId":"agt_go"}`,
		`2026-10-24T15:40:00+0800 host dsh-relay[1]: {"time":"2026-10-24T15:40:00.5+08:00","level":"INFO","msg":"relay: device detached","deviceId":"dev_go1","agentId":"agt_go","reason":"socket closed"}`,
	}, true
}

// TestHourlyActivityReadsGoJSONLines 钉住 2026-10-24 切换后的日志格式：
// 只认 Python 的文本行，切换之后的每一格都会是 0，而日志里明明有数据。
func TestHourlyActivityReadsGoJSONLines(t *testing.T) {
	start := at(20261024, 14, 0)
	end := at(20261024, 16, 0)
	devices := []store.Device{{DeviceID: "dev_go1", AccountID: "acc_go", AgentID: "agt_go"}}
	agents := map[string]store.Agent{"agt_go": {AgentID: "agt_go", AccountID: "acc_go"}}
	buckets := hourlyActivityBuckets(start, end, devices, agents,
		[]string{"dsh-relay", "dsh-relay-go"}, jsonJournal)
	if len(buckets) != 3 {
		t.Fatalf("14:00–16:00 应有三格，得到 %d 格", len(buckets))
	}
	if buckets[0].Accounts != 1 || buckets[0].Devices != 1 {
		t.Fatalf("14 点这一格应算一个账号一台设备：%+v", buckets[0])
	}
	if buckets[1].Accounts != 1 {
		t.Fatalf("15:40 才断开，15 点这一格还在线：%+v", buckets[1])
	}
	if buckets[2].Accounts != 0 {
		t.Fatalf("16 点已断开，应为 0：%+v", buckets[2])
	}
}

// TestHourlyActivityMergesBothUnits：切换期两个单元都在写，缺一份就少一半。
func TestHourlyActivityMergesBothUnits(t *testing.T) {
	start := at(20261024, 13, 0)
	end := at(20261024, 15, 0)
	devices := []store.Device{
		{DeviceID: "dev_py", AccountID: "acc_py", AgentID: "agt_py"},
		{DeviceID: "dev_go", AccountID: "acc_go", AgentID: "agt_go"},
	}
	agents := map[string]store.Agent{
		"agt_py": {AgentID: "agt_py", AccountID: "acc_py"},
		"agt_go": {AgentID: "agt_go", AccountID: "acc_go"},
	}
	journal := func(unit string, sinceMS, untilMS int64) ([]string, bool) {
		if unit == "dsh-relay" {
			return []string{
				"2026-10-24T13:05:00+0800 host dsh-relay[1]: device dev_py attached to agent agt_py",
			}, true
		}
		return []string{
			`2026-10-24T14:05:00+0800 host dsh-relay[1]: {"time":"2026-10-24T14:05:00.9+08:00","msg":"relay: device attached","deviceId":"dev_go","agentId":"agt_go"}`,
		}, true
	}
	buckets := hourlyActivityBuckets(start, end, devices, agents,
		[]string{"dsh-relay", "dsh-relay-go"}, journal)
	last := buckets[len(buckets)-1]
	if last.Accounts != 2 || last.Devices != 2 {
		t.Fatalf("15 点两台设备都还连着，应有两个账号：%+v", last)
	}
}
