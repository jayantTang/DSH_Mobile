// Package monitor 是"异常"与"反复断开"的收集器：按类别去重、限量，写进告警队列
// 等投递（Python 版 relay/monitor.py 与 alert-dispatch.py 的对应物）。
//
// 为什么要有这个包（2026-10-17 事故）：
//
//	中转把每一帧发给手机前都要按 UTF-8 数字节计费。连接器送来的一帧里有一个被切开
//	的 emoji（落单的 UTF-16 代理项），编码抛异常，整条 agent 链路随之断开；手机重连
//	再被同一帧打死，于是永远停在"连接中"。24 小时里这件事发生了 143 次、连接器断了
//	702 次，**一条告警都没有**——直到用户自己发来反馈。运维是从 systemd 日志里翻出来的。
//
// 所以这里的判据不是"有没有异常"，而是"**有没有出现过我们没见过的异常**"：
//
//	新类别 → 立刻上报；同类别的后续出现只累计次数，默认 24 小时内不再打扰。
//	抖动（同一台电脑在窗口内反复断开）算一个类别，同一个窗口只报一次。
//
// 三条硬约束（它跑在转发进程里，不能变成负担）：
//
//  1. 热路径零开销：只有异常栈、agent 断开、坏字符这三个时刻会被调用；HTTP 中间件
//     正常路径上只是把 ResponseWriter 包一层。
//  2. 绝不 panic：所有写入都包了错误处理，监控坏掉最多少一条告警，不能让请求或
//     转发跟着失败。
//  3. 不写正文：告警里只有类别、位置、次数、上下文片段；用户内容不进运维通道。
//
// 投递不在这里：本包只把告警追加到 `<alert_dir>/alerts.jsonl`，由 admin 的
// alert-dispatch 子命令取走并投到我们的信箱。中转进程因此不必持有任何发信凭据，
// 发信失败也不会影响它。
package monitor

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/apierr"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
)

// 队列与状态文件的固定名字（与 Python 版同一个目录、同一组文件）。
const (
	QueueName = "alerts.jsonl"
	TakenName = "alerts.taken.jsonl"
	StateName = "state.json"
)

// MaxQueueBytes 是队列文件的自我上限。超过就停止追加（只留日志），
// 免得磁盘被一条重复异常写满。
const MaxQueueBytes = 4 * 1024 * 1024

// stateVersion 是落盘状态文件的版本。改结构时递增，读到不认识的版本就当没有状态重来。
const stateVersion = 1

// Options 是构造一个收集器的全部输入；零值取与 Python 一样的默认值。
type Options struct {
	AlertDir string
	Logger   *slog.Logger
	Clock    func() time.Time

	RenotifyAfter          time.Duration
	MaxAlertsPerHour       int
	MaxAlertsPerDay        int
	FlapWindow             time.Duration
	FlapThreshold          int
	SurrogateSamplesPerDay int
}

// Record 是一行告警队列（alerts.jsonl）。
//
// 字段顺序与 Python 版一致：运维会用两版文件做对照，键序不同只会制造噪声。
type Record struct {
	TS                       int64          `json:"ts"`
	Key                      string         `json:"key"`
	Kind                     string         `json:"kind"`
	Title                    string         `json:"title"`
	Summary                  string         `json:"summary"`
	Details                  map[string]any `json:"details"`
	Count                    int            `json:"count"`
	OccurrencesInWindow      int            `json:"occurrencesInWindow"`
	SuppressedSinceLastAlert int            `json:"suppressedSinceLastAlert"`
	NewCategory              bool           `json:"newCategory"`
}

// categoryState 是某一类别的累计状态（state.json 里 categories 的一项）。
type categoryState struct {
	Count     int     `json:"count"`
	FirstTS   float64 `json:"firstTs"`
	LastTS    float64 `json:"lastTs"`
	AlertedTS float64 `json:"alertedTs"`
}

// stateFile 是 state.json 的形状；categories 的键是类别键。
type stateFile struct {
	Version          int                      `json:"version"`
	SavedAt          int64                    `json:"savedAt"`
	Categories       map[string]categoryState `json:"categories"`
	SurrogateSamples map[string]int           `json:"surrogateSamples"`
}

