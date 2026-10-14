import Foundation

/// 消息层的两个取页注入件（spec 023 的 S4-1：随 `MessageLayer` 一起搬进 DSHKit）。
///
/// 它们在产品构建里**恒不生效**（配额默认 0），只有 App 侧通过 `MessageLayer.Probes` 注入配额
/// 与开关时才动作。搬进来的理由：它们要包在 `MessagePipeline` 的取页闭包外层，
/// 而那个闭包现在属于 DSHKit；留在 App 会让数据层反过来依赖 App 的调试仪器。


/// DEBUG 故障注入：让接下来 N 次**往更早方向**的取页回一个空包
/// （`-DSHProbeEmptyPage <n>`，spec 009 追加修订 2「空页即异常」的设备层验证用）。
///
/// 为什么需要注入：本机部署的 `_link/sessionWindow` 不带 roles 过滤时永远不回空包
/// （空包只在整页被 roles 滤空时出现，而那条路径走 `UserInputBackfiller` 自己的
/// fetch，不经 `SessionPipeline`）。所以「空页 → `failed(retryable)` → 点重试」
/// 在设备上本来造不出来，T038 只有单测覆盖。
///
/// 为什么必须分方向：往**更新**方向探空是正常形态（窗口尾部之上暂时没有新内容，
/// `adeb3aa` 的语义），打上去只会把正常路径记成失败，验不到要看的那一条。
/// 判据不另写一份：直接用 `SessionPipeline.isNewerDirectionProbe`（管道判失败用的
/// 就是它），再要求这一页确实落在热窗口之下。热窗口还没建立（冷启动首拉就是最新页）
/// 时也不吃配额——那不是"探"，是首屏。
///
/// 与 `PageFailureInjector` 同一套做法：包在 `MessageLayer` 的取页闭包外层，
/// 产品构建里 `remaining` 恒为 0（release 的 `ProbeVariants` 桩返回 0）。
/// 与那个注入器唯一的不同：方向判据要现读热窗口，所以多一个**弱引用**的管道绑定
/// （`attach` 建好管道之后补绑；取页闭包因此在主线程之外也能问方向，
/// 而不必把 `MessageLayer` 自己捕进闭包）。
final class EmptyPageInjector: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private weak var pipeline: MessagePipeline?

    init(remaining: Int) { self.remaining = remaining }

    /// `MessageLayer.attach` 建好管道之后调用一次。
    func bind(pipeline: MessagePipeline) {
        lock.lock()
        defer { lock.unlock() }
        self.pipeline = pipeline
    }

    /// 某会话热窗口的最新 seq（nil = 还没建管道 / 还没有窗口）。
    func hotNewest(for ref: MessagePipeline.SessionRef) async -> Int? {
        await boundPipeline()?.hotNewest(for: ref)
    }

    /// 同步读一次弱引用（锁只在同步函数里用：NSLock 在 async 上下文里不可用）。
    private func boundPipeline() -> MessagePipeline? {
        lock.lock()
        defer { lock.unlock() }
        return pipeline
    }

    /// 这一次请求要不要伪装成「0 条 + hasMore=true」的空回包。
    ///
    /// - Parameters:
    ///   - page: 这一页的**对齐**区间（管道按页边界请求）。
    ///   - hotNewest: 该会话热窗口的最新 seq，nil = 还没有窗口。
    ///   - priority: 只有用户驱动的取页吃配额。预取瀑布（`.prefetch`）与冷启动
    ///     首拉（`.jump`）不消耗，注入次数才是确定的。
    func shouldEmpty(page: ClosedRange<Int>, hotNewest: Int?,
                     priority: SessionPipeline.FetchPriority) -> Bool {
        guard priority == .userVisible else { return false }
        guard let hotNewest,
              !SessionPipeline.isNewerDirectionProbe(pageLowerBound: page.lowerBound,
                                                     hotNewest: hotNewest),
              page.upperBound < hotNewest
        else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }
}

/// 取页失败注入抛出的错误。
///
/// 公开：App 侧的旧分页路径（`ChatModel.loadOlder`）也用同一套注入，抛的必须是同一个类型，
/// 否则 `catch is PageFailureInjected` 会漏。
public struct PageFailureInjected: Error {
    public init() {}
}
