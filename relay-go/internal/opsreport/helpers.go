package opsreport

import (
	"math"
	"sort"
	"strings"

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

// publicInvite 判断一张码是否面向公众发放。
//
// 评审演示码（备注以 `App Review` 开头）也在库里、也「未用未过期」，但它**不能发**
// 给用户。日报的「可用 N 张」若把它们算进去，就会出现「报表说还剩 2 张、网页上
// 一个也没有」（2026-11-01 实际发生）。内部码一律不计入余量。
func publicInvite(row store.Invite) bool {
	note := strings.TrimSpace(derefString(row.Note))
	return !strings.HasPrefix(strings.ToLower(note), "app review")
}

func countUsable(rows []store.Invite, stamp int64) int {
	count := 0
	for _, row := range rows {
		if row.ExpiresAt > stamp && publicInvite(row) {
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
		if row.ExpiresAt <= stamp || !publicInvite(row) {
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

// derefString 把可空字符串拍平；nil 与空串都当空串。
func derefString(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}