// Monitor 是按类别去重的告警收集器。
//
// AlertDir 为空 = 关闭：所有方法退化成空操作，行为与没有本包时逐字一致。
type Monitor struct {
	alertDir string
	log      *slog.Logger
	clock    func() time.Time

	renotifyAfter   time.Duration
	maxPerHour      int
	maxPerDay       int
	flapWindow      time.Duration
	flapThreshold   int
	surrogateSample int

	mu               sync.Mutex
	seen             map[string]categoryState
	alertTimes       []float64
	suppressed       int
	flaps            map[string][]float64
	flapReported     map[string]float64
	surrogateSamples map[int64]int
	stateDirty       bool
}

// New 建一个收集器；AlertDir 为空时是禁用实例。
//
// 零值字段取与 Python 构造函数一样的默认值。FromEnv 不走这里的默认值：环境变量写明
// 0 时要按 Python 的夹取规则处理（每小时上限夹到 1、样本数夹到 0），不能悄悄变成默认值。
func New(options Options) *Monitor {
	if options.RenotifyAfter == 0 {
		options.RenotifyAfter = 24 * time.Hour
	}
	if options.MaxAlertsPerHour == 0 {
		options.MaxAlertsPerHour = 6
	}
	if options.MaxAlertsPerDay == 0 {
		options.MaxAlertsPerDay = 40
	}
	if options.FlapWindow == 0 {
		options.FlapWindow = 300 * time.Second
	}
	if options.FlapThreshold == 0 {
		options.FlapThreshold = 5
	}
	if options.SurrogateSamplesPerDay == 0 {
		options.SurrogateSamplesPerDay = 20
	}
	return newMonitor(options)
}

// newMonitor 只做夹取，不补默认值；FromEnv 与 New 共用这一条构造路径。
func newMonitor(options Options) *Monitor {
	logger := options.Logger
	if logger == nil {
		logger = slog.Default()
	}
	clock := options.Clock
	if clock == nil {
		clock = time.Now
	}
	m := &Monitor{
		alertDir: options.AlertDir, log: logger, clock: clock,
		renotifyAfter:    maxDuration(0, options.RenotifyAfter),
		maxPerHour:       maxInt(1, options.MaxAlertsPerHour),
		maxPerDay:        maxInt(1, options.MaxAlertsPerDay),
		flapWindow:       maxDuration(time.Second, options.FlapWindow),
		flapThreshold:    maxInt(1, options.FlapThreshold),
		surrogateSample:  maxInt(0, options.SurrogateSamplesPerDay),
		seen:             map[string]categoryState{},
		flaps:            map[string][]float64{},
		flapReported:     map[string]float64{},
		surrogateSamples: map[int64]int{},
	}
	if m.enabled() {
		m.loadState()
	}
	return m
}

// FromEnv 按环境变量配置；DLP_ALERT_DIR 缺省 = 关闭。
func FromEnv(getenv func(string) string, logger *slog.Logger) *Monitor {
	if getenv == nil {
		getenv = os.Getenv
	}
	number := func(name string, fallback float64) float64 {
		raw := strings.TrimSpace(getenv(name))
		if raw == "" {
			return fallback
		}
		parsed, err := strconv.ParseFloat(raw, 64)
		if err != nil {
			return fallback
		}
		return parsed
	}
	alertDir := getenv("DLP_ALERT_DIR")
	if alertDir == "" {
		// 空 = 关闭：这时不必再解析任何数值，行为与没有本包时逐字一致。
		return newMonitor(Options{AlertDir: "", Logger: logger})
	}
	// 与 Python 的构造函数夹取口径一致（int() 截断，然后 max(0/1, ...)）。
	return newMonitor(Options{
		AlertDir: alertDir,
		Logger:   logger,
		RenotifyAfter: time.Duration(
			math.Max(0, number("DLP_ALERT_RENOTIFY_HOURS", 24)) * float64(time.Hour)),
		MaxAlertsPerHour: maxInt(1,
			int(math.Trunc(number("DLP_ALERT_MAX_PER_HOUR", 6)))),
		MaxAlertsPerDay: maxInt(1,
			int(math.Trunc(number("DLP_ALERT_MAX_PER_DAY", 40)))),
		FlapWindow: time.Duration(
			math.Max(1, number("DLP_ALERT_FLAP_WINDOW_S", 300)) * float64(time.Second)),
		FlapThreshold: maxInt(1,
			int(math.Trunc(number("DLP_ALERT_FLAP_THRESHOLD", 5)))),
		SurrogateSamplesPerDay: maxInt(0,
			int(math.Trunc(number("DLP_ALERT_SURROGATE_SAMPLES", 20)))),
	})
}

