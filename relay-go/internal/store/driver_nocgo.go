//go:build !cgo

package store

// 没有 cgo 时退回纯 Go 驱动：静态构建、交叉编译都能用，schema 与 SQL 完全相同，
// 只是基准里慢一些（见 maintainers/BENCH-20261023-sqlite-driver.md）。
import _ "modernc.org/sqlite"

// cgoDriver 标记当前构建用的是 cgo 驱动；测试据此确认默认驱动的选择。
const cgoDriver = false

// driverName 是 database/sql 的驱动名。
const driverName = "sqlite"
