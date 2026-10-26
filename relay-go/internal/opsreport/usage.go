package opsreport

import (
	"context"
	"math"
	"sort"
)

// usageScan 按天读一遍 usageDaily，同时给出 series / ranked / activeByDay。
//
// 为了区分“7 天内回访”与“超 7 天回访”，实际读取窗口比输出窗口多 7 天：输出日 D 的
// 回访分类需要 D-7..D-1 的活跃集合。多读的 7 天不进入 series / 排名 / 留存集合。
func usageScan(ctx context.Context, src Source, days int, end int64,
	debugIDs map[string]struct{}, names map[string]*string, knownIDs,
	external map[string]struct{}, firstSeen map[string]int64) ([]usageDay, []accountUsageRow,
	map[int64]map[string]struct{}, map[int64]map[string]struct{}, error) {
	seriesDays := recentDays(days, end)
	scanDays := recentDays(days+7, end)
	perDay := make(map[int64]*usageDay, len(seriesDays))
	for _, day := range seriesDays {
		perDay[day] = &usageDay{Day: day}
	}
	allActiveByDay := make(map[int64]map[string]struct{}, len(scanDays))
	allMessageActiveByDay := make(map[int64]map[string]struct{}, len(scanDays))
	for _, day := range scanDays {
		allActiveByDay[day] = map[string]struct{}{}
		allMessageActiveByDay[day] = map[string]struct{}{}
	}
	merged := map[string]*accountUsageRow{}
	seenDevices := map[string]map[string]struct{}{}
	for _, day := range scanDays {
		rows, err := src.UsageRows(ctx, day)
		if err != nil {
			return nil, nil, nil, nil, err
		}
		for _, row := range rows {
			if _, debug := debugIDs[row.DeviceID]; debug {
				continue
			}
			if isOrphanUsage(row, knownIDs, external) {
				continue
			}
			if row.AccountID != "" {
				allActiveByDay[day][row.AccountID] = struct{}{}
				if row.Prompts > 0 {
					allMessageActiveByDay[day][row.AccountID] = struct{}{}
				}
			}
			entry := perDay[day]
			if entry == nil {
				continue // 多读的 7 天只用于回访分类，不进入输出窗口
			}
			entry.EgressBytes += row.EgressBytes
			entry.Connections += row.Connections
			entry.Prompts += row.Prompts
			entry.Answers += row.Answers
			entry.Devices++
			account := merged[row.AccountID]
			if account == nil {
				accountID := row.AccountID
				account = &accountUsageRow{AccountID: &accountID, Name: names[row.AccountID]}
				merged[row.AccountID] = account
			}
			account.EgressBytes += row.EgressBytes
			account.Connections += row.Connections
			account.Prompts += row.Prompts
			account.Answers += row.Answers
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

	// 按天推进 lastActive：D 当天新增的不算回访；上次活跃在 7 天内算“7 天内回访”，
	// 其余（含 7 天以上、或窗口前才有记录）算“超 7 天回访”。
	lastActive := map[string]int64{}
	for _, day := range scanDays {
		if entry := perDay[day]; entry != nil {
			for account := range allActiveByDay[day] {
				if first, ok := firstSeen[account]; ok && first == day {
					continue // NewAccounts 由 buildUsageReport 按同一个 firstSeen 算
				}
				last, seen := lastActive[account]
				if !seen || dayGap(day, last) > 7 {
					entry.ReturningOldAccounts++
				} else {
					entry.Returning7Accounts++
				}
			}
		}
		for account := range allActiveByDay[day] {
			lastActive[account] = day
		}
	}

	series := make([]usageDay, 0, len(seriesDays))
	activeSets := make(map[int64]map[string]struct{}, len(seriesDays))
	messageSets := make(map[int64]map[string]struct{}, len(seriesDays))
	for _, day := range seriesDays {
		entry := perDay[day]
		entry.Accounts = len(allActiveByDay[day])
		entry.MessageAccounts = len(allMessageActiveByDay[day])
		series = append(series, *entry)
		activeSets[day] = allActiveByDay[day]
		messageSets[day] = allMessageActiveByDay[day]
	}
	ranked := make([]accountUsageRow, 0, len(merged))
	for accountID, account := range merged {
		account.Devices = len(seenDevices[accountID])
		ranked = append(ranked, *account)
	}
	sort.SliceStable(ranked, func(left, right int) bool {
		return ranked[left].EgressBytes > ranked[right].EgressBytes
	})
	return series, ranked, activeSets, messageSets, nil
}

// buildUsageReport 是用量板块的 JSON。
func buildUsageReport(series []usageDay, ranked []accountUsageRow,
	activeByDay map[int64]map[string]struct{}, messageActiveByDay map[int64]map[string]struct{},
	firstSeen map[string]int64) usageReport {
	var peak *dayBytes
	var total, totalPrompts, totalAnswers int64
	activeAll := map[string]struct{}{}
	messageAll := map[string]struct{}{}
	for _, entry := range series {
		total += entry.EgressBytes
		totalPrompts += entry.Prompts
		totalAnswers += entry.Answers
		for account := range activeByDay[entry.Day] {
			activeAll[account] = struct{}{}
		}
		for account := range messageActiveByDay[entry.Day] {
			messageAll[account] = struct{}{}
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
	message7d := map[string]struct{}{}
	for _, day := range last7 {
		for account := range activeByDay[day] {
			active7d[account] = struct{}{}
		}
		for account := range messageActiveByDay[day] {
			message7d[account] = struct{}{}
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
	messagesPerAccount := 0.0
	if len(messageAll) > 0 {
		messagesPerAccount = float64(totalPrompts) / float64(len(messageAll))
	}
	return usageReport{
		PerDay: series, TopAccounts: takeAccounts(ranked, reportTopAccounts),
		Totals: usageTotals{EgressBytes: total, Connections: connections,
			Prompts: totalPrompts, Answers: totalAnswers},
		AveragePerDay: average, PeakDay: peak, ActiveDays: activeDays,
		ActiveAccounts: len(activeAll), ActiveAccounts7d: len(active7d),
		MessageActiveAccounts: len(messageAll), MessageActiveAccounts7d: len(message7d),
		MessagesPerAccount: messagesPerAccount,
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
