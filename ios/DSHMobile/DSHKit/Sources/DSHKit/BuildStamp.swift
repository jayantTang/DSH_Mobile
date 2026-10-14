import Foundation

/// **App 构建号**的比较（不是连接器/主机版本；那两个走 `HostVersion`）。
///
/// 构建号是 `yyyyMMdd.HHmm` 时间戳，更老的版本是单个 12 位时间戳。两种都按"逐段比数字"排序，
/// 这正是 iOS 自己读 `CFBundleVersion` 的方式。
///
/// ## 为什么单独一个类型，而不是并进 `HostVersion`
///
/// 两者长得像、**语义不同**：
/// * `HostVersion.isOlder(_:than:)` 比的是**连接器报上来的版本**，认不出数字前缀就返回 `false`
///   （宁可不说，也不猜）；
/// * 这里比的是**我们自己发布的构建号**，畸形段按 0 处理，且允许 `1.2` 与 `1.2.0` 等价。
///
/// 2026-10-14 之前这段逻辑同时存在于 App 的 `UpdateChecker` 与 DSHKit 的 `HostVersion`，
/// 是"同一类判断两份实现"的典型；现在构建号比较只有这一份，App 侧只调用。
public enum BuildStamp {

    /// `candidate` 是否比 `current` 新。
    ///
    /// - 空串一律返回 `false`（不知道就不说"有新版本"）；
    /// - 段数不同时缺的段按 0 补齐，所以 `1.2` 与 `1.2.0` 不算更新；
    /// - 非数字段按 0 处理，不抛错（构建号是我们自己发的，畸形也要能比较而不是崩）。
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard !candidate.isEmpty, !current.isEmpty else { return false }
        let lhs = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = current.split(separator: ".").map { Int($0) ?? 0 }
        guard !lhs.isEmpty, !rhs.isEmpty else { return candidate != current }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}
