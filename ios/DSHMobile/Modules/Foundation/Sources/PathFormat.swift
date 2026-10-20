import Foundation

/// Formats an absolute path relative to the host's home directory.
///
/// The desktop client abbreviates paths this way; matching it keeps the two
/// clients readable side by side.
public enum PathFormat {
    /// `home` 前缀替换为 `~`，按**路径分量**比较：
    /// /Users/tester2/x 在 home=/Users/tester 时不得缩成 ~2/x（028 缺陷3）。
    public static func short(_ path: String, home: String?) -> String {
        guard let home, !home.isEmpty else { return path }
        let normalizedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard path == normalizedHome || path.hasPrefix(normalizedHome + "/") else { return path }
        return "~" + path.dropFirst(normalizedHome.count)
    }

    public static func directory(_ path: String, home: String?) -> String {
        (short(path, home: home) as NSString).lastPathComponent
    }
}
