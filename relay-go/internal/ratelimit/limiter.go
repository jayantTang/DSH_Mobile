// Package ratelimit 是进程内的按桶计数预算（Python api.ClaimLimiter）。
//
// 它只回答两件事："这个桶还能不能再记一次"与"记一次"。桶键是什么、记的是失败还是
// 全部调用，由调用方决定；这里不猜"客户端是谁"，也不碰数据库。
//
// 为什么单独成包：配对、登记、内部端点与反馈四端点用的是同一套计数规则，而它们
// 分属不同包（httpapi、feedback）。规则只留一份，超限的判定就不会在几处漂移。
package ratelimit

import (
	"sync"
	"time"
)

// Limiter 是一份按桶计数的内存预算：每个键在窗口内最多 limit 次。
type Limiter struct {
	limit  int
	window time.Duration

	mu      sync.Mutex
	hits    map[string][]time.Time
	total   int
	nowFunc func() time.Time
}

// New 建一个 limit 次 / window 窗口的预算。
func New(limit int, window time.Duration) *Limiter {
	return &Limiter{
		limit:   limit,
		window:  window,
		hits:    map[string][]time.Time{},
		nowFunc: time.Now,
	}
}

func (l *Limiter) now() time.Time {
	if l.nowFunc != nil {
		return l.nowFunc()
	}
	return time.Now()
}

// Blocked 报告该桶是否已用尽，并顺手清掉窗口外的旧记录。查询本身不收费。
func (l *Limiter) Blocked(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()

	cutoff := l.now().Add(-l.window)
	hits := l.hits[key]
	kept := hits[:0]
	for _, at := range hits {
		if at.After(cutoff) {
			kept = append(kept, at)
		}
	}
	l.hits[key] = kept
	return len(kept) >= l.limit
}

// RecordFailure 记一次失败并计入全局失败总数（/pair/claim 的上限路径）。
func (l *Limiter) RecordFailure(key string) {
	l.CountFailure(key, true)
}

// CountFailure 记一次调用；total=false 表示这次调用已经记在别的桶上，这里只留痕、
// 不重复计入全局总数。
func (l *Limiter) CountFailure(key string, total bool) {
	l.mu.Lock()
	defer l.mu.Unlock()

	l.hits[key] = append(l.hits[key], l.now())
	if total {
		l.total++
	}
}

// Reset 清空一个桶（认领成功，或"设备数到顶"这类与猜测无关的拒绝）。
func (l *Limiter) Reset(key string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.hits, key)
}

// FailuresTotal 是这份预算记过的全部失败数，跨桶累计。
func (l *Limiter) FailuresTotal() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.total
}
