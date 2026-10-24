package monitor_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/monitor"
)

// ── 夹具 ───────────────────────────────────────────────────────────────────

// testClock 是可推进的时钟（Python 用例的 `_clock`）。
type testClock struct{ seconds int64 }

func newClock() *testClock { return &testClock{seconds: 1_700_000_000} }

func (c *testClock) now() time.Time        { return time.Unix(c.seconds, 0) }
func (c *testClock) advance(seconds int64) { c.seconds += seconds }

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func newMonitor(t *testing.T, dir string, clock *testClock, options monitor.Options) *monitor.Monitor {
	t.Helper()
	options.AlertDir = dir
	options.Clock = clock.now
	options.Logger = testLogger()
	return monitor.New(options)
}

func readRecords(t *testing.T, dir string) []monitor.Record {
	t.Helper()
	payload, err := os.ReadFile(filepath.Join(dir, monitor.QueueName))
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		t.Fatalf("读告警队列: %v", err)
	}
	records := make([]monitor.Record, 0)
	for _, line := range strings.Split(strings.TrimSpace(string(payload)), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		var record monitor.Record
		if err := json.Unmarshal([]byte(line), &record); err != nil {
			t.Fatalf("队列行不是 JSON: %v (%s)", err, line)
		}
		records = append(records, record)
	}
	return records
}

// 两个不同的调用点：异常类型相同、位置不同 = 两个类别。
func noteFromAlpha(m *monitor.Monitor) {
	m.NoteException(errors.New("first place"), "/x", "http")
}

func noteFromBeta(m *monitor.Monitor) {
	m.NoteException(errors.New("second place"), "/x", "http")
}

// noteSamePlace 是固定调用点，用来验证"同一类别只累计、不重复报"。
func noteSamePlace(m *monitor.Monitor, message string) {
	m.NoteException(errors.New(message), "/link/agent", "http")
}

// ── 去重与重报 ─────────────────────────────────────────────────────────────

func TestANewCategoryIsQueuedAndRepeatsAreOnlyCounted(t *testing.T) {
	clock := newClock()
	dir := t.TempDir()
	m := newMonitor(t, dir, clock, monitor.Options{})

	noteSamePlace(m, "boom")
	noteSamePlace(m, "again")
	noteSamePlace(m, "third")

	records := readRecords(t, dir)
	if len(records) != 1 {
		t.Fatalf("同一类别的重复出现不该每来一条就发一封：%d 条", len(records))
	}
	if records[0].Count != 1 || !records[0].NewCategory {
		t.Fatalf("首条记录 = %+v", records[0])
	}
	if !strings.Contains(records[0].Title, "*errors.errorString") {
		t.Fatalf("标题 = %q", records[0].Title)
	}
	if records[0].Details["path"] != "/link/agent" {
		t.Fatalf("details.path = %v", records[0].Details["path"])
	}

	// 后面的两次只累计在状态里（下次同类放行时才会带上新的总数）。
	m.Flush()
	stateRaw, err := os.ReadFile(filepath.Join(dir, monitor.StateName))
	if err != nil {
		t.Fatalf("读状态文件: %v", err)
	}
	var state struct {
		Version    int `json:"version"`
		Categories map[string]struct {
			Count int `json:"count"`
		} `json:"categories"`
	}
	if err := json.Unmarshal(stateRaw, &state); err != nil {
		t.Fatalf("状态文件不是 JSON: %v", err)
	}
	if state.Version != 1 || state.Categories[records[0].Key].Count != 3 {
		t.Fatalf("状态 = %+v", state)
	}

	// 24 小时后同类再来一次：重新上报，并带上"又出现了几次"。
	clock.advance(24*3600 + 1)
	noteSamePlace(m, "old")
	records = readRecords(t, dir)
	if len(records) != 2 {
		t.Fatalf("24 小时后应当再报一次：%d 条", len(records))
	}
	if records[1].NewCategory || records[1].Count != 4 {
		t.Fatalf("重报记录 = %+v", records[1])
	}
}

