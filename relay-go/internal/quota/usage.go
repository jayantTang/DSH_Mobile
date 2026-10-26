package quota

import (
	"context"
	"errors"
	"log/slog"
	"sort"
	"sync"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// Sink 是 quota 需要的仓储面（DESIGN §3.3 步骤 2.1：3 个方法）。
//
// 它只含额度基线与用量落盘/汇总：quota 不读设备、账户或推送数据。*store.Store
// 实现它；单测注入失败实现验证"写失败就把这批放回内存"。
type Sink interface {
	UsageBytesOn(ctx context.Context, day int64, deviceID string) (int64, error)
	AddUsage(ctx context.Context, entries []store.UsageEntry) (int, error)
	TodayUsage(ctx context.Context, day int64) (store.TodayUsage, error)
}

// ErrNoStore 表示 quota 没有配库（只在测试与 health-only 装配里可能发生）。
//
// 文案沿用迁移前 hub 的错误串：它会出现在运维日志里，步骤 2 不改日志文案。
var ErrNoStore = errors.New("relay: hub has no store")

// DeviceRef 是记账主体：一台设备及其归属。
//
// 它是 quota 与连接对象之间唯一的数据面——quota 不认识 *hub.DeviceLink，只按这三个
// 字段记（账本按 deviceId，冲盘行还要 agent/account 归属）。
type DeviceRef struct {
	DeviceID  string
	AgentID   string
	AccountID string
}

// Usage 是"哪天哪台设备用了多少"的内存账本（尚未落盘的那一半）。
//
// 键是 (本地日, deviceId)，与 Python 的 `RelayHub._usage` 同口径。按天而不是只按
// 设备记，是因为跨日时**前一天还没冲盘的尾巴不能丢**：只按设备记的话，跨日换账本
// 等于把它扔掉。也正因为这样，本类型不需要"换账本"这个动作。
//
// 账本按设备而非按连接：手机重连不该让"今天的用量"归零。
type Usage struct {
	sink  Sink
	today func() int64
	log   *slog.Logger

	mu      sync.Mutex
	day     int64
	entries map[usageKey]*usageEntry
	// bytesSinceFlush 是距上次冲盘的出口字节数（Python 的
	// `_usage_bytes_since_flush`）；操作计数另有 opsSinceFlush，两个阈值都会
	// 触发提前冲盘。
	bytesSinceFlush int64
	// opsSinceFlush 是距上次冲盘的操作计数；低流量设备也要在关停/跨日前
	// 有一个可落盘的时机，不能只靠出口字节。
	opsSinceFlush int64
	// seen 是跨连接、跨天保留的最近操作指纹；它不随 entries 冲盘清空。
	seen seenStore
}

// usageKey 是账本的主键：本地日 + 设备。
type usageKey struct {
	day      int64
	deviceID string
}

// usageEntry 是一台设备一天内的增量（store.UsageEntry 的内存形态）。
type usageEntry struct {
	day         int64
	deviceID    string
	agentID     string
	accountID   string
	egressBytes int64
	connections int64
	prompts     int64
	answers     int64
	at          int64
	lastBuild   string
}

// NewUsage 建一个空账本；sink 为 nil 时冲盘与今日汇总返回 ErrNoStore。
func NewUsage(sink Sink, today func() int64, log *slog.Logger) *Usage {
	return &Usage{
		sink: sink, today: today, log: log, entries: map[usageKey]*usageEntry{},
	}
}

// entryLocked 取（或建）一台设备今天的增量；调用方持锁。
func (u *Usage) entryLocked(ref DeviceRef) *usageEntry {
	day := u.today()
	if day > u.day {
		u.day = day
	}
	key := usageKey{day: day, deviceID: ref.DeviceID}
	entry := u.entries[key]
	if entry == nil {
		entry = &usageEntry{
			day: day, deviceID: ref.DeviceID,
			agentID: ref.AgentID, accountID: ref.AccountID,
			at: store.NowMS(),
		}
		u.entries[key] = entry
	}
	return entry
}

// CurrentDay 是账本最近一次见到的本地日（冲盘循环用它判断跨日）。
func (u *Usage) CurrentDay() int64 {
	u.mu.Lock()
	defer u.mu.Unlock()
	return u.day
}

// BytesSinceFlush 是距上次冲盘的出口字节数。
func (u *Usage) BytesSinceFlush() int64 {
	u.mu.Lock()
	defer u.mu.Unlock()
	return u.bytesSinceFlush
}

// Pending 表示账本里有没有需要落盘的内容（字节、连接数、计数、构建号任一）。
func (u *Usage) Pending() bool {
	u.mu.Lock()
	defer u.mu.Unlock()
	for _, entry := range u.entries {
		if !entry.empty() {
			return true
		}
	}
	return false
}

// empty 是"这一行有没有内容"的唯一判断：Pending 与 copyLocked 共用，避免两处漂移。
func (e *usageEntry) empty() bool {
	return e.egressBytes == 0 && e.connections == 0 &&
		e.prompts == 0 && e.answers == 0 && e.lastBuild == ""
}

// OpsSinceFlush 是距上次冲盘的操作计数。
func (u *Usage) OpsSinceFlush() int64 {
	u.mu.Lock()
	defer u.mu.Unlock()
	return u.opsSinceFlush
}

// NoteConnection 记一次连接（/stats 的 today.connections）。
func (u *Usage) NoteConnection(ref DeviceRef) {
	u.mu.Lock()
	defer u.mu.Unlock()
	entry := u.entryLocked(ref)
	entry.connections++
	entry.at = store.NowMS()
}

// NoteEgress 在字节真正送出后累加出口字节。
//
// 这是发送热路径上唯一的一次字典加法；写库留给周期冲盘。
func (u *Usage) NoteEgress(ref DeviceRef, size int) {
	if size <= 0 {
		return
	}
	u.mu.Lock()
	defer u.mu.Unlock()
	entry := u.entryLocked(ref)
	entry.egressBytes += int64(size)
	entry.at = store.NowMS()
	u.bytesSinceFlush += int64(size)
}

// NoteBuild 记下当天见到的构建号。
func (u *Usage) NoteBuild(ref DeviceRef, build string) {
	if build == "" {
		return
	}
	u.mu.Lock()
	defer u.mu.Unlock()
	entry := u.entryLocked(ref)
	entry.lastBuild = build
	entry.at = store.NowMS()
}

// DefaultOpFlushCount 是操作计数的提前冲盘阈值。
//
// 低流量设备可能很久攒不到 1 MiB 出口字节；计数若只靠断开/跨日冲盘，
// 进程异常退出会丢掉整天的操作数。32 是一个很小的批量，写入仍是单事务。
const DefaultOpFlushCount = 32

// NoteOpOnce 记录一次设备操作；同一设备、同一操作、同一指纹只计一次。
//
// 指纹由 hub 从协议帧的幂等键算出（prompt 的 requestId、作答的 eventId），
// 去重表按设备、按操作隔离，跨连接与跨天保留。计数只在帧成功入队后调用，
// 所以电脑离线或队列溢出不会被记成一次用户操作。
func (u *Usage) NoteOpOnce(ref DeviceRef, op Op, fingerprint uint64) bool {
	if op != OpPrompt && op != OpAnswer {
		return false
	}
	if !u.seen.add(ref.DeviceID, op, fingerprint) {
		return false
	}
	u.mu.Lock()
	defer u.mu.Unlock()
	entry := u.entryLocked(ref)
	switch op {
	case OpPrompt:
		entry.prompts++
	case OpAnswer:
		entry.answers++
	}
	entry.at = store.NowMS()
	u.opsSinceFlush++
	return true
}

// ForgetDevice 丢掉一台设备的去重指纹（设备撤销/清理时调用）。
//
// 已经落盘的用量行不受影响；这里只释放进程内的最近键表。
func (u *Usage) ForgetDevice(deviceID string) {
	u.seen.forget(deviceID)
}

// Snapshot 返回账本当前内容（**不删除**）：只含真的有内容的行，按日、设备排序。
//
// 它同时是 /stats 的合并来源与单测的断言对象；真正冲盘用 Drain（原子取走并清空，
// 写成功才算数）。
func (u *Usage) Snapshot() []store.UsageEntry {
	u.mu.Lock()
	defer u.mu.Unlock()
	entries := u.copyLocked(false)
	sortUsageEntries(entries)
	return entries
}

// Drain 取走全部待冲盘的行并把账本清空。
//
// "先取走、写成功才算数"是这里的全部要点：AddUsage 是累加（UPSERT +），同一批
// 写两次会把用量翻倍，所以失败时必须由 Restore 放回，而不能重试时再取一次。
func (u *Usage) Drain() []store.UsageEntry {
	u.mu.Lock()
	defer u.mu.Unlock()
	entries := u.copyLocked(true)
	u.bytesSinceFlush = 0
	u.opsSinceFlush = 0
	sortUsageEntries(entries)
	return entries
}

// Restore 在冲盘失败后把这一批放回账本。
//
// 期间新到的字节可能已经为同一台设备建了新行，所以这里是**合并**而不是覆盖：
// 两边的字节、连接数与操作计数相加，构建号取后者非空的，时间取较晚的。
func (u *Usage) Restore(entries []store.UsageEntry) {
	if len(entries) == 0 {
		return
	}
	u.mu.Lock()
	defer u.mu.Unlock()
	for _, restored := range entries {
		key := usageKey{day: restored.Day, deviceID: restored.DeviceID}
		entry := u.entries[key]
		if entry == nil {
			entry = &usageEntry{day: restored.Day, deviceID: restored.DeviceID}
			u.entries[key] = entry
		}
		entry.agentID = restored.AgentID
		entry.accountID = restored.AccountID
		entry.egressBytes += restored.EgressBytes
		entry.connections += restored.Connections
		entry.prompts += restored.Prompts
		entry.answers += restored.Answers
		if restored.LastBuild != nil {
			entry.lastBuild = *restored.LastBuild
		}
		if restored.At > entry.at {
			entry.at = restored.At
		}
		u.bytesSinceFlush += restored.EgressBytes
		u.opsSinceFlush += restored.Prompts + restored.Answers
	}
}

// copyLocked 把有内容的行复制出来；drain=true 时同时从账本里删除。
func (u *Usage) copyLocked(drain bool) []store.UsageEntry {
	out := make([]store.UsageEntry, 0, len(u.entries))
	for key, entry := range u.entries {
		if entry.empty() {
			continue
		}
		out = append(out, store.UsageEntry{
			Day: entry.day, DeviceID: entry.deviceID, AgentID: entry.agentID,
			AccountID: entry.accountID, EgressBytes: entry.egressBytes,
			Connections: entry.connections, Prompts: entry.prompts, Answers: entry.answers,
			At: entry.at, LastBuild: OptionalString(entry.lastBuild),
		})
		if drain {
			delete(u.entries, key)
		}
	}
	return out
}

// sortUsageEntries 让同一批内容的顺序稳定（按日、再按设备）。
func sortUsageEntries(entries []store.UsageEntry) {
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].Day != entries[j].Day {
			return entries[i].Day < entries[j].Day
		}
		return entries[i].DeviceID < entries[j].DeviceID
	})
}

