import DSHKit
import SwiftUI

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
    var onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var onlyMine = false
    @State private var hits: [TranscriptSearchHit] = []
    @State private var isLoadingMore = false
    /// 现在**真的在屏幕上**的结果行（行自己上报，用于算"底下还剩几条"）。
    @State private var visibleHitIds: Set<String> = []
    /// 读者上次滑动之后，已经"没有新行产出"地预读了几页（滑动会把它清零）。
    @State private var scrollDrivenLoads = 0
    /// 最近一次滚动偏移（用来判"读者真的滑了"；追加行不会改变它）。
    @State private var lastScrollOffset: CGFloat?
    /// 上一次看到的行数，用来判这一轮预读有没有产出。
    @State private var lastRowCount = 0
    /// 可见范围之外至少要先备好这么多条：不够就继续往前读。
    ///
    /// 为什么不是"底部哨兵露面才读"：哨兵行只在 `onAppear` 时触发一次，之后它一直
    /// 留在屏幕上（新行是追加在它上面的？不，是追加在末尾、把它挤下去之前）——
    /// 2026-09-25 用户实测"继续下拉会往前读"根本没生效：第一页之后哨兵没重建，
    /// 就再没有第二次触发。改成按可见范围算余量，读到够为止。
    private static let prefetchAhead = 10
    /// 读者滑一次最多"没有新行产出"地预读几页。
    ///
    /// 为什么要有这个上限：关键词很"冷"的时候（比如整段历史里只有 1 条命中），
    /// "可见范围外备够 10 条"这个条件**永远满足不了**，不限量就会把整段历史读完
    /// （2026-09-25 实测就是这么把 43 页全读光的）。滑动一次最多试探 4 页，
    /// 读者再滑一次就再试探 4 页——仍然是"一边下拉一边读"，但不会自己跑到底。
    private static let maxScrollDrivenLoads = 4
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                field
                filter
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
            refresh()
            // 不抢焦点：面板的默认态是"能一眼看到并点选"，键盘会把列表盖掉一半。
            // 想搜关键词的点一下输入框就行。
            // 浏览态的第一页交给列表底部的哨兵行去取（它一露面就会触发）。
        }
        .onChange(of: query) { _, _ in
            scrollDrivenLoads = 0
            refresh()
        }
        .onChange(of: onlyMine) { _, _ in refresh() }
        // 补页 / 往前翻历史之后范围变大，结果要跟着更新（读者不用重新打字）。
        .onChange(of: model.timeline.items.count) { _, _ in refresh() }
        .onChange(of: model.searchScopeVersion) { _, _ in refresh() }
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
                refresh()
            }
            .accessibilityIdentifier("search.scope.all")
            chip("只看我的提问", selected: onlyMine) {
                onlyMine = true
                scrollDrivenLoads = 0
                // 收起键盘，让"我原来问过什么"这份列表整屏可见；想按关键词缩小范围
                // 再点输入框。
                isFocused = false
                refresh()
                // 只先取一页：读到多少显示多少，剩下的由列表往下滑时一页页接着读
                // （见 `olderSection` 的哨兵行）。读者看不到"等它读完"的阻塞。
                Task { await loadMore() }
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
                        Text(isLoadingMore ? "正在往前读…" : "这段历史里还没有你发过的消息。")
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
                    Text("由近及远。上面还有更早的时候，可以继续往前翻。")
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
                    Text(onlyMine ? "已加载的这段里没有你问过的「\(query)」。"
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

    /// 浏览态：只看我的提问，且还没输入关键词。
    private var isBrowsing: Bool {
        onlyMine && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var summary: String {
        if isBrowsing {
            return String(format: String(localized: "我的提问 %lld 条"), hits.count)
        }
        let searched = model.searchItems.count
        if onlyMine {
            return String(format: String(localized: "已搜 %lld 行 · 我的提问 %lld 条"), searched, hits.count)
        }
        return String(format: String(localized: "已搜 %lld 行 · 命中 %lld 条"), searched, hits.count)
    }

    /// 列表底部：备货不够时显示转圈，读完了显示"到头了"，中间态给一颗可点的兜底。
    ///
    /// 真正的触发在 `prefetchIfRunningLow()`（按可见范围算余量）；这一行只是把状态
    /// 说清楚，外加一个"点了就再读一页"的兜底——自动预加载万一没触发，读者还有手可用。
    @ViewBuilder
    private var olderSection: some View {
        if model.canExtendSearch {
            Section {
                Button {
                    Task { await loadMore() }
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
                Text("搜索只覆盖已经读到手机上的那段历史。")
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

    /// 片段 + 命中处加粗上色。用字符偏移切，避免把 `AttributedString` 的
    /// 索引和 `String` 的索引混在一起（片段是压过空白的，索引体系不同）。
    private func highlighted(_ hit: TranscriptSearchHit) -> Text {
        let characters = Array(hit.snippet)
        let start = min(max(0, hit.highlightStart), characters.count)
        let end = min(characters.count, start + max(0, hit.highlightLength))
        let head = String(characters[0..<start])
        let match = String(characters[start..<end])
        let tail = String(characters[end...])
        return Text(head)
            + Text(match).bold().foregroundColor(DSHTheme.brand)
            + Text(tail)
    }

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

    // MARK: - 动作

    private func refresh() {
        // 浏览态列全部提问；否则按关键词在"时间线 + 往前读进来的缓冲"里搜。
        hits = isBrowsing
            ? TranscriptSearch.myQuestions(in: model.searchItems)
            : TranscriptSearch.hits(in: model.searchItems, query: query, onlyMine: onlyMine)
        // 结果集换了（切筛选、改关键词、缓冲变大）：可见集合按 id 保留即可，
        // 余量重新算一次。这一步不能省——它也是"点一下只读一页就够显示"的入口。
        visibleHitIds = visibleHitIds.filter { id in hits.contains { $0.id == id } }
        prefetchIfRunningLow()
    }

    private func pick(_ hit: TranscriptSearchHit) {
        onPick(hit.id)
        dismiss()
    }

    /// 往搜索缓冲里再取一页（**不动时间线**，也就不会挪动读者的位置）。
    /// 可见范围之外还剩几条？不够 `prefetchAhead` 就继续往前读——读完再判一次，
    /// 所以"一旦触发就会连着读到够"（页里通常只有几条提问，一次要读好几页才攒够 10 条）。
    private func prefetchIfRunningLow(fallbackWhenNothingVisible: Bool = false) {
        guard !isLoadingMore, model.canExtendSearch, !hits.isEmpty else { return }
        let lastVisible = hits.lastIndex { visibleHitIds.contains($0.id) }
        guard let lastVisible else {
            // 还没有行上报可见（首次布局那一瞬间）：只有底部那行露面时才兜底读一页。
            if fallbackWhenNothingVisible { Task { await loadMore() } }
            return
        }
        let remaining = hits.count - 1 - lastVisible
        ViewportProbe.note("search.buffer", [
            "rows": String(hits.count),
            "visible": String(visibleHitIds.count),
            "remaining": String(remaining),
        ])
        guard remaining <= Self.prefetchAhead else { return }
        // 一轮滑动（或一次筛选/关键词变更）里最多自动读 `maxScrollDrivenLoads` 页：
        // 读者再滑一下就又有这么多。**不能**按"有产出就一直读"放开——关键词命中很多时
        // 那条路会把整段历史读完（2026-09-25 实测：搜 circleboom 一次读掉 9 页到 seq 0）。
        let produced = hits.count > lastRowCount
        guard scrollDrivenLoads < Self.maxScrollDrivenLoads else {
            ViewportProbe.note("search.prefetch.budget", [
                "rows": String(hits.count),
                "remaining": String(remaining),
                "budget": String(scrollDrivenLoads),
            ], force: true)
            return
        }
        scrollDrivenLoads += 1
        ViewportProbe.note("search.prefetch", [
            "rows": String(hits.count),
            "remaining": String(remaining),
            "produced": produced ? "1" : "0",
            "budget": String(scrollDrivenLoads),
        ], force: true)
        Task { await loadMore() }
    }

    private func loadMore() async {
        guard !isLoadingMore, model.canExtendSearch else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        // 探针：记下"追加前后"的条数与**第一条**。追加只发生在列表末尾，所以第一条
        // 必须始终不变——这是"加载无感、列表不跳"的机器判据（`firstBefore == firstAfter`）。
        let firstBefore = hits.first?.id
        let countBefore = hits.count
        await model.extendSearchHistory()
        refresh()
        ViewportProbe.note("search.page", [
            "before": String(countBefore),
            "after": String(hits.count),
            "firstBefore": firstBefore ?? "-",
            "firstAfter": hits.first?.id ?? "-",
            "kept": firstBefore == hits.first?.id ? "1" : "0",
        ], force: true)
        lastRowCount = hits.count
        // 追加进来的行在屏幕外，不会再触发 `onAppear`；所以这里主动再判一次余量，
        // 不够就接着读（"触发了就继续预加载"）。
        prefetchIfRunningLow()
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
