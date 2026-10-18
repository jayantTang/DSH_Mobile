#if os(iOS)
import DSHKit
import SwiftUI
import UIKit
import DSHChatDomain
import DSHFoundation

/// 转写列表的新宿主（spec 008）。
///
/// 与 007 的 SwiftUI `List` 的关键差别：**插入/丢弃与 `contentOffset` 修正发生在同一次
/// 更新里**——先把新行插进 diffable 快照并 `layoutIfNeeded()`，量出锚点行在内容坐标里的
/// 位移，再把同样多的位移加到 `contentOffset` 上。全程**不做"滚到某一行"**：那正是 007
/// 崩溃的来源（`_validateScrollingTargetIndexPath`：更新与滚动是两次独立动作，中间那一瞬
/// 目标行可能已经不存在）。
///
/// 行视图继续用现有的 SwiftUI 行视图（`UIHostingConfiguration` 包一层），所以视觉按 spec
/// 的"等价"验收，不做逐像素对齐。
/// SwiftUI ↔ 宿主之间的桥（spec 008 的 US1）。
///
/// `items` 每次变化都做一次差集：**往上插了一页**就 `prepend`（原子修正位移），
/// 其它情况（换窗口/跳转/裁剪）就整批 `setRows` 并锚回指定行。
struct TranscriptListRepresentable: UIViewRepresentable {

    let items: [TimelineItem]
    /// 行视图：由 `ChatView` 传进来（直接用它自己的 `row(_:)`，两条宿主共用同一套行）。
    let makeRow: (TimelineItem) -> AnyView
    /// 钉到底部（打开会话与内容变化时）。
    let pinToBottom: Bool
    /// 探针出口。
    let onDiagnostic: (String, [String: String]) -> Void
    /// 诊断用：宿主是否还有更早的历史、是否正在取页。
    /// 只读，不参与渲染；缺了这个，顶部状态只能靠"首行是不是缺口行"猜，会误报。
    var canLoadOlder: () -> Bool = { false }
    var isLoadingOlder: () -> Bool = { false }
    /// 读者滑到顶部附近：调用方负责取页（`ChatModel.loadOlder`）。
    let onNearTop: () -> Void
    /// 滚动几何回调（007 的 `older.sentinel` 等价）。
    let onScroll: (CGFloat) -> Void
    /// 跟随尾部时按预算丢最老端（入参是"屏幕大约能放几行"，返回要删除的
    /// **显示行 id**；空 = 不丢）。折叠后原始行数 ≠ 显示行数，不能再返回行数。
    /// 传屏高进去是为了让保留带至少覆盖一两屏——否则丢弃会把内容压到比一屏还短
    /// （run 20261008-230106 的现象：窗口只剩 20 行、视口滚不动、连补页都不再触发）。
    let onBudgetCheck: (Int) -> [String]
    /// `-DSHProbeOlderScroll` 的 uikit 驱动轮数（0 = 不驱动）。
    let driveRounds: Int
    /// 驱动开始前调用：真实手指上滑会把"跟随中"关掉，驱动必须做同样的事，
    /// 否则"回到底部"按钮永远不会出现（2026-10-08 实测：探针里 `following=1`、按钮不可见）。
    let onDriveBegin: () -> Void
    /// 该回收这些行（宿主判定，调用方执行）。
    let onReclaim: ([String]) -> Void
    /// 这些 seq 需要内容（调用方从本地库读回来后调用 `coordinator.rehydrate(items:)`）。
    let onNeedRehydrate: ([Int]) -> Void
    /// 读者是否贴在最新那一头（唯一可靠的"跟随"依据）。
    let onBottomChanged: (Bool) -> Void
    /// 009 跟底两态的几何输入（tasks T017）：距底距离 + 向上拖动中。
    var onFollowGeometry: (CGFloat, Bool) -> Void = { _, _ in }
    /// 跳转目标行（spec 008 的 US2）：换窗口之后由宿主滚过去，**不经过 SwiftUI 的 ScrollViewProxy**。
    let jumpToId: String?
    /// 把宿主实例交回给 `ChatView`（回收/水合要用它把行交回来）。
    let hostRef: Binding<TranscriptListHost?>
    /// 长按了某一行（行 id）。宿主只负责"谁被长按了"，弹什么由 SwiftUI 决定。
    ///
    /// 为什么手势在宿主里：`UIHostingConfiguration` 里的 SwiftUI `onLongPressGesture`
    /// **收不到长按**（2026-10-12 用唯一串实测：按满 1 秒回调也不跑）；而系统
    /// `contextMenu` 在这个宿主里的预览/背板几何是错的（抬起来的整行压住导航栏、遮罩只盖一半）。
    let onRowAsk: (String) -> Void
    /// 009 数据源（MessagePipeline 快照）模式：每次 `items` 变化都是一次多段
    /// 混合变更，必须作为**一次原子更新**提交（统一锚位移修正，tasks T015），
    /// 不再走「prepend / setRows 二选一」的启发式（那会拆成两次提交或误锚尾部）。
    var atomicApply: Bool = false

    func makeUIView(context: Context) -> TranscriptListHost {
        let host = TranscriptListHost()
        context.coordinator.onBudgetCheck = onBudgetCheck
        host.makeRow = makeRow
        host.onDiagnostic = onDiagnostic
        #if DEBUG
        host.canLoadOlder = canLoadOlder
        host.isLoadingOlderProvider = isLoadingOlder
        #endif
        host.onScroll = onScroll
        host.onBottomChanged = onBottomChanged
        host.onFollowGeometry = onFollowGeometry
        host.onNearTop = { [weak coordinator = context.coordinator] in
            coordinator?.requestOlder()
        }
        host.apply(.setRows(items, anchorId: items.last?.id))
        context.coordinator.known = Set(items.map(\.id))
        context.coordinator.host = host
        context.coordinator.onNearTop = onNearTop
        context.coordinator.onDiagnostic = onDiagnostic
        host.onRowAsk = onRowAsk
        host.onReclaim = onReclaim
        host.onNeedRehydrate = { [weak coordinator = context.coordinator] seqs in
            coordinator?.onNeedRehydrate?(seqs)
        }
        context.coordinator.onNeedRehydrate = onNeedRehydrate
        context.coordinator.onDriveBegin = onDriveBegin
        context.coordinator.startDriveIfNeeded(rounds: driveRounds)
        context.coordinator.maybeForceRehydrate(host: host)
        hostRef.wrappedValue = host
        return host
    }

