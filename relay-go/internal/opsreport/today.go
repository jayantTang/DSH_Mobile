package opsreport

import (
	"context"
	"sort"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// buildTodayReport 是「今日」板块：锚点所在本地自然日 00:00 起（到锚点为止）。
func buildTodayReport(ctx context.Context, src Source, stamp int64,
	threads []FeedbackRow, real []store.Device, debugIDs map[string]struct{},
	names map[string]*string, knownIDs, external map[string]struct{}) (todayReport, error) {
	day := localDayOf(stamp)
	start := dayStartMS(day)
	known := make(map[string]store.Device, len(real))
	for _, device := range real {
		known[device.DeviceID] = device
	}
	freshRows := firstDeviceRows(real)

	byDevice := []todayDeviceRow{}
	byAccount := map[string]*todayAccountRow{}
	builds := map[string]*struct {
		devices  int
		accounts map[string]struct{}
	}{}
	var egress, connections int64
	var firstSeen, lastSeen *int64
	rows, err := src.UsageRows(ctx, day)
	if err != nil {
		return todayReport{}, err
	}
	for _, row := range rows {
		if _, debug := debugIDs[row.DeviceID]; debug {
			continue
		}
		if isOrphanUsage(row, knownIDs, external) {
			continue
		}
		device := known[row.DeviceID]
		size := row.EgressBytes
		count := row.Connections
		egress += size
		connections += count
		from := row.FirstSeenAt
		to := row.LastSeenAt
		if firstSeen == nil || from < *firstSeen {
			firstSeen = &from
		}
		if lastSeen == nil || to > *lastSeen {
			lastSeen = &to
		}
		if row.LastBuild != nil && *row.LastBuild != "" {
			build := builds[*row.LastBuild]
			if build == nil {
				build = &struct {
					devices  int
					accounts map[string]struct{}
				}{accounts: map[string]struct{}{}}
				builds[*row.LastBuild] = build
			}
			build.devices++
			if row.AccountID != "" {
				build.accounts[row.AccountID] = struct{}{}
			}
		}
		account := byAccount[row.AccountID]
		if account == nil {
			account = &todayAccountRow{AccountID: &row.AccountID,
				Name: names[row.AccountID]}
			byAccount[row.AccountID] = account
		}
		account.EgressBytes += size
		account.Connections += count
		account.Devices++
		deviceName := device.Name
		entry := todayDeviceRow{
			DeviceID: row.DeviceID, Name: &deviceName, Model: device.Model,
			AppVersion: device.AppVersion, AccountID: row.AccountID,
			AccountName: names[row.AccountID], EgressBytes: size, Connections: count,
			LastBuild: row.LastBuild, Revoked: device.RevokedAt != nil,
		}
		fromValue, toValue := from, to
		entry.FirstSeenAt = &fromValue
		entry.LastSeenAt = &toValue
		byDevice = append(byDevice, entry)
	}
	sort.SliceStable(byDevice, func(left, right int) bool {
		if byDevice[left].EgressBytes != byDevice[right].EgressBytes {
			return byDevice[left].EgressBytes > byDevice[right].EgressBytes
		}
		return byDevice[left].Connections > byDevice[right].Connections
	})
	ranked := make([]todayAccountRow, 0, len(byAccount))
	for _, row := range byAccount {
		ranked = append(ranked, *row)
	}
	sort.SliceStable(ranked, func(left, right int) bool {
		return ranked[left].EgressBytes > ranked[right].EgressBytes
	})

	live := make([]store.Device, 0, len(real))
	for _, device := range real {
		if device.RevokedAt == nil || *device.RevokedAt > stamp {
			live = append(live, device)
		}
	}
	freshThreads := make([]FeedbackRow, 0, len(threads))
	for _, thread := range threads {
		if thread.CreatedAt >= start && thread.CreatedAt <= stamp {
			freshThreads = append(freshThreads, thread)
		}
	}
	enrollments, err := src.ListEnrollments(ctx)
	if err != nil {
		return todayReport{}, err
	}
	todayEnrollments := make([]store.Enrollment, 0, len(enrollments))
	for _, row := range enrollments {
		if row.UsedAt >= start && row.UsedAt <= stamp && !isTestEnrollment(row) {
			todayEnrollments = append(todayEnrollments, row)
		}
	}

	buildRows := make([]buildRow, 0, len(builds))
	for build, entry := range builds {
		buildRows = append(buildRows, buildRow{
			Build: build, Devices: entry.devices, Accounts: len(entry.accounts),
		})
	}
	sort.SliceStable(buildRows, func(left, right int) bool {
		if buildRows[left].Devices != buildRows[right].Devices {
			return buildRows[left].Devices > buildRows[right].Devices
		}
		return buildRows[left].Build < buildRows[right].Build
	})

	newPhones := 0
	for _, device := range freshRows {
		if device.CreatedAt >= start && device.CreatedAt <= stamp {
			newPhones++
		}
	}
	newRaw := 0
	for _, device := range real {
		if device.CreatedAt >= start && device.CreatedAt <= stamp {
			newRaw++
		}
	}
	active := 0
	revokedToday := 0
	for _, device := range live {
		if device.LastSeenAt != nil && *device.LastSeenAt >= start && *device.LastSeenAt <= stamp {
			active++
		}
	}
	for _, device := range real {
		if device.RevokedAt != nil && *device.RevokedAt >= start && *device.RevokedAt <= stamp {
			revokedToday++
		}
	}

	openThreads, repliedThreads := 0, 0
	for _, thread := range freshThreads {
		switch thread.Status {
		case "open":
			openThreads++
		case "replied":
			repliedThreads++
		}
	}
	accountsCount := 0
	for accountID := range byAccount {
		if accountID != "" {
			accountsCount++
		}
	}
	return todayReport{
		Day: day, DayStartAt: start,
		Usage: todayUsage{
			EgressBytes: egress, Connections: connections, Devices: len(byDevice),
			Accounts: accountsCount, FirstSeenAt: firstSeen, LastSeenAt: lastSeen,
			Builds: buildRows,
		},
		TopAccounts: takeTodayAccounts(ranked, reportTodayLimit),
		Devices: todayDevices{
			List: takeDeviceRows(byDevice, reportTodayLimit), New: newPhones,
			NewRaw: newRaw, Active: active, Revoked: revokedToday, Live: len(live),
		},
		Feedback: todayFeedback{
			New: len(freshThreads), Open: openThreads, Replied: repliedThreads,
			Threads: takeFeedbackRows(freshThreads, reportTodayLimit),
		},
		Invites: todayInvites{
			Used:        len(todayEnrollments),
			Enrollments: takeEnrollments(todayEnrollments, reportTodayLimit),
		},
	}, nil
}
