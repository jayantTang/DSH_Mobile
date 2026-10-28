import DSHFoundation
import DSHKit
import Foundation

/// 占位行的「点击重试」与它的时间上限（设计 `20261027-折叠抖动-方案A.md` M5'-5）。
///
/// 从阶段一的子集实现整体替换而来。旧实现只有两条结论：播种得到已知边界（行消失），
/// 或仍是 `.unresolved`——既不会走到 `.failed(...)`，也没有上限（一旦某一步不返回，
/// 占位行就永远停在"正在确认…"）。现在四条路按证据强弱逐级下降，且**任何分支都不许
/// 停在 `.resolving`**：`timeout` 到点就是 `.failed(.timeout)`。
extension ChatModel {

    /// 重试的终态与结局（探针要同时看到这两个词）。
    struct TailRetryResult: Sendable {
        let state: TimelineProcessPlaceholder.State
        let outcome: BackfillOutcome
    }

    /// 占位行的「点击重试」唯一入口。
    ///
    /// 顺序固定，拿到证据就停：① 本地补读 → ② 宿主摘要 + 播种 → ③ 概要页（复用既有通路，
    /// 不新增网络路径）→ ④ 终态。
    ///
    /// - Parameter timeout: 整段上限（默认 5 s）。参数只为可测。
    public func retryTailBoundary(timeout: Duration = .seconds(5)) async {
        guard tailBoundaryAttempt != .resolving else { return }
        tailBoundaryAttempt = .resolving
        let latch = TailRetryLatch()
        // 工作与计时各报一次，只认第一次；调用方只等这个闩。
        // 不用 `withTaskGroup`：它的作用域退出要等全部子任务，超时那一路会把上限原样
        // 等回来（实测一个 30 s 的挂起让"5 s 上限"变成 30 s），上限等于不存在。
        let work = Task { @MainActor [weak self] in
            let result = await self?.resolveTailBoundary()
            latch.settle(result)
        }
        let timer = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            latch.settle(nil)
        }
        let raced = await latch.wait()
        work.cancel()
        timer.cancel()
        let result = raced ?? TailRetryResult(state: .failed(.timeout), outcome: .failed("timeout"))
        tailBoundaryAttempt = result.state
        TailTrace.noteRetry(session: session?.sessionId ?? "",
                            state: TailTrace.placeholderStateName(result.state),
                            outcome: Self.backfillName(result.outcome))
    }

    /// 重试的实际动作（不含状态写与上限）：返回终态与结局。
    func resolveTailBoundary() async -> TailRetryResult {
        #if DEBUG
        // 测试挂起点（DEBUG-only，生产恒为 nil）：让"超时"这条分支能被真实跑到。
        if let tailRetryHold { await tailRetryHold() }
        #endif
        guard let summary = session else {
            return TailRetryResult(state: .unresolved, outcome: .earliest)
        }
        let sessionId = summary.sessionId
        var prefix: [SessionRecord] = []
        var outcome: BackfillOutcome = .earliest
        // ① 本地补读：与首帧同一段实现（`loadStoredTail` + `alignTail`），不复制第二套读法。
        if let scope = sessionScope,
           let stored = await loadStoredTail(scope: scope, sessionId: sessionId) {
            let aligned = await alignTail(stored, scope: scope, sessionId: sessionId)
            prefix = aligned.prefix
            outcome = aligned.outcome
            if let boundary = Self.tailBoundary(in: aligned.prefix + stored.records) {
                timeline.seedTail(boundary)
            }
        }
        if !timeline.tail.boundary.isUnknown {
            await absorbTailPrefix(prefix)
            return TailRetryResult(state: .unresolved, outcome: outcome)
        }
        // ② 宿主摘要（列表级事实，第二强证据）。
        await refreshSummary()
        if let fresh = session {
            let seed = await seedBoundary(for: fresh,
                                          cached: transcriptCache.entry(for: sessionId))
            if !seed.isUnknown {
                timeline.seedTail(seed)
                await absorbTailPrefix(prefix)
                return TailRetryResult(state: .unresolved, outcome: outcome)
            }
        }
        // ③ v2 能力在时复用概要页通路（不新增网络路径）。
        if store?.chatHost?.historySummaryFoldEnabled == true {
            await retrySummaryScreen()
            if !timeline.tail.boundary.isUnknown {
                await absorbTailPrefix(prefix)
                return TailRetryResult(state: .unresolved, outcome: outcome)
            }
        }
        // ④ 终态：边界仍未确认 → 按补读结局落一个可见且可再试的状态。
        return TailRetryResult(state: Self.placeholderState(for: outcome), outcome: outcome)
    }

    /// 补回来的前缀必须进管道：`reset` 已画好首屏，管道的下一次 refold 也要含它。
    /// （首帧与重试共用这一条，别再造第二个 absorb 调用点。）
    func absorbTailPrefix(_ prefix: [SessionRecord]) async {
        guard !prefix.isEmpty, let bridge = pipelineBridge else { return }
        // 桥的会话把手是异步取的：先落实它，否则 `absorb` 会把这段静默丢掉。
        await bridge.prepareSession()
        await bridge.absorb(records: prefix)
    }
}

/// "谁先到用谁"的闩：工作与计时各报一次，只认第一次。
///
/// 为什么不用 `withTaskGroup` / `async let`：两者的作用域退出都会等**全部**子任务，
/// 挂在网络上的那一路会把上限拖长（那就等于没有上限）。这个闩只让调用方等一个续体，
/// 输的那一路被 cancel 掉、不再有人等它。
final class TailRetryLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private var result: ChatModel.TailRetryResult?
    private var waiter: CheckedContinuation<ChatModel.TailRetryResult?, Never>?

    /// 报一次结果。`nil` = 超时（工作没能在上限内给出答案）。
    func settle(_ value: ChatModel.TailRetryResult?) {
        lock.lock()
        guard !settled else { lock.unlock(); return }
        settled = true
        result = value
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: value)
    }

    func wait() async -> ChatModel.TailRetryResult? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if settled {
                let value = result
                lock.unlock()
                continuation.resume(returning: value)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}