    func updateUIView(_ host: TranscriptListHost, context: Context) {
        let known = context.coordinator.known
        let incoming = items.filter { !known.contains($0.id) }
        let removed = known.subtracting(items.map(\.id))
        if atomicApply {
            // 009：多段混合变更一次原子提交（统一锚位移修正，tasks T015）。
            host.apply(.reconcile(items, reason: "pipeline"))
        } else if !removed.isEmpty {
            // 变少了（裁剪/换窗口）⇒ 整批重来；只多出来且都在前面 ⇒ 原子前插。
            host.apply(.setRows(items, anchorId: items.last?.id))
        } else if !incoming.isEmpty {
            if TranscriptListSection.isPrepend(incoming, current: host.rows.compactMap(\.item)) {
                host.apply(.prepend(incoming))
            } else {
                host.apply(.setRows(items, anchorId: items.last?.id))
            }
        }
        if pinToBottom, let last = items.last?.id { host.scrollTo(id: last) }
        context.coordinator.known = Set(items.map(\.id))
        onDiagnostic("list.pinAfterUpdate", ["pin": pinToBottom ? "1" : "0", "items": String(items.count)])
        if pinToBottom { host.pinAfterUpdate() }
        context.coordinator.finishOlderIfNeeded(host: host, items: items)
        // 强制水合要等**真有行被回收**之后才有东西可水合：`makeUIView` 那一刻还没回收，
        // 所以在每次更新时也问一次（2026-10-08 实测：只在 makeUIView 里问 ⇒ request=0）。
        context.coordinator.maybeForceRehydrate(host: host)
        // 跳转请求形如 "id#nonce"：nonce 让同一行的重试也能触发（009 场景⑥：
        // 首次滚动常被未落定的布局冲掉，只认 id 变化会让重试全部失效）。
        if let request = jumpToId, request != context.coordinator.lastJumped {
            let target = request.split(separator: "#").first.map(String.init) ?? request
            if items.contains(where: { $0.id == target }) {
                context.coordinator.lastJumped = request
                host.scrollTo(id: target)
                onDiagnostic("search.jump", ["item": target, "via": "list-host"])
            }
        }
        // 跟随尾部时按预算丢最老端：宿主做原子丢弃（同一批 id），模型同步丢。
        // 只调一次：`onBudgetCheck` **有副作用**（它会把模型端该丢的行也丢掉），
        // 调两次会让"探针那次"先把行丢了、"执行那次"拿到 0（2026-10-08 实测：`window.trimmed` 反而消失）。
        let budgetIDs = context.coordinator.onBudgetCheck?(host.visibleRowEstimate) ?? []
        onDiagnostic("list.budget", [
            "count": String(budgetIDs.count),
            "pin": pinToBottom ? "1" : "0",
            "items": String(items.count),
        ])
        if pinToBottom, !budgetIDs.isEmpty {
            let oldest = budgetIDs.last ?? "-"
            host.apply(.dropOldestIDs(budgetIDs))
            onDiagnostic("window.trimmed", [
                "dropped": String(budgetIDs.count),
                "items": String(max(0, items.count - budgetIDs.count)),
                "oldest": oldest,
            ])
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// 把"取页 → 发 `older.pump`"和 spike 用的驱动收在这里：
    /// SwiftUI 的视图结构体每次更新都会重建，只有 coordinator 能跨更新记住状态。
    @MainActor
    final class Coordinator {
        var known: Set<String> = []
        weak var host: TranscriptListHost?
        var onNearTop: (() -> Void)?
        var onDiagnostic: ((String, [String: String]) -> Void)?
        var onBudgetCheck: ((Int) -> [String])?
        var onDriveBegin: (() -> Void)?
        var onNeedRehydrate: (([Int]) -> Void)?
        /// 本地库取回内容之后，把行交回宿主水合（真实路径的入口）。
        private var forcedRehydrate = false

        /// `-DSHProbeForceRehydrate`：把第一条已回收的行按**真实路径**要回来。
        /// 这条链与"读者滑回去"完全同源（同一个 `onNeedRehydrate` 回调），只是触发点不同。
        func maybeForceRehydrate(host: TranscriptListHost) {
            guard ChatProbe.shared.forceRehydrate, !forcedRehydrate else { return }
            guard let reclaimed = host.rows.firstIndex(where: { $0.isReclaimed }) else { return }
            guard case .reclaimed(let seq, _, _) = host.rows[reclaimed].state else { return }
            forcedRehydrate = true
            onDiagnostic?("list.rehydrate.request", ["seqs": "1", "seq": String(seq),
                                                     "rows": String(host.rows.count)])
            onNeedRehydrate?([seq])
        }

        func rehydrate(items: [TimelineItem]) {
            host?.rehydrate(items: items)
        }
        private var waitingForOlder = false
        private var driveStarted = false
        private var lastKnownCount = 0
        private var lastRequestAt = Date.distantPast
        var lastJumped: String?

        func requestOlder() {
            // 闩锁要能被"超时"打开：取页失败或 `updateUIView` 没再进来时，`waitingForOlder`
            // 会一直挂着，之后每次 `requestOlder` 都被它挡掉（2026-10-08 实测：整轮只剩 1 次请求、
            // 于是只补到 1 页、只丢 2 次）。8 秒没人来收，就允许再请求一次。
            if waitingForOlder, Date().timeIntervalSince(lastRequestAt) < 8 { return }
            lastRequestAt = Date()
            waitingForOlder = true
            onDiagnostic?("older.request", ["items": String(host?.rows.count ?? 0)])
            onNearTop?()
        }

        /// 取页回来（`items` 变多）之后，把 007 的 `older.pump` 等价出来：
        /// `kept` 由宿主最近一次 `settle` 的残差换算（≤8pt 即 1）。
        ///
        /// `items` 用**取页之后**的条数：原来在 `items` 还没变多时就把探针发了，字段是旧值
        /// （run 20261008-222846 实测第一条 `items=54` 而页已落地）。
        func finishOlderIfNeeded(host: TranscriptListHost, items: [TimelineItem]) {
            guard waitingForOlder, items.count > lastKnownCount, let settle = host.lastSettle else {
                // 诊断：`older.pump` 没发出来时，说明卡在哪一条守卫上。
                if waitingForOlder {
                    onDiagnostic?("older.pump.skip", [
                        "grew": items.count > lastKnownCount ? "1" : "0",
                        "settle": host.lastSettle == nil ? "0" : "1",
                        "items": String(items.count),
                    ])
                }
                lastKnownCount = max(lastKnownCount, items.count)
                return
            }
            lastKnownCount = items.count
            waitingForOlder = false
            onDiagnostic?("older.pump", [
                "items": String(items.count),
                "anchor": host.currentAnchorId ?? "-",
                "hasOlder": "1",
                "kept": settle.ok ? "1" : "0",
            ])
        }

        /// `-DSHProbeOlderScroll <n>`：把视口送到顶端 n 次（007 的驱动在 uikit 下的等价物）。
        func startDriveIfNeeded(rounds: Int) {
            guard rounds > 0, !driveStarted else { return }
            driveStarted = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(6))   // 与 007 的驱动一致：等首屏钉底
                ChatProbe.shared.noteDriveBegan?()  // -DSHProbeFailPageOnDrive 的武装点（用例 48）
                self?.onDriveBegin?()
                for round in 1...rounds {
                    guard let self, let host = self.host else { return }
                    // 先回到新的一头再往上滑：宿主只在"离开顶端 120pt 以上"之后才重新武装
                    // `onNearTop`（这是防抖，产品里由真实手指完成）。驱动只 scrollToTop 的话
                    // 第一轮之后 distance 一直是 0，永远不再触发补页——2026-10-08 实测就是这样
                    // 只补到 4 页、只丢 1 次。
                    host.scrollToBottom()
                    try? await Task.sleep(for: .milliseconds(400))
                    self.onDiagnostic?("older.drive", [
                        "round": String(round), "phase": "up",
                        "items": String(host.rows.count),
                    ])
                    host.scrollToTop()
                    try? await Task.sleep(for: .seconds(3))
                    // 失败落锚的一次性 rebase 会把视口从绝对顶往下挪约一行：缺口行恰好被
                    // 推到视口上方（用例 48 的 run 20261011-100805：distance=56、视口第一行
                    // 已是缺口后的内容行，重试条在屏幕外 44pt）。真实手指滑到顶会停在绝对顶，
                    // 所以驱动在等取页结束之后补送一次，落在与读者一致的落点。
                    host.scrollToTop()
                    try? await Task.sleep(for: .milliseconds(600))
                    // 驱动还要能"滑回被回收的那一段"：只在两端跳的话，被回收的往往在中间，
                    // `near` 永远是 0，水合这条路在仿真器里就永远验不到（2026-10-08 实测）。
                    // 胶囊类用例用 -DSHProbeOlderNoReclaim 关掉这段绕行（它会把视口带回底部）。
                    if !ChatProbe.shared.olderDriveSkipsReclaimed,
                       let reclaimed = host.rows.first(where: { $0.isReclaimed })?.id {
                        self.onDiagnostic?("older.drive", ["round": String(round), "phase": "reclaimed"])
                        host.scrollTo(id: reclaimed)
                        try? await Task.sleep(for: .milliseconds(2000))
                    }
                }
                self?.onDiagnostic?("older.drive", ["phase": "done",
                                                    "items": String(self?.host?.rows.count ?? 0)])
            }
        }
    }
}

