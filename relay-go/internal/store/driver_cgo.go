//go:build cgo

package store

// 默认（CGO_ENABLED=1）用 cgo 驱动：基准里它在全部读写指标上快 26–91%
// （依据 maintainers/20261023-SQLite驱动基准.md）。
import _ "github.com/mattn/go-sqlite3"

// cgoDriver 标记当前构建用的是 cgo 驱动；测试据此确认默认驱动的选择。
const cgoDriver = true

// driverName 是 database/sql 的驱动名。
const driverName = "sqlite3"
