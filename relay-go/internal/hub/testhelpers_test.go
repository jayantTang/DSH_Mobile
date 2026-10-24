package hub

import (
	"context"
	"io"
	"log/slog"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/presence"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// fakeSink 是测试里的写出口：记下写过的帧与关闭调用，可配置阻塞/心跳失败。
//
// 它实现的是 hub.Sink 而不是去模拟 WebSocket——这一层存在的原因就是让路由、队列
// 与背压能脱离真实 socket 验证。
type fakeSink struct {
	mu     sync.Mutex
	writes [][]byte
	closes []closeCall
	// block 非 nil 时 Write 会阻塞到它被关闭（模拟读得太慢的对端）。
	block     chan struct{}
	blockOnce *sync.Once
	// pingErr 非 nil 时心跳失败（模拟已经死掉但 TCP 还没察觉的连接）。
	pingErr error
	// pings 记录心跳次数。
	pings int
}

type closeCall struct {
	Code   int
	Reason string
}

func newFakeSink() *fakeSink { return &fakeSink{} }

func (s *fakeSink) Write(ctx context.Context, payload []byte) error {
	s.mu.Lock()
	block := s.block
	s.mu.Unlock()
	if block != nil {
		select {
		case <-block:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	copied := make([]byte, len(payload))
	copy(copied, payload)
	s.mu.Lock()
	s.writes = append(s.writes, copied)
	s.mu.Unlock()
	return nil
}

func (s *fakeSink) Ping(context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pings++
	return s.pingErr
}

// pingCount 是 WS 控制帧心跳的次数（agent 链路不该再用它）。
func (s *fakeSink) pingCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.pings
}

func (s *fakeSink) Close(code int, reason string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, existing := range s.closes {
		if existing.Code == code && existing.Reason == reason {
			return nil
		}
	}
	s.closes = append(s.closes, closeCall{Code: code, Reason: reason})
	s.mu.Unlock()
	// 关闭即放行：阻塞中的 Write 不该把用例挂在关闭之后。
	s.releaseBlock()
	s.mu.Lock()
	return nil
}

// setBlocking 让后续写入阻塞（模拟慢客户端），返回解除函数。
func (s *fakeSink) setBlocking() func() {
	gate := make(chan struct{})
	s.mu.Lock()
	s.block = gate
	s.blockOnce = &sync.Once{}
	s.mu.Unlock()
	return func() { s.releaseBlock() }
}

// releaseBlock 放行被阻塞的写入（幂等：关闭调用与用例收尾都会来一次）。
func (s *fakeSink) releaseBlock() {
	s.mu.Lock()
	gate, once := s.block, s.blockOnce
	s.mu.Unlock()
	if gate != nil && once != nil {
		once.Do(func() { close(gate) })
	}
}

// frames 返回写出去的全部帧（解析后）。
func (s *fakeSink) frames(t *testing.T) []dlp.Frame {
	t.Helper()
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]dlp.Frame, 0, len(s.writes))
	for _, payload := range s.writes {
		// 用与生产同一条解析路径（UseNumber），否则数字会变成 float64，
		// 断言就变成了"测 json.Unmarshal"。
		frame, _, err := dlp.Parse(payload)
		if err != nil {
			t.Fatalf("写出的不是合法帧：%v (%s)", err, payload)
		}
		out = append(out, frame)
	}
	return out
}

// lastClose 返回最后一次关闭调用；还没有时 ok=false。
// closeCalls 返回全部关闭调用（副本）。
func (s *fakeSink) closeCalls() []closeCall {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]closeCall(nil), s.closes...)
}

func (s *fakeSink) lastClose() (closeCall, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.closes) == 0 {
		return closeCall{}, false
	}
	return s.closes[len(s.closes)-1], true
}

// waitFor 在 2 秒内等待条件成立；超时即失败（不做无声的 sleep 等待）。
func waitFor(t *testing.T, what string, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatalf("等待超时：%s", what)
}

// expectQuiet 是否定观察窗口的轮询形态：2 秒内持续检查不变量，被破坏立即失败
// （对齐 relay/tests/test_hub_routing.py 的轮询写法，不用 sleep 盲等一个固定时长）。
func expectQuiet(t *testing.T, what string, holds func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if !holds() {
			t.Fatalf("观察窗口内不变量被破坏：%s", what)
		}
		time.Sleep(15 * time.Millisecond)
	}
}