@MainActor
final class TranscriptListHost: UIView, UICollectionViewDelegate {

    /// 宿主对上层暴露的指令（契约 §1）。
    enum Command {
        case setRows([TimelineItem], anchorId: String?)
        case prepend([TimelineItem])
        /// 033：按显示行 id 丢弃一个前缀（折叠后原始行数 ≠ 显示行数）。
        /// 不再提供"按行数删"的入口：显示行与原始行已经不是一回事。
        case dropOldestIDs([String])
        case reclaim([String])
        case rehydrate([String])
        /// 一次原子提交的多段混合变更（spec 009 tasks T015）：头部插入 + 缺口
        /// 生灭 + 尾部更新合在同一次快照应用里；位移修正走唯一位移锚
        /// （视口顶部首个完整可见行 + 行内偏移，上方高度差汇总一次应用）。
        case reconcile([TimelineItem], reason: String)
    }

    private(set) var rows: [TranscriptRowPayload] = []
    private(set) var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<String, String>!

    /// The first fully visible row, used by the reader-context hold in spec 033.
    var topVisibleRowID: String? { firstFullyVisibleRowId() }

    /// 行视图构造：由 `ChatView` 注入（它知道怎么把 `TimelineItem` 画出来）。
    var makeRow: ((TimelineItem) -> AnyView)?
    /// 诊断出口（`ViewportProbe` 或 spike 自己接）。
    var onDiagnostic: ((String, [String: String]) -> Void)?
    /// 滚动几何：距内容顶端的距离（点）。
    var onScroll: ((CGFloat) -> Void)?
    /// 读者滑到顶部附近——**只在"靠近"这一次里触发一次**，离开足够远才重新武装。
    var onNearTop: (() -> Void)?
    /// 读者是否贴在最新那一头（由滚动几何算，不信拖动位移）。
    var onBottomChanged: ((Bool) -> Void)?
    /// 009 跟底两态（tasks T017）的几何输入：距底距离（点）+ 是否"用户手指向上拖动中"。
    /// 阈值判定与状态迁移都在调用方（ChatModel+Follow），宿主只负责量。
    var onFollowGeometry: ((CGFloat, Bool) -> Void)?
    /// "用户手指向上拖动中"（往更早内容方向）：拖动期间即使几何贴底也不算 atBottom
    /// （spec 009 场景 3：误判会把读者拽回底部）。
    private(set) var isUserDraggingUp = false
    /// 拖动起手时的 offset：没有速度信息的中段拖动靠位移方向判定。
    private var dragStartOffsetY: CGFloat = 0
    /// 上一帧 scroll 回调的 offset（拖动瞬时方向的判定基准）。
    private var lastScrollOffsetY: CGFloat = 0
    /// 读者滚走（离开底部）时撤销"回到底部"的意图。
    func noteUserMovedAwayFromBottom() { wantsBottom = false }
    /// 内容变了之后要不要继续钉底：**只有本来就在底部**（或按钮刚点过）才钉。
    /// 这条替代了原来"用时间窗口猜程序化滚动"的做法——那套会把读者 600ms 内的真实上滑
    /// 误判成我们自己的滚动，于是内容一变就把会话拽回底部（真机反馈第 2 条）。
    func pinAfterUpdate() {
        guard wantsBottom || lastReportedAtBottom else { return }
        setOffsetToBottom()
    }

    /// 把偏移直接设到底（**不用 `scrollToItem`**：`apply(snapshot)` 是异步的，
    /// 同一轮里 `scrollToItem` 打的是旧数据源的下标，UIKit 会忽略——真机反馈"点了仍无效"，
    /// 探针里也是 `before == after`）。
    func setOffsetToBottom() {
        collectionView.layoutIfNeeded()
        let bottom = max(-collectionView.adjustedContentInset.top,
                         collectionView.contentSize.height + collectionView.adjustedContentInset.bottom
                            - collectionView.bounds.height)
        collectionView.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
    }
    /// "回到底部"的意图：一次点击之后**持续满足**，直到真的到了底部。
    /// 一次性的 `scrollToItem` 会被在飞的批量更新吞掉——真机反馈过"点了仍无效"。
    private var wantsBottom = false
    /// 贴底容差（点）：在这个范围内就算"在最新那一头"。
    static let bottomSlack: CGFloat = 40

    /// 预取余量：一屏半。
    private func prefetchMargin() -> CGFloat {
        max(240, collectionView.bounds.height * 1.5)
    }