func TestADifferentCodeLocationIsADifferentCategory(t *testing.T) {
	clock := newClock()
	dir := t.TempDir()
	m := newMonitor(t, dir, clock, monitor.Options{})
	noteFromAlpha(m)
	noteFromBeta(m)
	records := readRecords(t, dir)
	if len(records) != 2 {
		t.Fatalf("换个位置就算新类别：%d 条", len(records))
	}
	if records[0].Key == records[1].Key {
		t.Fatalf("类别键相同：%q", records[0].Key)
	}
	if records[0].Details["place"] == records[1].Details["place"] {
		t.Fatalf("位置相同：%v", records[0].Details["place"])
	}
}

// 四种不同异常类型：同一调用点上，"类型 + 位置"才是类别键，换类型就是新类别。
type hourlyErrorA struct{}
type hourlyErrorB struct{}
type hourlyErrorC struct{}
type hourlyErrorD struct{}

func (hourlyErrorA) Error() string { return "a" }
func (hourlyErrorB) Error() string { return "b" }
func (hourlyErrorC) Error() string { return "c" }
func (hourlyErrorD) Error() string { return "d" }

func TestTheHourlyCapSuppressesAndReportsWhatItDropped(t *testing.T) {
	clock := newClock()
	dir := t.TempDir()
	m := newMonitor(t, dir, clock, monitor.Options{
		MaxAlertsPerHour: 2, MaxAlertsPerDay: 10,
	})
	errorsInOrder := []error{
		hourlyErrorA{}, hourlyErrorB{}, hourlyErrorC{}, hourlyErrorD{},
	}
	for index := 0; index < 3; index++ {
		m.NoteException(errorsInOrder[index], "/x", "http")
	}
	if len(readRecords(t, dir)) != 2 {
		t.Fatal("一小时上限必须生效")
	}

	// 被打掉的那条会在下一条放行的告警里报出来（不是静默丢弃）。
	clock.advance(3600 + 1)
	m.NoteException(errorsInOrder[3], "/x", "http")
	records := readRecords(t, dir)
	if len(records) != 3 {
		t.Fatalf("记录数 = %d", len(records))
	}
	if records[len(records)-1].SuppressedSinceLastAlert != 1 {
		t.Fatalf("suppressedSinceLastAlert = %d",
			records[len(records)-1].SuppressedSinceLastAlert)
	}
}

func TestFlappingIsReportedOncePerWindow(t *testing.T) {
	clock := newClock()
	dir := t.TempDir()
	m := newMonitor(t, dir, clock, monitor.Options{
		FlapWindow: 300 * time.Second, FlapThreshold: 5,
	})
	for index := 0; index < 4; index++ {
		m.NoteAgentDisconnect("agt_1", "Windows-PC")
		clock.advance(10)
	}
	if records := readRecords(t, dir); len(records) != 0 {
		t.Fatalf("只断 4 次不算抖：%d 条", len(records))
	}
	m.NoteAgentDisconnect("agt_1", "Windows-PC")
	records := readRecords(t, dir)
	if len(records) != 1 || records[0].Kind != "flap" {
		t.Fatalf("记录 = %+v", records)
	}
	if disconnects := records[0].Details["disconnectsInWindow"]; fmt.Sprint(disconnects) != "5" {
		t.Fatalf("disconnectsInWindow = %v", disconnects)
	}

	// 同一个窗口里再断几次：不重复打扰。
	for index := 0; index < 3; index++ {
		clock.advance(10)
		m.NoteAgentDisconnect("agt_1", "Windows-PC")
	}
	if len(readRecords(t, dir)) != 1 {
		t.Fatal("同一窗口只报一次")
	}

	// 过了窗口又重新计数。
	clock.advance(400)
	for index := 0; index < 5; index++ {
		clock.advance(10)
		m.NoteAgentDisconnect("agt_1", "Windows-PC")
	}
	if len(readRecords(t, dir)) != 2 {
		t.Fatalf("新窗口应当再报一次：%d 条", len(readRecords(t, dir)))
	}
}

