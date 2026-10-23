package store

import (
	"fmt"
	"strings"
)

// StoreError 是仓储层错误的基础类型，对应 Python store.py 的 StoreError。
type StoreError struct {
	Message string
}

func (e *StoreError) Error() string { return e.Message }

// domainError 是"这是一次业务结果，不是数据库故障"的标记。
//
// NotFound / Conflict / InviteRejected 等类型都嵌入 StoreError，方法被提升，
// 所以日志层用一次接口断言就能把"配对码已被占用"与"database is locked"分开，
// 不必枚举每个业务错误类型。
func (*StoreError) domainError() {}

// NotFound 表示请求的行不存在、已被禁用或已过期（Python 的 store.NotFound）。
type NotFound struct {
	StoreError
}

// Conflict 表示写入违反唯一性约束（Python 的 store.Conflict）。
type Conflict struct {
	StoreError
}

// InviteRejected 表示邀请码不可兑换，Reason 是 unknown / used / expired。
type InviteRejected struct {
	Reason string
	StoreError
}

// PairCodeClaimRejected 表示配对码认领失败，Reason 是 unknown / revoked / expired。
//
// Details 只用于日志诊断（命中的那一行的时间戳与归属），不属于接口契约。
type PairCodeClaimRejected struct {
	Reason  string
	Details map[string]any
	StoreError
}

// RateLimited 表示某个桶的失败预算已用尽；这次请求既没有读行、也不该再记一次失败。
type RateLimited struct {
	StoreError
}

// PairedDeviceLimitReached 表示一个账户未撤销的设备数已达上限。
type PairedDeviceLimitReached struct {
	Limit int
	Live  int
	StoreError
}

func newStoreError(format string, args ...any) *StoreError {
	return &StoreError{Message: fmt.Sprintf(format, args...)}
}

func newNotFound(format string, args ...any) *NotFound {
	return &NotFound{StoreError{Message: fmt.Sprintf(format, args...)}}
}

func newConflict(format string, args ...any) *Conflict {
	return &Conflict{StoreError{Message: fmt.Sprintf(format, args...)}}
}

// IsBusy 报告错误是否来自 SQLite 的写锁竞争（busy / locked）。
//
// 两个驱动给出的错误类型不同（mattn 是 sqlite3.Error、modernc 是自己的错误类型），
// 统一按错误文本判定：这是 database/sql 之上唯一跨驱动稳定的信息，也是 DESIGN §6
// 要求映射成 503 的那一类。
func IsBusy(err error) bool {
	if err == nil {
		return false
	}
	message := strings.ToLower(err.Error())
	return strings.Contains(message, "database is locked") ||
		strings.Contains(message, "database table is locked") ||
		strings.Contains(message, "sqlite_busy")
}