    /// 该回收这些行（由调用方决定最终是否回收）。
    var onReclaim: (([String]) -> Void)?
    /// 长按了某一行（行 id）。只报给调用方；这一层不弹任何东西。
    var onRowAsk: ((String) -> Void)?
    /// 这些 seq 需要把内容要回来（调用方从本地库读，0 网络）。
    var onNeedRehydrate: (([Int]) -> Void)?
    private var reclaimCheckTask: Task<Void, Never>?
    /// 排着的检查是不是「即查」（程序化跳落触发的 60ms 版）。
    private var reclaimCheckIsImmediate = false
    /// 最近一次补页后的残差（用来把 007 的 `older.pump kept` 等价出来）。
    private(set) var lastSettle: (moved: CGFloat, ok: Bool)?
    /// 顶部补页的节流：贴近顶部时持续上拉要能持续补，不能只触发一次。
    /// 触发条件由"离开顶部再回来"改为"贴顶就请求"，频率交给节流与 coordinator 的闩锁。
    private var lastNearTopFire: CFTimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func setUp() {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.showsSeparators = false
        // 行间距按"原来紧挨着"来：list 的 section 内边距、行内 hosting 的默认 margins 叠起来
        // 会多出一圈空白（2026-10-08 真机反馈：思考过程/工具件之间隔得太开）。三处一起清零。
        let layout = UICollectionViewCompositionalLayout { _, environment in
            let section = NSCollectionLayoutSection.list(using: configuration,
                                                         layoutEnvironment: environment)
            section.contentInsets = .zero
            section.interGroupSpacing = 0
            return section
        }
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
        // 转写行没有"选中"这个语义：`UICollectionView` 默认允许选中，而
        // `UICollectionViewListCell` 的默认背景配置会在**按下与选中**两态给整行铺一层系统灰
        // （实测色值 #D1D0D5，满宽、高度正好一个 item）。owner 两次截图指的就是它：
        // 手指落在一条回答上，整块矩形变灰，而且松手后还留着。
        // 三处一起关：不参与选中、不高亮、cell 背景配置清空（正常态也一并不画）。
        // 长按菜单不受影响——`contextMenu` 走的是另一条手势，不经过 cell 的高亮。
        collectionView.allowsSelection = false
        // 长按一行 = 打开这一行的动作单（SwiftUI 画）。
        //
        // 手势放在宿主里，有两个实测理由（2026-10-12，spec 013）：`UIHostingConfiguration`
        // 里的 SwiftUI `onLongPressGesture` 收不到长按；系统 `contextMenu` 在这个宿主里的
        // 预览与背板几何是错的（被长按的一行常常比屏幕还高，抬起来压住导航栏、遮罩只盖一部分）。
        // `cancelsTouchesInView` 保持默认 true：长按已经成立时，不该再让手指底下的按钮也响应。
        let rowLongPress = UILongPressGestureRecognizer(
            target: self, action: #selector(handleRowLongPress(_:))
        )
        rowLongPress.minimumPressDuration = 0.4
        collectionView.addGestureRecognizer(rowLongPress)
        addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, String> {
            [weak self] cell, _, id in
            guard let self, let payload = self.rows.first(where: { $0.id == id }) else { return }
            // 行自己画自己那块（工具卡片、气泡、代码块都有自己的底色）；cell 一律不画，
            // 于是按下/选中都不会留下灰色底（见 setUp 里的说明）。
            cell.backgroundConfiguration = .clear()
            if let item = payload.item {
                cell.contentConfiguration = UIHostingConfiguration {
                    self.makeRow?(item) ?? AnyView(Color.clear)
                }
                .margins(.all, 0)
            } else if case .reclaimed(_, _, let height) = payload.state {
                // 回收行的占位：按回收时记下的真实高度撑住几何（FR-005 高度不变）。
                // 老实现直接不配置 cell（return）——自撑高列表里这等于一行 0 高的
                // 空白，整屏被回收行占满时就是"只剩输入框"的白屏（用例 57 根因）。
                cell.contentConfiguration = UIHostingConfiguration {
                    // 没量到真实高度的（从没排版就被回收）退到典型行高 44，
                    // 不能让占位是 0 高——0 高会把整段内容高度抽没。
                    AnyView(Color.clear.frame(height: max(height, 44)))
                }
                .margins(.all, 0)
            }
        }
        dataSource = UICollectionViewDiffableDataSource<String, String>(
            collectionView: collectionView
        ) { view, indexPath, id in
            view.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
    }

    /// 长按落在哪一行：交给调用方。
    ///
    /// 只认 `.began`（一个手势只报一次）；落在没有可拷贝文本的行上就不报——那类行本来就没有
    /// 动作单（分隔、提示、缺口）。
    @objc private func handleRowLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        let point = recognizer.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: point),
              let id = dataSource?.itemIdentifier(for: indexPath),
              let item = rows.first(where: { $0.id == id })?.item,
              item.selectableMessage != nil else { return }
        onRowAsk?(id)
    }

    // MARK: - UICollectionViewDelegate

    /// 行不高亮。
    ///
    /// `allowsSelection = false` 只关掉"选中"，按下时的高亮是另一条路径：cell 的
    /// `isHighlighted` 仍会置位，默认背景配置就会铺一层灰。转写行没有任何"我按住了"
    /// 需要表达的语义，所以显式关掉；长按菜单（`contextMenu`）不经过它。
    func collectionView(_ collectionView: UICollectionView,
                        shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        false
    }

    // MARK: - 诊断：连续上滑

#if DEBUG
    /// `-DSHDiagSwipeUp <n>`：连续上滑 n 次（每次约一屏），用于诊断取页与顶部状态。
    /// 与 `-DSHProbeOlderScroll` 的区别：**不回到底部**，轨迹与人的连续上拉一致。
    var canLoadOlder: () -> Bool = { false }
    var isLoadingOlderProvider: () -> Bool = { false }
    private var diagSwipeStarted = false
    private var diagSwipeTask: Task<Void, Never>?

    private static func diagSwipeCount() -> Int? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-DSHDiagSwipeUp"), index + 1 < args.count,
              let count = Int(args[index + 1]), count > 0 else { return nil }
        return count
    }

    func startDiagnosticSwipeIfNeeded() {
        guard !diagSwipeStarted, let count = Self.diagSwipeCount(), !rows.isEmpty else { return }
        diagSwipeStarted = true
        diagSwipeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            var stalled = 0
            for _ in 0..<count {
                guard let self, !Task.isCancelled else { return }
                let height = self.collectionView.bounds.height
                let top = -self.collectionView.adjustedContentInset.top
                let before = self.collectionView.contentOffset.y
                let y = max(top, before - height * 0.85)
                self.collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                try? await Task.sleep(nanoseconds: 350_000_000)
                let after = self.collectionView.contentOffset.y
                DSHLog.event("diag.scroll", [
                    "phase": "up", "delta": String(Int(after - before)), "off": String(Int(after)),
                    "rows": String(self.rows.count),
                    "hasOlder": self.canLoadOlder() ? "1" : "0",
                    "loading": self.isLoadingOlderProvider() ? "1" : "0",
                ])
                stalled = abs(after - before) < 0.5 ? stalled + 1 : 0
                guard stalled < 2 else { break }
            }
            // 到顶后停留观察：模拟持续上拉的"回弹"，每秒一次，看是否最终发起取页。
            for i in 0..<12 {
                guard let self, !Task.isCancelled else { return }
                self.collectionView.setContentOffset(CGPoint(x: 0, y: -30), animated: false)
                try? await Task.sleep(nanoseconds: 120_000_000)
                self.collectionView.setContentOffset(CGPoint(x: 0, y: 0), animated: false)
                try? await Task.sleep(nanoseconds: 880_000_000)
                DSHLog.event("diag.hold", [
                    "i": String(i), "rows": String(self.rows.count),
                    "hasOlder": self.canLoadOlder() ? "1" : "0",
                    "loading": self.isLoadingOlderProvider() ? "1" : "0",
                ])
            }
            // 到顶后的对照：同一位置下拉应能移动，上拉不应移动。
            for phase in ["down", "up", "down", "up"] {
                guard let self, !Task.isCancelled else { return }
                let height = self.collectionView.bounds.height
                let before = self.collectionView.contentOffset.y
                let delta = height * 0.85 * (phase == "down" ? -1 : 1)
                self.collectionView.setContentOffset(
                    CGPoint(x: 0, y: before + delta), animated: false)
                try? await Task.sleep(nanoseconds: 300_000_000)
                let after = self.collectionView.contentOffset.y
                DSHLog.event("diag.scroll", [
                    "phase": phase, "delta": String(Int(after - before)), "off": String(Int(after)),
                    "rows": String(self.rows.count),
                    "hasOlder": self.canLoadOlder() ? "1" : "0",
                    "loading": self.isLoadingOlderProvider() ? "1" : "0",
                ])
            }
        }
    }
