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
            isFocused = true
        }
        .onChange(of: query) { _, _ in refresh() }
        .onChange(of: onlyMine) { _, _ in refresh() }
        // 补页之后已加载范围变大，结果要跟着更新（读者不用重新打字）。
        .onChange(of: model.timeline.items.count) { _, _ in refresh() }
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
            chip("全部内容", selected: !onlyMine) { onlyMine = false }
                .accessibilityIdentifier("search.scope.all")
            chip("只看我的提问", selected: onlyMine) { onlyMine = true }
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
    @ViewBuilder
    private var results: some View {
        List {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section {
                    Text("输入关键词，搜已加载的这段会话记录。")
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
                            onPick(hit.id)
                            dismiss()
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

    private var summary: String {
        let loaded = model.timeline.items.count
        if onlyMine {
            return String(format: String(localized: "已加载 %lld 条 · 我的提问 %lld 条"), loaded, hits.count)
        }
        return String(format: String(localized: "已加载 %lld 条 · 命中 %lld 条"), loaded, hits.count)
    }

    @ViewBuilder
    private var olderSection: some View {
        if model.hasOlder {
            Section {
                Button {
                    Task { await loadMore() }
                } label: {
                    HStack(spacing: DSHTheme.Spacing.hairline) {
                        if isLoadingMore { ProgressView().controlSize(.mini) }
                        Text(isLoadingMore ? "正在往上找…" : "上面还有更早的消息，继续往上找")
                            .font(DSHTheme.Typography.caption)
                    }
                    .foregroundStyle(DSHTheme.brand)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("search.older")
            } footer: {
                Text("搜索只覆盖已经加载到手机上的那段历史。")
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.labelTertiary)
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
                Text(String(format: String(localized: "%@ · 第 %lld 条"), label(hit.role), hit.seq))
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
        hits = TranscriptSearch.hits(in: model.timeline.items, query: query, onlyMine: onlyMine)
    }

    private func loadMore() async {
        guard !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        await model.loadOlder()
        refresh()
    }
}
