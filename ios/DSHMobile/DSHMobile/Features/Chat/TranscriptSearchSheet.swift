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
    /// 浏览态正在自动往前翻历史。
    @State private var isExtending = false
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
        .onChange(of: query) { _, _ in refresh() }
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
                refresh()
            }
            .accessibilityIdentifier("search.scope.all")
            chip("只看我的提问", selected: onlyMine) {
                onlyMine = true
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
                        Text(isExtending ? "正在往前翻历史…" : "这段历史里还没有你发过的消息。")
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

    /// 列表底部：滑到这里就再往前读一页（无限滚动），读完给出明确交代。
    ///
    /// 为什么不一次读完：长会话整段历史要 9–43 页（实测 20_lieGuo 12968 条），
    /// 一次读完既让读者盯着转圈、又白读一堆用不上的记录。所以按读者的滑动节奏来：
    /// 新行**追加在列表末尾**，已经看到的那几行不动，界面不跳。
    @ViewBuilder
    private var olderSection: some View {
        if model.canExtendSearch {
            Section {
                HStack(spacing: DSHTheme.Spacing.hairline) {
                    if isLoadingMore { ProgressView().controlSize(.mini) }
                    Text(isLoadingMore ? "正在往前读…" : "继续下拉会接着往前读")
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DSHTheme.Spacing.tight)
                .onAppear {
                    // 哨兵露面 = 读者滑到了底部：接着读一页。没在读的时候不重复触发。
                    guard !isLoadingMore else { return }
                    Task { await loadMore() }
                }
                .accessibilityIdentifier("search.older")
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
    }

    private func pick(_ hit: TranscriptSearchHit) {
        onPick(hit.id)
        dismiss()
    }

    /// 往搜索缓冲里再取一页（**不动时间线**，也就不会挪动读者的位置）。
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
    }
}