// waitFrame 等到第一条满足条件的帧。
func waitFrame(t *testing.T, sink *fakeSink, what string, match func(dlp.Frame) bool) dlp.Frame {
	t.Helper()
	var found dlp.Frame
	waitFor(t, what, func() bool {
		for _, frame := range sink.frames(t) {
			if match(frame) {
				found = frame
				return true
			}
		}
		return false
	})
	return found
}

// expectNoFrame 断言一段时间内没有满足条件的帧。
func expectNoFrame(t *testing.T, sink *fakeSink, what string, match func(dlp.Frame) bool) {
	t.Helper()
	time.Sleep(60 * time.Millisecond)
	for _, frame := range sink.frames(t) {
		if match(frame) {
			t.Fatalf("不该出现的帧出现了（%s）：%v", what, frame)
		}
	}
}

// testLogger 把 hub 的日志丢进测试输出（-v 时才看得见）。
func testLogger(t *testing.T) *slog.Logger {
	t.Helper()
	return slog.New(slog.NewTextHandler(testWriter{t}, &slog.HandlerOptions{Level: slog.LevelDebug}))
}

type testWriter struct{ t *testing.T }

func (w testWriter) Write(payload []byte) (int, error) {
	w.t.Logf("%s", payload)
	return len(payload), nil
}

// discardLogger 把后台任务的日志丢进虚空（用例只关心状态，不关心日志文本）。
func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// openTestStore 开一个临时库，随用例结束关闭（给需要自建 Hub 的用例用）。
func openTestStore(t *testing.T) *store.Store {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "state.db"))
	if err != nil {
		t.Fatalf("打开临时库: %v", err)
	}
	t.Cleanup(func() {
		if err := st.Close(); err != nil {
			t.Errorf("关闭临时库: %v", err)
		}
	})
	return st
}

// fixture 是一套隔离的 store + hub。
type fixture struct {
	t     *testing.T
	store *store.Store
	hub   *Hub
}

func newFixture(t *testing.T, options Options) *fixture {
	t.Helper()
	return newFixtureWithStore(t, openTestStore(t), options)
}

// newFixtureWithStore 用调用方准备好的库建 Hub（需要在装配时就注入 UsageSink 的
// 用例用它：注入口在 Options 里，晚于 New 就没有 Hook 了）。
func newFixtureWithStore(t *testing.T, st *store.Store, options Options) *fixture {
	t.Helper()
	options.Store = st
	if options.Logger == nil {
		options.Logger = testLogger(t)
	}
	fixture := &fixture{t: t, store: st, hub: New(options)}
	// 用例结束时关掉它挂过的全部连接：写循环与心跳 watchdog 用的是
	// context.Background()，不关就活到进程结束——-count=N 时前一轮的 watchdog
	// 会在后一轮里打日志（t.Logf 在用例结束后会 panic），泄漏的 goroutine 也会
	// 让 -race 的结论失真。这是收尾，不是放宽任何断言。
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		fixture.hub.Shutdown(ctx)
	})
	return fixture
}

// tenant 是"一个账户 + 一台电脑"。
type tenant struct {
	account store.Account
	agent   store.Agent
}

// newTenant 直接经仓储层建账户与电脑（等价于 admin 的 account-create + agent-register）。
func (f *fixture) newTenant(name string) tenant {
	f.t.Helper()
	ctx := context.Background()
	account, err := f.store.CreateAccount(ctx, name)
	if err != nil {
		f.t.Fatalf("CreateAccount: %v", err)
	}
	agent, _, err := f.store.RegisterAgent(ctx, account.AccountID, name, nil)
	if err != nil {
		f.t.Fatalf("RegisterAgent: %v", err)
	}
	return tenant{account: account, agent: agent}
}

