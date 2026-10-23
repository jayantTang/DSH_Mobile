package httpapi

import (
	"fmt"
	"html/template"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// /stats 的 HTML 运维页：与 Python relay/api.py 的 `_stats_page` 同口径
// （连接数、限额、死设备记录、每设备本次出口与被限速时长），并补上 JSON 里本来
// 就有的「今日用量」段——运维打开同一台机器的一条 curl 就能看到全部的账。
//
// 数字全部来自 handleStats 已经拼好的 statsResponse：页面不是第二个数据源，
// 只是同一份响应的另一种呈现。`Accept: text/html` 才走这里，其余客户端继续拿 JSON。

// statsPageData 是模板的渲染输入。字符串字段在这里格式化好，模板只负责转义与排版。
type statsPageData struct {
	Now      string
	Agents   int
	Devices  int
	Egress   string
	Records  statsPageRecords
	Limits   statsPageLimits
	Devices2 []statsPageDevice
	Today    statsPageToday
	Counters statsPageCounters
}

type statsPageRecords struct {
	Dead    int
	Revoked int
	Expired int
	Live    int
	Limit   string
}

type statsPageLimits struct {
	Rate       string
	Daily      string
	MaxDevices string
}

type statsPageDevice struct {
	Name     string
	DeviceID string
	Egress   string
	Paced    string
	Quota    string
}

type statsPageToday struct {
	Day      string
	Egress   string
	Devices  int
	Accounts []statsPageAccount
}

type statsPageAccount struct {
	AccountID string
	Devices   int
	Egress    string
}

type statsPageCounters struct {
	Superseded       int64
	ReconnectStorm   int64
	UnverifiedAgents int
}

// mb2 把字节数格式化成两位小数的 MB。
func mb2(bytes int64) string {
	return fmt.Sprintf("%.2f MB", float64(bytes)/1024/1024)
}

// mb1 把字节数格式化成一位小数的 MB（额度列用）。
func mb1(bytes int64) string {
	return fmt.Sprintf("%.1f MB", float64(bytes)/1024/1024)
}

// unlimited 是 Python 页面里 0/None 的统一文案。
func unlimited() string { return "不限" }

// formatLimitInt 把 *int 限额写成「值」或「不限」。
func formatLimitInt(value *int) string {
	if value == nil {
		return unlimited()
	}
	return strconv.Itoa(*value)
}

// formatLimitFloat 把 *float64 限额写成不带小数的整数（Python 的整数速率）。
func formatLimitFloat(value *float64) string {
	if value == nil {
		return unlimited()
	}
	return strconv.FormatFloat(*value, 'f', -1, 64)
}

// rateText 把每设备限速写成「N B/s」或「不限」。
func rateText(value *float64) string {
	if value == nil {
		return unlimited()
	}
	return strconv.FormatFloat(*value, 'f', -1, 64) + " B/s"
}

// dailyText 把每日额度写成「N B」或「不限」。
func dailyText(value *int64) string {
	if value == nil {
		return unlimited()
	}
	return strconv.FormatInt(*value, 10) + " B"
}

// dayText 把本地日序号（20261023）写成 2026-10-23。
func dayText(day int64) string {
	if day <= 0 {
		return "—"
	}
	return fmt.Sprintf("%04d-%02d-%02d", day/10000, day/100%100, day%100)
}

// newStatsPageData 把 /stats 的响应整理成模板输入。
func newStatsPageData(payload statsResponse) statsPageData {
	data := statsPageData{
		Now:     time.UnixMilli(payload.Now).Format("2006-01-02 15:04:05"),
		Agents:  payload.Load.Agents,
		Devices: payload.Load.Devices,
		Egress:  mb2(payload.Traffic.TotalEgressBytes),
		Records: statsPageRecords{
			Dead:    payload.DeviceRecords.Dead,
			Revoked: payload.DeviceRecords.Revoked,
			Expired: payload.DeviceRecords.Expired,
			Live:    payload.DeviceRecords.Live,
			Limit:   formatLimitInt(payload.Limits.DeadDeviceWarnThreshold),
		},
		Limits: statsPageLimits{
			Rate:       rateText(payload.Limits.DeviceBytesPerSecond),
			Daily:      dailyText(payload.Limits.DeviceDailyBytes),
			MaxDevices: formatLimitInt(payload.Limits.MaxDevicesPerAgent),
		},
		Today: statsPageToday{
			Day:     dayText(payload.Today.Day),
			Egress:  mb2(payload.Today.TotalEgressBytes),
			Devices: len(payload.Today.Devices),
		},
		Counters: statsPageCounters{
			Superseded:       payload.Superseded,
			ReconnectStorm:   payload.ReconnectStorm,
			UnverifiedAgents: payload.UnverifiedAgents,
		},
	}
	for _, device := range payload.Traffic.Devices {
		name := device.Name
		if name == "" {
			name = "—"
		}
		quota := unlimited()
		if device.QuotaRemainingBytes >= 0 {
			quota = mb1(device.QuotaRemainingBytes)
		}
		data.Devices2 = append(data.Devices2, statsPageDevice{
			Name: name, DeviceID: device.DeviceID,
			Egress: mb2(device.EgressBytes),
			Paced:  fmt.Sprintf("%.1fs", device.PacedSeconds),
			Quota:  quota,
		})
	}
	for _, account := range payload.Today.Accounts {
		data.Today.Accounts = append(data.Today.Accounts, statsPageAccount{
			AccountID: account.AccountID,
			Devices:   account.Devices,
			Egress:    mb2(account.EgressBytes),
		})
	}
	return data
}

// statsPageTemplate 与 Python 页面同一套排版；`meta refresh` 每 5 秒自刷新，
// 所以运维不需要轮询命令。
var statsPageTemplate = template.Must(template.New("stats").Parse(`<!doctype html>
<html lang="zh"><head><meta charset="utf-8"><title>DLP relay</title>
<meta http-equiv="refresh" content="5">
<style>
 body { font: 14px/1.6 -apple-system, "PingFang SC", sans-serif; margin: 2rem; color: #1c1c1e; }
 h1 { font-size: 1.1rem; } h2 { font-size: 1rem; margin-top: 2rem; }
 table { border-collapse: collapse; width: 100%; }
 th, td { border-bottom: 1px solid #e5e5ea; padding: .4rem .6rem; text-align: left; }
 th { color: #6c6c70; font-weight: 600; }
 .num { text-align: right; } .mono { font-family: ui-monospace, monospace; font-size: 12px; }
 .muted { color: #8e8e93; } .big { font-size: 1.4rem; font-weight: 600; }
</style></head><body>
<h1>DLP relay — 实时负载与流量</h1>
<p>agent <span class=big>{{.Agents}}</span> 个 · 连接设备 <span class=big>{{.Devices}}</span> 台 ·
   本次启动累计出口 <span class=big>{{.Egress}}</span>
   <span class=muted>（页面每 5 秒自刷新；数字是 relay 自己算的，不含 SSH 与 OTA 流量）</span></p>
<p>死设备记录 <span class=big>{{.Records.Dead}}</span> 条
   <span class=muted>（已撤销 {{.Records.Revoked}} · 已过期 {{.Records.Expired}} ·
   在用 {{.Records.Live}}；一个 agent 超 {{.Records.Limit}} 条会在它连上时记 WARNING）</span></p>
<p class=muted>限制：每设备 {{.Limits.Rate}} · 每日 {{.Limits.Daily}} ·
   每 agent 设备数 {{.Limits.MaxDevices}}<br>
   连接生命周期：顶替 {{.Counters.Superseded}} 次 · 重复连接抑制 {{.Counters.ReconnectStorm}} 次 ·
   未上报版本的在线连接 {{.Counters.UnverifiedAgents}} 条</p>
<table><thead><tr><th>设备</th><th>deviceId</th><th class=num>本次出口</th>
<th class=num>被限速时长</th><th class=num>今日剩余额度</th></tr></thead>
<tbody>{{range .Devices2}}<tr><td>{{.Name}}</td><td class=mono>{{.DeviceID}}</td>
<td class=num>{{.Egress}}</td><td class=num>{{.Paced}}</td><td class=num>{{.Quota}}</td></tr>
{{else}}<tr><td colspan="5" class=muted>当前没有设备连着</td></tr>{{end}}</tbody></table>
<h2>今日用量（本地日 {{.Today.Day}}）</h2>
<p>总出口 <span class=big>{{.Today.Egress}}</span> · {{.Today.Devices}} 台设备</p>
<table><thead><tr><th>账号</th><th class=num>设备数</th><th class=num>今日出口</th></tr></thead>
<tbody>{{range .Today.Accounts}}<tr><td class=mono>{{.AccountID}}</td>
<td class=num>{{.Devices}}</td><td class=num>{{.Egress}}</td></tr>
{{else}}<tr><td colspan="3" class=muted>今天还没有用量</td></tr>{{end}}</tbody></table>
<p class=muted>now {{.Now}}（同一响应里的时间戳只有一份）</p>
</body></html>
`))

// writeStatsPage 渲染 HTML 运维页。
func writeStatsPage(w http.ResponseWriter, payload statsResponse) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	if err := statsPageTemplate.Execute(w, newStatsPageData(payload)); err != nil {
		// 头部已经写出，只能记访问日志；页面自身失败不影响 JSON 客户端。
		return
	}
}

// wantsStatsPage 判断客户端要不要 HTML（与 Python 的 `"text/html" in Accept` 同口径）。
func wantsStatsPage(r *http.Request) bool {
	return strings.Contains(r.Header.Get("Accept"), "text/html")
}
