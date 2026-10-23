package opsreport

import (
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

var (
	deviceEventPattern = regexp.MustCompile(
		`device (dev_[A-Za-z0-9]+) .*?(attached to agent|attached again|detached|` +
			`closed a socket that had already been replaced)`)
	agentInLinePattern = regexp.MustCompile(`agent (agt_[A-Za-z0-9]+)`)
)

// hourlyActivityBuckets 从 systemd 日志重建过去 N 小时的"有设备在连"的账号与设备数。
//
// 取不到日志时返回 nil（JSON 里是 null）：日报宁可少一张图，也不编数字。
func hourlyActivityBuckets(hours int, endMS int64, devices []store.Device,
	agents map[string]store.Agent, unit string,
	journal func(string, int64, int64) ([]string, bool)) []hourlyBucket {
	hourMS := int64(3_600_000)
	end := endMS
	start := end - int64(hours)*hourMS
	if journal == nil {
		return nil
	}
	lines, ok := journal(unit, start, end)
	if !ok {
		return nil
	}
	deviceByID := make(map[string]store.Device, len(devices))
	for _, device := range devices {
		deviceByID[device.DeviceID] = device
	}
	openAt := map[string]struct {
		at    int64
		agent string
	}{}
	type span struct {
		opened int64
		closed int64
		device string
		agent  string
	}
	spans := make([]span, 0, 64)
	for _, line := range lines {
		match := deviceEventPattern.FindStringSubmatch(line)
		if match == nil {
			continue
		}
		deviceID, kind := match[1], match[2]
		if kind == "closed a socket that had already been replaced" {
			continue
		}
		at, ok := parseJournalTime(line)
		if !ok {
			continue
		}
		if at < start {
			at = start
		}
		if at > end {
			at = end
		}
		agentID := ""
		if found := agentInLinePattern.FindStringSubmatch(line); found != nil {
			agentID = found[1]
		}
		if strings.HasPrefix(kind, "attached") {
			if previous, stillOpen := openAt[deviceID]; stillOpen {
				spans = append(spans, span{opened: previous.at, closed: at,
					device: deviceID, agent: previous.agent})
				delete(openAt, deviceID)
			}
			openAt[deviceID] = struct {
				at    int64
				agent string
			}{at: at, agent: agentID}
			continue
		}
		if previous, stillOpen := openAt[deviceID]; stillOpen {
			spans = append(spans, span{opened: previous.at, closed: at,
				device: deviceID, agent: previous.agent})
			delete(openAt, deviceID)
		}
	}
	for deviceID, previous := range openAt {
		spans = append(spans, span{opened: previous.at, closed: end,
			device: deviceID, agent: previous.agent})
	}

	accountOf := func(deviceID, agentID string) string {
		device, known := deviceByID[deviceID]
		if known && isDebugDevice(device) {
			return ""
		}
		if known && device.AccountID != "" {
			return device.AccountID
		}
		ownerAgent := agentID
		if known && device.AgentID != "" {
			ownerAgent = device.AgentID
		}
		if ownerAgent == "" {
			return ""
		}
		return agents[ownerAgent].AccountID
	}

	first := (start / hourMS) * hourMS
	type bucket struct {
		accounts map[string]struct{}
		devices  map[string]struct{}
	}
	buckets := map[int64]*bucket{}
	for at := first; at <= end; at += hourMS {
		buckets[at] = &bucket{accounts: map[string]struct{}{},
			devices: map[string]struct{}{}}
	}
	for _, item := range spans {
		if item.closed < item.opened {
			continue
		}
		accountID := accountOf(item.device, item.agent)
		if accountID == "" {
			continue
		}
		for cursor := (item.opened / hourMS) * hourMS; cursor <= item.closed; cursor += hourMS {
			entry := buckets[cursor]
			if entry == nil {
				continue
			}
			entry.devices[item.device] = struct{}{}
			entry.accounts[accountID] = struct{}{}
		}
	}
	keys := make([]int64, 0, len(buckets))
	for key := range buckets {
		keys = append(keys, key)
	}
	sort.Slice(keys, func(left, right int) bool { return keys[left] < keys[right] })
	out := make([]hourlyBucket, 0, len(keys))
	for _, key := range keys {
		entry := buckets[key]
		out = append(out, hourlyBucket{
			HourStartAt: key, Accounts: len(entry.accounts), Devices: len(entry.devices),
		})
	}
	return out
}

// parseJournalTime 解析 short-iso 行首的 `2026-10-17T15:44:16+0800`。
func parseJournalTime(line string) (int64, bool) {
	stamp := strings.SplitN(strings.TrimSpace(line), " ", 2)[0]
	layouts := []string{
		"2006-01-02T15:04:05-0700",
		"2006-01-02T15:04:05.000000-0700",
		time.RFC3339,
		time.RFC3339Nano,
	}
	for _, layout := range layouts {
		if parsed, err := time.ParseInLocation(layout, stamp, time.Local); err == nil {
			return parsed.UnixMilli(), true
		}
	}
	return 0, false
}