// pairDevice 走真实的铸码 + 认领，得到一台已配对设备。
func (f *fixture) pairDevice(owner tenant, name string) store.Device {
	f.t.Helper()
	ctx := context.Background()
	minted, err := f.store.MintPairCode(ctx, owner.agent.AgentID, nil)
	if err != nil {
		f.t.Fatalf("MintPairCode: %v", err)
	}
	claimed, err := f.store.ClaimPairCode(ctx, minted.Code, store.ClaimParams{
		DeviceName: name, MaxPairedDevices: 8,
		// 与生产同口径：不传有效期会得到 expiresAt=now，设备当场就算过期。
		TTLMS: store.DefaultDeviceTTLMS,
	})
	if err != nil {
		f.t.Fatalf("ClaimPairCode: %v", err)
	}
	device, found, err := f.store.DeviceByID(ctx, claimed.DeviceID)
	if err != nil || !found {
		f.t.Fatalf("DeviceByID: found=%v err=%v", found, err)
	}
	return device
}

// attachAgent 把一条假电脑连接挂进 hub（走真实的准入路径，被拒即用例失败）。
func (f *fixture) attachAgent(owner tenant) (*AgentLink, *fakeSink) {
	f.t.Helper()
	sink := newFakeSink()
	link := f.hub.AttachAgent(context.Background(), owner.agent, sink, f.admitAgent(owner))
	return link, sink
}

// attachAgentWithSink 用调用方给的 sink 走真实准入并挂接。
func (f *fixture) attachAgentWithSink(owner tenant, sink *fakeSink) *AgentLink {
	f.t.Helper()
	return f.hub.AttachAgent(context.Background(), owner.agent, sink, f.admitAgent(owner))
}

// admitAgent 取一张准入票；单测里被拒绝说明策略窗口配得不对。
func (f *fixture) admitAgent(owner tenant) *presence.Ticket {
	f.t.Helper()
	ticket, refusal := f.hub.AdmitAgent(context.Background(), owner.agent)
	if refusal != nil {
		f.t.Fatalf("AdmitAgent: %v（reason=%s）", refusal, refusal.Reason)
	}
	return ticket
}

// attachDevice 把一条假手机连接挂进 hub。
func (f *fixture) attachDevice(device store.Device) (*DeviceLink, *fakeSink, error) {
	f.t.Helper()
	sink := newFakeSink()
	link, err := f.hub.AttachDevice(context.Background(), device, sink)
	if err != nil {
		return nil, sink, err
	}
	return link, sink, nil
}

// mustAttachDevice 是 attachDevice 的失败即终止版本。
func (f *fixture) mustAttachDevice(device store.Device) (*DeviceLink, *fakeSink) {
	f.t.Helper()
	link, sink, err := f.attachDevice(device)
	if err != nil {
		f.t.Fatalf("AttachDevice: %v", err)
	}
	return link, sink
}

// scanWire 把一段 JSON 变成转发视图（用例里手写帧用）。
//
// 走的是与生产同一条入口（dlp.Scan）：用例因此也覆盖了扫描路径。
func scanWire(t *testing.T, raw string) dlp.Wire {
	t.Helper()
	wire, damage, err := dlp.Scan([]byte(raw))
	if err != nil {
		t.Fatalf("Scan(%s): %v", raw, err)
	}
	if damage != nil {
		t.Fatalf("用例里的帧不该带代理项损伤：%v", damage)
	}
	return wire
}

// wireOf 把一帧 map 变成转发视图（需要构造动态键的用例用）。
func wireOf(t *testing.T, frame dlp.Frame) dlp.Wire {
	t.Helper()
	encoded, err := dlp.Encode(frame)
	if err != nil {
		t.Fatalf("Encode: %v", err)
	}
	return scanWire(t, string(encoded))
}

// isKind 是帧类型判定。
func isKind(kind string) func(dlp.Frame) bool {
	return func(frame dlp.Frame) bool { return frame.Type() == kind }
}

// 编译期确认 *AgentLink / *DeviceLink 满足 Target（wsapi 也要用）。
var (
	_ Target = (*AgentLink)(nil)
	_ Target = (*DeviceLink)(nil)
	_ Sink   = (*fakeSink)(nil)
)

// closeStatus 取关闭码，没有关闭时返回 0。
func closeStatus(sink *fakeSink) int {
	if call, ok := sink.lastClose(); ok {
		return call.Code
	}
	return 0
}