// Enabled 报告告警是否开启。
func (m *Monitor) Enabled() bool { return m != nil && m.enabled() }

func (m *Monitor) enabled() bool { return m != nil && m.alertDir != "" }

// QueuePath 是队列文件路径（禁用时返回空串）。
func (m *Monitor) QueuePath() string {
	if !m.Enabled() {
		return ""
	}
	return filepath.Join(m.alertDir, QueueName)
}

// StatePath 是状态文件路径（禁用时返回空串）。
func (m *Monitor) StatePath() string {
	if !m.Enabled() {
		return ""
	}
	return filepath.Join(m.alertDir, StateName)
}

// Describe 是启动日志那一行用的运维口径（不含用户数据）。
func (m *Monitor) Describe() map[string]any {
	if !m.Enabled() {
		return map[string]any{"enabled": false}
	}
	m.mu.Lock()
	known := len(m.seen)
	m.mu.Unlock()
	return map[string]any{
		"enabled":           true,
		"alertDir":          m.alertDir,
		"renotifyHours":     math.RoundToEven(m.renotifyAfter.Hours()*100) / 100,
		"maxPerHour":        m.maxPerHour,
		"maxPerDay":         m.maxPerDay,
		"flapWindowSeconds": m.flapWindow.Seconds(),
		"flapThreshold":     m.flapThreshold,
		"knownCategories":   known,
	}
}

// ── 取数入口（都是热路径上的"顺便"，必须便宜且不 panic）──────────────────

// NoteException 记录一个没人处理的异常。同类型 + 同一处调用点 = 同一类别。
//
// 位置取自本函数的调用点（Go 的 error 不携带栈；这里要的是"这次错误在哪里被
// 观察到"，与 Python 的 traceback 最内层落在同一处代码）。
func (m *Monitor) NoteException(err error, path, source string) {
	if !m.Enabled() || err == nil {
		return
	}
	m.noteException(err, path, source, captureStack(3))
}

// noteException 是带显式栈的实现（测试与内部调用用）。
func (m *Monitor) noteException(err error, path, source string, stack []uintptr) {
	defer m.guard("note an exception")
	place, frames := classify(stack)
	typeName := shortType(err)
	summary := truncateRunes(fmt.Sprintf("%s: %v", typeName, err), 300)
	summary = strings.ReplaceAll(summary, "\n", " ")
	source = defaultSource(source)
	subject := path
	if subject == "" {
		subject = source
	}
	m.record(categoryKey(typeName, place), recordInput{
		kind:    "exception",
		title:   fmt.Sprintf("中转异常：%s @ %s", typeName, place),
		summary: fmt.Sprintf("%s → %s", subject, summary),
		details: map[string]any{
			"source": source, "path": path, "place": place, "frames": frames,
		},
	})
}

// NotePanic 记录一个被 recover 的 panic；stack 由调用方在 defer 里取。
func (m *Monitor) NotePanic(recovered any, path string, stack []uintptr) {
	if !m.Enabled() || recovered == nil {
		return
	}
	defer m.guard("note a panic")
	place, frames := classifyPanic(stack)
	typeName := shortType(recovered)
	summary := truncateRunes(fmt.Sprintf("%s: %v", typeName, recovered), 300)
	summary = strings.ReplaceAll(summary, "\n", " ")
	m.record(categoryKey(typeName, place), recordInput{
		kind:    "exception",
		title:   fmt.Sprintf("中转异常：%s @ %s", typeName, place),
		summary: fmt.Sprintf("%s → %s", path, summary),
		details: map[string]any{
			"source": "http", "path": path, "place": place, "frames": frames,
		},
	})
}

