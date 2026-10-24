// Package opsreport 构建 relay 的 ops-report 报告。
//
// 这里是报告的形状、聚合与日算术；取数只经过 Source（10 个方法），SQL 与业务
// 规则仍在 store，journalctl 的进程调用留在 admincli。报告是只读的：本包不写库，
// 也不缓存任何跨次请求的状态。
//
// 输出兼容是硬约束：JSON 字段名、键序、缩进（2 空格）与 SetEscapeHTML(false)
// 形状固定；scripts/dev/feedback.mjs 直接消费
// 这份 JSON，改名即破坏日报。
package opsreport

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// 日报的窗口与上限（与 admin.py 的同名常量一致）。
const (
	// reportThreadLimit 是一份报告最多列出的反馈线程。
	reportThreadLimit = 1000
	// reportDeviceLimit 是设备清单的上限：生产库上历史设备有 1900+ 行。
	reportDeviceLimit = 200
	// reportTopAccounts 是出口排名最多列几个账号。
	reportTopAccounts = 20
	// reportTodayLimit 是「今日」板块每类明细的上限。
	reportTodayLimit = 20
	// reportActivityDays 是活跃分布矩阵的窗口：14 天 × 24 小时（owner 2026-10-24 定，
	// 原来是过去 72 小时）。窗口按本地日起算，行列才是整齐的 24×14。
	reportActivityDays = 14
	// reportActivityHours 是把上面的天数折算成小时，写进 JSON 的 windowHours。
	reportActivityHours = reportActivityDays * 24
	// reportVersionHours 是版本分布的窗口（只看最近 48 小时连过的用户）。
	reportVersionHours = 48
	// retentionHistoryDays 是"账号第一次活跃"的查询上界。
	retentionHistoryDays = 400
	// DefaultJournalUnits 是 systemd 单元名（逗号分隔）：2026-10-24 生产从前端 Python
	// （dsh-relay）切到 Go（dsh-relay-go），14 天窗口跨切换点，两份日志都要读。
	DefaultJournalUnits = "dsh-relay,dsh-relay-go"
)

// Source 是报告构建的取数面：只包含本包实际调用的 10 个仓储方法。
//
// 接口声明在使用方（Go 的 consumer-side interface）；实现是 *store.Store，编译期
// 断言在 ports_test.go 里。取数不做二次封装、不加缓存：报告是一次性只读命令。
type Source interface {
	ListDevices(ctx context.Context, agentID string, includeRevoked bool) ([]store.Device, error)
	ListAgents(ctx context.Context, accountID string) ([]store.Agent, error)
	ListAccounts(ctx context.Context) ([]store.Account, error)
	ListInvites(ctx context.Context, includeUsed bool) ([]store.Invite, error)
	ListEnrollments(ctx context.Context) ([]store.Enrollment, error)
	UsageRows(ctx context.Context, day int64) ([]store.UsageRow, error)
	UsageTotals(ctx context.Context, days int, by string) ([]store.UsageTotal, error)
	OwnerUnreadCounts(ctx context.Context) (map[string]int, error)
	ListFeedbackThreads(ctx context.Context, status *string, sinceMS *int64,
		limit int, messagesPerThread int) ([]store.FeedbackThread, error)
	FeedbackDigest(ctx context.Context, threadIDs []string,
		excerptChars int) (map[string]store.FeedbackDigestEntry, error)
}

// Options 是一次报告构建的全部锚点。
type Options struct {
	// Days 是窗口天数（本地日，含锚点那一天）；小于 1 按 1 处理。
	Days int
	// AsOfStamp 是报告锚点（毫秒）；由 ResolveAsOf 从 --as-of 翻出来。
	AsOfStamp int64
	// GeneratedAt 是"生成时刻"（毫秒），只用于输出，不参与过滤。
	GeneratedAt int64
	// JournalUnits 是 systemd 单元名列表。调用方给什么就传什么：空列表与命令行一致
	// （取不到日志），不在包内偷偷回退成默认值。
	JournalUnits []string
	// Journal 取某段时间的系统日志；nil 或 ok=false 时 hourlyActivity.buckets
	// 输出 null（不编数字）。生产由 admincli 注入 journalctl 调用。
	Journal func(unit string, sinceMS, untilMS int64) ([]string, bool)
}

// Report 组装整份报告。返回的形状是包内类型，调用方只需把它交给 JSON 编码器。
func Report(ctx context.Context, src Source, opts Options) (any, error) {
	days := opts.Days
	if days < 1 {
		days = 1
	}
	report, err := build(ctx, src, days, opts.AsOfStamp, opts.GeneratedAt,
		opts.JournalUnits, opts.Journal)
	if err != nil {
		return nil, err
	}
	return report, nil
}

// ResolveAsOf 把 --as-of 翻成报告锚点（毫秒）。
func ResolveAsOf(value string, now int64) (int64, error) {
	text := strings.TrimSpace(value)
	if text == "" || text == "now" {
		return now, nil
	}
	if text == "yesterday" {
		return dayStartMS(localDayOf(now)) - 1, nil
	}
	parsed, err := time.ParseInLocation("2006-01-02", text, time.Local)
	if err != nil {
		return 0, fmt.Errorf("--as-of 只能是 now / yesterday / YYYY-MM-DD，收到 %q", value)
	}
	day := int64(parsed.Year())*10000 + int64(parsed.Month())*100 + int64(parsed.Day())
	return dayStartMS(dayShift(day, 1)) - 1, nil
}
