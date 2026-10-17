#if os(iOS)
import DSHDesign
import DSHKit
import SwiftUI
import DSHChatDomain

/// 会话内搜索面板。
///
/// 一个面板解决两件事：
///   * 「我原来问过什么」——把筛选切到「只看我的提问」，等价于只列 userMessage；
///   * 「这段记录在哪」——搜全文（助手正文、工具名与结果），点结果跳过去。
///
/// 只搜**已经加载**的那段历史：host 的 `session/search` 在这个部署里是关的
/// （`session-query` 索引 `openAt: never`），而转写本来就在手机上。上面还有更早的
/// 时候，面板底部给一个「继续往上找」，取一页再搜一次——补页这条路已经做成
/// 连续的（见 `ChatView.pumpOlder`），所以这里只是把同一个动作接到搜索上。
struct TranscriptSearchSheet: View {
    @Bindable var model: ChatModel
    /// 选中一条结果：把行 id 交回转写页，由它滚动并高亮。
    var onPick: (TranscriptSearchHit) -> Void

    // 动作半边在 TranscriptSearchSheet+Actions.swift（500 行上限拆分）；
    // 下面这些成员因此保持 internal，供扩展文件访问。
    @Environment(\.dismiss) var dismiss
    @State var query = ""
    @State var onlyMine = false
    @State var hits: [TranscriptSearchHit] = []
    /// 连接器给的续页游标；`source` 说明这一屏命中覆盖到哪儿（spec 007 P2）。
    @State var searchCursor: String?
    @State var pageHasMore = false
    /// 扫描进度（片）。老连接器不发就是 nil——界面按"进度未知"说，不假装知道。
    @State var searchProgress: ChatModel.SearchPage.SearchProgress?
    /// 这一屏命中是从哪儿来的。`localStore` = 本地 record 全量库（T034，零网络）；
    /// `connector` = 连接器整会话；`localWindow` = 已加载的那一段。
    ///
    /// T040 起只剩「搜全部内容」会走 `connector`，「我问过的」被 `localStore` 独占
    ///（删掉了"本地为空/未灌全就退回连接器"的岔路），所以用枚举而不是裸字符串：
    /// 分支写漏会在编译期现形。
    enum SearchSource: String {
        case localWindow = "local"
        case localStore
        case connector
    }
    @State var searchSource: SearchSource = .localWindow
    /// 本会话「我问过的」本地库是否已灌全（`session_state.user_inputs_synced_at`）。
    /// `nil` = 还没问出来（第一次查询前不显示状态行，避免已灌全时闪一下「同步中…」）。
    @State var isUserInputsSynced: Bool?
    /// 未灌全时每 1.5s 重查一次完整性标记（一次本地索引读）。
    static let syncPollMilliseconds = 1500
    @State var isLoadingMore = false
    /// 现在**真的在屏幕上**的结果行（行自己上报，用于算"底下还剩几条"）。
    @State var visibleHitIds: Set<String> = []
    /// 读者上次滑动之后，已经"没有新行产出"地预读了几页（滑动会把它清零）。
    @State var scrollDrivenLoads = 0
    /// 最近一次滚动偏移（用来判"读者真的滑了"；追加行不会改变它）。
    @State private var lastScrollOffset: CGFloat?
    /// 上一次看到的行数，用来判这一轮预读有没有产出。
    @State var lastRowCount = 0
    /// 防抖之后真正跑的那次搜索（打字时每敲一下都会把它取消重排）。
    @State var searchTask: Task<Void, Never>?
    /// 已经搜过的"筛选 + 关键词"指纹：没变就不重搜（用户要求"有变更再触发"）。
    @State var lastSearchKey = ""
    /// **正在执行**的那次搜索的指纹（防抖走完、真正开始查之后才置上，落地即清）。
    /// 后台刷新（时间线变大、范围版本 +1）不许取消同 key 的在飞搜索——用例 49 的
    /// 回归就是连接器往返被这一刀砍掉的。
    @State var runningSearchKey: String?
    /// 最近一次**成功落地**的指纹与来源：连接器命中覆盖整个会话，本地范围变大
    /// 不需要重跑（重跑就是白打一次 2 秒往返，还会把列表换掉）。
    @State var landedKey = ""
    /// 在飞期间来过同 key 的范围刷新：落地后补一次（只对依赖本地窗口的来源）。
    @State var pendingScopeRefresh = false
    /// 最新排队的指纹；只有它对应的那次搜索有权把 `isSearchPending` 放下来。
    @State var latestSearchKey = ""
    /// 正在搜（打字期间为真）：这段时间里不预读、不追加行，免得和输入抢主线程。
    @State var isSearchPending = false
    /// 打字停顿多久才真正搜。60ms 一跳的输入里，只有最后一次会落地。
    static let typingDebounce = 260
    /// 可见范围之外至少要先备好这么多条：不够就继续往前读。
    ///
    /// 为什么不是"底部哨兵露面才读"：哨兵行只在 `onAppear` 时触发一次，之后它一直
    /// 留在屏幕上（新行是追加在它上面的？不，是追加在末尾、把它挤下去之前）——
    /// 2026-09-25 用户实测"继续下拉会往前读"根本没生效：第一页之后哨兵没重建，
    /// 就再没有第二次触发。改成按可见范围算余量，读到够为止。
    static let prefetchAhead = 10
    /// 读者滑一次最多"没有新行产出"地预读几页。
    ///
    /// 为什么要有这个上限：关键词很"冷"的时候（比如整段历史里只有 1 条命中），
    /// "可见范围外备够 10 条"这个条件**永远满足不了**，不限量就会把整段历史读完
    /// （2026-09-25 实测就是这么把 43 页全读光的）。滑动一次最多试探 4 页，
    /// 读者再滑一次就再试探 4 页——仍然是"一边下拉一边读"，但不会自己跑到底。
    static let maxScrollDrivenLoads = 4
    @FocusState private var isFocused: Bool

