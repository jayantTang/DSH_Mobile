package admincli

import (
	"context"
	"fmt"
	"io"
	"math"
	"os/exec"
	"regexp"
	"sort"
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
	// reportActivityHours 是「过去 72 小时」分布图的窗口。
	reportActivityHours = 72
	// reportVersionHours 是版本分布的窗口（只看最近 48 小时连过的用户）。
	reportVersionHours = 48
	// retentionHistoryDays 是"账号第一次活跃"的查询上界。
	retentionHistoryDays = 400
	// defaultJournalUnit 是 systemd 单元名。
	defaultJournalUnit = "dsh-relay"
)

// testDeviceModels 是模拟器 / 测试台来源上报的"机型"：日报按它把验收单剔出去。
var testDeviceModels = map[string]struct{}{
	"arm64": {}, "x86_64": {}, "deploy-check": {}, "Node": {},
	"simulator": {}, "test-harness": {},
}

// ── 出参形状（字段顺序与 admin.py 一致）────────────────────────────────────

type opsReport struct {
	OK                  bool            `json:"ok"`
	GeneratedAt         int64           `json:"generatedAt"`
	AsOf                int64           `json:"asOf"`
	Days                int             `json:"days"`
	Versions            []versionRow    `json:"versions"`
	VersionsWindowHours int             `json:"versionsWindowHours"`
	HourlyActivity      hourlyActivity  `json:"hourlyActivity"`
	Today               todayReport     `json:"today"`
	Feedback            feedbackReport  `json:"feedback"`
	Devices             deviceReport    `json:"devices"`
	Usage               usageReport     `json:"usage"`
	Retention           retentionReport `json:"retention"`
	Invites             inviteReport    `json:"invites"`
}

type versionRow struct {
	AppVersion *string `json:"appVersion"`
	Devices    int     `json:"devices"`
	Accounts   int     `json:"accounts"`
	LastSeenAt *int64  `json:"lastSeenAt"`
}

type hourlyActivity struct {
	WindowHours int            `json:"windowHours"`
	Buckets     []hourlyBucket `json:"buckets"`
}

type hourlyBucket struct {
	HourStartAt int64 `json:"hourStartAt"`
	Accounts    int   `json:"accounts"`
	Devices     int   `json:"devices"`
}

type dayCount struct {
	Day   int64 `json:"day"`
	Count int   `json:"count"`
}

type dayBytes struct {
	Day         int64 `json:"day"`
	EgressBytes int64 `json:"egressBytes"`
}

type accountUsageRow struct {
	AccountID   *string `json:"accountId"`
	Name        *string `json:"name"`
	EgressBytes int64   `json:"egressBytes"`
	Connections int64   `json:"connections"`
	LastSeenAt  *int64  `json:"lastSeenAt"`
	LastBuild   *string `json:"lastBuild"`
	Devices     int     `json:"devices"`
}

type buildRow struct {
	Build    string `json:"build"`
	Devices  int    `json:"devices"`
	Accounts int    `json:"accounts"`
}

type todayUsage struct {
	EgressBytes int64      `json:"egressBytes"`
	Connections int64      `json:"connections"`
	Devices     int        `json:"devices"`
	Accounts    int        `json:"accounts"`
	FirstSeenAt *int64     `json:"firstSeenAt"`
	LastSeenAt  *int64     `json:"lastSeenAt"`
	Builds      []buildRow `json:"builds"`
}

type todayDeviceRow struct {
	DeviceID    string  `json:"deviceId"`
	Name        *string `json:"name"`
	Model       *string `json:"model"`
	AppVersion  *string `json:"appVersion"`
	AccountID   string  `json:"accountId"`
	AccountName *string `json:"accountName"`
	EgressBytes int64   `json:"egressBytes"`
	Connections int64   `json:"connections"`
	FirstSeenAt *int64  `json:"firstSeenAt"`
	LastSeenAt  *int64  `json:"lastSeenAt"`
	LastBuild   *string `json:"lastBuild"`
	Revoked     bool    `json:"revoked"`
}

