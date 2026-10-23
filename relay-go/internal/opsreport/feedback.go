package opsreport

import (
	"context"
	"math"
	"sort"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// feedbackDigestExcerptChars 是清单摘要的长度（Python `_feedback_rows` 的口径）。
const feedbackDigestExcerptChars = 80

// FeedbackSource 是清单里的来源段（Python `_feedback_rows` 的 `source`）。
type FeedbackSource struct {
	Kind          string  `json:"kind"`
	DeviceID      *string `json:"deviceId"`
	AccountID     *string `json:"accountId"`
	DeviceModel   *string `json:"deviceModel"`
	AppVersion    *string `json:"appVersion"`
	SystemVersion *string `json:"systemVersion"`
}

// FeedbackRow 是反馈清单的一行；字段名与 admin.py 一致。
//
// feedback-list 与 ops-report 的 feedback/today 板块共用这一份投影：摘要长度、
// 来源判定与格式回退只在这里定义一次。
type FeedbackRow struct {
	ThreadID      string         `json:"threadId"`
	Subject       *string        `json:"subject"`
	CreatedAt     int64          `json:"createdAt"`
	LastMessageAt int64          `json:"lastMessageAt"`
	Status        string         `json:"status"`
	OwnerUnread   int            `json:"ownerUnread"`
	Source        FeedbackSource `json:"source"`
	Excerpt       string         `json:"excerpt"`
	Format        string         `json:"format"`
	Messages      int            `json:"messages"`
}

// FeedbackRows 是 owner 清单的每一行。
//
// 未读数与摘要各一次查完：清单默认不带留言，而 owner 要的两个数都在消息表里。
func FeedbackRows(ctx context.Context, src Source, status *string, sinceMS *int64,
	limit int) ([]FeedbackRow, error) {
	unread, err := src.OwnerUnreadCounts(ctx)
	if err != nil {
		return nil, err
	}
	threads, err := src.ListFeedbackThreads(ctx, status, sinceMS, limit, 0)
	if err != nil {
		return nil, err
	}
	ids := make([]string, 0, len(threads))
	for _, thread := range threads {
		ids = append(ids, thread.ThreadID)
	}
	digest, err := src.FeedbackDigest(ctx, ids, feedbackDigestExcerptChars)
	if err != nil {
		return nil, err
	}

	rows := make([]FeedbackRow, 0, len(threads))
	for _, thread := range threads {
		entry := digest[thread.ThreadID]
		kind := "anonymous"
		if thread.DeviceID != nil || thread.AccountID != nil {
			kind = "device"
		}
		format := entry.Format
		if format == "" {
			format = store.DefaultFeedbackFormat
		}
		rows = append(rows, FeedbackRow{
			ThreadID: thread.ThreadID, Subject: thread.Subject,
			CreatedAt: thread.CreatedAt, LastMessageAt: thread.LastMessageAt,
			Status: thread.Status, OwnerUnread: unread[thread.ThreadID],
			Source: FeedbackSource{
				Kind: kind, DeviceID: thread.DeviceID, AccountID: thread.AccountID,
				DeviceModel: thread.DeviceModel, AppVersion: thread.AppVersion,
				SystemVersion: thread.SystemVersion,
			},
			Excerpt: entry.Excerpt, Format: format, Messages: thread.MessageCount,
		})
	}
	return rows, nil
}

// isTestThread 判定"测试台来源"的线程：来自调试设备或已知的模拟器机型。
func isTestThread(row FeedbackRow, debugIDs map[string]struct{}) bool {
	if row.Source.DeviceID != nil {
		if _, debug := debugIDs[*row.Source.DeviceID]; debug {
			return true
		}
	}
	model := ""
	if row.Source.DeviceModel != nil {
		model = *row.Source.DeviceModel
	}
	_, test := testDeviceModels[model]
	return test
}

// filterFeedback 过滤清单行（报告按锚点裁掉锚点之后创建的线程）。
func filterFeedback(rows []FeedbackRow, keep func(FeedbackRow) bool) []FeedbackRow {
	out := make([]FeedbackRow, 0, len(rows))
	for _, row := range rows {
		if keep(row) {
			out = append(out, row)
		}
	}
	return out
}

// takeFeedbackRows 截取前 limit 行。
func takeFeedbackRows(rows []FeedbackRow, limit int) []FeedbackRow {
	if len(rows) > limit {
		return rows[:limit]
	}
	return rows
}

var testDeviceModels = map[string]struct{}{
	"arm64": {}, "x86_64": {}, "deploy-check": {}, "Node": {},
	"simulator": {}, "test-harness": {},
}

// buildFeedbackReport 是反馈板块：窗口内的新增/待回复/已回复、首复中位小时数。
func buildFeedbackReport(ctx context.Context, src Source, threads []FeedbackRow,
	testCount int) (feedbackReport, error) {
	ids := make([]string, 0, len(threads))
	for _, thread := range threads {
		ids = append(ids, thread.ThreadID)
	}
	digest, err := src.FeedbackDigest(ctx, ids, 0)
	if err != nil {
		return feedbackReport{}, err
	}
	spans := make([]float64, 0, len(threads))
	open, replied := 0, 0
	for _, thread := range threads {
		if thread.Status == "open" {
			open++
		}
		if thread.Status == "replied" {
			replied++
		}
		if entry, ok := digest[thread.ThreadID]; ok && entry.FirstReplyAt != nil {
			spans = append(spans, float64(*entry.FirstReplyAt-thread.CreatedAt)/3_600_000)
		}
	}
	sort.Float64s(spans)
	var median *float64
	if len(spans) > 0 {
		middle := len(spans) / 2
		value := spans[middle]
		if len(spans)%2 == 0 {
			value = (spans[middle-1] + spans[middle]) / 2
		}
		rounded := math.RoundToEven(value*10) / 10
		median = &rounded
	}
	return feedbackReport{
		New: len(threads), Open: open, Replied: replied,
		MedianFirstReplyHours: median, Test: testCount, Threads: threads,
	}, nil
}