    /// 连接器不支持"搜整个会话"时的硬门槛提示（FR-036）：只说明天花板，不禁用搜索。
    @ViewBuilder
    private var upgradeNotice: some View {
        if let notice = model.searchUpgradeNotice {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle")
                    .font(.caption)
                Text(notice)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(DSHTheme.labelSecondary)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("search.upgrade")
        }
    }

    /// 连接器拒绝这次搜索时的提示（FR-013：拒绝 ≠ 没有结果）。原因来自连接器，
    /// 没有它的话读者只会看到空列表，以为"确实没搜到"。
    @ViewBuilder
    private var refusalNotice: some View {
        if let notice = model.searchRefusalNotice {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption)
                Text(notice)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(DSHTheme.labelSecondary)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("search.refusal")
        }
    }

    /// 未灌全（`user_inputs_synced_at` 为空）时的一等状态行（T040）：面板照常显示
    /// 本地已有的命中，同时明说"这份列表还没灌全"。
    ///
    /// 放**顶部**而不是 footer：footer 在列表末尾，命中一多就得滑到底才看得见，而这条
    /// 恰恰是"别以为这就是全部"的提醒，必须一眼可见（与 `upgradeNotice` 同位）。
    @ViewBuilder
    private var syncNotice: some View {
        if onlyMine, isUserInputsSynced == false {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("同步中…")
                    .font(.caption)
                Spacer(minLength: 0)
            }
            .foregroundStyle(DSHTheme.labelSecondary)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("search.sync")
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                field
                filter
                syncNotice
                upgradeNotice
                refusalNotice
                Hairline()
                results
            }
            .background(DSHTheme.background)
            .navigationTitle("会话内搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onAppear {
            scheduleSearch(immediate: true)
            // 不抢焦点：面板的默认态是"能一眼看到并点选"，键盘会把列表盖掉一半。
            // 想搜关键词的点一下输入框就行。
            // T040 起浏览态（「只看我的提问」）直接读本地全量库，一次就位，没有"第一页"
            // 要等；`watchUserInputSyncState()` 负责在灌全时把它变完整。
        }
        // 切到「只看我的提问」：先按需把这个会话灌上（(a)），再盯着完整性标记。
        // 面板本来就有"同步中…"状态与 1.5 秒轮询，所以这里只负责**把灌库跑起来**。
        .task(id: onlyMine) {
            if onlyMine { await model.ensureUserInputsBackfilled() }
            await watchUserInputSyncState()
        }
        // 打字：防抖，只有停下来（或换了关键词）才真正搜一次。
        .onChange(of: query) { _, _ in
            scrollDrivenLoads = 0
            scheduleSearch()
        }
        .onChange(of: onlyMine) { _, _ in
            scrollDrivenLoads = 0
            scheduleSearch(immediate: true)
        }
        // 补页 / 往前翻历史之后范围变大，结果要跟着更新（读者不用重新打字）。
        .onChange(of: model.timeline.items.count) { _, _ in scheduleSearch() }
        .onChange(of: model.searchScopeVersion) { _, _ in scheduleSearch() }
    }

    // MARK: - 输入与筛选

    private var field: some View {
        HStack(spacing: DSHTheme.Spacing.tight) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DSHTheme.labelTertiary)
            TextField("搜索会话内容", text: $query)
                .font(DSHTheme.Typography.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isFocused)
                .accessibilityIdentifier("search.field")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DSHTheme.labelTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空")
            }
        }
        .padding(.horizontal, DSHTheme.Spacing.standard)
        .padding(.vertical, 9)
        .background(DSHTheme.layer2, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, DSHTheme.Spacing.loose)
        .padding(.top, DSHTheme.Spacing.tight)
    }

    /// 两个筛选做成胶囊按钮而不是系统分段控件：分段控件在 XCUITest 里点了不切换
    /// （见 14 号用例踩过的坑），而这两颗本来就是"选一个"的语义。
    private var filter: some View {
        HStack(spacing: DSHTheme.Spacing.tight) {
            chip("全部内容", selected: !onlyMine) {
                onlyMine = false
                scrollDrivenLoads = 0
                scheduleSearch(immediate: true)
            }
            .accessibilityIdentifier("search.scope.all")
            chip("只看我的提问", selected: onlyMine) {
                onlyMine = true
                scrollDrivenLoads = 0
                // 收起键盘，让"我原来问过什么"这份列表整屏可见；想按关键词缩小范围
                // 再点输入框。
                isFocused = false
                // 只排这一次搜索：T040 起「我问过的」直接读本地全量库（瞬时、零网络），
                // 不再有"先取一页连接器"这一步（原来的 `requestLoad()` 已删）。
                scheduleSearch(immediate: true)
            }
            .accessibilityIdentifier("search.scope.mine")
            Spacer()
        }
        .padding(.horizontal, DSHTheme.Spacing.loose)
        .padding(.bottom, DSHTheme.Spacing.tight)
    }

    private func chip(_ title: LocalizedStringKey, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(selected ? Color.white : DSHTheme.labelSecondary)
                .padding(.horizontal, DSHTheme.Spacing.standard)
                .padding(.vertical, 5)
                .background(selected ? DSHTheme.brand : DSHTheme.layer3, in: Capsule())
                .overlay(Capsule().stroke(selected ? Color.clear : DSHTheme.border2, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 结果

    /// 结果区永远是一个 `List`：空查询、空结果、有结果三种状态，加上底部那段
    /// 「继续往上找」。都放在同一个 List 里，是因为那颗按钮不属于某一种状态——
    /// 读者打开面板第一件事就可能是"先往上取一页再搜"（第一版把它藏在"有结果"分支里，
    /// 空查询时根本看不到，用例的 s21 就是这么挂的）。
    /// 结果区永远是一个 `List`：浏览态（只看我的提问、还没输关键词）、空态、
    /// 命中态三种，加上底部那段「继续往上找」。都放在同一个 List 里，是因为那颗按钮
    /// 不属于某一种状态——读者打开面板第一件事就可能是"先往上取一页再搜"。
    @ViewBuilder
    private var results: some View {
        List {
            if isBrowsing {
                Section {
                    if hits.isEmpty {
                        // 空列表必须说清是哪一种空（T040）：还没灌到 ≠ 确实没有。
                        Text(isUserInputsSynced == false
                             ? "本机还没同步到你的提问。"
                             : "这段历史里还没有你发过的消息。")
                            .font(DSHTheme.Typography.caption)
                            .foregroundStyle(DSHTheme.labelTertiary)
                    }
                    ForEach(hits) { hit in
                        Button {
                            pick(hit)
                        } label: {
                            row(hit)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("search.hit.\(hit.id)")
                        .onAppear {
                            visibleHitIds.insert(hit.id)
                            prefetchIfRunningLow()
                        }
                        .onDisappear { visibleHitIds.remove(hit.id) }
                    }
                } header: {
                    Text(summary)
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelTertiary)
                } footer: {
                    // 浏览态恒为本地全量库（T040 起没有连接器岔路），所以不再有
                    // "上面还有更早的可以继续翻"那句。
                    Text("由近及远。")
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelTertiary)
                }
            } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section {
                    Text("输入关键词，搜已加载的这段会话记录；或者切到「只看我的提问」，直接点选你问过的那句。")
                        .font(DSHTheme.Typography.caption)
                        .foregroundStyle(DSHTheme.labelTertiary)
                }
            } else if hits.isEmpty {
                Section {
                    // 「只看我的提问」命中来自本机全量库（T040 起无连接器岔路），
                    // 文案不能再说是"已加载的这段"。
                    Text(onlyMine ? "本机记录里没有你问过的「\(query)」。"
                                  : "已加载的这段里没有「\(query)」。")
                        .font(DSHTheme.Typography.caption)
                        .foregroundStyle(DSHTheme.labelSecondary)
                }
            } else {
                Section {
                    ForEach(hits) { hit in
                        Button {
                            pick(hit)
                        } label: {
                            row(hit)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("search.hit.\(hit.id)")
                        .onAppear {
                            visibleHitIds.insert(hit.id)
                            prefetchIfRunningLow()
                        }
                        .onDisappear { visibleHitIds.remove(hit.id) }
                    }
                } header: {
                    Text(summary)
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelTertiary)
                }
            }
            olderSection
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // 读者滑动 = 新一轮预读预算（偏移变了才算滑动；追加行不会改变偏移，
        // 所以这里不会被自动预读自己触发）。
        .modifier(SheetScrollWatcher { offset in
            if let last = lastScrollOffset, abs(offset - last) > 8 { scrollDrivenLoads = 0 }
            lastScrollOffset = offset
        })
    }

    /// 浏览态：只看我的提问，且还没输入关键词。internal：动作半边要用。
    var isBrowsing: Bool {
        onlyMine && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 统计行按来源分开说：连接器是远端全量（"已搜 N"写成本机窗口大小会误导成
    /// 只搜了本地），本地全量库与窗口无关；只有降级窗口路径才报窗口大小。
    /// 量词统一为「条」（2026-10 用户反馈："行"与"条"并用像一个东西，分不清）。
    private var summary: String {
        if isBrowsing {
            return String(format: String(localized: "我的提问 %lld 条"), hits.count)
        }
        switch searchSource {
        case .connector:
            // 只有**扫到最老那一片**（`pageHasMore == false`）才配说"全部历史"：这话原来
            // 在第一页就说了，而扫描一页最多 4 片（2000 seq/片），数字其实还在长。
            if pageHasMore, let progress = searchProgress, progress.totalChunks > 0 {
                return String(format: String(localized: "命中 %lld 条 · 已扫 %lld/%lld 片"),
                              hits.count, progress.scannedChunks, progress.totalChunks)
            }
            if pageHasMore {
                return String(format: String(localized: "命中 %lld 条 · 还在往前找"), hits.count)
            }
            return String(format: String(localized: "命中 %lld 条（已搜全部历史）"), hits.count)
        case .localStore:
            return String(format: String(localized: "命中 %lld 条（本机记录）"), hits.count)
        case .localWindow:
            return String(format: String(localized: "已搜 %lld 条 · 命中 %lld 条"),
                          model.searchItems.count, hits.count)
        }
    }

    /// 列表底部：备货不够时显示转圈，读完了显示"到头了"，中间态给一颗可点的兜底。
    ///
    /// 真正的触发在 `prefetchIfRunningLow()`（按可见范围算余量）；这一行只是把状态
    /// 说清楚，外加一个"点了就再读一页"的兜底——自动预加载万一没触发，读者还有手可用。
    @ViewBuilder
    private var olderSection: some View {
        if searchSource == .localStore {
            // T025：本地全量库没有"更早的一页"。只在**灌全后**才说"已同步到本机"——
            // 还在灌的时候把它写成已同步，就和顶部「同步中…」自相矛盾（T040）。
            if isUserInputsSynced == true {
                Section {
                    Text("提问已同步到本机，列表与搜索不联网。")
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DSHTheme.Spacing.tight)
                        .accessibilityIdentifier("search.older.local")
                }
            }
        } else if canRequestAnotherPage {
            Section {
                Button {
                    requestLoad()
                } label: {
                    HStack(spacing: DSHTheme.Spacing.hairline) {
                        if isLoadingMore { ProgressView().controlSize(.mini) }
                        Text(isLoadingMore ? "正在往前读…" : "继续往下滑，会接着往前读")
                            .font(DSHTheme.Typography.micro)
                            .foregroundStyle(isLoadingMore ? DSHTheme.labelTertiary : DSHTheme.brand)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DSHTheme.Spacing.tight)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("search.older")
                .onAppear { prefetchIfRunningLow(fallbackWhenNothingVisible: true) }
            } footer: {
                // 连接器覆盖整个会话，这句话只对"本地窗口"的降级路径成立。
                Text(searchSource == .connector ? "继续往下滑，会一段一段往前扫。"
                                                : "搜索只覆盖已经读到手机上的那段历史。")
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.labelTertiary)
            }
        } else {
            Section {
                Text("已经读到这段会话的最开头。")
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.labelTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DSHTheme.Spacing.tight)
                    .accessibilityIdentifier("search.older.done")
            }
        }
    }

    private func row(_ hit: TranscriptSearchHit) -> some View {
        HStack(alignment: .top, spacing: DSHTheme.Spacing.tight) {
            Image(systemName: icon(hit.role))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hit.role == .me ? DSHTheme.brand : DSHTheme.labelTertiary)
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                highlighted(hit)
                    .font(DSHTheme.Typography.caption)
                    .foregroundStyle(DSHTheme.labelPrimary)
                    .lineLimit(3)
                Text(isBrowsing ? String(format: String(localized: "第 %lld 条"), hit.seq)
                                : String(format: String(localized: "%@ · 第 %lld 条"), label(hit.role), hit.seq))
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.labelTertiary)
            }
        }
        .padding(.vertical, 2)
    }

    // 命中片段的 markdown 渲染（`highlighted`/`inlineMarkdown`）在
    // TranscriptSearchSheet+HitRow.swift（500 行上限拆分）。

    private func icon(_ role: TranscriptSearchHit.Role) -> String {
        switch role {
        case .me: return "person.fill"
        case .agent: return "sparkle"
        case .tool: return "wrench.and.screwdriver"
        }
    }

    private func label(_ role: TranscriptSearchHit.Role) -> String {
        switch role {
        case .me: return String(localized: "我")
        case .agent: return String(localized: "助手")
        case .tool: return String(localized: "工具")
        }
    }

}

/// 监听面板列表的滚动偏移，只为一件事：判断"读者真的滑了"（追加行不会改变偏移）。
///
/// 不用 `DragGesture`：在 `List` 上挂 drag 会吃掉行内的点击（2026-09-25 实测：
/// 点了结果面板不关）。iOS 17 没有这个 API，那边就只剩"有产出才继续预读"这条腿——
/// 表现为读者滑到底后可能要再点一下底部那行，属于可接受的降级。
private struct SheetScrollWatcher: ViewModifier {
    let onChange: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { _, offset in
                onChange(offset)
            }
        } else {
            content
        }
    }
}
#endif