// NoteHTTPStatus 记录一个 5xx 响应。
//
// Python 版只记未处理异常；DESIGN §8 要求 Go 版把 5xx 也纳入可观测性，所以这是有意的
// 扩展。类别按"状态码 + 方法 + 路径"归：同一个端点的 5xx 只在首次（或 24 小时后）
// 打扰一次，不同端点互不掩盖。
func (m *Monitor) NoteHTTPStatus(method, path string, status int) {
	if !m.Enabled() || status < 500 {
		return
	}
	defer m.guard("note an HTTP status")
	place := method + " " + path
	typeName := fmt.Sprintf("HTTP%d", status)
	m.record(categoryKey(typeName, place), recordInput{
		kind:    "exception",
		title:   fmt.Sprintf("中转异常：HTTP %d @ %s", status, place),
		summary: fmt.Sprintf("%s %s → status %d", method, path, status),
		details: map[string]any{
			"source": "http", "method": method, "path": path, "status": status,
		},
	})
}

// NoteAgentDisconnect 记录一条 agent 链路断了。窗口内断够次数才算"抖"，
// 同一窗口只报一次。
//
// "同一窗口"由类别键带窗口序号保证：过了这个窗口再抖算一次新事件，所以要再报一次；
// 而类别去重本身仍然管"同窗口内不重复"。
func (m *Monitor) NoteAgentDisconnect(agentID, name string) {
	if !m.Enabled() {
		return
	}
	defer m.guard("note a disconnect")
	m.mu.Lock()
	defer m.mu.Unlock()

	now := m.nowSeconds()
	window := append(m.flaps[agentID], now)
	cutoff := now - m.flapWindow.Seconds()
	for len(window) > 0 && window[0] < cutoff {
		window = window[1:]
	}
	m.flaps[agentID] = window
	if len(window) < m.flapThreshold {
		return
	}
	if reported, ok := m.flapReported[agentID]; ok && now-reported < m.flapWindow.Seconds() {
		return
	}
	m.flapReported[agentID] = now

	prefix := "flap:" + agentID + ":"
	key := prefix + strconv.Itoa(int(now/m.flapWindow.Seconds()))
	// 上一个窗口的类别键留着没有意义，顺手清掉，免得状态文件随运行时间无限增长。
	for known := range m.seen {
		if strings.HasPrefix(known, prefix) && known != key {
			delete(m.seen, known)
		}
	}
	display := name
	if display == "" {
		display = "agent"
	}
	m.recordLocked(key, recordInput{
		kind:  "flap",
		title: "连接器反复断开",
		summary: fmt.Sprintf("%s（%s）在 %d 秒内断开 %d 次", display, agentID,
			int(m.flapWindow.Seconds()), len(window)),
		details: map[string]any{
			"agentId": agentID, "name": name,
			"windowSeconds":       int(m.flapWindow.Seconds()),
			"disconnectsInWindow": len(window),
		},
	}, now)
}

// NoteControlDrop 记录一次可丢控制帧（pong/ping/hostStatus/accountState）因
// 优先队列满而被丢弃。
//
// 类别按"链路 + 帧类型"归：同一条连接的同一种帧只在首次（或 24 小时后）打扰一次，
// 之后只累计。链路标识里带 agentId / deviceId，所以不同 agent 互不掩盖。
// 这是 2026-10-23 回滚事件要补的观察点：当时控制帧丢弃只有一条 closing 日志，
// 无法区分"丢的是 pong"还是"丢的是 deviceAttach"。
func (m *Monitor) NoteControlDrop(link, frameType string) {
	if !m.Enabled() {
		return
	}
	defer m.guard("note a control drop")
	m.record("backpressure:control:"+link+":"+frameType, recordInput{
		kind:  "backpressure:control",
		title: "控制帧因背压被丢弃",
		summary: fmt.Sprintf("%s 的 %s 控制帧在优先队列满时被丢弃（可丢类别，连接继续）",
			link, frameType),
		details: map[string]any{"link": link, "frame": frameType},
	})
}

