package opsreport

import (
	"context"
	"math"
	"sort"
)

// usageScan 按天读一遍 usageDaily，同时给出 series / ranked / activeByDay。
//
// 消息活跃账号按“首次发出消息”分三档：当天首次发消息算新增；首次发消息在最近
// 7 天内算回访；首次发消息在 7 天以前、且今天仍发消息算超 7 天回访。三档互斥，
// 加起来等于当天 messageAccounts。firstPrompt 来自 400 天历史，不是本次窗口。
func usageScan(ctx context.Context, src Source, days int, end int64,
	debugIDs map[string]struct{}, names map[string]*string, knownIDs,
	external map[string]struct{}, firstPrompt map[string]int64) ([]usageDay, []accountUsageRow,
	map[int64]map[string]struct{}, map[int64]map[string]struct{}, error) {
	recent := recentDays(days, end)
	perDay := make(map[int64]*usageDay, len(recent))
	activeByDay := make(map[int64]map[string]struct{}, len(recent))
	messageActiveByDay := make(map[int64]map[string]struct{}, len(recent))
	for _, day := range recent {
		perDay[day] = &usageDay{Day: day}
		activeByDay[day] = map[string]struct{}{}
		messageActiveByDay[day] = map[string]struct{}{}
	}
	merged := map[string]*accountUsageRow{}
	seenDevices := map[string]map[string]struct{}{}
	for _, day := range recent {
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
			entry := perDay[day]
			entry.EgressBytes += row.EgressBytes
			entry.Connections += row.Connections
			entry.Prompts += row.Prompts
			entry.Answers += row.Answers
			entry.Devices++
			if row.AccountID != "" {
				activeByDay[day][row.AccountID] = struct{}{}
				if row.Prompts > 0 {
					messageActiveByDay[day][row.AccountID] = struct{}{}
				}
			}
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
	for _, day := range recent {
		entry := perDay[day]
		for account := range messageActiveByDay[day] {
			first, known := firstPrompt[account]
			switch {
			case !known:
				entry.MessageReturningOldAccounts++
			case first == day:
				entry.MessageNewAccounts++
			case dayGap(day, first) <= 7:
				entry.MessageReturning7Accounts++
			default:
				entry.MessageReturningOldAccounts++
			}
		}
	}
	series := make([]usageDay, 0, len(recent))
	for _, day := range recent {
		entry := perDay[day]
		entry.Accounts = len(activeByDay[day])
		entry.MessageAccounts = len(messageActiveByDay[day])
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
	return series, ranked, activeByDay, messageActiveByDay, nil
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

// firstSeenDays 是每个账号第一次有用量记录与第一次发出消息的本地日。
//
// 前者是连接活跃留存的起点；后者是消息活跃账号三档（当日新增 / 7 天内 /
// 超 7 天）的唯一口径，不能用连接首次活跃代替“首次使用设备发出消息”。
func firstSeenDays(ctx context.Context, src Source, debugIDs map[string]struct{},
	owners map[string]string) (map[string]int64, map[string]int64, error) {
	rows, err := src.UsageTotals(ctx, retentionHistoryDays, "device")
	if err != nil {
		return nil, nil, err
	}
	first := map[string]int64{}
	firstPrompt := map[string]int64{}
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
		if row.Prompts > 0 {
			if current, ok := firstPrompt[account]; !ok || row.Day < current {
				firstPrompt[account] = row.Day
			}
		}
	}
	return first, firstPrompt, nil
}
