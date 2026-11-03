package opsreport

import (
	"context"
	"sort"
)

// messagesPerAccountCap 是直方图的右端：15 条以上并进「15+」一格。
const messagesPerAccountCap = 15

// messagePerAccount 是「每人发出多少条消息」的分布：今天截至生成时刻，与近 7 天的日均分布。
//
// 纵轴是账号数。账号口径与「活跃账号」一致（当天有连接即入分母），所以 0 这一格表示
// 「连上了但一条消息也没发」。基准用近 7 天的**全天**均值：库里只有按天的消息计数，
// 没有时段，做不到「同一时刻」对照（2026-11-03 owner 决定先用全天均值）。
type messagePerAccount struct {
	Cap              int       `json:"cap"`
	Today            []int     `json:"today"`
	Baseline         []float64 `json:"baseline"`
	TodayAccounts    int       `json:"todayAccounts"`
	TodayZero        int       `json:"todayZero"`
	TodayMean        float64   `json:"todayMean"`
	TodayMedian      float64   `json:"todayMedian"`
	BaselineDays     int       `json:"baselineDays"`
	BaselineAccounts float64   `json:"baselineAccounts"`
	BaselineZero     float64   `json:"baselineZero"`
	BaselineMean     float64   `json:"baselineMean"`
	BaselineMedian   float64   `json:"baselineMedian"`
}

func buildMessagesPerAccount(ctx context.Context, src Source, stamp int64,
	debugIDs, knownIDs, external map[string]struct{}) (messagePerAccount, error) {
	today := localDayOf(stamp)
	days := make([]int64, 0, 8)
	for offset := 7; offset >= 0; offset-- {
		days = append(days, dayShift(today, -offset))
	}
	hists := make([][]int, 0, len(days))
	counts := make([]int, 0, len(days))
	zeros := make([]int, 0, len(days))
	sumsOfDay := make([]float64, 0, len(days))
	medians := make([]float64, 0, len(days))
	for _, day := range days {
		rows, err := src.UsageRows(ctx, day)
		if err != nil {
			return messagePerAccount{}, err
		}
		perAccount := map[string]int64{}
		for _, row := range rows {
			if _, debug := debugIDs[row.DeviceID]; debug {
				continue
			}
			if isOrphanUsage(row, knownIDs, external) || row.AccountID == "" {
				continue
			}
			perAccount[row.AccountID] += row.Prompts
		}
		hist := make([]int, messagesPerAccountCap+1)
		values := make([]int64, 0, len(perAccount))
		zero := 0
		var sum int64
		for _, prompts := range perAccount {
			bucket := int(prompts)
			if bucket > messagesPerAccountCap {
				bucket = messagesPerAccountCap
			}
			hist[bucket]++
			if prompts == 0 {
				zero++
			}
			values = append(values, prompts)
			sum += prompts
		}
		hists = append(hists, hist)
		counts = append(counts, len(perAccount))
		zeros = append(zeros, zero)
		if len(values) == 0 {
			sumsOfDay = append(sumsOfDay, 0)
		} else {
			sumsOfDay = append(sumsOfDay, float64(sum)/float64(len(values)))
		}
		medians = append(medians, medianOf(values))
	}

	baselineDays := len(days) - 1
	baseline := make([]float64, messagesPerAccountCap+1)
	baselineCounts, baselineZeros, baselineMeans, baselineMedians := 0.0, 0.0, 0.0, 0.0
	for index := 0; index < baselineDays; index++ {
		for bucket := range baseline {
			baseline[bucket] += float64(hists[index][bucket]) / float64(baselineDays)
		}
		baselineCounts += float64(counts[index]) / float64(baselineDays)
		baselineZeros += float64(zeros[index]) / float64(baselineDays)
		baselineMeans += sumsOfDay[index] / float64(baselineDays)
		baselineMedians += medians[index] / float64(baselineDays)
	}
	last := len(days) - 1
	return messagePerAccount{
		Cap:              messagesPerAccountCap,
		Today:            hists[last],
		Baseline:         baseline,
		TodayAccounts:    counts[last],
		TodayZero:        zeros[last],
		TodayMean:        sumsOfDay[last],
		TodayMedian:      medians[last],
		BaselineDays:     baselineDays,
		BaselineAccounts: baselineCounts,
		BaselineZero:     baselineZeros,
		BaselineMean:     baselineMeans,
		BaselineMedian:   baselineMedians,
	}, nil
}

func medianOf(values []int64) float64 {
	if len(values) == 0 {
		return 0
	}
	sorted := append([]int64(nil), values...)
	sort.Slice(sorted, func(left, right int) bool { return sorted[left] < sorted[right] })
	middle := len(sorted) / 2
	if len(sorted)%2 == 1 {
		return float64(sorted[middle])
	}
	return (float64(sorted[middle-1]) + float64(sorted[middle])) / 2
}
