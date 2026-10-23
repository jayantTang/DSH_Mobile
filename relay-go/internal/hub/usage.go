package hub

import (
	"context"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/quota"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// errNoStore 表示没有配库（只在测试与 health-only 装配里可能发生）。
//
// 它是 quota.ErrNoStore 的别名：步骤 2 之后"有没有库"由 quota 的 Sink 判定，
// 但 hub 对外的错误身份与文案不变（DESIGN §3.3 行为不变）。
var errNoStore = quota.ErrNoStore

// Today 是 /stats 的 today 段：库里已经冲下去的 + 内存里还没冲的。
//
// 放在 quota 而不是让 handler 直接查库，是因为最近 30 秒的字节还在内存里；
// 两边合起来才是"此刻为止"。hub 只保留门面（DESIGN §2.6）。
func (h *Hub) Today(ctx context.Context) (store.TodayUsage, error) {
	return h.usage.Today(ctx)
}

// FlushUsage 把内存里攒的用量写进 usageDaily。
//
// 调用时机：周期、累计超过 usage_flush_bytes、设备断开、跨日、进程收尾。写失败时
// 把这批放回内存等下次——账不能因为一次写库异常就丢了（Python flush_usage 的口径）。
//
// 返回错误只供调用方决定是否立刻重试；失败已经被记进日志，并且这批数据仍在账本里。
// 它仍是**同步**调用：断开路径等它写完（有时限），不改成异步（DESIGN §3.3）。
func (h *Hub) FlushUsage(ctx context.Context) error {
	return h.usage.Flush(ctx)
}
