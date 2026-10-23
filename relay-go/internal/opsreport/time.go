package opsreport

import (
	"sort"
	"time"
)

// ── 本地日/时间 ────────────────────────────────────────────────────────────

func localDayOf(ms int64) int64 {
	local := time.UnixMilli(ms).In(time.Local)
	return int64(local.Year())*10000 + int64(local.Month())*100 + int64(local.Day())
}

func dayStartMS(day int64) int64 {
	year := int(day / 10000)
	month := int(day / 100 % 100)
	date := int(day % 100)
	return time.Date(year, time.Month(month), date, 0, 0, 0, 0, time.Local).UnixMilli()
}

func dayShift(day int64, offset int) int64 {
	year := int(day / 10000)
	month := int(day / 100 % 100)
	date := int(day % 100)
	shifted := time.Date(year, time.Month(month), date, 0, 0, 0, 0, time.Local).
		AddDate(0, 0, offset)
	return int64(shifted.Year())*10000 + int64(shifted.Month())*100 + int64(shifted.Day())
}

func dayGap(later, earlier int64) int {
	// 用 UTC 的日期零点相减：本地时区若有夏令时，一天可能是 23/25 小时。
	left := time.Date(int(later/10000), time.Month(int(later/100%100)),
		int(later%100), 0, 0, 0, 0, time.UTC)
	right := time.Date(int(earlier/10000), time.Month(int(earlier/100%100)),
		int(earlier%100), 0, 0, 0, 0, time.UTC)
	return int(left.Sub(right).Hours() / 24)
}

func isoWeek(day int64) (int, int) {
	date := time.Date(int(day/10000), time.Month(int(day/100%100)),
		int(day%100), 0, 0, 0, 0, time.Local)
	return date.ISOWeek()
}

// recentDays 是最近 N 天的本地日序号（含 end 所在的那一天），从早到晚。
func recentDays(days int, end int64) []int64 {
	if days < 1 {
		days = 1
	}
	endDay := localDayOf(end)
	seen := map[int64]struct{}{}
	out := make([]int64, 0, days)
	for offset := 0; offset < days; offset++ {
		day := dayShift(endDay, -offset)
		if _, ok := seen[day]; ok {
			continue
		}
		seen[day] = struct{}{}
		out = append(out, day)
	}
	sort.Slice(out, func(left, right int) bool { return out[left] < out[right] })
	return out
}

func sortedDays(values map[int64]map[string]struct{}) []int64 {
	out := make([]int64, 0, len(values))
	for day := range values {
		out = append(out, day)
	}
	sort.Slice(out, func(left, right int) bool { return out[left] < out[right] })
	return out
}

func lastDays(days []int64, count int) []int64 {
	if len(days) <= count {
		return days
	}
	return days[len(days)-count:]
}
