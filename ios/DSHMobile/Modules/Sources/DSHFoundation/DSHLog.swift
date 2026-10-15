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
    public static func push(_ message: String) {
        NSLog("[DSHMobile/push] %@", message)
    }
}