type todayDevices struct {
	List    []todayDeviceRow `json:"list"`
	New     int              `json:"new"`
	NewRaw  int              `json:"newRaw"`
	Active  int              `json:"active"`
	Revoked int              `json:"revoked"`
	Live    int              `json:"live"`
}

type todayFeedback struct {
	New     int               `json:"new"`
	Open    int               `json:"open"`
	Replied int               `json:"replied"`
	Threads []feedbackListRow `json:"threads"`
}

type todayInvites struct {
	Used        int                `json:"used"`
	Enrollments []store.Enrollment `json:"enrollments"`
}

type todayReport struct {
	Day         int64             `json:"day"`
	DayStartAt  int64             `json:"dayStartAt"`
	Usage       todayUsage        `json:"usage"`
	TopAccounts []todayAccountRow `json:"topAccounts"`
	Devices     todayDevices      `json:"devices"`
	Feedback    todayFeedback     `json:"feedback"`
	Invites     todayInvites      `json:"invites"`
}

// todayAccountRow 是「今日」板块的账号排名。
//
// 它比 usage 板块的账号行少 lastSeenAt / lastBuild：Python 的 `_today_report` 只建
// accountId/name/egressBytes/connections/devices 这五个键。两个形状分开定义，因为
// 日报脚本按"有没有这个键"取数。
type todayAccountRow struct {
	AccountID   *string `json:"accountId"`
	Name        *string `json:"name"`
	EgressBytes int64   `json:"egressBytes"`
	Connections int64   `json:"connections"`
	Devices     int     `json:"devices"`
}

type feedbackReport struct {
	New                   int               `json:"new"`
	Open                  int               `json:"open"`
	Replied               int               `json:"replied"`
	MedianFirstReplyHours *float64          `json:"medianFirstReplyHours"`
	Test                  int               `json:"test"`
	Threads               []feedbackListRow `json:"threads"`
}

type deviceReport struct {
	Paired         int               `json:"paired"`
	Active7d       int               `json:"active7d"`
	ActiveWindow   int               `json:"activeWindow"`
	NewInWindow    int               `json:"newInWindow"`
	NewRawInWindow int               `json:"newRawInWindow"`
	WindowDays     int               `json:"windowDays"`
	Revoked        int               `json:"revoked"`
	Debug          int               `json:"debug"`
	NewPerDay      []dayCount        `json:"newPerDay"`
	NewRawPerDay   []dayCount        `json:"newRawPerDay"`
	List           []deviceReportRow `json:"list"`
}

// deviceReportRow 是设备清单的一行：全列 + 打码 + 那台电脑的版本三段 + 推送登记。
type deviceReportRow struct {
	DeviceID         string   `json:"deviceId"`
	DeviceTokenHash  string   `json:"deviceTokenHash"`
	AgentID          string   `json:"agentId"`
	AccountID        string   `json:"accountId"`
	Name             string   `json:"name"`
	Model            *string  `json:"model"`
	AppVersion       *string  `json:"appVersion"`
	CreatedAt        int64    `json:"createdAt"`
	ExpiresAt        int64    `json:"expiresAt"`
	LastSeenAt       *int64   `json:"lastSeenAt"`
	RevokedAt        *int64   `json:"revokedAt"`
	APNSToken        *string  `json:"apnsToken"`
	APNSEnv          *string  `json:"apnsEnv"`
	PushTurnEnd      int      `json:"pushTurnEnd"`
	PushAttention    int      `json:"pushAttention"`
	PushUpdatedAt    *int64   `json:"pushUpdatedAt"`
	DeviceKey        *string  `json:"deviceKey"`
	ConnectorVersion *string  `json:"connectorVersion"`
	HostVersion      *string  `json:"hostVersion"`
	VersionsAt       *int64   `json:"versionsAt"`
	Revoked          bool     `json:"revoked"`
	Push             pushInfo `json:"push"`
	AccountName      *string  `json:"accountName"`
}

