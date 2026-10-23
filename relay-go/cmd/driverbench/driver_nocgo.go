//go:build !cgo

package main

// CGO_ENABLED=0 时 mattn/go-sqlite3 没有可编译的 Go 文件，不能 import。
const cgoAvailable = false
