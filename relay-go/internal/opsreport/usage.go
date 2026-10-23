package opsreport

import (
	"context"
	"math"
	"sort"
)

// usageScan 按天读一遍 usageDaily，同时给出 series / ranked / activeByDay。
func usageScan(ctx context.Context, src Source, days int, end int64,
	debugIDs map[string]struct{}, names map[string]*string, knownIDs,
	external map[string]struct{}) ([]usageDay, []accountUsageRow, map[int64]map[string]struct{}, error) {
	recent := recentDays(days, end)
	perDay := make(map[int64]*usageDay, len(recent))
	activeByDay := make(map[int64]map[string]struct{}, len(recent))
	for _, day := range recent {
		perDay[day] = &usageDay{Day: day}
		activeByDay[day] = map[string]struct{}{}
	}
	merged := map[string]*accountUsageRow{}
	seenDevices := map[string]map[string]struct{}{}
	for _, day := range recent {
		rows, err := src.UsageRows(ctx, day)
		if err != nil {
			return nil, nil, nil, err
		}
		for _, row := range rows {
			if _, debug := debugIDs[row.DeviceID]; debug {
				continue
			}
			if isOrphanUsage(row, knownIDs, external) {
				continue
			}
			entry := perDay[day]
			entry.EgressBytes += row.EgressBytes
			entry.Connections += row.Connections
			entry.Devices++
			if row.AccountID != "" {
				activeByDay[day][row.AccountID] = struct{}{}
			}
			account := merged[row.AccountID]
			if account == nil {
				accountID := row.AccountID
				account = &accountUsageRow{AccountID: &accountID, Name: names[row.AccountID]}
				merged[row.AccountID] = account
			}
			account.EgressBytes += row.EgressBytes
			account.Connections += row.Connections
			if seenDevices[row.AccountID] == nil {
				seenDevices[row.AccountID] = map[string]struct{}{}
			}
			seenDevices[row.AccountID][row.DeviceID] = struct{}{}
			// lastSeenAt / lastBuild 取窗口内最后出现过的那次（求和没意义）。
			if row.LastSeenAt > int64Value(account.LastSeenAt) {
				value := row.LastSeenAt
				account.LastSeenAt = &value
				if row.LastBuild != nil {
					account.LastBuild = row.LastBuild
				}
			}
		}
	}
	series := make([]usageDay, 0, len(recent))
	for _, day := range recent {
		entry := perDay[day]
		entry.Accounts = len(activeByDay[day])
		series = append(series, *entry)
	}
	ranked := make([]accountUsageRow, 0, len(merged))
	for accountID, account := range merged {
		account.Devices = len(seenDevices[accountID])
		ranked = append(ranked, *account)
	}
	sort.SliceStable(ranked, func(left, right int) bool {
		return ranked[left].EgressBytes > ranked[right].EgressBytes
	})
	activeSets := make(map[int64]map[string]struct{}, len(activeByDay))
	for day, set := range activeByDay {
		activeSets[day] = set
	}
	return series, ranked, activeSets, nil
}

// buildUsageReport 是用量板块的 JSON。
func buildUsageReport(series []usageDay, ranked []accountUsageRow,
	activeByDay map[int64]map[string]struct{}, firstSeen map[string]int64) usageReport {
	var peak *dayBytes
	var total int64
	activeAll := map[string]struct{}{}
	for _, entry := range series {
		total += entry.EgressBytes
		for account := range activeByDay[entry.Day] {
			activeAll[account] = struct{}{}
		}
		if peak == nil || entry.EgressBytes > peak.EgressBytes {
			value := dayBytes{Day: entry.Day, EgressBytes: entry.EgressBytes}
			peak = &value
		}
	}
	last7 := make([]int64, 0, 7)
	for _, day := range sortedDays(activeByDay) {
		last7 = append(last7, day)
	}
	if len(last7) > 7 {
		last7 = last7[len(last7)-7:]
	}
	active7d := map[string]struct{}{}
	for _, day := range last7 {
		for account := range activeByDay[day] {
			active7d[account] = struct{}{}
		}
	}
	for index := range series {
		entry := &series[index]
		active := activeByDay[entry.Day]
		fresh := 0
		for account := range active {
			if firstSeen[account] == entry.Day {
				fresh++
			}
		}
		entry.NewAccounts = fresh
		entry.ReturningAccounts = len(active) - fresh
	}
	average := int64(0)
	if len(series) > 0 {
		// Python 的 round(total / len) 取最近整数（不是截断）。
		average = int64(math.RoundToEven(float64(total) / float64(len(series))))
	}
	activeDays := 0
	for _, entry := range series {
		if entry.EgressBytes > 0 {
			activeDays++
		}
	}
	var connections int64
	for _, entry := range series {
		connections += entry.Connections
	}
	return usageReport{
		PerDay: series, TopAccounts: takeAccounts(ranked, reportTopAccounts),
		Totals:        usageTotals{EgressBytes: total, Connections: connections},
		AveragePerDay: average, PeakDay: peak, ActiveDays: activeDays,
		ActiveAccounts: len(activeAll), ActiveAccounts7d: len(active7d),
	}
}

// firstSeenDays 是每个账号第一次有用量记录的本地日（留存队列的起点）。
func firstSeenDays(ctx context.Context, src Source, debugIDs map[string]struct{},
	owners map[string]string) (map[string]int64, error) {
	rows, err := src.UsageTotals(ctx, retentionHistoryDays, "device")
	if err != nil {
		return nil, err
	}
	first := map[string]int64{}
	for _, row := range rows {
		if row.DeviceID == nil {
			continue
		}
		if _, debug := debugIDs[*row.DeviceID]; debug {
			continue
		}
		account := owners[*row.DeviceID]
		if account == "" {
			continue
		}
		if current, ok := first[account]; !ok || row.Day < current {
			first[account] = row.Day
		}
	}
	return first, nil
}
