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
/// 探针汇聚点：App 在启动时装配一次，此后只读。
/// `@unchecked Sendable`：属性在并发读之前完成写入（DSHMobileApp.init），此后不可变；
/// 探针是诊断工具，不做同步开销。
public final class ChatProbe: @unchecked Sendable {

    /// 全局汇聚点。未装配时全部 no-op（等于探针没打开），是产品行为。
    public static let shared = ChatProbe()

    public init() {}

    // MARK: - 诊断日志

    /// 一条诊断行（原 `ViewportProbe.note`）。nil = 探针没接线，调用点静默跳过。
    public var probeNote: ((_ kind: String, _ fields: [String: String], _ force: Bool) -> Void)?

    // MARK: - 视口几何（源在 App 的 `ViewportProbe`）

    /// 转写区里有多少内容（`ViewportProbe.setContent`）。
    public var setContent: ((_ items: Int, _ streaming: Int) -> Void)?
    /// 转写区自己的屏幕矩形（`ViewportProbe.setViewport`）。
    public var setViewport: ((CGRect) -> Void)?
    /// 首帧画完了（`ViewportProbe.markReady`）。
    public var markReady: (() -> Void)?
    /// 起采样计时器（`ViewportProbe.start`）。
    public var start: (() -> Void)?
    /// 转写页离开屏幕 / 回到屏幕（`ViewportProbe.pause` / `.resume`）。
    public var pause: (() -> Void)?
    public var resume: (() -> Void)?
    /// 最近一次滚动几何（偏移 / 内容高，`ViewportProbe.scrollFacts`）。
    public var scrollFacts: (() -> (offset: CGFloat, content: CGFloat)?)?
    /// 视口里最上面那一行的 id（`ViewportProbe.topVisibleRow`）。
    public var topVisibleRow: (() -> String?)?
    /// 落在视口里的行 id（`ViewportProbe.visibleRowIds`）。
    public var visibleRowIds: (() -> [String])?
    /// 一行的屏幕矩形进/出视口（`ViewportProbe.enter/update/leave`）。
    public var enterRow: ((_ id: String, _ rect: CGRect) -> Void)?
    public var updateRow: ((_ id: String, _ rect: CGRect) -> Void)?
    public var leaveRow: ((_ id: String) -> Void)?
    /// 记一次滚动几何（`ViewportProbe.lastScroll = …`）。
    public var setScroll: ((_ offset: CGFloat, _ content: CGFloat) -> Void)?

    // MARK: - 自动化与故障注入开关（源在 App 的 `ProbeVariants`）

    /// `-DSHProbeOlderScroll <n>`：由 App 自己把视口送到顶部 n 次。
    public var olderScrollRounds: Int?
    /// `-DSHProbeOlderNoReclaim`：翻页驱动的"滑回被回收行"绕行关掉。
    public var olderDriveSkipsReclaimed: Bool = false

    /// 转写列表宿主走哪条实现（spec 008）：缺省 `uikit`。
    public var listHost: String = "uikit"
    /// `-DSHProbeListSpike`：转写页换成 spike 屏。
    public var listSpike: Bool = false
    /// `-DSHProbeVariants lazy-stack`：转写换回 `ScrollView + LazyVStack`。
    public var lazyStack: Bool = false
    /// `-DSHProbeVariants no-rows`：不挂"把行矩形报给探针"的 background。
    public var noRowProbe: Bool = false

    /// `-DSHProbeWindowRows <n>`：内存窗口行数上限。
    public var windowRows: Int?
    /// `-DSHProbePayloadBudgetKB <n>`：行载荷预算（KB）。
    public var payloadBudgetKB: Int?
    /// `-DSHProbeFailPage <n>`：前 n 次取页失败。
    public var failPageAttempts: Int = 0
    /// `-DSHProbePageShortfall <n>`：每页少给最新的 n 条记录。
    public var pageShortfall: Int = 0
    /// `-DSHProbeAutoRetryMs <ms>`：失败后那次自动补试的等待时长。
    public var autoRetryMs: Int = 3000
    /// `-DSHProbeNoHistoryWindow`：假装连接器没有精确窗口能力。
    public var noHistoryWindow: Bool = false
    /// `-DSHProbeNoSessionSearch`：把 `session-search` 从能力表里摘掉。
    public var noSessionSearch: Bool = false
    /// `-DSHProbeReclaimScreens <n>` / `-DSHProbeRehydrateScreens <n>`（spec 008 的 FR-009）。
    public var reclaimScreens: Int = 5
    public var rehydrateScreens: Int = 4
    /// `-DSHProbeForceRehydrate`：强制走一次"回收 → 再水合"。
    public var forceRehydrate: Bool = false
    /// `-DSHProbeStaleFollowFrame`（032）：打开会话后注入一帧"上一个会话迟到的帧"，
    /// 用来验证"跨会话的帧不落地"这条守卫（注入走同一条判断）。
    public var staleFollowFrame: Bool = false
    /// `-DSHProbeStaleSend`：把最后一条用户消息标成「已发送，未确认」，用来截图核对
    /// 徽标换掉了"等待开始"（真实触发要宿主撤单，见 MessagePipeline.markUnconfirmed）。
    public var staleSendState: Bool = false
    /// 驱动开始（`-DSHProbeOlderScroll` 第一轮）时由宿主报到（`ProbeVariants.noteDriveBegan`）。
    public var noteDriveBegan: (() -> Void)?
}
