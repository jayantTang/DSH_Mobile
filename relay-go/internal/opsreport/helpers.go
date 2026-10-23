package opsreport

import (
	"math"
	"sort"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// ── 通用小工具 ─────────────────────────────────────────────────────────────

func sumCounts(rows []dayCount) int {
	total := 0
	for _, row := range rows {
		total += row.Count
	}
	return total
}

func countActive(devices []store.Device, lastSeen map[string]int64, from, to int64) int {
	count := 0
	for _, device := range devices {
		seen, ok := lastSeen[device.DeviceID]
		if ok && seen >= from && seen <= to {
			count++
		}
	}
	return count
}

func countUsable(rows []store.Invite, stamp int64) int {
	count := 0
	for _, row := range rows {
		if row.ExpiresAt > stamp {
			count++
		}
	}
	return count
}

func countExpiringSoon(rows []store.Invite, stamp int64) int {
	soon := stamp + 7*86_400_000
	count := 0
	for _, row := range rows {
		if row.ExpiresAt > stamp && row.ExpiresAt <= soon {
			count++
		}
	}
	return count
}

func countExpiredUnused(rows []store.Invite, stamp int64) int {
	count := 0
	for _, row := range rows {
		if row.ExpiresAt <= stamp {
			count++
		}
	}
	return count
}

func inviteUnusedRows(rows []store.Invite, stamp int64) []inviteUnused {
	usable := make([]inviteUnused, 0, len(rows))
	for _, row := range rows {
		if row.ExpiresAt <= stamp {
			continue
		}
		usable = append(usable, inviteUnused{
			CreatedAt: row.CreatedAt, ExpiresAt: row.ExpiresAt, Note: row.Note,
		})
	}
	sort.SliceStable(usable, func(left, right int) bool {
		return usable[left].ExpiresAt < usable[right].ExpiresAt
	})
	if len(usable) > 12 {
		usable = usable[:12]
	}
	return usable
}

func takeAccounts(rows []accountUsageRow, limit int) []accountUsageRow {
	if len(rows) > limit {
		return rows[:limit]
	}
	return rows
}

func takeTodayAccounts(rows []todayAccountRow, limit int) []todayAccountRow {
	if len(rows) > limit {
		return rows[:limit]
	}
	return rows
}

func takeDeviceRows(rows []todayDeviceRow, limit int) []todayDeviceRow {
	if len(rows) > limit {
		return rows[:limit]
	}
	return rows
}

func takeEnrollments(rows []store.Enrollment, limit int) []store.Enrollment {
	if len(rows) > limit {
		return rows[:limit]
	}
	return rows
}

func intersect(values map[string]struct{}, keep map[string]struct{}) map[string]struct{} {
	out := map[string]struct{}{}
	for value := range values {
		if _, ok := keep[value]; ok {
			out[value] = struct{}{}
		}
	}
	return out
}

func ratio(active, cohort int) *float64 {
	if cohort == 0 {
		return nil
	}
	value := math.RoundToEven(float64(active)/float64(cohort)*1000) / 1000
	return &value
}

func int64Value(value *int64) int64 {
	if value == nil {
		return 0
	}
	return *value
}
