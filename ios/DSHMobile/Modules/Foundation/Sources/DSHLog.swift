import Foundation

/// The app's own log lines.
///
/// A tiny wrapper rather than `print` scattered at the call sites: push
/// registration and the file-send path are flows whose failures are *silent*
/// (no token, no banner, no error shown to anyone), so every step says what it
/// saw, and one filter turns the whole story up.
///
/// 025 阶段4b：从 App 的 `Support/APNSRegistrar.swift` 搬进 DSHFoundation——
/// 聊天单元（模块层）的文件发送失败也要写这一行，而模块不认识 App 的文件。
public enum DSHLog {
    /// 结构化事件的出口。只有 OTA 诊断构建会在启动时接上（`AppDiagnostics`）；
    /// TestFlight / App Store 里保持 nil，于是 `event` 只做一次判空，零成本、零输出。
    ///
    /// 只在启动时赋值一次、之后只读，所以不加锁：事件本身是低频的状态变化，
    /// 不是逐帧的东西，加锁的排队开销比事件本身还大。
    public nonisolated(unsafe) static var sink: (@Sendable (String) -> Void)?

    public static func push(_ message: String) {
        NSLog("[DSHMobile/push] %@", message)
    }

    /// 把一条事件压成一行：`kind k=v k=v`，键排序、值去空白并截断。
    /// 纯函数，单测直接断言格式；解析侧按空格切、按第一个 `=` 分键值即可。
    public static func format(_ kind: String, _ fields: [String: String]) -> String {
        var line = kind
        for key in fields.keys.sorted() {
            line += " \(key)=\(sanitize(fields[key] ?? ""))"
        }
        return line
    }

    /// 发一条结构化事件；没有 sink 时什么也不做。
    public static func event(_ kind: String, _ fields: [String: String] = [:]) {
        guard let sink else { return }
        sink(format(kind, fields))
    }

    private static func sanitize(_ value: String) -> String {
        let flattened = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let single = flattened.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: "_")
        return single.count > 120 ? String(single.prefix(120)) + "…" : single
    }
}
