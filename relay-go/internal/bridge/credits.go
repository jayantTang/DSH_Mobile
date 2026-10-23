package bridge

import (
	"context"
	"errors"
	"sync"
)

// ErrCreditsClosed 表示这条连接器链路已经不再接受新的上行额度。
//
// 它只回答"这笔额度永远不会到手"，不回答"已经到手的那部分怎么办"：后者由调用方
// 自己的 defer 归还，队列里已入队的帧由写循环 drainQueue 归还。
var ErrCreditsClosed = errors.New("relay: the connector link is closed")

// Credits 是"一条连接器链路上最多允许多少字节的文件上行帧排队"的有界信号量。
//
// 为什么需要它：`/files/up` 的每一片都是 ClassControl（丢一片就是坏一次上传，不能
// 当流式帧丢掉），所以它绕过了 Link 的队列字节上限；连接器读得慢时，4096 个深度的
// 队列可以堆到 4096 × 1.33 MB。额度把"能堆多少"从"队列深度"改成"字节数"。
//
// 谁能拿、谁负责还：额度在**入队之前**取得，在帧真正写出去（或被丢弃、或随连接关闭
// 清空）之后归还。取得与归还都在同一笔 reservation 上记一次账，不存在"中间某一帧
// 忘了还"的路径：所有权的转移只有 hub 的 Link.EnqueueWithCredit 一处。
//
// 额度是每条连接器链路一份，不是全局一份：字节压在**哪条**队列上，额度就该算在
// 哪条链路上。否则一台电脑的慢连接会把另一台电脑的上传一起卡住。实例仍由链路持有
// （`Link.credits`），这里只拥有它的状态与等待队列（DESIGN §3.4）。
type Credits struct {
	capacity int64

	mu       sync.Mutex
	used     int64
	waiters  []*creditWaiter
	closed   bool
	overFree int64 // 归还次数多于取得次数的累计（只用于用例断言"没有多还"）
}

// creditWaiter 是一笔还没到手的额度。
//
// ready 关闭时二选一：granted 为 true（额度已记在 used 里），或 err 非空（链路关闭）。
// 取消路径（ctx.Done）不关 ready，由 Acquire 自己从队列里摘掉。
type creditWaiter struct {
	need    int64
	granted bool
	err     error
	ready   chan struct{}
}

// NewCredits 建一份额度；capacity 为负时按 0 处理（等于永远只有空预算放行）。
func NewCredits(capacity int64) *Credits {
	if capacity < 0 {
		capacity = 0
	}
	return &Credits{capacity: capacity}
}

// Capacity 是这条链路的上行桥字节上限。
func (c *Credits) Capacity() int64 { return c.capacity }

// InUse 是已经取得、还没归还的额度（/stats 与用例的诊断口）。
func (c *Credits) InUse() int64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.used
}

// Waiting 是正卡在额度上的请求数（诊断口：慢连接器时它会大于 0）。
func (c *Credits) Waiting() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.waiters)
}

// Acquire 取得 n 字节额度；不够时阻塞，直到有人归还、ctx 结束或链路关闭。
//
// 阻塞就是**背压**：调用方（/files/up 的 handler）停在这里就不再读请求体，手机侧
// 的 TCP 窗口随之关闭，数据留在发送端，不丢也不落库。
func (c *Credits) Acquire(ctx context.Context, n int64) error {
	if n <= 0 {
		return nil
	}
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return ErrCreditsClosed
	}
	// 快路径只在"没人排队"时才走：否则后来者会插到先来者前面。
	if len(c.waiters) == 0 && c.fitsLocked(n) {
		c.used += n
		c.mu.Unlock()
		return nil
	}
	waiter := &creditWaiter{need: n, ready: make(chan struct{})}
	c.waiters = append(c.waiters, waiter)
	c.mu.Unlock()

	select {
	case <-waiter.ready:
		if waiter.err != nil {
			return waiter.err
		}
		return nil
	case <-ctx.Done():
	}

	c.mu.Lock()
	if waiter.granted {
		// 授权与取消撞在一起：额度已经记在我们头上，必须原样还回去，
		// 否则这一次取消就漏掉了 n 字节。
		c.freeLocked(waiter.need)
		c.mu.Unlock()
		return ctx.Err()
	}
	for index, queued := range c.waiters {
		if queued == waiter {
			c.waiters = append(c.waiters[:index], c.waiters[index+1:]...)
			break
		}
	}
	c.mu.Unlock()
	return ctx.Err()
}

// Release 归还 n 字节额度；按排队顺序唤醒能放下的等待者。
func (c *Credits) Release(n int64) {
	if n <= 0 {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.freeLocked(n)
}

// freeLocked 记一次归还并补发额度；调用方必须持有 mu。
func (c *Credits) freeLocked(n int64) {
	if c.used < n {
		// 只可能是调用方重复归还（一个额度还了两次）。夹到 0 避免把后续账目
		// 弄成负数，同时留一个可断言的计数——用例会要求它恒为 0。
		c.overFree++
		c.used = 0
	} else {
		c.used -= n
	}
	c.pumpLocked()
}

// fitsLocked 判断一笔 n 字节的额度现在能不能发；调用方必须持有 mu。
//
// 比总容量还大的一笔额度只在"当前一分钱都没花"时放行：否则它永远等不到
// （队列里同类的分片都是 1 MiB，正常不会走到这里，但配置得很小必须不死锁）。
func (c *Credits) fitsLocked(n int64) bool {
	if n > c.capacity {
		return c.used == 0
	}
	return c.used+n <= c.capacity
}

// pumpLocked 按先进先出补发额度；头一个放不下就停（不做插队）。
func (c *Credits) pumpLocked() {
	for len(c.waiters) > 0 {
		next := c.waiters[0]
		if !c.fitsLocked(next.need) {
			return
		}
		c.waiters = c.waiters[1:]
		c.used += next.need
		next.granted = true
		close(next.ready)
	}
}

// Close 结束这条链路的额度：之后的 Acquire 立刻失败，正在等的那批也立刻失败。
//
// 已经占用的额度不在这里清零——它们压在队列里，由写循环退出时的 drainQueue 逐帧
// 归还；这里只负责让"还在等额度"的请求不再无限期挂着（连接器被顶替时就是这条路径）。
func (c *Credits) Close() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return
	}
	c.closed = true
	waiting := c.waiters
	c.waiters = nil
	for _, waiter := range waiting {
		waiter.err = ErrCreditsClosed
		close(waiter.ready)
	}
}

// overReleased 是"多还了"的累计次数（用例断言它必须为 0）。
func (c *Credits) overReleased() int64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.overFree
}
