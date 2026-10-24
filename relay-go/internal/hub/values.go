package hub

// 小型取值助手：日志字段与"空串/指针"之间的转换。
//
// optionalString 只有一份，在 internal/quota（OptionalString）：hub 依赖 quota，
// 共享的 helper 只能放在下游，反过来会成环。

// stringValue 取 *string 的内容；nil 时为空串。
func stringValue(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}

// statusValue 取 *int 的内容（日志字段用；nil 时是 nil）。
func statusValue(value *int) any {
	if value == nil {
		return nil
	}
	return *value
}
