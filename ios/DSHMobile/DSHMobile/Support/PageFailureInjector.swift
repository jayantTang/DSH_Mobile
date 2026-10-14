import Foundation

/// DEBUG 故障注入：让前 N 次取页失败（`-DSHProbeFailPage <n>`，用例 48 /
/// 慢闸场景③「断网缺口失败重试」用）。
///
/// 产品构建里 `remaining` 恒为 0（release 的 `ProbeVariants` 桩返回 0），
/// 类本体不放在 `#if DEBUG` 里是因为两个调用点都不是 DEBUG-only 代码：
/// 旧 pager 路径（`ChatModel.loadOlder` 非管道分支）与 009 链路
/// （`MessageLayer.attach` 的 fetchFactory，包装在 PageFetch 闭包外层）。
final class PageFailureInjector: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int

    init(remaining: Int) { self.remaining = remaining }

    func shouldFail() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }
}

// `PageFailureInjected` 已随 `MessageLayer` 搬进 DSHKit（Runtime/ProbeInjectors.swift）：
// 两处注入抛的必须是同一个类型，否则 `catch is PageFailureInjected` 会漏。
