package httpapi

import (
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/ratelimit"
)

// ClaimLimiter 是配对 / 登记 / 内部端点共用的按桶计数预算。
//
// 实现已经搬进 internal/ratelimit：反馈四端点（internal/feedback）用的是同一套
// 计数规则，而它不能 import 本包（本包要 import 它，会成环）。这里保留类型与构造
// 函数的别名，M1 的调用点与单测不用改写法，规则仍只有一份。
type ClaimLimiter = ratelimit.Limiter

// NewClaimLimiter 建一个 limit 次 / window 窗口的预算。
func NewClaimLimiter(limit int, window time.Duration) *ClaimLimiter {
	return ratelimit.New(limit, window)
}

// 两个用途共用它：
//   - /pair/claim 以来源地址为键，桶**会拒绝**请求；
//   - /agents/enroll 同时记两个桶——码哈希（闸门，会拒绝）与来源地址（只记账、
//     永不否决合法邀请码，见 owner 2026-09-25 的决定）。
//
// "客户端是什么"由 ClientIdentifier 决定，不在这里。
