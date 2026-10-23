// Package quota 拥有中转的三份计数状态（DESIGN-20261023 §2.3）：
//
//   - Ledger：每台设备当天的出口额度（deviceDailyBytes）；
//   - Usage：还没落盘的用量增量与冲盘（周期、字节阈值、断开、跨日、关停）；
//   - Bucket：每台设备的每秒出口令牌桶（deviceBytesPerSecond）。
//
// 它不 import hub/wsapi/files/httpapi，也不认识连接、帧与协议：账本只按 deviceId
// 记，令牌桶只认字节。额度是入队时点的准入数，用量是写出后的送达数——两个计数器
// 语义不同，不合并（DESIGN §4.8）。仓储只经 Sink 的 3 个方法。
package quota

import (
	"math"
	"sync"
	"time"
)

// Bucket 是一台设备的每秒字节额度（Python hub.TokenBucket）。
//
// 中转跑在固定带宽的机器上，那份带宽由所有设备共享。一台设备传几张截图（十张就
// 27 MB）就会把整条通道占满几十秒，别人全都变慢。这不是恶意行为，所以做法是限速
// 而不是封禁：桶一开始是满的，并有至少 64 KiB 的突发额度，普通一轮对话完全不会等。
//
// 限速发生在**写循环**里，不是丢弃：帧照常到达，只是摊开在时间上。若在入队时收费，
// 慢下来就会变成队列被填满、进而被判"背压"断开（4008）——那是完全不同的坏消息。
//
// 一个桶会被两条写路径同时使用：WebSocket 写循环与 /files/down 的 HTTP 正文。
// Python 版只有一个事件循环，所以它的 TokenBucket 不需要锁；Go 版必须加，
// 否则一次下载与一条正在转发的连接会在 tokens/updated 上竞争。
type Bucket struct {
	mu      sync.Mutex
	rate    float64
	burst   float64
	tokens  float64
	updated time.Time
}

// NewBucket 建一个满桶；rate<=0 表示不限速。
func NewBucket(rate float64, now time.Time) *Bucket {
	bucket := &Bucket{rate: math.Max(0, rate), updated: now}
	bucket.burst = math.Max(bucket.rate, 64*1024)
	bucket.tokens = bucket.burst
	return bucket
}

// Take 为 n 字节计费，返回发送前应等待的时长。
//
// 正数表示已超额；无论是否超额都立即记账，保证一串小帧按写入顺序排队。
func (b *Bucket) Take(size int, now time.Time) time.Duration {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.rate <= 0 {
		return 0
	}
	if now.After(b.updated) {
		b.tokens = math.Min(b.burst, b.tokens+now.Sub(b.updated).Seconds()*b.rate)
		b.updated = now
	}
	b.tokens -= float64(size)
	if b.tokens >= 0 {
		return 0
	}
	return time.Duration(-b.tokens / b.rate * float64(time.Second))
}