#endif

    // MARK: - 指令

    func apply(_ command: Command) {
        switch command {
        case .setRows(let items, let anchorId):
            rows = TranscriptListSection.ordered(items).map { TranscriptRowPayload(item: $0) }
            applySnapshot()
            // 快照是异步落的：同一轮里滚会打到旧数据源的下标（见 `scrollTo(id:)` 的注释）。
            // 这里显式推迟一轮，`scrollTo` 里还有一道按实时条数的兜底校验。
            if let anchorId {
                DispatchQueue.main.async { [weak self] in
                    self?.scrollTo(id: anchorId, animated: false)
                }
            }
            diagnostic("list.host", ["mode": "uikit", "rows": String(rows.count)])
        case .prepend(let items):
            prepend(items, reason: "page")
        case .dropOldestIDs(let ids):
            dropOldest(ids: ids)
        case .reclaim(let ids):
            reclaim(ids: ids)
        case .rehydrate(let ids):
            var touched = Set<String>()
            for index in rows.indices where ids.contains(rows[index].id) {
                rows[index].contentVersion += 1
                touched.insert(rows[index].id)
            }
            // 与 rehydrate(items:) 同一条纪律：身份不变内容变，必须 reload，
            // 否则 cell 停在旧配置。
            applySnapshot(reloading: touched)
            diagnostic("list.rehydrate", ["rows": String(ids.count), "ms": "0", "net": "0"])
        case .reconcile(let items, let reason):
            reconcile(items, reason: reason)
        }
    }

    /// 009 的统一锚一次提交（spec「唯一位移锚」/ tasks T015）。
    ///
    /// 与 `prepend`/`dropOldest` 同一套纪律——量锚、一次应用快照、把上方高度差
    /// 汇总后**一次**加回 `contentOffset`，残差超容差再修一次（仍只改 offset，
    /// 不滚到行）。区别只在两点：
    /// - 变更可以是多段混合（头部插入 + 缺口生灭 + 尾部更新），所以锚不能取
    ///   「当前第一行」（它可能正在被换掉），要取**视口顶部首个完整可见行**；
    /// - 被回收的行保留回收态（身份与高度不变，内容仍由水合路径要回）。
    /// 上一次 reconcile 应用的行签名（id + 内容签名）：都没变就整次跳过
    /// （SwiftUI 每次 body 重算都会路过这里，真去 apply + layoutIfNeeded
    /// 会把打字都变成一次布局——T015 的性能纪律）。
    private var lastReconcile: [(id: String, signature: String)] = []

    func reconcile(_ items: [TimelineItem], reason: String) {
        let started = CFAbsoluteTimeGetCurrent()
        let ordered = TranscriptListSection.ordered(items)
        let incoming = ordered.map { (id: $0.id, signature: Self.signature(of: $0)) }
        guard incoming.map(\.signature) != lastReconcile.map(\.signature)
                || incoming.map(\.id) != lastReconcile.map(\.id) else { return }
        var changedIds = Set<String>()
        for (index, pair) in incoming.enumerated() {
            guard index < lastReconcile.count, lastReconcile[index].id == pair.id else { continue }
            if lastReconcile[index].signature != pair.signature { changedIds.insert(pair.id) }
        }
        lastReconcile = incoming
        let anchorId = firstFullyVisibleRowId() ?? rows.first?.id
        let anchorSeq = rows.first(where: { $0.id == anchorId })?.seq
        let before = visualY(of: anchorId)
        let effectiveAnchorId = TranscriptAnchorResolver.resolve(
            anchorID: anchorId, anchorSeq: anchorSeq, in: ordered)
        let reclaimedById = Dictionary(
            rows.filter(\.isReclaimed).map { ($0.id, $0.state) },
            uniquingKeysWith: { old, _ in old })
        rows = ordered.map { item in
            var payload = TranscriptRowPayload(item: item)
            // 只有数据行保留回收态：缺口行没有磁盘记录，水合要不回内容，
            // 保留回收态就是一条永久空白占位（数据行由磁盘水合路径要回）。
            if item.kind.isContentRow, let reclaimed = reclaimedById[item.id] {
                payload.state = reclaimed
            }
            return payload
        }
        applySnapshot(reloading: changedIds)
        collectionView.layoutIfNeeded()
        let after = visualY(of: effectiveAnchorId)
        var delta = (after ?? 0) - (before ?? 0)
        if delta != 0 {
            collectionView.contentOffset.y += delta
            collectionView.layoutIfNeeded()
        }
        var residual = (visualY(of: effectiveAnchorId) ?? before ?? 0) - (before ?? 0)
        if abs(residual) > Self.tolerance {
            collectionView.contentOffset.y += residual
            collectionView.layoutIfNeeded()
            delta += residual
            residual = (visualY(of: effectiveAnchorId) ?? before ?? 0) - (before ?? 0)
        }
        diagnostic("list.reconcile", [
            "rows": String(rows.count),
            "deltaPt": String(format: "%.0f", delta),
            "ms": String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - started) * 1000),
            "reason": reason,
        ])
        settle(anchorId: effectiveAnchorId ?? "-", moved: residual)
        satisfyBottomIntent()
        if distanceToTop() < prefetchMargin() { onNearTop?() }
    }

    /// 行内容签名：身份之外「内容有没有变」的判定（相同 id 的行被更新时要
    /// reload cell，缺口行的三态也在签名里）。回收态保留原签名——内容没变。
    private static func signature(of item: TimelineItem) -> String {
        let base = "\(item.id)#\(TranscriptRowPayload(item: item).payloadBytes)"
        switch item.kind {
        case .gap(_, _, let status):
            return "\(item.id)|gap:\(status)"
        case .userMessage(_, _, let isSteering, let isPending, _):
            // pending→sent 原地替换不改字节数，状态位必须进签名，否则徽标永远停在"等待开始"。
            // 失败/未确认两个标记同理：都只翻状态位，不改载荷字节数。
            return "\(base)|u:\(isSteering):\(isPending):\(item.sendFailed):\(item.sendUnconfirmed)"
        case .toolCall(let invocation):
            return "\(base)|t:\(invocation.isRunning):\(invocation.isError)"
        case .processHeader(let header):
            return "\(base)|ph:\(header.isExpanded):\(header.toolCount):\(header.reasoningCount):\(header.messageCount)"
        default:
            return base
        }
    }

    /// 唯一位移锚（spec 009）：视口顶部**首个完整可见行**的 id。
    /// 量不到（行还没布局出来）时返回 nil，调用方退而用第一行。
    private func firstFullyVisibleRowId() -> String? {
        let top = collectionView.contentOffset.y
        for index in rows.indices {
            let path = IndexPath(item: index, section: 0)
            guard let attributes = collectionView.collectionViewLayout
                .layoutAttributesForItem(at: path) else { continue }
            if attributes.frame.maxY <= top { continue }
            // 首个与视口相交的行：完整可见（minY 不低于视口顶）才够格当锚，
            // 否则继续找下一行——被切掉半行的锚会量出半个行高的假位移。
            if attributes.frame.minY >= top { return rows[index].id }
        }
        return nil
    }

    /// 往上插一页：量出锚点位移，同一次更新内把 offset 修回去。
    func prepend(_ items: [TimelineItem], reason: String) {
        let incoming = TranscriptListSection.ordered(items).map { TranscriptRowPayload(item: $0) }
        guard !incoming.isEmpty else { return }
        let anchorId = rows.first?.id ?? incoming.first?.id
        let before = visualY(of: anchorId)
        let started = CFAbsoluteTimeGetCurrent()
        rows.insert(contentsOf: incoming, at: 0)
        applySnapshot()
        collectionView.layoutIfNeeded()
        let layoutMs = (CFAbsoluteTimeGetCurrent() - started) * 1000
        let after = visualY(of: anchorId)
        var delta = (after ?? 0) - (before ?? 0)
        if delta != 0 {
            collectionView.contentOffset.y += delta
            collectionView.layoutIfNeeded()
        }
        // 修正之后自检一次：锚点相对**插入前**的视觉位置还有多少残差，> 容差就再修一次
        // （**仍然只改 offset，不滚到行**）。
        var residual = (visualY(of: anchorId) ?? before ?? 0) - (before ?? 0)
        if abs(residual) > Self.tolerance {
            collectionView.contentOffset.y += residual
            collectionView.layoutIfNeeded()
            delta += residual
            residual = (visualY(of: anchorId) ?? before ?? 0) - (before ?? 0)
        }
        diagnostic("list.insert", ["rows": String(incoming.count),
                                   "deltaPt": String(format: "%.0f", delta),
                                   "ms": String(format: "%.0f", layoutMs),
                                   "reason": reason])
        settle(anchorId: anchorId ?? "-", moved: residual)
        // 补完一页之后如果读者还贴在顶部，就**继续要下一页**：真实手指一直往上拉时内容不再移动，
        // `scrollViewDidScroll` 也就不会再报"靠近顶端"，只在第一页之后停住
        // （2026-10-08 真机反馈："仍不能无限拉，中断了"）。这里由宿主自己续上，
        // 次数交给调用方的"还有没有更早"兜底（到日志开头就不再要）。
        satisfyBottomIntent()
        if distanceToTop() < prefetchMargin() { onNearTop?() }
    }

    /// 按预算丢弃最老的已读行（spec 008 的 FR-002）。
    /// 033：丢掉显示行的一个前缀。折叠后显示行数少于原始行数，按行数裁剪会
    /// 删错行；调用方给出**显示行 id**，这里只做前缀删除与位移修正。
    func dropOldest(ids: [String]) {
        guard !ids.isEmpty, rows.count > ids.count else { return }
        let victims = Set(ids)
        guard let firstKept = rows.firstIndex(where: { !victims.contains($0.id) }) else { return }
        let anchorId = rows[firstKept].id
        let before = visualY(of: anchorId)
        rows.removeFirst(firstKept)
        applySnapshot()
        collectionView.layoutIfNeeded()
        let after = visualY(of: anchorId)
        let delta = (after ?? 0) - (before ?? 0)
        if delta != 0 {
            collectionView.contentOffset.y += delta
            collectionView.layoutIfNeeded()
        }
        let residual = (visualY(of: anchorId) ?? before ?? 0) - (before ?? 0)
        diagnostic("list.insert", ["rows": String(firstKept),
                                   "deltaPt": String(format: "%.0f", delta),
                                   "reason": "drop-ids"])
        settle(anchorId: anchorId, moved: residual)
    }

    // MARK: - 跳转 / 探针用的定位（**不许**用作插入与丢弃的位移手段）

    /// 某一行当前的高度（量不到返回 nil）。spike D 用它比较"回收/水合前后行高是否一致"。
    func rowHeight(of id: String) -> CGFloat? {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
        return collectionView.collectionViewLayout
            .layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame.height
    }

    /// 回收前把真实行高记进载荷：占位行要靠它撑住几何（FR-005 回收/水合高度一致）。
    /// 从没排版过的行（快速滚动里一眼没看就被回收）量不到，保持 nil——占位用兜底高。
    private func noteLaidOutHeight(at index: Int) {
        guard rows[index].height == nil, !rows[index].isReclaimed else { return }
        rows[index].height = collectionView.collectionViewLayout
            .layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame.height
    }

    /// 当前是否还有已回收的行（驱动与诊断用）。
    var hasReclaimedRows: Bool { rows.contains { $0.isReclaimed } }

    /// 行在屏幕上的 y（spike D 比较水合前后位置）。
    func screenY(of id: String) -> CGFloat? { visualY(of: id) }

    /// 回收一批行（只换载荷，不动身份与高度）。
    func reclaim(ids: [String]) {
        let wanted = Set(ids)
        // 只算真正从 full → reclaimed 的行：已经回收的行重复进名单时
        // freed 必须是 0，记账才看得出"重复回收"（用例 57 的 bytes=0 迷雾）。
        let freed = rows.filter { wanted.contains($0.id) && !$0.isReclaimed }
            .reduce(0) { $0 + $1.payloadBytes }
        for index in rows.indices where wanted.contains(rows[index].id) {
            noteLaidOutHeight(at: index)
            rows[index].reclaim()
        }
        applySnapshot()
        diagnostic("list.reclaim", ["rows": String(ids.count),
                                    "bytes": String(freed),
                                    "totalBytes": String(payloadBytes())])
    }

    /// 把记录还回来做水合（真实现里这些记录来自本地库，**0 网络**）。
    func rehydrate(items: [TimelineItem]) {
        let started = CFAbsoluteTimeGetCurrent()
        var rehydrated = 0
        var touched = Set<String>()
        for item in items {
            guard let index = rows.firstIndex(where: { $0.id == item.id }), rows[index].isReclaimed else { continue }
            rows[index].rehydrate(with: item)
            touched.insert(item.id)
            rehydrated += 1
        }
        // 水合回来的行必须 reload：diffable 数据源对"身份没变"的行不重配 cell，
        // 不 reload 的话 cell 永远停在回收时那份 Color.clear 占位——数据回来了
        // 屏幕还是白的（用例 57 间歇性全白、用例 49 跳到命中行后一片空白的根因）。
        applySnapshot(reloading: touched)
        collectionView.layoutIfNeeded()
        diagnostic("list.rehydrate", [
            "rows": String(rehydrated),
            "ms": String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - started) * 1000),
            "net": "0",
        ])
    }

    /// 上一次滚动上报时读者是不是贴着底。
    private var lastReportedAtBottom = true

    /// 满足"回到底部"的意图。
    ///
    /// 一次 `scrollToItem` 会被在飞的批量更新吞掉（真机反馈"点了仍无效"），所以：
    /// 记意图 + **按 0/120/300/600ms 重试**，每次重试前再确认一次"还没到底"。
    func satisfyBottomIntent() {
        guard wantsBottom, let last = rows.last?.id else { return }
        setOffsetToBottom()
        Task { @MainActor [weak self] in
            for delay in [0, 120, 300, 600, 1000] {
                if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                guard let self, self.wantsBottom else { return }
                if self.bottomDistance() <= Self.bottomSlack { return }
                // 直接改 `contentOffset`，**不用** `scrollToItem`：`apply(snapshot)` 是异步的，
                // 同一轮里 `scrollToItem` 打的是旧数据源的下标，UIKit 会直接忽略
                // （真机反馈"点了仍无效"，探针里也看到 `before == after`）。
                // 自撑高度的列表里内容高度是估算值，所以要按 0/120/300/600/1000ms 多修几次。
                self.setOffsetToBottom()
            }
            _ = last
        }
    }

    /// 视口距底部的距离（点）。
    func bottomDistance() -> CGFloat {
        let content = collectionView.contentSize.height + collectionView.adjustedContentInset.bottom
        return content - collectionView.bounds.height - collectionView.contentOffset.y
    }

    func cancelBottomIntent() { wantsBottom = false }

    /// 视口距内容顶端的距离（点）。
    func distanceToTop() -> CGFloat {
        collectionView.contentOffset.y + collectionView.adjustedContentInset.top
    }

    /// 驱动用：把视口送到内容顶端（`-DSHProbeOlderScroll` 的 uikit 版）。
    func scrollToTop() {
        // 程序化"离开底部"要撤销钉底意图：驱动每轮开头会 scrollToBottom() 把
        // wantsBottom 武装起来，不清掉的话下一条新消息经 pinAfterUpdate 又把
        // 视口拽回底部（2026-10-11 胶囊用例复跑实测）。生产语义同理：搜索跳转
        //  scrollTo(id:) 离开底部时也不该再挂着一个"回到底部"的意图。
        wantsBottom = false
        collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top),
                                        animated: false)
        scheduleReclaimCheck(immediate: true)
    }

    /// 钉到底部（打开会话、跟随中、以及"回到底部"按钮）。
    ///
    /// 记成**意图**：`scrollToItem` 一次可能被在飞的批量更新吞掉，所以之后每次布局/更新
    /// 都会再满足一次，直到真的贴到底（或者读者自己滚走）。
    func scrollToBottom() {
        wantsBottom = true
        satisfyBottomIntent()
        guard rows.last != nil else { return }
        // 诊断：按钮点了到底有没有把视口带走（真机反馈过"点了不生效"）。
        // 前后各报一次——只报"调用时"的距离说明不了问题，要看**滚完之后**还剩多远。
        let before = distanceToTop()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self else { return }
            self.diagnostic("list.scrollToBottom", [
                "before": String(format: "%.0f", before),
                "after": String(format: "%.0f", self.distanceToTop()),
                "items": String(self.rows.count),
            ])
        }
    }

    // MARK: - 回收 / 再水合（US3：FR-004/FR-005/SC-004）

    /// 视口内行的下标区间（按布局属性与可见带求交）。
    func visibleRange() -> Range<Int> {
        // 可见带 = 内容坐标里的"当前视口矩形"。不能拿 `bounds` 去 `inset(by:)`——
        // 那是把 inset 加到 origin 上，得到的矩形既不是视口也不是内容区，
        // 于是 `visible=2`（2026-10-08 实测：扫描探针里可见行只有 2 行，回收判定因此全乱）。
        let band = CGRect(origin: collectionView.contentOffset, size: collectionView.bounds.size)
        var first: Int?
        var last: Int?
        for index in rows.indices {
            guard let attributes = collectionView.collectionViewLayout
                .layoutAttributesForItem(at: IndexPath(item: index, section: 0)) else { continue }
            if attributes.frame.intersects(band) {
                if first == nil { first = index }
                last = index
            }
        }
        guard let first, let last else { return 0..<0 }
        return first..<(last + 1)
    }

    /// "几屏"按**点**算，不按行数。
    ///
    /// 行高差得很远（这个会话里一行能到 1151pt，一屏只放得下 2 行；短会话里一屏十几行），
    /// 所以"离视口 5 屏"只能用点：`5 × 视口高度`。按行数换算会把"5 屏"错算成几十行，
    /// 结果一上来就把远处全回收了（2026-10-08 实测：`visible=2`、`reclaim=7`）。
    private func bandWithMargin(screens: Int) -> CGRect {
        let viewport = CGRect(origin: collectionView.contentOffset, size: collectionView.bounds.size)
        let margin = CGFloat(screens) * viewport.height
        return viewport.insetBy(dx: 0, dy: -margin)
    }

    /// 离视口超过 `screens` 屏、且还没回收的行 —— 可以回收。
    ///
    /// 保护带 = 布局点带（视口 ± screens 屏）∪ 行数带（与水合同一把尺子，
    /// `ViewportBandPlanner`）：修复前回收只用点带、水合只用下标带，行高悬殊时
    /// 两把尺子量的不是同一段，水合刚要回来的行下一轮又被抽走（用例 57 的
    /// 「回收 → 水合 → 又回收」乒乓）；可见带退化（`visible=2`）时点带错位，
    /// 曾一次把正在读的 135 行抽走（`bytes=0 rows=135`）。
    func rowsToReclaim(screens: Int) -> [String] {
        guard !rows.isEmpty, collectionView.bounds.height > 0 else { return [] }
        let visible = visibleRange()
        // 布局剧烈变动期量不出可见带：宁可不回收，也不猜着收（2026-10-11 用例 57）。
        guard !visible.isEmpty else { return [] }
        let band = bandWithMargin(screens: screens)
        var pointProtected = Set<Int>()
        for index in rows.indices {
            guard let attributes = collectionView.collectionViewLayout
                .layoutAttributesForItem(at: IndexPath(item: index, section: 0)) else { continue }
            if attributes.frame.intersects(band) { pointProtected.insert(index) }
        }
        let indices = ViewportBandPlanner.reclaimCandidates(
            rowCount: rows.count,
            visible: visible,
            pointProtected: pointProtected,
            screens: screens
        ) { index in
            guard !rows[index].isReclaimed else { return false }
            // 缺口行不回收：载荷几乎为零，且它没有磁盘记录可取——水合要不回
            // spinner/重试态，只会留下一条永久空白占位。
            if let item = rows[index].item, !item.kind.isContentRow { return false }
            return true
        }
        return indices.map { rows[$0].id }
    }

    /// 已被回收、但已经回到视口 `screens` 屏以内的行 —— 需要把内容要回来（seq 列表）。
    func reclaimedSeqsNearViewport(screens: Int) -> [Int] {
        guard !rows.isEmpty else { return [] }
        // 用**下标**判近远，不用布局属性：被回收的行往往没被渲染，
        // `layoutAttributesForItem` 对它们返回 nil，于是"近"永远判不出来（2026-10-08 实测 `near=0`）。
        // 与回收共用 `ViewportBandPlanner` 的行数带：水合带（2 屏）严格小于
        // 回收保护带（5 屏），要回来的行不会在下一轮又被回收（乒乓修复）。
        let visible = visibleRange()
        let indices = ViewportBandPlanner.rehydrateCandidates(
            rowCount: rows.count,
            visible: visible,
            screens: screens
        ) { index in
            if case .reclaimed = rows[index].state { return true }
            return false
        }
        return indices.compactMap { index in
            guard case .reclaimed(let seq, _, _) = rows[index].state else { return nil }
            return seq
        }
    }

    /// 契约里的两个距离：**回收 5 屏 / 水合 4 屏**（真值口径在 `contracts/list-host.md` §4，
    /// 常量在 DSHKit 的 `TranscriptWindowPlanner.Distances`；水合那一档是 009 修闪白时调宽的）。
    /// 这里读探针覆盖（DEBUG 才可能非零），缺省就是契约值。
    static var reclaimDistanceScreens: Int { ChatProbe.shared.reclaimScreens }
    static var rehydrateDistanceScreens: Int { ChatProbe.shared.rehydrateScreens }

    func scrollTo(id: String, animated: Bool = false,
                  anchor: UICollectionView.ScrollPosition = .centeredVertically,
                  retrying: Bool = false) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        // `apply(snapshot, animatingDifferences: false)` 仍然是**异步**的：`rows` 已经换成
        // 新数组，而 collection view 的数据源可能还停在上一份。同一轮里拿新下标调
        // `scrollToItem`，UIKit 会以 `_validateScrollingTargetIndexPath:` 断言把 App 打死
        // （SIGABRT）。2026-10-18 真机"一打开会话就闪退"就是这条：打开时行数增多，
        // 末行下标超出旧快照的条数。
        //
        // 因此这里必须按**数据源当前条数**校验，而不是按 `rows` 校验；越界说明快照还没落定，
        // 交给下一轮再试一次（后续更新与布局也会重新表达意图）。
        let liveCount = collectionView.numberOfItems(inSection: 0)
        guard index < liveCount else {
            // 只重试一次：数据源始终没跟上就放弃（后续更新会重新表达意图），
            // 不在这里空转 runloop。
            guard !retrying else { return }
            DispatchQueue.main.async { [weak self] in
                self?.scrollTo(id: id, animated: animated, anchor: anchor, retrying: true)
            }
            return
        }
        // 程序化"跳走"同样撤销钉底意图（与 scrollToTop 同一条纪律）：
        // 搜索命中跳转停在中间时，挂着 wantsBottom 会让下一条新消息把读者拽回底部。
        wantsBottom = false
        collectionView.scrollToItem(at: IndexPath(item: index, section: 0),
                                    at: anchor, animated: animated)
        scheduleReclaimCheck(immediate: true)
    }

    /// 记录"锚点位移"，用例据此判定（≤8pt 为 `ok=1`）。
    func settle(anchorId: String, moved: CGFloat) {
        lastSettle = (moved, abs(moved) <= Self.tolerance)
        diagnostic("list.settle", ["moved": String(format: "%.0f", moved),
                                   "ok": lastSettle?.ok == true ? "1" : "0",
                                   "anchor": anchorId])
    }

    var currentAnchorId: String? { rows.first?.id }

    /// 屏幕大约能放几行（按行高 ~44pt 估）。保留带用它换算，保证丢弃后仍填得满屏幕。
    var visibleRowEstimate: Int {
        let height = collectionView.bounds.height
        guard height > 0 else { return 8 }
        return max(8, Int(height / 44))
    }

    // MARK: - 内部

    static let tolerance: CGFloat = 8

    private func item(for id: String) -> TimelineItem? {
        rows.first { $0.id == id }?.item
    }

    private func payloadBytes() -> Int {
        rows.reduce(0) { $0 + $1.payloadBytes }
    }

    private func applySnapshot(reloading reloadIds: Set<String> = []) {
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        snapshot.appendSections([TranscriptListSection.main])
        // 防御：diffable 对重复 identifier 会**直接断言打死 App**。身份稳定是本设计的承诺，
        // 真出现重复说明调用方拼错了数据——那就去重并留一条诊断，不许把 App 带走。
        var seen = Set<String>()
        let identifiers = rows.map(\.id).filter { seen.insert($0).inserted }
        if identifiers.count != rows.count {
            diagnostic("list.duplicate", ["rows": String(rows.count),
                                          "unique": String(identifiers.count)])
            rows = rows.filter { seen.contains($0.id) }
        }
        snapshot.appendItems(identifiers, toSection: TranscriptListSection.main)
        // 身份不变但内容变了的行（流式增长、缺口三态、pending→sent）要 reload
        // 才会重配 cell；同一事务里完成，不拆第二次提交。
        let reloadable = reloadIds.intersection(identifiers)
        if !reloadable.isEmpty { snapshot.reloadItems(Array(reloadable)) }
        dataSource.apply(snapshot, animatingDifferences: false)
        #if DEBUG
        startDiagnosticSwipeIfNeeded()
        #endif
    }

    /// 某一行在**屏幕上**的 y（内容坐标 − 当前 offset）；量不到返回 nil。
    private func visualY(of id: String?) -> CGFloat? {
        guard let id, let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
        let path = IndexPath(item: index, section: 0)
        guard let attributes = collectionView.collectionViewLayout.layoutAttributesForItem(at: path) else {
            return nil
        }
        return attributes.frame.minY - collectionView.contentOffset.y
    }

    private func diagnostic(_ name: String, _ fields: [String: String]) {
        onDiagnostic?(name, fields)
    }
}