// NoteUnpairedSurrogates 记录转发路径刚修好一个落单代理项。这是定位上游根因的取样点。
//
// 详情每次都写落盘日志（那本来就有），但**进告警的样本按天限量**：坏字符可能每分钟
// 来一次，抽样够看形态，不必每条都推给人。
func (m *Monitor) NoteUnpairedSurrogates(agentID, deviceID, frameType string,
	damage dlp.SurrogateDamage) {
	if !m.Enabled() {
		return
	}
	defer m.guard("note a surrogate")
	m.mu.Lock()
	defer m.mu.Unlock()

	now := m.nowSeconds()
	day := localDay(time.Unix(int64(now), 0))
	taken := m.surrogateSamples[day]
	shape := damage.AsDetails()
	details := map[string]any{
		"agentId": agentID, "deviceId": deviceID, "frameType": frameType,
	}
	for key, value := range shape {
		details[key] = value
	}
	if taken < m.surrogateSample {
		m.surrogateSamples[day] = taken + 1
		details["sample"] = fmt.Sprintf("%d/%d", taken+1, m.surrogateSample)
	} else {
		details = map[string]any{
			"agentId": agentID, "deviceId": deviceID, "frameType": frameType,
			"sampled": false,
		}
	}
	m.recordLocked("surrogate:unpaired", recordInput{
		kind:  "corrupt-frame",
		title: "上游送来了带落单代理项（被切开的 emoji）的帧",
		summary: fmt.Sprintf(
			"来自 %s 的 %s 帧，已用 U+FFFD 修好并转发；坏字符位置 %v/%v（帧尾还剩 %v 字节）",
			agentID, frameType, shape["firstIndex"], shape["totalChars"],
			shape["trailingChars"]),
		details: details,
	}, now)
}

// ── 判定与落盘 ─────────────────────────────────────────────────────────────

// recordInput 是 record / recordLocked 的共同入参。
type recordInput struct {
	kind    string
	title   string
	summary string
	details map[string]any
}

// record 取到当前时刻后交给 recordLocked。
func (m *Monitor) record(key string, input recordInput) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.recordLocked(key, input, m.nowSeconds())
}

// recordLocked 是去重、限量、入队、落盘的全部逻辑；调用方必须持有 m.mu。
func (m *Monitor) recordLocked(key string, input recordInput, now float64) {
	entry, exists := m.seen[key]
	novel := false
	if !exists {
		entry = categoryState{FirstTS: now, LastTS: now}
		novel = true
	} else {
		novel = now-entry.AlertedTS >= m.renotifyAfter.Seconds()
	}
	entry.Count++
	entry.LastTS = now
	m.seen[key] = entry
	m.stateDirty = true

	if !novel {
		// 已知类别、还在静默期：只累计。库里那份计数就是"这类还在发生"的证据。
		return
	}
	if !m.allowNowLocked(now) {
		m.suppressed++
		return
	}
	entry.AlertedTS = now
	m.seen[key] = entry
	m.appendLocked(Record{
		TS: int64(now), Key: key, Kind: input.kind, Title: input.title,
		Summary: input.summary, Details: input.details, Count: entry.Count,
		OccurrencesInWindow: entry.Count, SuppressedSinceLastAlert: m.suppressed,
		NewCategory: entry.Count == 1,
	})
	m.suppressed = 0
	m.saveStateLocked()
}

// allowNowLocked 是一小时与一天的条数上限；超了只计数，避免告警洪水。
func (m *Monitor) allowNowLocked(now float64) bool {
	for len(m.alertTimes) > 0 && now-m.alertTimes[0] > 86_400 {
		m.alertTimes = m.alertTimes[1:]
	}
	inLastHour := 0
	for _, stamp := range m.alertTimes {
		if now-stamp <= 3600 {
			inLastHour++
		}
	}
	if inLastHour >= m.maxPerHour {
		return false
	}
	if len(m.alertTimes) >= m.maxPerDay {
		return false
	}
	m.alertTimes = append(m.alertTimes, now)
	return true
}

// appendLocked 把一条告警追加进队列；失败只记日志。
func (m *Monitor) appendLocked(record Record) {
	line, err := marshalJSON(record)
	if err != nil {
		m.log.Warn("relay: could not encode an alert record", "error", err)
		return
	}
	path := m.QueuePath()
	if info, err := os.Stat(path); err == nil && info.Size() > MaxQueueBytes {
		m.log.Warn("relay: alert queue is full; dropping one record", "path", path)
		return
	}
	if err := os.MkdirAll(m.alertDir, 0o755); err != nil {
		m.log.Warn("relay: could not create the alert directory", "error", err)
		return
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o644)
	if err != nil {
		m.log.Warn("relay: could not open the alert queue", "error", err)
		return
	}
	if _, err := file.Write(append(line, '\n')); err != nil {
		m.log.Warn("relay: could not write the alert queue", "error", err)
		_ = file.Close()
		return
	}
	if err := file.Close(); err != nil {
		m.log.Warn("relay: could not close the alert queue", "error", err)
		return
	}
	m.log.Warn("relay: incident queued", "key", record.Key, "summary", record.Summary)
}