// TestControlDropsAreDeduplicatedPerLinkAndFrame：backpressure:control 按"链路 +
// 帧类型"归类别，同一位置在重报窗口内只打扰一次，不同 agent 互不掩盖。
func TestControlDropsAreDeduplicatedPerLinkAndFrame(t *testing.T) {
	clock := newClock()
	dir := t.TempDir()
	m := newMonitor(t, dir, clock, monitor.Options{
		RenotifyAfter: 3600 * time.Second, MaxAlertsPerHour: 100, MaxAlertsPerDay: 100,
	})
	m.NoteControlDrop("agent agt_1", "pong")
	m.NoteControlDrop("agent agt_1", "pong")
	m.NoteControlDrop("agent agt_2", "hostStatus")
	records := readRecords(t, dir)
	if len(records) != 2 {
		t.Fatalf("期望两条（同链路同帧去重、不同 agent 各自一条），实际 %d 条", len(records))
	}
	if records[0].Kind != "backpressure:control" {
		t.Fatalf("kind = %q，期望 backpressure:control", records[0].Kind)
	}
	if records[0].Details["frame"] != "pong" || records[0].Details["link"] != "agent agt_1" {
		t.Fatalf("首条 details = %v", records[0].Details)
	}
}

// TestStreamDropAlertsCarryNoFrameContent：backpressure:stream 按链路归类别，
// 详情只有链路标识与窗口计数——流式帧里装的是会话数据，一个字段都不许带。
func TestStreamDropAlertsCarryNoFrameContent(t *testing.T) {
	clock := newClock()
	dir := t.TempDir()
	m := newMonitor(t, dir, clock, monitor.Options{
		RenotifyAfter: 3600 * time.Second, MaxAlertsPerHour: 100, MaxAlertsPerDay: 100,
	})
	m.NoteStreamDrop("device dev_1", 100)
	m.NoteStreamDrop("device dev_1", 100)
	m.NoteStreamDrop("agent agt_1", 100)
	records := readRecords(t, dir)
	if len(records) != 2 {
		t.Fatalf("期望两条（同链路去重、不同链路各自一条），实际 %d 条", len(records))
	}
	first := records[0]
	if first.Kind != "backpressure:stream" || first.Key != "backpressure:stream:device dev_1" {
		t.Fatalf("记录 = %+v", first)
	}
	if len(first.Details) != 2 || first.Details["link"] != "device dev_1" ||
		fmt.Sprint(first.Details["droppedInWindow"]) != "100" {
		t.Fatalf("details 只允许 link 与 droppedInWindow：%v", first.Details)
	}
}

func TestSurrogateSamplesAreCappedPerDay(t *testing.T) {
	clock := newClock()
	dir := t.TempDir()
	m := newMonitor(t, dir, clock, monitor.Options{
		SurrogateSamplesPerDay: 2, MaxAlertsPerHour: 100, MaxAlertsPerDay: 100,
	})
	damage := dlp.SurrogateDamage{
		Count: 1, TotalChars: 10, FirstIndex: 9, TrailingChars: 0,
		Kinds: "high", Context: "尾巴 ",
	}
	for index := 0; index < 3; index++ {
		m.NoteUnpairedSurrogates("agt_1", "dev_1", "item", damage)
	}
	records := readRecords(t, dir)
	if len(records) != 1 {
		t.Fatalf("同一类别只报一条：%d", len(records))
	}
	if records[0].Key != "surrogate:unpaired" || records[0].Kind != "corrupt-frame" {
		t.Fatalf("记录 = %+v", records[0])
	}
	if sample := records[0].Details["sample"]; sample != "1/2" {
		t.Fatalf("sample = %v", sample)
	}
	// 单条告警里就带着定位根因的字段。
	if trailing := records[0].Details["trailingChars"]; fmt.Sprint(trailing) != "0" {
		t.Fatalf("trailingChars = %v", trailing)
	}
}

func TestStateSurvivesARestart(t *testing.T) {
	clock := newClock()
	dir := t.TempDir()
	first := newMonitor(t, dir, clock, monitor.Options{})
	noteSamePlace(first, "boom")
	if len(readRecords(t, dir)) != 1 {
		t.Fatal("首条应当入队")
	}

	// 重启（新进程、新实例）之后同类不该再报一次。
	second := newMonitor(t, dir, clock, monitor.Options{})
	noteSamePlace(second, "after restart")
	if records := readRecords(t, dir); len(records) != 1 {
		t.Fatalf("重启后同类不该再报：%d 条", len(records))
	}
}