type usageDay struct {
	Day               int64 `json:"day"`
	EgressBytes       int64 `json:"egressBytes"`
	Connections       int64 `json:"connections"`
	Devices           int   `json:"devices"`
	Accounts          int   `json:"accounts"`
	NewAccounts       int   `json:"newAccounts"`
	ReturningAccounts int   `json:"returningAccounts"`
}

type usageTotals struct {
	EgressBytes int64 `json:"egressBytes"`
	Connections int64 `json:"connections"`
}

type usageReport struct {
	PerDay           []usageDay        `json:"perDay"`
	TopAccounts      []accountUsageRow `json:"topAccounts"`
	Totals           usageTotals       `json:"totals"`
	AveragePerDay    int64             `json:"averagePerDay"`
	PeakDay          *dayBytes         `json:"peakDay"`
	ActiveDays       int               `json:"activeDays"`
	ActiveAccounts   int               `json:"activeAccounts"`
	ActiveAccounts7d int               `json:"activeAccounts7d"`
}

type retentionUsers struct {
	DAU        int      `json:"dau"`
	WAU        int      `json:"wau"`
	MAU        int      `json:"mau"`
	Stickiness *float64 `json:"stickiness"`
	External   int      `json:"external"`
}

type cohortRow struct {
	Rate   *float64 `json:"rate"`
	Cohort int      `json:"cohort"`
	Active int      `json:"active"`
}

type activationRow struct {
	Rate   *float64 `json:"rate"`
	Cohort int      `json:"cohort"`
	Active int      `json:"active"`
}

type weekRow struct {
	Week   string   `json:"week"`
	Size   int      `json:"size"`
	Active int      `json:"active"`
	Rate   *float64 `json:"rate"`
}

type retentionReport struct {
	Scope      string         `json:"scope"`
	Users      retentionUsers `json:"users"`
	D1         *cohortRow     `json:"d1"`
	D7         *cohortRow     `json:"d7"`
	Activation *activationRow `json:"activation"`
	Weeks      []weekRow      `json:"weeks"`
}

type inviteUnused struct {
	CreatedAt int64   `json:"createdAt"`
	ExpiresAt int64   `json:"expiresAt"`
	Note      *string `json:"note"`
}

type inviteReport struct {
	Minted        int                `json:"minted"`
	Used          int                `json:"used"`
	Remaining     int                `json:"remaining"`
	Test          int                `json:"test"`
	Usable        int                `json:"usable"`
	ExpiringSoon  int                `json:"expiringSoon"`
	ExpiredUnused int                `json:"expiredUnused"`
	Unused        []inviteUnused     `json:"unused"`
	Enrollments   []store.Enrollment `json:"enrollments"`
}

// ── 命令入口 ───────────────────────────────────────────────────────────────

// runOpsReport 实现 ops-report：日报的原始数据。
func runOpsReport(ctx context.Context, st *store.Store, args []string,
	stdout, stderr io.Writer) error {
	fs := newFlagSet(cmdOpsReport, stderr)
	days := fs.Int("days", 30, "窗口天数（本地日，含锚点那一天）")
	asOf := fs.String("as-of", "now", "now | yesterday | YYYY-MM-DD")
	journalUnit := fs.String("journal-unit", defaultJournalUnit,
		"从哪个 systemd 单元的日志重建 72 小时分布")
	if err := fs.Parse(args); err != nil {
		return newUsageError("%v", err)
	}
	windowDays := *days
	if windowDays < 1 {
		windowDays = 1
	}
	generated := store.NowMS()
	stamp, err := resolveAsOf(*asOf, generated)
	if err != nil {
		return err
	}
	report, err := buildOpsReport(ctx, st, windowDays, stamp, generated, *journalUnit)
	if err != nil {
		return err
	}
	return emit(stdout, report)
}