// ── 状态文件（重启后不重复报同一类别）──────────���───────────────────────────

// loadState 读上次的状态；文件缺失、坏掉、版本不认都当没有状态。
func (m *Monitor) loadState() {
	defer m.guard("load the alert state")
	raw, err := os.ReadFile(m.StatePath())
	if err != nil {
		return
	}
	var state stateFile
	if err := json.Unmarshal(raw, &state); err != nil || state.Version != stateVersion {
		return
	}
	for key, entry := range state.Categories {
		if entry.Count < 0 {
			continue
		}
		m.seen[key] = entry
	}
	for day, count := range state.SurrogateSamples {
		value, err := strconv.ParseInt(day, 10, 64)
		if err != nil {
			continue
		}
		m.surrogateSamples[value] = count
	}
}

// saveStateLocked 原子地写状态文件；调用方必须持有 m.mu。
func (m *Monitor) saveStateLocked() {
	if !m.enabled() {
		return
	}
	samples := make(map[string]int, len(m.surrogateSamples))
	for day, count := range m.surrogateSamples {
		samples[strconv.FormatInt(day, 10)] = count
	}
	payload, err := marshalJSON(stateFile{
		Version: stateVersion, SavedAt: int64(m.nowSeconds()),
		Categories: m.seen, SurrogateSamples: samples,
	})
	if err != nil {
		m.log.Debug("relay: could not encode the alert state", "error", err)
		return
	}
	if err := os.MkdirAll(m.alertDir, 0o755); err != nil {
		m.log.Debug("relay: could not create the alert directory", "error", err)
		return
	}
	temporary := m.StatePath() + ".tmp"
	if err := os.WriteFile(temporary, payload, 0o644); err != nil {
		m.log.Debug("relay: could not write the alert state", "error", err)
		return
	}
	if err := os.Rename(temporary, m.StatePath()); err != nil {
		m.log.Debug("relay: could not replace the alert state", "error", err)
		_ = os.Remove(temporary)
		return
	}
	m.stateDirty = false
}

// Flush 周期调用：把计数落盘；没变化就不写。
func (m *Monitor) Flush() {
	if !m.Enabled() {
		return
	}
	defer m.guard("flush the alert state")
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.stateDirty {
		m.saveStateLocked()
	}
}

// SaveState 无条件落盘（关停时用）。
func (m *Monitor) SaveState() {
	if !m.Enabled() {
		return
	}
	defer m.guard("save the alert state")
	m.mu.Lock()
	defer m.mu.Unlock()
	m.saveStateLocked()
}

// guard 把任何意外 panic 变成一条 debug 日志：监控自己不许把调用方带下去。
func (m *Monitor) guard(what string) {
	if recovered := recover(); recovered != nil {
		m.log.Debug("relay: monitor failed to "+what, "panic", recovered)
	}
}

func (m *Monitor) nowSeconds() float64 { return float64(m.clock().UnixNano()) / 1e9 }

func localDay(at time.Time) int64 {
	local := at.In(time.Local)
	return int64(local.Year())*10000 + int64(local.Month())*100 + int64(local.Day())
}

// ── 分类 ───────────────────────────────────────────────────────────────────

// classify 返回最内层位置与最近四帧的可读栈。
func classify(stack []uintptr) (string, string) {
	frames := runtime.CallersFrames(stack)
	place := "?"
	framesText := make([]string, 0, 4)
	for {
		frame, more := frames.Next()
		if !ignoredFrame(frame.Function) {
			if place == "?" {
				place = fmt.Sprintf("%s:%d", filepath.Base(frame.File), frame.Line)
			}
			if len(framesText) < 4 {
				framesText = append(framesText, fmt.Sprintf("%s:%d %s",
					filepath.Base(frame.File), frame.Line, shortFunction(frame.Function)))
			}
		}
		if !more {
			break
		}
	}
	return place, strings.Join(framesText, " ← ")
}

