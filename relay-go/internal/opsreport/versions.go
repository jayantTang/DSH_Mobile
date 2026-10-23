package opsreport

import (
	"context"
	"sort"
	"strings"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// versionReport 是版本分布：近 48 小时有设备用量行的账号装在哪个版本。
func versionReport(ctx context.Context, src Source, stamp int64, devices []store.Device,
	debugIDs, knownIDs, external map[string]struct{}) ([]versionRow, error) {
	byID := make(map[string]store.Device, len(devices))
	for _, device := range devices {
		byID[device.DeviceID] = device
	}
	since := stamp - reportVersionHours*3_600_000
	// Python 的 dict 以 appVersion 为键，None 也是合法键；Go 用空串代表 None。
	grouped := map[string]*versionRow{}
	accountsByVersion := map[string]map[string]struct{}{}
	seenDevices := map[string]struct{}{}
	startDay := localDayOf(since)
	endDay := localDayOf(stamp)
	// 按日历日迭代：直接 `day++` 在跨月时会先查 20260931 这种不存在的日号
	// （Python 同样是整数 range，结果相同但多做几十次空查询）。
	for offset := 0; ; offset++ {
		day := dayShift(startDay, offset)
		if day > endDay {
			break
		}
		rows, err := src.UsageRows(ctx, day)
		if err != nil {
			return nil, err
		}
		for _, row := range rows {
			if _, debug := debugIDs[row.DeviceID]; debug {
				continue
			}
			if _, seen := seenDevices[row.DeviceID]; seen {
				continue
			}
			if isOrphanUsage(row, knownIDs, external) {
				continue
			}
			seen := row.LastSeenAt
			if seen > stamp {
				seen = stamp
			}
			if seen < since {
				continue
			}
			seenDevices[row.DeviceID] = struct{}{}
			device := byID[row.DeviceID]
			version := ""
			if device.AppVersion != nil {
				version = strings.TrimSpace(*device.AppVersion)
			}
			entry := grouped[version]
			if entry == nil {
				var label *string
				if version != "" {
					value := version
					label = &value
				}
				entry = &versionRow{AppVersion: label}
				grouped[version] = entry
			}
			entry.Devices++
			if row.AccountID != "" {
				// 账号数按账号去重：同账号多台设备只算一个。
				if accountsByVersion[version] == nil {
					accountsByVersion[version] = map[string]struct{}{}
				}
				accountsByVersion[version][row.AccountID] = struct{}{}
			}
			if entry.LastSeenAt == nil || seen > *entry.LastSeenAt {
				value := seen
				entry.LastSeenAt = &value
			}
			grouped[version] = entry
		}
	}
	out := make([]versionRow, 0, len(grouped))
	for version, entry := range grouped {
		entry.Accounts = len(accountsByVersion[version])
		out = append(out, *entry)
	}
	sort.SliceStable(out, func(left, right int) bool {
		if out[left].Devices != out[right].Devices {
			return out[left].Devices > out[right].Devices
		}
		return versionValue(out[left].AppVersion) < versionValue(out[right].AppVersion)
	})
	return out, nil
}

func versionValue(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}