// MergeToday 把内存里还没落盘的增量并进库里的当日汇总。
//
// 形状与 Python hub.usage_today 一致：库里那份 + 内存里那份，按设备出口字节降序；
// 账户侧按账户聚合后再排序。
func (u *Usage) MergeToday(day int64, base store.TodayUsage) store.TodayUsage {
	devices := make(map[string]*store.TodayDevice, len(base.Devices))
	for index := range base.Devices {
		row := base.Devices[index]
		devices[row.DeviceID] = &row
	}

	u.mu.Lock()
	for _, entry := range u.entries {
		if entry.day != day {
			continue
		}
		row := devices[entry.deviceID]
		if row == nil {
			row = &store.TodayDevice{
				DeviceID: entry.deviceID, AgentID: entry.agentID, AccountID: entry.accountID,
			}
			devices[entry.deviceID] = row
		}
		row.EgressBytes += entry.egressBytes
		row.Connections += entry.connections
		row.Prompts += entry.prompts
		row.Answers += entry.answers
		if entry.lastBuild != "" {
			row.LastBuild = OptionalString(entry.lastBuild)
		}
	}
	u.mu.Unlock()

	rows := make([]store.TodayDevice, 0, len(devices))
	var total, totalPrompts, totalAnswers int64
	accounts := map[string]*store.TodayAccount{}
	for _, row := range devices {
		rows = append(rows, *row)
		total += row.EgressBytes
		totalPrompts += row.Prompts
		totalAnswers += row.Answers
		bucket := accounts[row.AccountID]
		if bucket == nil {
			bucket = &store.TodayAccount{AccountID: row.AccountID}
			accounts[row.AccountID] = bucket
		}
		bucket.EgressBytes += row.EgressBytes
		bucket.Devices++
	}
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].EgressBytes > rows[j].EgressBytes })
	accountRows := make([]store.TodayAccount, 0, len(accounts))
	for _, bucket := range accounts {
		accountRows = append(accountRows, *bucket)
	}
	sort.SliceStable(accountRows, func(i, j int) bool {
		return accountRows[i].EgressBytes > accountRows[j].EgressBytes
	})
	return store.TodayUsage{Day: day, TotalEgressBytes: total, TotalPrompts: totalPrompts,
		TotalAnswers: totalAnswers, Devices: rows, Accounts: accountRows}
}