func TestDisabledMonitorIsANoOp(t *testing.T) {
	observed := t.TempDir()
	m := monitor.New(monitor.Options{Logger: testLogger()})
	if m.Enabled() {
		t.Fatal("AlertDir 为空应当是关闭")
	}
	m.NoteException(errors.New("boom"), "/x", "http")
	m.NoteAgentDisconnect("agt_1", "")
	m.NoteHTTPStatus("GET", "/x", "", 500)
	m.NoteUnpairedSurrogates("agt_1", "dev_1", "item", dlp.SurrogateDamage{})
	m.Flush()
	m.SaveState()
	entries, err := os.ReadDir(observed)
	if err != nil {
		t.Fatalf("读目录: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("禁用实例写了文件：%v", entries)
	}
}

func TestABrokenAlertDirectoryNeverPanics(t *testing.T) {
	blocker := filepath.Join(t.TempDir(), "alerts")
	if err := os.WriteFile(blocker, []byte("not a directory"), 0o644); err != nil {
		t.Fatalf("准备坏目录: %v", err)
	}
	clock := newClock()
	m := newMonitor(t, blocker, clock, monitor.Options{})
	m.NoteException(errors.New("boom"), "/x", "http")
	m.NoteAgentDisconnect("agt_1", "")
	m.Flush()
}

func TestDescribeIsOperatorFacingOnly(t *testing.T) {
	clock := newClock()
	described := newMonitor(t, t.TempDir(), clock, monitor.Options{}).Describe()
	if described["enabled"] != true {
		t.Fatalf("describe = %v", described)
	}
	for _, key := range []string{"alertDir", "renotifyHours", "maxPerHour", "flapThreshold"} {
		if _, ok := described[key]; !ok {
			t.Fatalf("describe 缺 %q：%v", key, described)
		}
	}
}

// ── HTTP 中间件 ────────────────────────────────────────────────────────────

func TestTheMiddlewareRecordsAPanicAndStillReturnsJSON(t *testing.T) {
	dir := t.TempDir()
	clock := newClock()
	m := newMonitor(t, dir, clock, monitor.Options{})
	mux := http.NewServeMux()
	mux.HandleFunc("/test/explode", func(http.ResponseWriter, *http.Request) {
		panic("handler 里没接住的异常")
	})
	handler := monitor.Middleware(m, testLogger())(mux)
	request := httptest.NewRequest(http.MethodGet, "/test/explode", nil)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusInternalServerError {
		t.Fatalf("状态码 = %d", recorder.Code)
	}
	var envelope map[string]any
	if err := json.Unmarshal(recorder.Body.Bytes(), &envelope); err != nil {
		t.Fatalf("500 不是 JSON: %v (%s)", err, recorder.Body.String())
	}
	if envelope["ok"] != false {
		t.Fatalf("信封 = %v", envelope)
	}

	records := readRecords(t, dir)
	if len(records) != 1 || records[0].Kind != "exception" {
		t.Fatalf("记录 = %+v", records)
	}
	if records[0].Details["path"] != "/test/explode" ||
		records[0].Details["source"] != "http" {
		t.Fatalf("details = %v", records[0].Details)
	}
	if records[0].Details["place"] == "?" {
		t.Fatalf("panic 位置没取到：%v", records[0].Details)
	}
}

func TestTheMiddlewareRecordsA5xxButIgnoresNormalHTTPErrors(t *testing.T) {
	dir := t.TempDir()
	clock := newClock()
	m := newMonitor(t, dir, clock, monitor.Options{})
	mux := http.NewServeMux()
	mux.HandleFunc("/broken", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"ok":false}`))
	})
	handler := monitor.Middleware(m, testLogger())(mux)

	for _, path := range []string{"/no/such/route", "/link/agent"} {
		request := httptest.NewRequest(http.MethodGet, path, nil)
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, request)
		if recorder.Code < 400 || recorder.Code >= 500 {
			t.Fatalf("%s 的状态码 = %d", path, recorder.Code)
		}
	}
	if records := readRecords(t, dir); len(records) != 0 {
		t.Fatalf("4xx 是协议的一部分，不是事故：%+v", records)
	}

	request := httptest.NewRequest(http.MethodGet, "/broken", nil)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	records := readRecords(t, dir)
	if len(records) != 1 {
		t.Fatalf("5xx 应当进监控：%d 条", len(records))
	}
	if records[0].Details["path"] != "/broken" ||
		fmt.Sprint(records[0].Details["status"]) != "500" {
		t.Fatalf("details = %v", records[0].Details)
	}
}

// TestTheMiddlewareRecordsTheRouteTemplate 钉住 B4：告警归类的 path 是 mux 的
// 路由模板，不是真实请求路径——参数值不进告警通道，同类端点的 5xx 才能聚合。
func TestTheMiddlewareRecordsTheRouteTemplate(t *testing.T) {
	dir := t.TempDir()
	clock := newClock()
	m := newMonitor(t, dir, clock, monitor.Options{})
	mux := http.NewServeMux()
	mux.HandleFunc("GET /things/{id}/explode", func(http.ResponseWriter, *http.Request) {
		panic("参数化路由里的异常")
	})
	handler := monitor.Middleware(m, testLogger())(mux)

	request := httptest.NewRequest(http.MethodGet, "/things/dev_secret123/explode", nil)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusInternalServerError {
		t.Fatalf("状态码 = %d", recorder.Code)
	}
	records := readRecords(t, dir)
	if len(records) != 1 {
		t.Fatalf("记录 = %+v", records)
	}
	if records[0].Details["path"] != "/things/{id}/explode" {
		t.Fatalf("path = %v，期望路由模板（不含真实参数值）", records[0].Details["path"])
	}
	if strings.Contains(fmt.Sprint(records[0].Details), "dev_secret123") {
		t.Fatalf("参数值泄进了告警：%v", records[0].Details)
	}
}

func TestTheMiddlewareDoesNotBreakWebSocketUpgrades(t *testing.T) {
	m := newMonitor(t, t.TempDir(), newClock(), monitor.Options{})
	handler := monitor.Middleware(m, testLogger())(http.HandlerFunc(
		func(w http.ResponseWriter, r *http.Request) {
			conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
				InsecureSkipVerify: true,
			})
			if err != nil {
				return
			}
			defer conn.CloseNow()
			_, payload, err := conn.Read(r.Context())
			if err != nil {
				return
			}
			_ = conn.Write(r.Context(), websocket.MessageText, payload)
		}))
	server := httptest.NewServer(handler)
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx,
		"ws"+strings.TrimPrefix(server.URL, "http"), nil)
	if err != nil {
		t.Fatalf("WebSocket 握手失败（中间件挡住了 Hijacker）：%v", err)
	}
	defer conn.CloseNow()
	if err := conn.Write(ctx, websocket.MessageText, []byte("hello")); err != nil {
		t.Fatalf("写 WS: %v", err)
	}
	_, payload, err := conn.Read(ctx)
	if err != nil {
		t.Fatalf("读 WS: %v", err)
	}
	if string(payload) != "hello" {
		t.Fatalf("回显 = %q", payload)
	}
}

// ── 队列：取走 / 放回 ──────────────────────────────────────────────────────

func writeQueue(t *testing.T, dir string, records ...monitor.Record) string {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("建目录: %v", err)
	}
	path := filepath.Join(dir, monitor.QueueName)
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o644)
	if err != nil {
		t.Fatalf("开队列: %v", err)
	}
	defer file.Close()
	for _, record := range records {
		line, err := json.Marshal(record)
		if err != nil {
			t.Fatalf("编码记录: %v", err)
		}
		if _, err := file.Write(append(line, '\n')); err != nil {
			t.Fatalf("写队列: %v", err)
		}
	}
	return path
}

func sampleRecord(key string) monitor.Record {
	return monitor.Record{
		TS: 1_700_000_000, Key: key, Kind: "exception", Title: "中转异常：ValueError @ hub.py:1042",
		Summary: "/link/agent → ValueError: boom", Count: 1, OccurrencesInWindow: 1,
		NewCategory: true, Details: map[string]any{"path": "/link/agent"},
	}
}

func TestReadQueueSkipsMalformedLines(t *testing.T) {
	dir := t.TempDir()
	path := writeQueue(t, dir, sampleRecord("a"), sampleRecord("b"))
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		t.Fatalf("开队列: %v", err)
	}
	_, _ = file.WriteString("{not json\n")
	_ = file.Close()

	records, bad, err := monitor.ReadQueue(path)
	if err != nil {
		t.Fatalf("读队列: %v", err)
	}
	if len(records) != 2 || bad != 1 {
		t.Fatalf("records=%d bad=%d", len(records), bad)
	}
}

func TestTakeQueueIsAtomicAndRestorePutsEveryRecordBack(t *testing.T) {
	dir := t.TempDir()
	queuePath := writeQueue(t, dir, sampleRecord("a"), sampleRecord("b"))
	before, err := os.ReadFile(queuePath)
	if err != nil {
		t.Fatalf("读队列: %v", err)
	}

	records, bad, err := monitor.TakeQueue(dir)
	if err != nil || bad != 0 || len(records) != 2 {
		t.Fatalf("取走: records=%d bad=%d err=%v", len(records), bad, err)
	}
	if _, err := os.Stat(queuePath); !os.IsNotExist(err) {
		t.Fatalf("取走之后队列应当消失：%v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, monitor.TakenName)); err != nil {
		t.Fatalf("taken 文件应当存在：%v", err)
	}

	if err := monitor.RestoreQueue(dir); err != nil {
		t.Fatalf("放回: %v", err)
	}
	after, err := os.ReadFile(queuePath)
	if err != nil {
		t.Fatalf("读放回后的队列: %v", err)
	}
	if string(after) != string(before) {
		t.Fatalf("放回不是原样：\n%q\n%q", after, before)
	}
	if _, err := os.Stat(filepath.Join(dir, monitor.TakenName)); !os.IsNotExist(err) {
		t.Fatal("放回之后 taken 应当删除")
	}
}

func TestTakeQueueOnAMissingQueueIsNotAnError(t *testing.T) {
	dir := t.TempDir()
	records, bad, err := monitor.TakeQueue(dir)
	if err != nil || len(records) != 0 || bad != 0 {
		t.Fatalf("records=%d bad=%d err=%v", len(records), bad, err)
	}
}

func TestTakeQueueDiscardsAnEmptyQueue(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("建目录: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, monitor.QueueName), []byte("\n\n"), 0o644); err != nil {
		t.Fatalf("写空队列: %v", err)
	}
	records, _, err := monitor.TakeQueue(dir)
	if err != nil || len(records) != 0 {
		t.Fatalf("records=%d err=%v", len(records), err)
	}
	if _, err := os.Stat(filepath.Join(dir, monitor.TakenName)); !os.IsNotExist(err) {
		t.Fatal("空队列的 taken 应当删除")
	}
}

func TestFromEnvReadsTheOperatorSwitches(t *testing.T) {
	dir := t.TempDir()
	values := map[string]string{
		"DLP_ALERT_DIR":               dir,
		"DLP_ALERT_RENOTIFY_HOURS":    "1.5",
		"DLP_ALERT_MAX_PER_HOUR":      "2",
		"DLP_ALERT_MAX_PER_DAY":       "9",
		"DLP_ALERT_FLAP_WINDOW_S":     "60",
		"DLP_ALERT_FLAP_THRESHOLD":    "3",
		"DLP_ALERT_SURROGATE_SAMPLES": "0",
	}
	m := monitor.FromEnv(func(name string) string { return values[name] }, testLogger())
	if !m.Enabled() {
		t.Fatal("DLP_ALERT_DIR 非空时必须启用")
	}
	described := m.Describe()
	if described["maxPerHour"] != 2 || described["maxPerDay"] != 9 ||
		described["flapThreshold"] != 3 {
		t.Fatalf("describe = %v", described)
	}
	if hours, ok := described["renotifyHours"].(float64); !ok || hours != 1.5 {
		t.Fatalf("renotifyHours = %v", described["renotifyHours"])
	}
	if window, ok := described["flapWindowSeconds"].(float64); !ok || window != 60 {
		t.Fatalf("flapWindowSeconds = %v", described["flapWindowSeconds"])
	}

	if monitor.FromEnv(func(string) string { return "" }, testLogger()).Enabled() {
		t.Fatal("DLP_ALERT_DIR 为空时必须关闭")
	}
}