// classifyPanic 跳过 runtime.gopanic 等帧，找到真正的 panic 位置。
func classifyPanic(stack []uintptr) (string, string) {
	frames := runtime.CallersFrames(stack)
	place := "?"
	framesText := make([]string, 0, 4)
	for {
		frame, more := frames.Next()
		if !ignoredFrame(frame.Function) && !isRuntimeFrame(frame.Function) {
			if place == "?" {
				place = fmt.Sprintf("%s:%d", filepath.Base(frame.File), frame.Line)
			}
			if len(framesText) < 4 {
				framesText = append(framesText, fmt.Sprintf("%s:%d %s",
					filepath.Base(frame.File), frame.Line, shortFunction(frame.Function)))
			}
		}
		if !more {
			break
		}
	}
	return place, strings.Join(framesText, " ← ")
}

func ignoredFrame(function string) bool {
	return strings.HasPrefix(function, "runtime.") ||
		strings.Contains(function, "/internal/monitor.")
}

func isRuntimeFrame(function string) bool { return strings.HasPrefix(function, "runtime.") }

// shortFunction 砍掉包路径，只留 package.Func（日志可读性）。
func shortFunction(function string) string {
	if index := strings.LastIndex(function, "/"); index >= 0 {
		return function[index+1:]
	}
	return function
}

func categoryKey(typeName, place string) string {
	return "exc:" + typeName + "@" + place
}

// shortType 是错误/panic 值的类型短名（去掉包路径）。
func shortType(value any) string {
	if value == nil {
		return "error"
	}
	name := reflect.TypeOf(value).String()
	if index := strings.LastIndex(name, "/"); index >= 0 {
		name = name[index+1:]
	}
	return name
}

func captureStack(skip int) []uintptr {
	pcs := make([]uintptr, 64)
	count := runtime.Callers(skip, pcs)
	return pcs[:count]
}

// ── HTTP 中间件 ────────────────────────────────────────────────────────────

// Middleware 把 panic 与 5xx 送进监控，并保持原有的 500 JSON 信封。
//
// 正常请求路径上只多一层 ResponseWriter 包装；异常分支里才有日志与序列化。
// m 为 nil 时只做 panic 兜底（不记录），保证单测与未配置的部署行为不变。
//
// 包装器只实现 Unwrap，不实现 Hijacker：coder/websocket 会顺着 Unwrap 找到真正的
// ResponseWriter，WebSocket 升级因此不受影响。
func Middleware(m *Monitor, logger *slog.Logger) func(http.Handler) http.Handler {
	if logger == nil {
		logger = slog.Default()
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			recorder := &statusRecorder{ResponseWriter: w, monitor: m,
				method: r.Method, path: r.URL.Path}
			defer func() {
				recovered := recover()
				if recovered == nil {
					return
				}
				if recovered == http.ErrAbortHandler {
					// net/http 用这个值主动中止响应；不是事故，也不该写 500。
					panic(recovered)
				}
				logger.Error("relay: handler panicked",
					"method", r.Method, "path", r.URL.Path, "panic", recovered)
				if m.Enabled() {
					m.NotePanic(recovered, r.URL.Path, captureStack(3))
				}
				recorder.silent = true
				if !recorder.wroteHeader {
					apierr.Write(recorder, http.StatusInternalServerError, "internal/error",
						"the relay could not complete this request", nil)
				}
			}()
			next.ServeHTTP(recorder, r)
		})
	}
}

// statusRecorder 观察响应状态码，并把 5xx 报给监控。
type statusRecorder struct {
	http.ResponseWriter
	monitor     *Monitor
	method      string
	path        string
	status      int
	wroteHeader bool
	// silent 为 true 时不把状态码算成事故（panic 已经单独记过）。
	silent bool
}

func (r *statusRecorder) WriteHeader(status int) {
	if r.wroteHeader {
		return
	}
	r.wroteHeader = true
	r.status = status
	if !r.silent && status >= 500 && r.monitor.Enabled() {
		r.monitor.NoteHTTPStatus(r.method, r.path, status)
	}
	r.ResponseWriter.WriteHeader(status)
}

func (r *statusRecorder) Write(payload []byte) (int, error) {
	if !r.wroteHeader {
		r.WriteHeader(http.StatusOK)
	}
	return r.ResponseWriter.Write(payload)
}

// Unwrap 让 http.ResponseController 与 coder/websocket 找到底层 writer。
func (r *statusRecorder) Unwrap() http.ResponseWriter { return r.ResponseWriter }

// ── 告警队列（投递侧取走 / 失败放回）──────────────────────────────────────

