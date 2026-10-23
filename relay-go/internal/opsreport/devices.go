package opsreport

import (
	"sort"
	"strings"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// PushInfo 是设备行的 push 段（Python 同名结构）。
//
// device-list 与 ops-report 共用这一份形状：两个命令对"推送登记"的说法必须一致。
type PushInfo struct {
	Registered bool    `json:"registered"`
	Env        *string `json:"env"`
	TurnEnd    bool    `json:"turnEnd"`
	Attention  bool    `json:"attention"`
	UpdatedAt  *int64  `json:"updatedAt"`
}

// deviceReportList 是设备清单：只列未撤销的真实设备，按最近在线倒序。
func deviceReportList(live []store.Device, lastSeen map[string]int64,
	agents map[string]store.Agent, names map[string]*string) []deviceReportRow {
	sorted := make([]store.Device, len(live))
	copy(sorted, live)
	sort.SliceStable(sorted, func(left, right int) bool {
		leftKey := lastSeen[sorted[left].DeviceID]
		if leftKey == 0 {
			leftKey = sorted[left].CreatedAt
		}
		rightKey := lastSeen[sorted[right].DeviceID]
		if rightKey == 0 {
			rightKey = sorted[right].CreatedAt
		}
		return leftKey > rightKey
	})
	if len(sorted) > reportDeviceLimit {
		sorted = sorted[:reportDeviceLimit]
	}
	out := make([]deviceReportRow, 0, len(sorted))
	for _, device := range sorted {
		agent := agents[device.AgentID]
		deviceName := device.Name
		entry := deviceReportRow{
			DeviceID: device.DeviceID, DeviceTokenHash: MaskPrefix(device.DeviceTokenHash, 12),
			AgentID: device.AgentID, AccountID: device.AccountID, Name: deviceName,
			Model: device.Model, AppVersion: device.AppVersion, CreatedAt: device.CreatedAt,
			ExpiresAt: device.ExpiresAt, RevokedAt: device.RevokedAt,
			APNSEnv: device.APNSEnv, PushTurnEnd: device.PushTurnEnd,
			PushAttention: device.PushAttention, PushUpdatedAt: device.PushUpdatedAt,
			DeviceKey: device.DeviceKey, ConnectorVersion: agent.ConnectorVersion,
			HostVersion: agent.HostVersion, VersionsAt: agent.VersionsAt,
			Revoked: device.RevokedAt != nil, AccountName: names[device.AccountID],
		}
		if device.APNSToken != nil {
			masked := MaskPrefix(*device.APNSToken, 8)
			entry.APNSToken = &masked
		}
		if seen, ok := lastSeen[device.DeviceID]; ok {
			value := seen
			entry.LastSeenAt = &value
		}
		entry.Push = PushInfo{
			Registered: device.APNSToken != nil, Env: device.APNSEnv,
			TurnEnd: device.PushTurnEnd != 0, Attention: device.PushAttention != 0,
			UpdatedAt: device.PushUpdatedAt,
		}
		out = append(out, entry)
	}
	return out
}

// MaskPrefix 复刻 admin.py 的打码：保留前 n 个字符再加省略号。
func MaskPrefix(value string, n int) string {
	if len(value) <= n {
		return value + "…"
	}
	return value[:n] + "…"
}

// ── 设备/线程/用量的小判定 ─────────────────────────────────────────────────

func isDebugDevice(device store.Device) bool {
	if strings.HasPrefix(device.Name, "DSH-") {
		return true
	}
	if device.Model == nil {
		return false
	}
	switch *device.Model {
	case "Node", "test-harness", "simulator":
		return true
	default:
		return false
	}
}

func isTestEnrollment(row store.Enrollment) bool {
	accountName := ""
	if row.AccountName != nil {
		accountName = *row.AccountName
	}
	return strings.HasPrefix(accountName, "DSH-") ||
		strings.HasPrefix(row.AgentName, "DSH-")
}

func isOrphanUsage(row store.UsageRow, knownIDs, external map[string]struct{}) bool {
	if _, known := knownIDs[row.DeviceID]; known {
		return false
	}
	_, ext := external[row.AccountID]
	return !ext
}

func firstDeviceRows(devices []store.Device) []store.Device {
	type key struct {
		account string
		phone   string
	}
	firsts := map[key]store.Device{}
	for _, device := range devices {
		phone := device.DeviceID
		if device.Model != nil && *device.Model != "" {
			phone = *device.Model
		} else if device.Name != "" {
			phone = device.Name
		}
		entry := key{account: device.AccountID, phone: phone}
		seen, ok := firsts[entry]
		if !ok || device.CreatedAt < seen.CreatedAt {
			firsts[entry] = device
		}
	}
	out := make([]store.Device, 0, len(firsts))
	for _, device := range firsts {
		out = append(out, device)
	}
	return out
}
