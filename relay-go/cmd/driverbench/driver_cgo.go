//go:build cgo

package main

// 只有 CGO_ENABLED=1 的构建才编进 cgo 驱动，纯 Go 构建（CGO_ENABLED=0）不含它。
import _ "github.com/mattn/go-sqlite3"

const cgoAvailable = true
