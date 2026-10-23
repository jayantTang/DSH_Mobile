package hub

import (
	"context"
	"errors"
	"log/slog"
	"sort"
	"sync"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// errNoStore 表示 hub 没有配库（只在测试里可能发生）。
var errNoStore = errors.New("relay: hub has no store")

// usageWriter 是冲盘需要的最小仓储接口（store.Store 实现它；单测注入失败实现，
// 用来验证"写失败就把这批放回内存"）。
type usageWriter interface {
	AddUsage(ctx context.Context, entries []store.UsageEntry) (int, error)
}

// usageLedger 是"哪天哪台设备用了多少"的内存账本（尚未落盘的那一半）。
//
// 键是 (本地日, deviceId)，与 Python 的 `RelayHub._usage` 同口径。按天而不是只按
// 设备记，是因为跨日时**前一天还没冲盘的尾巴不能丢**：只按设备记的话，跨日换账本
// 等于把它扔掉。也正因为这样，本类型不需要"换账本"这个动作。
//
// 账本按设备而非按连接：手机重连不该让"今天的用量"归零。
type usageLedger struct {
	today func() int64
	log   *slog.Logger

	mu      sync.Mutex
	day     int64
	entries map[usageKey]*usageEntry
	// bytesSinceFlush 是距上次冲盘的出口字节数（Python 的
	// `_usage_bytes_since_flush`）：只有字节会触发提前冲盘。
	bytesSinceFlush int64
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
	at          int64
	lastBuild   string
}

func newUsageLedger(today func() int64, log *slog.Logger) *usageLedger {
	return &usageLedger{today: today, log: log, entries: map[usageKey]*usageEntry{}}
}

// entryLocked 取（或建）一台设备今天的增量；调用方持锁。
func (u *usageLedger) entryLocked(device *DeviceLink) *usageEntry {
	day := u.today()
	if day > u.day {
		u.day = day
	}
	key := usageKey{day: day, deviceID: device.DeviceID}
	entry := u.entries[key]
	if entry == nil {
		entry = &usageEntry{
			day: day, deviceID: device.DeviceID,
			agentID: device.AgentID, accountID: device.AccountID,
			at: store.NowMS(),
		}
		u.entries[key] = entry
	}
	return entry
}

// CurrentDay 是账本最近一次见到的本地日（冲盘循环用它判断跨日）。
func (u *usageLedger) CurrentDay() int64 {
	u.mu.Lock()
	defer u.mu.Unlock()
	return u.day
}

// BytesSinceFlush 是距上次冲盘的出口字节数。
func (u *usageLedger) BytesSinceFlush() int64 {
	u.mu.Lock()
	defer u.mu.Unlock()
	return u.bytesSinceFlush
}

// Pending 表示账本里有没有需要落盘的内容（字节、连接数、构建号任一）。
func (u *usageLedger) Pending() bool {
	u.mu.Lock()
	defer u.mu.Unlock()
	for _, entry := range u.entries {
		if entry.egressBytes != 0 || entry.connections != 0 || entry.lastBuild != "" {
			return true
		}
	}
	return false
}

// NoteConnection 记一次连接（/stats 的 today.connections）。
func (u *usageLedger) NoteConnection(device *DeviceLink) {
	u.mu.Lock()
	defer u.mu.Unlock()
	entry := u.entryLocked(device)
	entry.connections++
	entry.at = store.NowMS()
}

// NoteEgress 在字节真正送出后累加出口字节。
//
// 这是发送热路径上唯一的一次字典加法；写库留给周期冲盘。
func (u *usageLedger) NoteEgress(device *DeviceLink, size int) {
	if size <= 0 {
		return
	}
	u.mu.Lock()
	defer u.mu.Unlock()
	entry := u.entryLocked(device)
	entry.egressBytes += int64(size)
	entry.at = store.NowMS()
	u.bytesSinceFlush += int64(size)
}

// NoteBuild 记下当天见到的构建号。
func (u *usageLedger) NoteBuild(device *DeviceLink, build string) {
	if build == "" {
		return
	}
	u.mu.Lock()
	defer u.mu.Unlock()
	entry := u.entryLocked(device)
	entry.lastBuild = build
	entry.at = store.NowMS()
}

// Snapshot 返回账本当前内容（**不删除**）：只含真的有内容的行，按日、设备排序。
//
// 它同时是 /stats 的合并来源与单测的断言对象；真正冲盘用 Drain（原子取走并清空，
// 写成功才算数）。
func (u *usageLedger) Snapshot() []store.UsageEntry {
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
func (u *usageLedger) Drain() []store.UsageEntry {
	u.mu.Lock()
	defer u.mu.Unlock()
	entries := u.copyLocked(true)
	u.bytesSinceFlush = 0
	sortUsageEntries(entries)
	return entries
}

// Restore 在冲盘失败后把这一批放回账本。
//
// 期间新到的字节可能已经为同一台设备建了新行，所以这里是**合并**而不是覆盖：
// 两边的字节与连接数相加，构建号取后者非空的，时间取较晚的。
func (u *usageLedger) Restore(entries []store.UsageEntry) {
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
		if restored.LastBuild != nil {
			entry.lastBuild = *restored.LastBuild
		}
		if restored.At > entry.at {
			entry.at = restored.At
		}
		u.bytesSinceFlush += restored.EgressBytes
	}
}

// copyLocked 把有内容的行复制出来；drain=true 时同时从账本里删除。
func (u *usageLedger) copyLocked(drain bool) []store.UsageEntry {
	out := make([]store.UsageEntry, 0, len(u.entries))
	for key, entry := range u.entries {
		if entry.egressBytes == 0 && entry.connections == 0 && entry.lastBuild == "" {
			continue
		}
		out = append(out, store.UsageEntry{
			Day: entry.day, DeviceID: entry.deviceID, AgentID: entry.agentID,
			AccountID: entry.accountID, EgressBytes: entry.egressBytes,
			Connections: entry.connections, At: entry.at,
			LastBuild: optionalString(entry.lastBuild),
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
func (u *usageLedger) MergeToday(day int64, base store.TodayUsage) store.TodayUsage {
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
		if entry.lastBuild != "" {
			row.LastBuild = optionalString(entry.lastBuild)
		}
	}
	u.mu.Unlock()

	rows := make([]store.TodayDevice, 0, len(devices))
	var total int64
	accounts := map[string]*store.TodayAccount{}
	for _, row := range devices {
		rows = append(rows, *row)
		total += row.EgressBytes
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
	return store.TodayUsage{Day: day, TotalEgressBytes: total, Devices: rows, Accounts: accountRows}
}

// Today 是 /stats 的 today 段：库里已经冲下去的 + 内存里还没冲的。
//
// 放在 hub 而不是让 handler 直接查库，是因为最近 30 秒的字节还在内存里；
// 两边合起来才是"此刻为止"。
func (h *Hub) Today(ctx context.Context) (store.TodayUsage, error) {
	if h.store == nil {
		return store.TodayUsage{}, errNoStore
	}
	day := h.today()
	base, err := h.store.TodayUsage(ctx, day)
	if err != nil {
		return store.TodayUsage{}, err
	}
	return h.usage.MergeToday(day, base), nil
}

// FlushUsage 把内存里攒的用量写进 usageDaily。
//
// 调用时机：周期、累计超过 usage_flush_bytes、设备断开、跨日、进程收尾。写失败时
// 把这批放回内存等下次——账不能因为一次写库异常就丢了（Python flush_usage 的口径）。
//
// 返回错误只供调用方决定是否立刻重试；失败已经被记进日志，并且这批数据仍在账本里。
func (h *Hub) FlushUsage(ctx context.Context) error {
	entries := h.usage.Drain()
	if len(entries) == 0 {
		return nil
	}
	if h.usageSink == nil {
		h.usage.Restore(entries)
		return errNoStore
	}
	if _, err := h.usageSink.AddUsage(ctx, entries); err != nil {
		h.usage.Restore(entries)
		h.log.Warn("relay: could not write usage rows; keeping them in memory",
			"entries", len(entries), "error", err)
		return err
	}
	return nil
}