extension TranscriptListHost {

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // 拖动过程中的瞬时方向：按上一帧 offset 的走向更新（慢拖没有速度回调）。
        if scrollView.isTracking {
            isUserDraggingUp = scrollView.contentOffset.y < lastScrollOffsetY
        }
        lastScrollOffsetY = scrollView.contentOffset.y
        let distance = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        onScroll?(distance)
        scheduleReclaimCheck()
        // 视口距底部的距离：这是"读者还在不在最新那一头"的唯一依据
        // （真机反馈过"刷新时偶尔自己跳到底部"——用拖动位移判定跟随是不可靠的）。
        let atBottom = bottomDistance() <= Self.bottomSlack
        lastReportedAtBottom = atBottom
        onBottomChanged?(atBottom)
        reportFollowGeometry(scrollView)
        // **可见余量预取**：离顶端还有一屏半就开始要，而不是等贴到顶（真机反馈"预取太慢"）。
        // 贴着顶时也允许继续要 —— 读者一直往上拉就一页页接着给。
        // 2026-10-18 实测：旧写法是边沿触发（贴顶触发一次、离开两倍边距才重新武装），
        // 读者停在顶部时永远等不到第二次，于是"还有更早、没有加载、也拉不动"。
        // 现在贴顶就请求，300ms 节流；真正的并发与"一页在飞"由 coordinator 的闩锁负责。
        if distance < prefetchMargin() {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastNearTopFire > 0.3 {
                lastNearTopFire = now
                onNearTop?()
            }
        }
    }

    // MARK: - 009 跟底两态的拖动方向（tasks T017）

    /// 上报一次跟底几何（距底距离 + 向上拖动中）。拖动开始/结束/减速结束各补一次：
    /// 这几何时刻 offset 未必再变，不补的话"松手停在底部"会一直被判成阅读中。
    private func reportFollowGeometry(_ scrollView: UIScrollView) {
        onFollowGeometry?(bottomDistance(), isUserDraggingUp)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        dragStartOffsetY = scrollView.contentOffset.y
        isUserDraggingUp = false
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        // 速度优先（快速甩动），速度近零时退到整段位移方向（慢拖）。
        // offset 变小 = 往更早内容方向 = "向上"。
        isUserDraggingUp = velocity.y < -0.05
            || (abs(velocity.y) <= 0.05 && scrollView.contentOffset.y < dragStartOffsetY)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            isUserDraggingUp = false
            reportFollowGeometry(scrollView)
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        isUserDraggingUp = false
        reportFollowGeometry(scrollView)
    }
}