// resolveAsOf 把 --as-of 翻成报告锚点（毫秒）。
func resolveAsOf(value string, now int64) (int64, error) {
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

// buildOpsReport 组装报告的全部板块。
func buildOpsReport(ctx context.Context, st *store.Store, days int, stamp, generated int64,
	journalUnit string) (opsReport, error) {
	threadsSince := stamp - int64(days)*86_400_000
	listed, err := feedbackRows(ctx, st, nil, &threadsSince, reportThreadLimit)
	if err != nil {
		return opsReport{}, err
	}
	// since_ms 只有下界：锚点在过去时，锚点之后新建的线程不属于这份报告。
	listed = filterFeedback(listed, func(row feedbackListRow) bool {
		return row.CreatedAt <= stamp
	})

	devices, err := st.ListDevices(ctx, "", true)
	if err != nil {
		return opsReport{}, err
	}
	agents, err := st.ListAgents(ctx, "")
	if err != nil {
		return opsReport{}, err
	}
	agentVersions := make(map[string]store.Agent, len(agents))
	for _, agent := range agents {
		agentVersions[agent.AgentID] = agent
	}
	accounts, err := st.ListAccounts(ctx)
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
	threads := make([]feedbackListRow, 0, len(listed))
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

	enrollments, err := st.ListEnrollments(ctx)
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

	invites, err := st.ListInvites(ctx, true)
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
		rows, err := st.UsageRows(ctx, day)
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
	series, ranked, activeByDay, err := usageScan(ctx, st, days, stamp, debugIDs, names,
		knownIDs, external)
	if err != nil {
		return opsReport{}, err
	}
	owners := make(map[string]string, len(devices))
	for _, device := range devices {
		owners[device.DeviceID] = device.AccountID
	}
	firstSeen, err := firstSeenDays(ctx, st, debugIDs, owners)
	if err != nil {
		return opsReport{}, err
	}

	versions, err := versionReport(ctx, st, stamp, devices, debugIDs, knownIDs, external)
	if err != nil {
		return opsReport{}, err
	}
	today, err := buildTodayReport(ctx, st, stamp, threads, real, debugIDs, names,
		knownIDs, external)
	if err != nil {
		return opsReport{}, err
	}
	feedbackSection, err := buildFeedbackReport(ctx, st, threads, len(listed)-len(threads))
	if err != nil {
		return opsReport{}, err
	}
	usageSection := buildUsageReport(series, ranked, activeByDay, firstSeen)

	report := opsReport{
		OK: true, GeneratedAt: generated, AsOf: stamp, Days: days,
		Versions: versions, VersionsWindowHours: reportVersionHours,
		HourlyActivity: hourlyActivity{
			WindowHours: reportActivityHours,
			Buckets: hourlyActivityBuckets(
				reportActivityHours, stamp, devices, agentVersions, journalUnit),
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
		Retention: retentionReportFor(ctx, st, days, stamp, external, activeByDay, firstSeen),
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

// ── 各板块 ─────────────────────────────────────────────────────────────────

// versionReport 是版本分布：近 48 小时有设备用量行的账号装在哪个版本。
func versionReport(ctx context.Context, st *store.Store, stamp int64, devices []store.Device,
	debugIDs, knownIDs, external map[string]struct{}) ([]versionRow, error) {
	byID := make(map[string]store.Device, len(devices))
	for _, device := range devices {
		byID[device.DeviceID] = device
	}
	since := stamp - reportVersionHours*3_600_000
	// Python 的 dict 以 appVersion 为键，None 也是合法键；Go 用空串代表 None。
	grouped := map[string]*versionRow{}
	accountsByVersion := map[string]map[string]struct{}{}
	seenDevices := map[string]struct{}{}
	startDay := localDayOf(since)
	endDay := localDayOf(stamp)
	// 按日历日迭代：直接 `day++` 在跨月时会先查 20260931 这种不存在的日号
	// （Python 同样是整数 range，结果相同但多做几十次空查询）。
	for offset := 0; ; offset++ {
		day := dayShift(startDay, offset)
		if day > endDay {
			break
		}
		rows, err := st.UsageRows(ctx, day)
		if err != nil {
			return nil, err
		}
		for _, row := range rows {
			if _, debug := debugIDs[row.DeviceID]; debug {
				continue
			}
			if _, seen := seenDevices[row.DeviceID]; seen {
				continue
			}
			if isOrphanUsage(row, knownIDs, external) {
				continue
			}
			seen := row.LastSeenAt
			if seen > stamp {
				seen = stamp
			}
			if seen < since {
				continue
			}
			seenDevices[row.DeviceID] = struct{}{}
			device := byID[row.DeviceID]
			version := ""
			if device.AppVersion != nil {
				version = strings.TrimSpace(*device.AppVersion)
			}
			entry := grouped[version]
			if entry == nil {
				var label *string
				if version != "" {
					value := version
					label = &value
				}
				entry = &versionRow{AppVersion: label}
				grouped[version] = entry
			}
			entry.Devices++
			if row.AccountID != "" {
				// 账号数按账号去重：同账号多台设备只算一个。
				if accountsByVersion[version] == nil {
					accountsByVersion[version] = map[string]struct{}{}
				}
				accountsByVersion[version][row.AccountID] = struct{}{}
			}
			if entry.LastSeenAt == nil || seen > *entry.LastSeenAt {
				value := seen
				entry.LastSeenAt = &value
			}
			grouped[version] = entry
		}
	}
	out := make([]versionRow, 0, len(grouped))
	for version, entry := range grouped {
		entry.Accounts = len(accountsByVersion[version])
		out = append(out, *entry)
	}
	sort.SliceStable(out, func(left, right int) bool {
		if out[left].Devices != out[right].Devices {
			return out[left].Devices > out[right].Devices
		}
		return versionValue(out[left].AppVersion) < versionValue(out[right].AppVersion)
	})
	return out, nil
}

func versionValue(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}

var (
	deviceEventPattern = regexp.MustCompile(
		`device (dev_[A-Za-z0-9]+) .*?(attached to agent|attached again|detached|` +
			`closed a socket that had already been replaced)`)
	agentInLinePattern = regexp.MustCompile(`agent (agt_[A-Za-z0-9]+)`)
)

// hourlyActivityBuckets 从 systemd 日志重建过去 N 小时的"有设备在连"的账号与设备数。
//
// 取不到日志时返回 nil（JSON 里是 null）：日报宁可少一张图，也不编数字。
func hourlyActivityBuckets(hours int, endMS int64, devices []store.Device,
	agents map[string]store.Agent, unit string) []hourlyBucket {
	hourMS := int64(3_600_000)
	end := endMS
	start := end - int64(hours)*hourMS
	lines, ok := readJournal(unit, start, end)
	if !ok {
		return nil
	}
	deviceByID := make(map[string]store.Device, len(devices))
	for _, device := range devices {
		deviceByID[device.DeviceID] = device
	}
	openAt := map[string]struct {
		at    int64
		agent string
	}{}
	type span struct {
		opened int64
		closed int64
		device string
		agent  string
	}
	spans := make([]span, 0, 64)
	for _, line := range lines {
		match := deviceEventPattern.FindStringSubmatch(line)
		if match == nil {
			continue
		}
		deviceID, kind := match[1], match[2]
		if kind == "closed a socket that had already been replaced" {
			continue
		}
		at, ok := parseJournalTime(line)
		if !ok {
			continue
		}
		if at < start {
			at = start
		}
		if at > end {
			at = end
		}
		agentID := ""
		if found := agentInLinePattern.FindStringSubmatch(line); found != nil {
			agentID = found[1]
		}
		if strings.HasPrefix(kind, "attached") {
			if previous, stillOpen := openAt[deviceID]; stillOpen {
				spans = append(spans, span{opened: previous.at, closed: at,
					device: deviceID, agent: previous.agent})
				delete(openAt, deviceID)
			}
			openAt[deviceID] = struct {
				at    int64
				agent string
			}{at: at, agent: agentID}
			continue
		}
		if previous, stillOpen := openAt[deviceID]; stillOpen {
			spans = append(spans, span{opened: previous.at, closed: at,
				device: deviceID, agent: previous.agent})
			delete(openAt, deviceID)
		}
	}
	for deviceID, previous := range openAt {
		spans = append(spans, span{opened: previous.at, closed: end,
			device: deviceID, agent: previous.agent})
	}

	accountOf := func(deviceID, agentID string) string {
		device, known := deviceByID[deviceID]
		if known && isDebugDevice(device) {
			return ""
		}
		if known && device.AccountID != "" {
			return device.AccountID
		}
		ownerAgent := agentID
		if known && device.AgentID != "" {
			ownerAgent = device.AgentID
		}
		if ownerAgent == "" {
			return ""
		}
		return agents[ownerAgent].AccountID
	}

	first := (start / hourMS) * hourMS
	type bucket struct {
		accounts map[string]struct{}
		devices  map[string]struct{}
	}
	buckets := map[int64]*bucket{}
	for at := first; at <= end; at += hourMS {
		buckets[at] = &bucket{accounts: map[string]struct{}{},
			devices: map[string]struct{}{}}
	}
	for _, item := range spans {
		if item.closed < item.opened {
			continue
		}
		accountID := accountOf(item.device, item.agent)
		if accountID == "" {
			continue
		}
		for cursor := (item.opened / hourMS) * hourMS; cursor <= item.closed; cursor += hourMS {
			entry := buckets[cursor]
			if entry == nil {
				continue
			}
			entry.devices[item.device] = struct{}{}
			entry.accounts[accountID] = struct{}{}
		}
	}
	keys := make([]int64, 0, len(buckets))
	for key := range buckets {
		keys = append(keys, key)
	}
	sort.Slice(keys, func(left, right int) bool { return keys[left] < keys[right] })
	out := make([]hourlyBucket, 0, len(keys))
	for _, key := range keys {
		entry := buckets[key]
		out = append(out, hourlyBucket{
			HourStartAt: key, Accounts: len(entry.accounts), Devices: len(entry.devices),
		})
	}
	return out
}

// readJournal 取中转日志；取不到（没装 systemd、无权限、单元名不对）时 ok=false。
func readJournal(unit string, sinceMS, untilMS int64) ([]string, bool) {
	since := time.UnixMilli(sinceMS).Format("2006-01-02 15:04:05")
	until := time.UnixMilli(untilMS).Format("2006-01-02 15:04:05")
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, "journalctl", "-u", unit,
		"--since", since, "--until", until, "--no-pager", "-o", "short-iso").Output()
	if err != nil {
		return nil, false
	}
	return strings.Split(strings.TrimRight(string(output), "\n"), "\n"), true
}

// parseJournalTime 解析 short-iso 行首的 `2026-10-17T15:44:16+0800`。
func parseJournalTime(line string) (int64, bool) {
	stamp := strings.SplitN(strings.TrimSpace(line), " ", 2)[0]
	layouts := []string{
		"2006-01-02T15:04:05-0700",
		"2006-01-02T15:04:05.000000-0700",
		time.RFC3339,
		time.RFC3339Nano,
	}
	for _, layout := range layouts {
		if parsed, err := time.ParseInLocation(layout, stamp, time.Local); err == nil {
			return parsed.UnixMilli(), true
		}
	}
	return 0, false
}

// buildTodayReport 是「今日」板块：锚点所在本地自然日 00:00 起（到锚点为止）。
func buildTodayReport(ctx context.Context, st *store.Store, stamp int64,
	threads []feedbackListRow, real []store.Device, debugIDs map[string]struct{},
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
	rows, err := st.UsageRows(ctx, day)
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
	freshThreads := make([]feedbackListRow, 0, len(threads))
	for _, thread := range threads {
		if thread.CreatedAt >= start && thread.CreatedAt <= stamp {
			freshThreads = append(freshThreads, thread)
		}
	}
	enrollments, err := st.ListEnrollments(ctx)
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

// buildFeedbackReport 是反馈板块：窗口内的新增/待回复/已回复、首复中位小时数。
func buildFeedbackReport(ctx context.Context, st *store.Store, threads []feedbackListRow,
	testCount int) (feedbackReport, error) {
	ids := make([]string, 0, len(threads))
	for _, thread := range threads {
		ids = append(ids, thread.ThreadID)
	}
	digest, err := st.FeedbackDigest(ctx, ids, 0)
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

// usageScan 按天读一遍 usageDaily，同时给出 series / ranked / activeByDay。
func usageScan(ctx context.Context, st *store.Store, days int, end int64,
	debugIDs map[string]struct{}, names map[string]*string, knownIDs,
	external map[string]struct{}) ([]usageDay, []accountUsageRow, map[int64]map[string]struct{}, error) {
	recent := recentDays(days, end)
	perDay := make(map[int64]*usageDay, len(recent))
	activeByDay := make(map[int64]map[string]struct{}, len(recent))
	for _, day := range recent {
		perDay[day] = &usageDay{Day: day}
		activeByDay[day] = map[string]struct{}{}
	}
	merged := map[string]*accountUsageRow{}
	seenDevices := map[string]map[string]struct{}{}
	for _, day := range recent {
		rows, err := st.UsageRows(ctx, day)
		if err != nil {
			return nil, nil, nil, err
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
			entry.Devices++
			if row.AccountID != "" {
				activeByDay[day][row.AccountID] = struct{}{}
			}
			account := merged[row.AccountID]
			if account == nil {
				accountID := row.AccountID
				account = &accountUsageRow{AccountID: &accountID, Name: names[row.AccountID]}
				merged[row.AccountID] = account
			}
			account.EgressBytes += row.EgressBytes
			account.Connections += row.Connections
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
	series := make([]usageDay, 0, len(recent))
	for _, day := range recent {
		entry := perDay[day]
		entry.Accounts = len(activeByDay[day])
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
	activeSets := make(map[int64]map[string]struct{}, len(activeByDay))
	for day, set := range activeByDay {
		activeSets[day] = set
	}
	return series, ranked, activeSets, nil
}

// buildUsageReport 是用量板块的 JSON。
func buildUsageReport(series []usageDay, ranked []accountUsageRow,
	activeByDay map[int64]map[string]struct{}, firstSeen map[string]int64) usageReport {
	var peak *dayBytes
	var total int64
	activeAll := map[string]struct{}{}
	for _, entry := range series {
		total += entry.EgressBytes
		for account := range activeByDay[entry.Day] {
			activeAll[account] = struct{}{}
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
	for _, day := range last7 {
		for account := range activeByDay[day] {
			active7d[account] = struct{}{}
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
	return usageReport{
		PerDay: series, TopAccounts: takeAccounts(ranked, reportTopAccounts),
		Totals:        usageTotals{EgressBytes: total, Connections: connections},
		AveragePerDay: average, PeakDay: peak, ActiveDays: activeDays,
		ActiveAccounts: len(activeAll), ActiveAccounts7d: len(active7d),
	}
}

// retentionReportFor 是留存板块：只算用邀请码登记的外部账号。
func retentionReportFor(ctx context.Context, st *store.Store, days int, stamp int64,
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

	enrollments, err := st.ListEnrollments(ctx)
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

// firstSeenDays 是每个账号第一次有用量记录的本地日（留存队列的起点）。
func firstSeenDays(ctx context.Context, st *store.Store, debugIDs map[string]struct{},
	owners map[string]string) (map[string]int64, error) {
	rows, err := st.UsageTotals(ctx, retentionHistoryDays, "device")
	if err != nil {
		return nil, err
	}
	first := map[string]int64{}
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
	}
	return first, nil
}

// deviceReportList 是设备清单：只列未撤销的真实设备，按最近在线倒序。
func deviceReportList(live []store.Device, lastSeen map[string]int64,
	agents map[string]store.Agent, names map[string]*string) []deviceReportRow {
	sorted := make([]store.Device, len(live))
	copy(sorted, live)
	sort.SliceStable(sorted, func(left, right int) bool {
		leftKey := lastSeen[sorted[left].DeviceID]
		if leftKey == 0 {
			leftKey = sorted[left].CreatedAt
		}
		rightKey := lastSeen[sorted[right].DeviceID]
		if rightKey == 0 {
			rightKey = sorted[right].CreatedAt
		}
		return leftKey > rightKey
	})
	if len(sorted) > reportDeviceLimit {
		sorted = sorted[:reportDeviceLimit]
	}
	out := make([]deviceReportRow, 0, len(sorted))
	for _, device := range sorted {
		agent := agents[device.AgentID]
		deviceName := device.Name
		entry := deviceReportRow{
			DeviceID: device.DeviceID, DeviceTokenHash: maskPrefix(device.DeviceTokenHash, 12),
			AgentID: device.AgentID, AccountID: device.AccountID, Name: deviceName,
			Model: device.Model, AppVersion: device.AppVersion, CreatedAt: device.CreatedAt,
			ExpiresAt: device.ExpiresAt, RevokedAt: device.RevokedAt,
			APNSEnv: device.APNSEnv, PushTurnEnd: device.PushTurnEnd,
			PushAttention: device.PushAttention, PushUpdatedAt: device.PushUpdatedAt,
			DeviceKey: device.DeviceKey, ConnectorVersion: agent.ConnectorVersion,
			HostVersion: agent.HostVersion, VersionsAt: agent.VersionsAt,
			Revoked: device.RevokedAt != nil, AccountName: names[device.AccountID],
		}
		if device.APNSToken != nil {
			masked := maskPrefix(*device.APNSToken, 8)
			entry.APNSToken = &masked
		}
		if seen, ok := lastSeen[device.DeviceID]; ok {
			value := seen
			entry.LastSeenAt = &value
		}
		entry.Push = pushInfo{
			Registered: device.APNSToken != nil, Env: device.APNSEnv,
			TurnEnd: device.PushTurnEnd != 0, Attention: device.PushAttention != 0,
			UpdatedAt: device.PushUpdatedAt,
		}
		out = append(out, entry)
	}
	return out
}

// ── 设备/线程/用量的小判定 ─────────────────────────────────────────────────

func isDebugDevice(device store.Device) bool {
	if strings.HasPrefix(device.Name, "DSH-") {
		return true
	}
	if device.Model == nil {
		return false
	}
	switch *device.Model {
	case "Node", "test-harness", "simulator":
		return true
	default:
		return false
	}
}

func isTestThread(row feedbackListRow, debugIDs map[string]struct{}) bool {
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

func isTestEnrollment(row store.Enrollment) bool {
	accountName := ""
	if row.AccountName != nil {
		accountName = *row.AccountName
	}
	return strings.HasPrefix(accountName, "DSH-") ||
		strings.HasPrefix(row.AgentName, "DSH-")
}

func isOrphanUsage(row store.UsageRow, knownIDs, external map[string]struct{}) bool {
	if _, known := knownIDs[row.DeviceID]; known {
		return false
	}
	_, ext := external[row.AccountID]
	return !ext
}

func firstDeviceRows(devices []store.Device) []store.Device {
	type key struct {
		account string
		phone   string
	}
	firsts := map[key]store.Device{}
	for _, device := range devices {
		phone := device.DeviceID
		if device.Model != nil && *device.Model != "" {
			phone = *device.Model
		} else if device.Name != "" {
			phone = device.Name
		}
		entry := key{account: device.AccountID, phone: phone}
		seen, ok := firsts[entry]
		if !ok || device.CreatedAt < seen.CreatedAt {
			firsts[entry] = device
		}
	}
	out := make([]store.Device, 0, len(firsts))
	for _, device := range firsts {
		out = append(out, device)
	}
	return out
}

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

// ── 通用小工具 ─────────────────────────────────────────────────────────────

func filterFeedback(rows []feedbackListRow, keep func(feedbackListRow) bool) []feedbackListRow {
	out := make([]feedbackListRow, 0, len(rows))
	for _, row := range rows {
		if keep(row) {
			out = append(out, row)
		}
	}
	return out
}

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

func takeFeedbackRows(rows []feedbackListRow, limit int) []feedbackListRow {
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
