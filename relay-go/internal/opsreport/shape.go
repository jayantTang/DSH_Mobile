package opsreport

import (
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// ── 出参形状（字段顺序与 admin.py 一致）────────────────────────────────────
//
// 这些类型不导出：报告只有一个消费者（admincli 的 emit），形状属于本包。
// 改动字段名或顺序会改变 JSON 的字节输出，等同于改日报契约。

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
	New     int           `json:"new"`
	Open    int           `json:"open"`
	Replied int           `json:"replied"`
	Threads []FeedbackRow `json:"threads"`
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
	New                   int           `json:"new"`
	Open                  int           `json:"open"`
	Replied               int           `json:"replied"`
	MedianFirstReplyHours *float64      `json:"medianFirstReplyHours"`
	Test                  int           `json:"test"`
	Threads               []FeedbackRow `json:"threads"`
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
	Push             PushInfo `json:"push"`
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