extension TranscriptListHost {

    /// 滚动里顺手做一次回收/水合判定，但**延后 400ms 且合并**：不与滚动抢主线程。
    /// 程序化跳落（`scrollTo`/`scrollToTop`）用 immediate：落点常常是被回收的段，
    /// 等 400ms 会把可见带白在那儿半秒以上（用例 57 的瞬态白段），60ms 内把水合
    /// 发出去，像素采样（500ms 一拍）就不会连着两拍看到空白。
    func scheduleReclaimCheck(immediate: Bool = false) {
        if immediate, reclaimCheckTask != nil, !reclaimCheckIsImmediate {
            // 已排的长延时检查升级成即查：跳落之后不需要再等满 400ms。
            reclaimCheckTask?.cancel()
            reclaimCheckTask = nil
        }
        guard reclaimCheckTask == nil else { return }
        reclaimCheckIsImmediate = immediate
        let delay = immediate ? 60 : 400
        reclaimCheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            // 被「升级成即查」取消的旧任务直接退场：不许清引用（指向新任务），
            // 也不许再跑一遍检查。
            guard !Task.isCancelled else { return }
            self?.reclaimCheckTask = nil
            self?.reclaimCheckIsImmediate = false
            guard let self, self.window != nil else { return }
            let reclaim = self.rowsToReclaim(screens: Self.reclaimDistanceScreens)
            if !reclaim.isEmpty { self.onReclaim?(reclaim) }
            let seqs = self.reclaimedSeqsNearViewport(screens: Self.rehydrateDistanceScreens)
            // 扫描探针：`reclaimed` 是当前已回收的行数，`near` 是"回到视口附近、该水合"的条数。
            // `list.rehydrate` 没出现时，看这两个数就知道是"没判定出来"还是"判出来了但取不到"。
            self.diagnostic("list.reclaim.scan", [
                "reclaimed": String(self.rows.filter(\.isReclaimed).count),
                "near": String(seqs.count),
                "visible": String(self.visibleRange().count),
                "reclaim": String(reclaim.count),
            ])
            if !seqs.isEmpty { self.onNeedRehydrate?(seqs) }
        }
    }
}
#endif
