package monitor

// 栈分类：把一串 PC 翻译成"最内层位置 + 最近四帧的可读栈"，
// 异常与 panic 共用一条实现（panicStack 只差一层运行时帧过滤）。

import (
	"fmt"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
)

// classify 返回最内层位置与最近四帧的可读栈；panic 栈额外跳过 runtime.gopanic
// 等运行时帧，让位置落在真正 panic 的地方。
func classify(stack []uintptr, panicStack bool) (string, string) {
	frames := runtime.CallersFrames(stack)
	place := "?"
	framesText := make([]string, 0, 4)
	for {
		frame, more := frames.Next()
		if !ignoredFrame(frame.Function) && !(panicStack && isRuntimeFrame(frame.Function)) {
			if place == "?" {
				place = fmt.Sprintf("%s:%d", filepath.Base(frame.File), frame.Line)
			}
			if len(framesText) < 4 {
				framesText = append(framesText, fmt.Sprintf("%s:%d %s",
					filepath.Base(frame.File), frame.Line, shortFunction(frame.Function)))
			}
		}
		if !more {
			break
		}
	}
	return place, strings.Join(framesText, " ← ")
}

func ignoredFrame(function string) bool {
	return strings.HasPrefix(function, "runtime.") ||
		strings.Contains(function, "/internal/monitor.")
}

func isRuntimeFrame(function string) bool { return strings.HasPrefix(function, "runtime.") }

// shortFunction 砍掉包路径，只留 package.Func（日志可读性）。
func shortFunction(function string) string {
	if index := strings.LastIndex(function, "/"); index >= 0 {
		return function[index+1:]
	}
	return function
}

func categoryKey(typeName, place string) string {
	return "exc:" + typeName + "@" + place
}

// shortType 是错误/panic 值的类型短名（去掉包路径）。
func shortType(value any) string {
	if value == nil {
		return "error"
	}
	name := reflect.TypeOf(value).String()
	if index := strings.LastIndex(name, "/"); index >= 0 {
		name = name[index+1:]
	}
	return name
}

func captureStack(skip int) []uintptr {
	pcs := make([]uintptr, 64)
	count := runtime.Callers(skip, pcs)
	return pcs[:count]
}
