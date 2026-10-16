#if os(iOS)
#if DEBUG
import DSHChatDomain
import Foundation

/// 量具（DEBUG-only）：一屏**实际交给渲染器的**转写行，是不是它自己那个会话的。
///
/// 为什么要专门立一件量具：新建/切换会话时"先画上一个会话、再变成空会话"这一闪，
/// 在现有四层口径下都看不见——用例的断言只覆盖稳定态（`want` 是轮询到成立）、
/// 截图在拍之前会先等画面静止（ENGINE 的 `waitUntilStill`）、
/// `ViewportProbe` 量的是"白不白"而不是"画出来的行属不属于这一屏"、
/// 单测则全程 `await open()` 到底且没有能停在中间的注入点。
///
/// 所以这里补的是**仪器**，不是修复：它挂在"把行交给渲染器"这一步上，
/// 因此修复前会响（这一支会把上一个会话的行交出去）、修复后不会响
/// （那一支只画占位，走不到这里）。同一次判定既能判红也能判绿，不需要两套。
///
/// 判定侧有三处，缺一不可：
///   * 本文件写 `switch.stale-render` 探针行（`ChatProbe.shared.probeNote`）；
///   * App 侧收到这一行时顺手存一张整屏现场图（`ViewportProbe.captureForAnomaly`）；
///   * `test/tools/run.mjs` 的 `probeVerdicts` 据此判该轮 fail，用例判据里写明
///     "本轮不得出现 `switch.stale-render`"。
@MainActor
enum StaleRenderWatch {

    /// 本进程命中了几次。
    ///
    /// 只用于报告里的一句话（"这一轮错了 N 次"）：判定看的是"有没有"，不是次数——
    /// 一次就足以说明这一屏画过别人的内容。
    private(set) static var hits = 0

    /// 这一屏要把 `rows` 条行交出去了，它们属于 `owner`。
    ///
    /// - Parameters:
    ///   - screen: 这一屏声称自己在显示哪个会话（`ChatView.sessionId`）。
    ///   - owner: 这批行真正属于谁（`ChatModel.rowsOwnerId`）。
    ///   - rows: 要交出去的行数。
    ///
    /// `rows == 0` 不算：空屏、占位、加载中都是合法画面，没有"别人的内容"可看。
    /// `owner == nil` 不算：还没打开过任何会话（冷启动首屏）。
    static func handed(screen: String, owner: String?, rows: Int) {
        guard rows > 0, let owner, owner != screen else { return }
        hits += 1
        ChatProbe.shared.probeNote?("switch.stale-render", [
            "screen": screen,
            "owner": owner,
            "rows": String(rows),
            "hit": String(hits),
        ], true)
    }
}
#endif
#endif
