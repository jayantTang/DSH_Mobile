package opsreport

import (
	"context"
	"fmt"
	"sort"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// retentionReportFor 是留存板块：只算用邀请码登记的外部账号。
func retentionReportFor(ctx context.Context, src Source, days int, stamp int64,
	external map[string]struct{}, activeByDay map[int64]map[string]struct{},
	firstSeen map[string]int64) retentionReport {
	window := sortedDays(activeByDay)
	report := retentionReport{Scope: "external", Weeks: []weekRow{}}
	if len(window) == 0 {
		return report
	}
	today := window[len(window)-1]
	start := window[0]
	todaySet := intersect(activeByDay[today], external)
	weekSet := map[string]struct{}{}
	for _, day := range lastDays(window, 7) {
		for account := range intersect(activeByDay[day], external) {
			weekSet[account] = struct{}{}
		}
	}
	monthSet := map[string]struct{}{}
	for _, day := range window {
		for account := range intersect(activeByDay[day], external) {
			monthSet[account] = struct{}{}
		}
	}
	report.Users = retentionUsers{
		DAU: len(todaySet), WAU: len(weekSet), MAU: len(monthSet),
		Stickiness: ratio(len(weekSet), len(monthSet)), External: len(external),
	}
	cohort := func(gap int) *cohortRow {
		limit := dayShift(today, -gap)
		members := make([]string, 0)
		for account := range external {
			first, ok := firstSeen[account]
			if !ok {
				continue
			}
			if first >= start && first <= limit {
				members = append(members, account)
			}
		}
		if len(members) == 0 {
			return nil
		}
		active := 0
		for _, account := range members {
			day := dayShift(firstSeen[account], gap)
			if _, ok := activeByDay[day][account]; ok {
				active++
			}
		}
		return &cohortRow{Rate: ratio(active, len(members)), Cohort: len(members), Active: active}
	}
	report.D1 = cohort(1)
	report.D7 = cohort(7)

	enrollments, err := src.ListEnrollments(ctx)
	if err == nil {
		recent := make([]store.Enrollment, 0, len(enrollments))
		for _, row := range enrollments {
			if isTestEnrollment(row) || row.UsedAt < dayStartMS(start) {
				continue
			}
			if _, ok := external[row.AccountID]; !ok {
				continue
			}
			recent = append(recent, row)
		}
		observable := make([]store.Enrollment, 0, len(recent))
		for _, row := range recent {
			if dayShift(localDayOf(row.UsedAt), 7) <= today {
				observable = append(observable, row)
			}
		}
		activated := 0
		for _, row := range observable {
			first, ok := firstSeen[row.AccountID]
			if !ok {
				continue
			}
			if gap := dayGap(first, localDayOf(row.UsedAt)); gap >= 0 && gap <= 7 {
				activated++
			}
		}
		report.Activation = &activationRow{
			Rate: ratio(activated, len(observable)), Cohort: len(observable), Active: activated,
		}
	}

	type weekKey struct {
		year int
		week int
	}
	buckets := map[weekKey]map[string]struct{}{}
	for account := range external {
		day, ok := firstSeen[account]
		if !ok || day < start {
			continue
		}
		year, week := isoWeek(day)
		key := weekKey{year: year, week: week}
		if buckets[key] == nil {
			buckets[key] = map[string]struct{}{}
		}
		buckets[key][account] = struct{}{}
	}
	keys := make([]weekKey, 0, len(buckets))
	for key := range buckets {
		keys = append(keys, key)
	}
	sort.Slice(keys, func(left, right int) bool {
		if keys[left].year != keys[right].year {
			return keys[left].year < keys[right].year
		}
		return keys[left].week < keys[right].week
	})
	for _, key := range keys {
		followers := make([]int64, 0)
		for _, day := range window {
			year, week := isoWeek(day)
			if year == key.year && week == key.week+1 {
				followers = append(followers, day)
			}
		}
		if len(followers) == 0 || followers[len(followers)-1] >= today {
			continue
		}
		again := map[string]struct{}{}
		for _, day := range followers {
			for account := range activeByDay[day] {
				if _, member := buckets[key][account]; member {
					again[account] = struct{}{}
				}
			}
		}
		report.Weeks = append(report.Weeks, weekRow{
			Week: fmt.Sprintf("%d-W%02d", key.year, key.week),
			Size: len(buckets[key]), Active: len(again),
			Rate: ratio(len(again), len(buckets[key])),
		})
	}
	if len(report.Weeks) > 4 {
		report.Weeks = report.Weeks[len(report.Weeks)-4:]
	}
	return report
}
