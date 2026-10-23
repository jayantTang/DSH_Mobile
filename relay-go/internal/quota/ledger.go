package quota

import (
	"context"
	"log/slog"
	"sync"
)

// Ledger 是"每台设备每天已经收了多少字节"的唯一账本。
//
// 与 Python 的一处有意差异：Python 的 DailyQuota 是每个连接一个对象，基线在 attach
// 时从库里读一次；Go 版把计数放在进程级、按 **deviceId** 记，所以同一台设备断开
// 重连不会把当天的额度清零（手机换网、锁屏、中转重启都会重连，而"2 GB 一天"说的是
// 一天，不是一个连接）。
//
// 基线仍来自 usageDaily（与运维报表同一份数）；进程重启后基线只等于最后一次冲盘
// 落库的数（最多晚一个冲盘周期）。
type Ledger struct {
	sink  Sink
	limit int64
	log   *slog.Logger
	today func() int64

	mu     sync.Mutex
	day    int64
	used   map[string]int64
	seated map[string]bool
}

// NewLedger 建一个空账本；sink 为 nil 时 Seat 直接返回（没有库可读基线）。
func NewLedger(sink Sink, limit int64, today func() int64, log *slog.Logger) *Ledger {
	return &Ledger{
		sink: sink, limit: limit, log: log, today: today,
		used: map[string]int64{}, seated: map[string]bool{},
	}
}

// rollLocked 在跨本地日时把账本清空；调用方必须持有 mu。
func (q *Ledger) rollLocked(day int64) {
	if q.day == day {
		return
	}
	q.day = day
	q.used = map[string]int64{}
	q.seated = map[string]bool{}
}

// Seat 为这台设备确定当天的基线，只在本次进程第一次见到它时读库。
//
// 读库失败只记一条告警、把基线当 0：记账出错时宁可给额度，也不能因此拒绝连接。
func (q *Ledger) Seat(ctx context.Context, deviceID string) {
	if q.limit <= 0 || q.sink == nil {
		return
	}
	day := q.today()
	q.mu.Lock()
	q.rollLocked(day)
	if q.seated[deviceID] {
		q.mu.Unlock()
		return
	}
	q.seated[deviceID] = true
	q.mu.Unlock()

	stored, err := q.sink.UsageBytesOn(ctx, day, deviceID)
	if err != nil {
		q.log.Warn("relay: could not read today's usage; starting the allowance from zero",
			"deviceId", deviceID, "error", err)
		return
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.day == day && stored > q.used[deviceID] {
		q.used[deviceID] = stored
	}
}

// Charge 记一次出口字节，返回是否仍在额度内。
//
// 与 Python 的 DailyQuota.charge 同口径：**先记账再判定**，所以把额度撑爆的那一帧
// 本身不会送达（调用方据此发 error 帧再以 4011 关闭）。
func (q *Ledger) Charge(deviceID string, size int) (bool, int64) {
	if q.limit <= 0 {
		return true, 0
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	q.rollLocked(q.today())
	q.used[deviceID] += int64(size)
	used := q.used[deviceID]
	return used <= q.limit, used
}

// Remaining 是这台设备今天还剩多少字节；不限量时返回 -1（Python 同口径）。
func (q *Ledger) Remaining(deviceID string) int64 {
	if q.limit <= 0 {
		return -1
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	q.rollLocked(q.today())
	remaining := q.limit - q.used[deviceID]
	if remaining < 0 {
		return 0
	}
	return remaining
}

// Used 是这台设备今天已经收到的字节（诊断用）。
func (q *Ledger) Used(deviceID string) int64 {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.rollLocked(q.today())
	return q.used[deviceID]
}
