package opsreport

import (
	"context"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// build 组装报告的全部板块。
//
// 过滤口径与本函数同名逻辑一一对应（锚点前后的裁切、调试设备剔除、孤立用量
// 剔除）；这里只做装配，各板块的聚合在 versions/activity/today/usage/retention。
func build(ctx context.Context, src Source, days int, stamp, generated int64,
	journalUnits []string, journal func(string, int64, int64) ([]string, bool)) (opsReport, error) {
	threadsSince := stamp - int64(days)*86_400_000
	listed, err := FeedbackRows(ctx, src, nil, &threadsSince, reportThreadLimit)
	if err != nil {
		return opsReport{}, err
	}
	// since_ms 只有下界：锚点在过去时，锚点之后新建的线程不属于这份报告。
	listed = filterFeedback(listed, func(row FeedbackRow) bool {
		return row.CreatedAt <= stamp
	})

	devices, err := src.ListDevices(ctx, "", true)
	if err != nil {
		return opsReport{}, err
	}
	agents, err := src.ListAgents(ctx, "")
	if err != nil {
		return opsReport{}, err
	}
	agentVersions := make(map[string]store.Agent, len(agents))
	for _, agent := range agents {
		agentVersions[agent.AgentID] = agent
	}
	accounts, err := src.ListAccounts(ctx)
	if err != nil {
		return opsReport{}, err
	}
	names := make(map[string]*string, len(accounts))
	for _, account := range accounts {
		value := account.Name
		names[account.AccountID] = &value
	}
	debugIDs := make(map[string]struct{})
	debugRows := 0
	for _, device := range devices {
		if isDebugDevice(device) {
			debugIDs[device.DeviceID] = struct{}{}
			if device.CreatedAt <= stamp {
				debugRows++
			}
		}
	}
	real := make([]store.Device, 0, len(devices))
	for _, device := range devices {
		if _, debug := debugIDs[device.DeviceID]; debug {
			continue
		}
		if device.CreatedAt > stamp {
			continue
		}
		real = append(real, device)
	}
	live := make([]store.Device, 0, len(real))
	for _, device := range real {
		if device.RevokedAt == nil || *device.RevokedAt > stamp {
			live = append(live, device)
		}
	}
	threads := make([]FeedbackRow, 0, len(listed))
	for _, row := range listed {
		if !isTestThread(row, debugIDs) {
			threads = append(threads, row)
		}
	}

	// 「每日新增手机」按手机去重：重装/换版本会插新设备行，不去重会记成新用户。
	createdPerDay := map[int64]int{}
	rawPerDay := map[int64]int{}
	for _, device := range real {
		rawPerDay[localDayOf(device.CreatedAt)]++
	}
	for _, device := range firstDeviceRows(real) {
		createdPerDay[localDayOf(device.CreatedAt)]++
	}
	recent := recentDays(days, stamp)
	newPerDay := make([]dayCount, 0, len(recent))
	rawNewPerDay := make([]dayCount, 0, len(recent))
	for _, day := range recent {
		newPerDay = append(newPerDay, dayCount{Day: day, Count: createdPerDay[day]})
		rawNewPerDay = append(rawNewPerDay, dayCount{Day: day, Count: rawPerDay[day]})
	}

	enrollments, err := src.ListEnrollments(ctx)
	if err != nil {
		return opsReport{}, err
	}
	testEnrollments := 0
	realEnrollments := make([]store.Enrollment, 0, len(enrollments))
	for _, row := range enrollments {
		if isTestEnrollment(row) {
			testEnrollments++
			continue
		}
		if row.UsedAt > stamp {
			continue
		}
		realEnrollments = append(realEnrollments, row)
	}
	external := make(map[string]struct{}, len(realEnrollments))
	for _, row := range realEnrollments {
		if row.AccountID != "" {
			external[row.AccountID] = struct{}{}
		}
	}

	invites, err := src.ListInvites(ctx, true)
	if err != nil {
		return opsReport{}, err
	}
	invitesAsOf := make([]store.Invite, 0, len(invites))
	for _, invite := range invites {
		if invite.CreatedAt <= stamp {
			invitesAsOf = append(invitesAsOf, invite)
		}
	}
	unusedAsOf := make([]store.Invite, 0, len(invitesAsOf))
	usedByStamp := 0
	for _, invite := range invitesAsOf {
		if invite.UsedAt != nil && *invite.UsedAt <= stamp {
			usedByStamp++
			continue
		}
		unusedAsOf = append(unusedAsOf, invite)
	}
	inviteTotals := store.InviteTotals{
		Minted: len(invitesAsOf), Used: usedByStamp, Remaining: len(unusedAsOf),
	}

	lastSeenByDevice := map[string]int64{}
	for _, day := range recent {
		rows, err := src.UsageRows(ctx, day)
		if err != nil {
			return opsReport{}, err
		}
		for _, row := range rows {
			seen := row.LastSeenAt
			if seen > stamp {
				seen = stamp
			}
			if seen > lastSeenByDevice[row.DeviceID] {
				lastSeenByDevice[row.DeviceID] = seen
			}
		}
	}

	knownIDs := make(map[string]struct{}, len(devices))
	for _, device := range devices {
		knownIDs[device.DeviceID] = struct{}{}
	}
	series, ranked, activeByDay, err := usageScan(ctx, src, days, stamp, debugIDs, names,
		knownIDs, external)
	if err != nil {
		return opsReport{}, err
	}
	owners := make(map[string]string, len(devices))
	for _, device := range devices {
		owners[device.DeviceID] = device.AccountID
	}
	firstSeen, err := firstSeenDays(ctx, src, debugIDs, owners)
	if err != nil {
		return opsReport{}, err
	}

	versions, err := versionReport(ctx, src, stamp, devices, debugIDs, knownIDs, external)
	if err != nil {
		return opsReport{}, err
	}
	today, err := buildTodayReport(ctx, src, stamp, threads, real, debugIDs, names,
		knownIDs, external)
	if err != nil {
		return opsReport{}, err
	}
	feedbackSection, err := buildFeedbackReport(ctx, src, threads, len(listed)-len(threads))
	if err != nil {
		return opsReport{}, err
	}
	usageSection := buildUsageReport(series, ranked, activeByDay, firstSeen)

	report := opsReport{
		OK: true, GeneratedAt: generated, AsOf: stamp, Days: days,
		Versions: versions, VersionsWindowHours: reportVersionHours,
		HourlyActivity: hourlyActivity{
			WindowDays:  reportActivityDays,
			WindowHours: reportActivityHours,
			Buckets: hourlyActivityBuckets(
				dayStartMS(dayShift(localDayOf(stamp), -(reportActivityDays-1))), stamp,
				devices, agentVersions, journalUnits, journal),
		},
		Today:    today,
		Feedback: feedbackSection,
		Devices: deviceReport{
			Paired:         len(live),
			Active7d:       countActive(live, lastSeenByDevice, stamp-7*86_400_000, stamp),
			ActiveWindow:   countActive(live, lastSeenByDevice, stamp-int64(days)*86_400_000, stamp),
			NewInWindow:    sumCounts(newPerDay),
			NewRawInWindow: sumCounts(rawNewPerDay),
			WindowDays:     days,
			Revoked:        len(real) - len(live),
			Debug:          debugRows,
			NewPerDay:      newPerDay,
			NewRawPerDay:   rawNewPerDay,
			List:           deviceReportList(live, lastSeenByDevice, agentVersions, names),
		},
		Usage:     usageSection,
		Retention: retentionReportFor(ctx, src, days, stamp, external, activeByDay, firstSeen),
		Invites: inviteReport{
			Minted: inviteTotals.Minted, Used: inviteTotals.Used,
			Remaining: inviteTotals.Remaining, Test: testEnrollments,
			Usable:        countUsable(unusedAsOf, stamp),
			ExpiringSoon:  countExpiringSoon(unusedAsOf, stamp),
			ExpiredUnused: countExpiredUnused(unusedAsOf, stamp),
			Unused:        inviteUnusedRows(unusedAsOf, stamp),
			Enrollments:   realEnrollments,
		},
	}
	return report, nil
}
