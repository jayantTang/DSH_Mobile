import CoreGraphics
import Foundation

/// App 注入的探针端口（025 阶段4b）。
///
/// 为什么要有它：聊天单元搬进模块包之后，`ChatModel` 不再认识 App 的调试仪器
/// （`Support/ViewportProbe.swift`）与启动参数开关（`ProbeVariants`）——那两样都是
/// App 的东西。诊断日志、视口几何、故障注入配额与变体开关全部从这里的 static
/// 变量进来，接线在 `DSHMobileApp.init`，与 `HostEventHub.probeNote` /
/// `SessionListModel.probeNote` 是同一个模式。
///
/// 默认值是**产品行为**：不落日志、不注入故障、视口钩子为空（等于探针没打开）。
/// 只有 App 带着 `-DSHViewportProbe` / `-DSHProbe*` 启动并注入之后，行为才与搬迁前
/// 逐字一致。
public enum ChatProbe {

    // MARK: - 诊断日志

    /// 一条诊断行（原 `ViewportProbe.note`）。nil = 探针没接线，调用点静默跳过。
    nonisolated(unsafe) public static var probeNote: ((_ kind: String, _ fields: [String: String], _ force: Bool) -> Void)?

    // MARK: - 视口几何（源在 App 的 `ViewportProbe`）

    /// 转写区里有多少内容（`ViewportProbe.setContent`）。
    nonisolated(unsafe) public static var setContent: ((_ items: Int, _ streaming: Int) -> Void)?
    /// 转写区自己的屏幕矩形（`ViewportProbe.setViewport`）。
    nonisolated(unsafe) public static var setViewport: ((CGRect) -> Void)?
    /// 首帧画完了（`ViewportProbe.markReady`）。
    nonisolated(unsafe) public static var markReady: (() -> Void)?
    /// 起采样计时器（`ViewportProbe.start`）。
    nonisolated(unsafe) public static var start: (() -> Void)?
    /// 转写页离开屏幕 / 回到屏幕（`ViewportProbe.pause` / `.resume`）。
    nonisolated(unsafe) public static var pause: (() -> Void)?
    nonisolated(unsafe) public static var resume: (() -> Void)?
    /// 最近一次滚动几何（偏移 / 内容高，`ViewportProbe.scrollFacts`）。
    nonisolated(unsafe) public static var scrollFacts: (() -> (offset: CGFloat, content: CGFloat)?)?
    /// 视口里最上面那一行的 id（`ViewportProbe.topVisibleRow`）。
    nonisolated(unsafe) public static var topVisibleRow: (() -> String?)?
    /// 落在视口里的行 id（`ViewportProbe.visibleRowIds`）。
    nonisolated(unsafe) public static var visibleRowIds: (() -> [String])?
    /// 一行的屏幕矩形进/出视口（`ViewportProbe.enter/update/leave`）。
    nonisolated(unsafe) public static var enterRow: ((_ id: String, _ rect: CGRect) -> Void)?
    nonisolated(unsafe) public static var updateRow: ((_ id: String, _ rect: CGRect) -> Void)?
    nonisolated(unsafe) public static var leaveRow: ((_ id: String) -> Void)?
    /// 记一次滚动几何（`ViewportProbe.lastScroll = …`）。
    nonisolated(unsafe) public static var setScroll: ((_ offset: CGFloat, _ content: CGFloat) -> Void)?

    // MARK: - 自动化与故障注入开关（源在 App 的 `ProbeVariants`）

    /// `-DSHProbeOlderScroll <n>`：由 App 自己把视口送到顶部 n 次。
    nonisolated(unsafe) public static var olderScrollRounds: Int?
    /// `-DSHProbeOlderNoReclaim`：翻页驱动的"滑回被回收行"绕行关掉。
    nonisolated(unsafe) public static var olderDriveSkipsReclaimed: Bool = false

    /// 转写列表宿主走哪条实现（spec 008）：缺省 `uikit`。
    nonisolated(unsafe) public static var listHost: String = "uikit"
    /// `-DSHProbeListSpike`：转写页换成 spike 屏。
    nonisolated(unsafe) public static var listSpike: Bool = false
    /// `-DSHProbeVariants lazy-stack`：转写换回 `ScrollView + LazyVStack`。
    nonisolated(unsafe) public static var lazyStack: Bool = false
    /// `-DSHProbeVariants no-rows`：不挂"把行矩形报给探针"的 background。
    nonisolated(unsafe) public static var noRowProbe: Bool = false

    /// `-DSHProbeWindowRows <n>`：内存窗口行数上限。
    nonisolated(unsafe) public static var windowRows: Int?
    /// `-DSHProbePayloadBudgetKB <n>`：行载荷预算（KB）。
    nonisolated(unsafe) public static var payloadBudgetKB: Int?
    /// `-DSHProbeFailPage <n>`：前 n 次取页失败。
    nonisolated(unsafe) public static var failPageAttempts: Int = 0
    /// `-DSHProbePageShortfall <n>`：每页少给最新的 n 条记录。
    nonisolated(unsafe) public static var pageShortfall: Int = 0
    /// `-DSHProbeAutoRetryMs <ms>`：失败后那次自动补试的等待时长。
    nonisolated(unsafe) public static var autoRetryMs: Int = 3000
    /// `-DSHProbeNoHistoryWindow`：假装连接器没有精确窗口能力。
    nonisolated(unsafe) public static var noHistoryWindow: Bool = false
    /// `-DSHProbeNoSessionSearch`：把 `session-search` 从能力表里摘掉。
    nonisolated(unsafe) public static var noSessionSearch: Bool = false
    /// `-DSHProbeReclaimScreens <n>` / `-DSHProbeRehydrateScreens <n>`（spec 008 的 FR-009）。
    nonisolated(unsafe) public static var reclaimScreens: Int = 5
    nonisolated(unsafe) public static var rehydrateScreens: Int = 4
    /// `-DSHProbeForceRehydrate`：强制走一次"回收 → 再水合"。
    nonisolated(unsafe) public static var forceRehydrate: Bool = false
    /// 驱动开始（`-DSHProbeOlderScroll` 第一轮）时由宿主报到（`ProbeVariants.noteDriveBegan`）。
    nonisolated(unsafe) public static var noteDriveBegan: (() -> Void)?
}