// Today 是 /stats 的 today 段：库里已经冲下去的 + 内存里还没冲的。
//
// 放在 quota 而不是让 handler 直接查库，是因为最近 30 秒的字节还在内存里；
// 两边合起来才是"此刻为止"。
func (u *Usage) Today(ctx context.Context) (store.TodayUsage, error) {
	day := u.today()
	if u.sink == nil {
		return store.TodayUsage{}, ErrNoStore
	}
	base, err := u.sink.TodayUsage(ctx, day)
	if err != nil {
		return store.TodayUsage{}, err
	}
	return u.MergeToday(day, base), nil
}

// Flush 把内存里攒的用量写进 usageDaily。
//
// 调用时机：周期、累计超过 usage_flush_bytes、设备断开、跨日、进程收尾。写失败时
// 把这批放回内存等下次——账不能因为一次写库异常就丢了（Python flush_usage 的口径）。
//
// 返回错误只供调用方决定是否立刻重试；失败已经被记进日志，并且这批数据仍在账本里。
func (u *Usage) Flush(ctx context.Context) error {
	entries := u.Drain()
	if len(entries) == 0 {
		return nil
	}
	if u.sink == nil {
		u.Restore(entries)
		return ErrNoStore
	}
	if _, err := u.sink.AddUsage(ctx, entries); err != nil {
		u.Restore(entries)
		u.log.Warn("relay: could not write usage rows; keeping them in memory",
			"entries", len(entries), "error", err)
		return err
	}
	return nil
}

// Start 是周期冲盘（迁移自 hub.usageFlushLoop）：阻塞到 ctx 结束，调用方用
// goroutine 启动。
//
// 每 interval 检查一次：跨本地日无条件冲一次（上一天的尾巴与新一天已产生的部分
// 一起取走），否则累计出口字节到 flushBytes 就冲。
func (u *Usage) Start(ctx context.Context, interval time.Duration, flushBytes int64) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
		u.seen.prune(store.NowMS(), seenMaxAgeMS)
		today := u.today()
		if u.CurrentDay() != today {
			_ = u.Flush(ctx)
			continue
		}
		if u.BytesSinceFlush() >= flushBytes || u.OpsSinceFlush() >= DefaultOpFlushCount {
			_ = u.Flush(ctx)
		}
	}
}

// OptionalString 把空串转成 nil（"上报方没给这一项"，不拿旧值去补）。
//
// 导出是因为依赖方向只允许留这一份：hub 也用它（hub → quota，反过来会成环）。
func OptionalString(value string) *string {
	if value == "" {
		return nil
	}
	return &value
}
