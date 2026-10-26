package hub

import (
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/quota"
)

// OperationStats 是进程级的统计卫生指标：它们不进入 usageDaily，只回答
// “去重有没有在工作、有多少帧因为缺键没被计数”。
type OperationStats struct {
	Deduped   uint64 `json:"deduped"`
	Uncounted uint64 `json:"uncounted"`
}

// deviceOperation 是一次设备帧的分类结果。
//
// relevant 表示这是一条我们关心的操作帧；keyed 表示拿到了稳定幂等键。
// 没有键时仍然 relevant，但由调用方记入 uncounted，而不是猜一个键。
type deviceOperation struct {
	op          quota.Op
	fingerprint uint64
	relevant    bool
	keyed       bool
}

// classifyDeviceOperation 把设备帧映射成可计数的操作。
//
// 只认两条稳定口径：
//   - session/prompt 的 args.request.requestId
//   - eventResult 的 result.eventId
//
// 其他方法一律不计数，也不改变转发。方法名只在这一处出现；后续新增统计只改
// 这个函数与 quota 的字段，不需要改 iOS 或连接器。
func classifyDeviceOperation(wire dlp.Wire) deviceOperation {
	switch {
	case wire.Is("eventResult"):
		key := wire.FieldPath("result", "eventId")
		if len(key) == 0 {
			return deviceOperation{op: quota.OpAnswer, relevant: true}
		}
		return deviceOperation{
			op: quota.OpAnswer, fingerprint: fingerprint(key), relevant: true, keyed: true,
		}
	case wire.Is("req"):
		if !wire.FieldEquals("method", "session/prompt") {
			return deviceOperation{}
		}
		key := wire.FieldPath("args", "request", "requestId")
		if len(key) == 0 {
			return deviceOperation{op: quota.OpPrompt, relevant: true}
		}
		return deviceOperation{
			op: quota.OpPrompt, fingerprint: fingerprint(key), relevant: true, keyed: true,
		}
	}
	return deviceOperation{}
}

// fingerprint 是 FNV-1a 64：只用于进程内的最近键表，不做持久化身份。
//
// 每台设备每种操作最多 512 个键，64 位碰撞概率可以忽略；实现成手写循环是为了
// 避免 hash.Hash 接口与 buffer 带来的分配。
func fingerprint(key []byte) uint64 {
	const (
		offset = 14695981039346656037
		prime  = 1099511628211
	)
	value := uint64(offset)
	for _, char := range key {
		value ^= uint64(char)
		value *= prime
	}
	return value
}

// OperationStats 返回统计卫生指标（/stats 的 opStats 段）。
func (h *Hub) OperationStats() OperationStats {
	return OperationStats{
		Deduped:   h.opDeduped.Load(),
		Uncounted: h.opUncounted.Load(),
	}
}
