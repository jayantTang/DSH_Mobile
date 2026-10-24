package opsreport

import (
	"encoding/json"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

var (
	journalJSONPattern = regexp.MustCompile(`\{"(?:level|time|msg)"`)
	deviceEventPattern = regexp.MustCompile(
		`device (dev_[A-Za-z0-9]+) .*?(attached to agent|attached again|detached|` +
			`closed a socket that had already been replaced)`)
	agentInLinePattern = regexp.MustCompile(`agent (agt_[A-Za-z0-9]+)`)
)

// hourlyActivityBuckets 从 systemd 日志重建 [startMS, endMS] 的"有设备在连"的账号与设备数。
//
// 多个单元（前端 Python 与 Go）的日志合并后按时刻排序：2026-10-24 生产切成 Go，
// 窗口跨切换点时两份都要读，否则切换前的历史与切换后的今天各缺一半。
//
// 取不到日志时返回 nil（JSON 里是 null）：日报宁可少一张图，也不编数字。
func hourlyActivityBuckets(startMS, endMS int64, devices []store.Device,
	agents map[string]store.Agent, units []string,
	journal func(string, int64, int64) ([]string, bool)) []hourlyBucket {
	hourMS := int64(3_600_000)
	end := endMS
	start := startMS
	if journal == nil {
		return nil
	}
	var lines []string
	readable := false
	for _, unit := range units {
		if unit == "" {
			continue
		}
		found, ok := journal(unit, start, end)
		if !ok {
			continue
		}
		readable = true
		lines = append(lines, found...)
	}
	if !readable {
		return nil
	}
	sort.SliceStable(lines, func(left, right int) bool {
		leftAt, leftOK := parseJournalTime(lines[left])
		rightAt, rightOK := parseJournalTime(lines[right])
		if !leftOK || !rightOK {
			return false
		}
		return leftAt < rightAt
	})
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
		deviceID, kind, agentID, matched := parseDeviceEvent(line)
		if !matched {
			continue
		}
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

// journalJSONBody 取出一行日志里的 JSON 正文。
//
// journalctl 每行前面都有 `2026-10-24T14:39:47+0800 host unit[pid]:`，Go 的 JSON 在冒号
// 之后——不能按行首是不是 `{` 判格式（2026-10-24 实测：那样一条都认不出，矩阵只剩 Python
// 阶段没闭合的旧 span，看起来「今天整天只有 3 个账号」）。
func journalJSONBody(line string) (string, bool) {
	match := journalJSONPattern.FindStringIndex(line)
	if match == nil {
		return "", false
	}
	return line[match[0]:], true
}

// parseDeviceEvent 解析一行「设备连上 / 断开」，返回 deviceId、事件类与 agentId。
//
// 两种格式都认：Python 服务是文本（`device dev_x (iPhone) attached to agent agt_y`），
// Go 服务（2026-10-24 起）是 JSON（`"msg":"relay: device attached","deviceId":…`）。
// 只认文本的话，切换之后的每一格都是空的，而日志里明明有数据。
func parseDeviceEvent(line string) (deviceID, kind, agentID string, ok bool) {
	if body, found := journalJSONBody(line); found {
		var payload struct {
			Msg      string `json:"msg"`
			DeviceID string `json:"deviceId"`
			AgentID  string `json:"agentId"`
		}
		if err := json.Unmarshal([]byte(body), &payload); err != nil {
			return "", "", "", false
		}
		if !strings.HasPrefix(payload.DeviceID, "dev_") {
			return "", "", "", false
		}
		for _, candidate := range []string{
			"closed a socket that had already been replaced", "attached again", "attached", "detached",
		} {
			if strings.Contains(payload.Msg, candidate) {
				return payload.DeviceID, candidate, payload.AgentID, true
			}
		}
		return "", "", "", false
	}
	match := deviceEventPattern.FindStringSubmatch(line)
	if match == nil {
		return "", "", "", false
	}
	if found := agentInLinePattern.FindStringSubmatch(line); found != nil {
		agentID = found[1]
	}
	return match[1], match[2], agentID, true
}

// parseJournalTime 解析一行日志的时刻：short-iso 行首的 `2026-10-17T15:44:16+0800`，
// 或 Go 服务 JSON 里的 `"time":"2026-10-24T14:30:26.865392225+08:00"`。
func parseJournalTime(line string) (int64, bool) {
	if body, found := journalJSONBody(line); found {
		var payload struct {
			Time string `json:"time"`
		}
		if err := json.Unmarshal([]byte(body), &payload); err != nil || payload.Time == "" {
			return 0, false
		}
		parsed, err := time.Parse(time.RFC3339Nano, payload.Time)
		if err != nil {
			return 0, false
		}
		return parsed.UnixMilli(), true
	}
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