// ReadQueue 读一份队列文件，返回合法记录与坏行数。
//
// 坏行跳过而不是让整批失败：一条写坏的记录不该把其余告警一起卡住。
func ReadQueue(path string) ([]Record, int, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, 0, err
	}
	defer file.Close()
	return readRecords(file)
}

func readRecords(reader io.Reader) ([]Record, int, error) {
	records := make([]Record, 0, 16)
	bad := 0
	buffered := bufio.NewReader(reader)
	for {
		line, err := buffered.ReadString('\n')
		trimmed := strings.TrimSpace(line)
		if trimmed != "" {
			var record Record
			if decodeErr := json.Unmarshal([]byte(trimmed), &record); decodeErr != nil {
				bad++
			} else {
				records = append(records, record)
			}
		}
		if err != nil {
			if err == io.EOF {
				return records, bad, nil
			}
			return records, bad, err
		}
	}
}

// TakeQueue 是投递侧的原子取走：把 alerts.jsonl 重命名成 alerts.taken.jsonl，
// 再读它。队列不存在时返回空（不是错误）。
//
// 取走之后再拼正文、再投递：投递成功由调用方 DiscardTaken，失败由 RestoreQueue
// 原样追加回队列。任何一步都不会丢告警。
func TakeQueue(alertDir string) ([]Record, int, error) {
	queuePath := filepath.Join(alertDir, QueueName)
	takenPath := filepath.Join(alertDir, TakenName)
	if err := os.Rename(queuePath, takenPath); err != nil {
		if os.IsNotExist(err) {
			return nil, 0, nil
		}
		return nil, 0, fmt.Errorf("取走告警队列: %w", err)
	}
	records, bad, err := ReadQueue(takenPath)
	if err != nil {
		// 读不出来也要把文件放回去，下一次还能重试。
		restoreErr := RestoreQueue(alertDir)
		if restoreErr != nil {
			return nil, bad, fmt.Errorf("读告警队列: %w（放回也失败: %v）", err, restoreErr)
		}
		return nil, bad, fmt.Errorf("读告警队列: %w", err)
	}
	if len(records) == 0 {
		_ = DiscardTaken(alertDir)
	}
	return records, bad, nil
}

// RestoreQueue 把取走的文件原样追加回队列，然后删掉 taken。
//
// 追加失败时**保留** taken：宁可留一个待人工处理的文件，也不丢记录。
func RestoreQueue(alertDir string) error {
	queuePath := filepath.Join(alertDir, QueueName)
	takenPath := filepath.Join(alertDir, TakenName)
	payload, err := os.ReadFile(takenPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("读回待放回的告警: %w", err)
	}
	target, err := os.OpenFile(queuePath, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o644)
	if err != nil {
		return fmt.Errorf("打开告警队列: %w", err)
	}
	if _, err := target.Write(payload); err != nil {
		_ = target.Close()
		return fmt.Errorf("放回告警: %w", err)
	}
	if err := target.Close(); err != nil {
		return fmt.Errorf("放回告警: %w", err)
	}
	return DiscardTaken(alertDir)
}

// DiscardTaken 删掉取走文件（投递成功之后）。
func DiscardTaken(alertDir string) error {
	err := os.Remove(filepath.Join(alertDir, TakenName))
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// ── 小工具 ─────────────────────────────────────────────────────────────────

func defaultSource(source string) string {
	if source == "" {
		return "http"
	}
	return source
}

func maxDuration(left, right time.Duration) time.Duration {
	if right < left {
		return left
	}
	return right
}

func maxInt(left, right int) int {
	if right < left {
		return left
	}
	return right
}

// marshalJSON 与 Python 的 json.dumps(..., ensure_ascii=False,
// separators=(",", ":")) 对齐：不转义 HTML 字符、不追加换行。
func marshalJSON(value any) ([]byte, error) {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buffer.Bytes(), []byte("\n")), nil
}

func truncateRunes(value string, limit int) string {
	if limit <= 0 {
		return ""
	}
	runes := []rune(value)
	if len(runes) <= limit {
		return value
	}
	return string(runes[:limit])
}

// SortedKeys 返回排好序的类别键（诊断/测试用）。
func (m *Monitor) SortedKeys() []string {
	m.mu.Lock()
	defer m.mu.Unlock()
	keys := make([]string, 0, len(m.seen))
	for key := range m.seen {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}
