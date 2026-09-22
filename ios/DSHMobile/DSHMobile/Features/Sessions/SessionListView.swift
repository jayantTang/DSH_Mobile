import DSHKit
import SwiftUI

/// The session list: the phone's equivalent of the desktop client's sidebar.
///
/// It is deliberately sparser than the desktop sidebar. A phone screen holds a
/// handful of rows, so anything that is reference material rather than current
/// work — subagent transcripts, sessions with no workspace — stays collapsed
/// until asked for.
struct SessionListView: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(HostEventHub.self) private var hub
    @Environment(UpdateChecker.self) private var updates
    @Environment(\.openURL) private var openURL
    @Bindable var model: SessionListModel
    var onOpenConnections: () -> Void
    var onOpenSettings: () -> Void
    /// Called with a freshly created session's id so the caller can open it.
    var onOpenSession: (String) -> Void = { _ in }

    @State private var isLooseExpanded = false
    @State private var isArchivedExpanded = false
    @State private var isCreatingSession = false
    /// The session just archived, so the swipe can be taken back.
    @State private var justArchived: SessionSummary?
    @State private var archiveFailure: String?

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            header
            Hairline()
            content
        }
        .background(DSHTheme.background)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let published = updates.available {
                UpdateBanner(published: published) {
                    if let url = URL(string: published.installPage) { openURL(url) }
                }
            }
        }
        // 不等连接：离线冷启动也要先把上次的列表画出来（否则就是空白+转圈）。
        .task { model.loadCachedList() }
        // 待答集合的唯一来源是 `$events` 的 waterfall（host 的会话摘要里没有这个
        // 信息：等回答时它照样报 running）。把它同步进 model，行状态与计数才看得见它；
        // hub 是 @Observable，这里读一下就等于订阅了变化。
        .task(id: hub.pending.map(\.sessionId)) {
            model.waitingSessionIds = Set(hub.pending.map(\.sessionId))
        }
        .searchable(text: $model.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索会话")
        .refreshable { await model.refresh() }
        .alert("归档失败", isPresented: Binding(
            get: { archiveFailure != nil },
            set: { if !$0 { archiveFailure = nil } }
        )) {
            Button("好", role: .cancel) { archiveFailure = nil }
        } message: {
            Text(archiveFailure ?? "")
        }
        .sheet(isPresented: $isCreatingSession) {
            NewSessionView(model: model, store: store) { sessionId in
                // A session is created inside a workspace, so it lands in that
                // directory's group. This stays as the fallback for a host that
                // hands back a session no workspace accounts for: unfolding the
                // bucket is what makes such a row visible at all.
                if model.loose.contains(where: { $0.sessionId == sessionId }) {
                    isLooseExpanded = true
                }
                onOpenSession(sessionId)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let archived = justArchived { archivedNotice(archived) }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onOpenConnections) {
                    ConnectionStatusButton(store: store)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("连接管理")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("设置")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isCreatingSession = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("新建会话")
                .accessibilityIdentifier("session.new")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DSHTheme.Spacing.tight) {
            VStack(alignment: .leading, spacing: 1) {
                Text("会话")
                    .font(DSHTheme.Typography.title)
                    .foregroundStyle(DSHTheme.labelPrimary)
                Text(statusLine)
                    .font(DSHTheme.Typography.caption)
                    .foregroundStyle(DSHTheme.labelTertiary)
            }
            Spacer(minLength: 0)
            HStack(spacing: DSHTheme.Spacing.hairline) {
                // 待答的总数包含折叠桶里的：那个桶默认收着，不把它算进来的话，
                // 一条"在等你回答"的会话可以在里面烂着而列表顶部毫无提示
                // （2026-09-22 验收时就撞上了：probe 夹具会话全落在未分组里）。
                if model.waitingCount + model.ungroupedWaitingCount > 0 {
                    Badge(text: String(localized: "\(model.waitingCount + model.ungroupedWaitingCount) 等你回应"), tone: .attention)
                }
                if model.runningCount > 0 {
                    Badge(text: String(localized: "\(model.runningCount) 运行中"), tone: .brand)
                }
                if model.ungroupedRunningCount > 0 {
                    Badge(text: String(localized: "未分组 \(model.ungroupedRunningCount)"), tone: .neutral)
                }
            }
        }
        .padding(.horizontal, DSHTheme.Spacing.loose)
        .padding(.vertical, DSHTheme.Spacing.tight)
    }

    private var statusLine: String {
        switch store.state {
        case .connected:
            // What is actually on screen. Counting the folded ungrouped bucket
            // made this disagree with the list — and with the desktop, whose
            // sidebar shows the same workspaces.
            let count = model.groups.reduce(0) { $0 + $1.sessions.count }
            if model.isUsingFallbackGrouping {
                // Say so rather than looking correct: directory grouping is not
                // the desktop's grouping, and a silent fallback once hid a real
                // defect behind something that looked right.
                return String(localized: "\(count) 个会话 · 工作区未加载，暂按目录分组")
            }
            // 屏幕上是缓存时把话说明白：列表能用，但它不是"现在"。
            return model.isShowingSnapshot
                ? String(localized: "\(count) 个会话 · 显示上次数据")
                : String(localized: "\(count) 个会话")
        case .connecting(let message):
            return model.isShowingSnapshot ? String(localized: "\(message) · 显示上次数据") : message
        case .failed(let message):
            return model.isShowingSnapshot ? String(localized: "\(message) · 显示上次数据") : message
        case .disconnected:
            return model.isShowingSnapshot ? String(localized: "未连接 · 显示上次数据") : String(localized: "未连接")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading where model.groups.isEmpty && model.loose.isEmpty:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message) where model.groups.isEmpty && model.loose.isEmpty:
            ErrorStateView(message: message) {
                Task { await model.refresh() }
            }

        default:
            if model.isEmpty {
                EmptyStateView(
                    icon: "tray",
                    title: model.searchText.isEmpty ? "还没有会话" : "没有匹配的会话",
                    message: model.searchText.isEmpty
                        ? "在电脑端开始一个会话，它会立刻出现在这里。"
                        : "换一个关键词试试。"
                )
            } else {
                list
            }
        }
    }

    private var list: some View {
        List {
            ForEach(model.groups) { group in
                Section {
                    ForEach(group.sessions) { session in
                        // Subagent transcripts are no longer listed: the chip
                        // ("👥 3") told nobody anything, and opening one led to
                        // an audit trail with no action to take on it.
                        parentRow(session: session)
                    }
                } header: {
                    WorkspaceHeader(title: group.title, path: group.path, home: store.hostHome)
                }
            }

            if !model.loose.isEmpty {
                Section {
                    if isLooseExpanded {
                        ForEach(model.loose) { session in
                            childRow(session, archivable: true)
                        }
                    }
                } header: {
                    LooseHeader(
                        count: model.loose.count,
                        running: model.ungroupedRunningCount,
                        waiting: model.ungroupedWaitingCount,
                        isExpanded: $isLooseExpanded
                    )
                }
            }

            // Archived sessions get a home of their own. Hiding them for good
            // is how "tidy up old sessions" turns into "lose old sessions": the
            // host keeps them and still lists them, so the phone keeps them
            // reachable, one line until asked for.
            if !model.archivedSessions.isEmpty {
                Section {
                    if isArchivedExpanded {
                        ForEach(model.archivedSessions) { session in
                            archivedRow(session)
                        }
                    }
                } header: {
                    ArchivedHeader(
                        count: model.archivedSessions.count,
                        isExpanded: $isArchivedExpanded
                    )
                } footer: {
                    if isArchivedExpanded {
                        // This DSH version has no un-archive call, so say what
                        // the phone can do rather than offering a button that
                        // would do nothing.
                        Text("归档的会话仍可打开查看；此版本的 DSH 没有取消归档的接口。")
                            .font(DSHTheme.Typography.micro)
                            .foregroundStyle(DSHTheme.labelTertiary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .accessibilityIdentifier("session.list")
    }

    // MARK: - Actions

    /// Files a session away, with a way back.
    ///
    /// Archiving is the phone's answer to a list that only grows: old sessions
    /// stay in the host's history but stop competing with current work.
    private func archive(_ session: SessionSummary) {
        Task {
            let ok = await model.setArchived(true, sessionId: session.sessionId)
            if ok {
                justArchived = session
                // Long enough to notice, short enough not to be in the way.
                try? await Task.sleep(for: .seconds(6))
                if justArchived?.sessionId == session.sessionId { justArchived = nil }
            } else if let failure = model.archiveError {
                archiveFailure = failure
            }
        }
    }

    /// Says what happened and how to get it back.
    ///
    /// No undo button: the host's `workspace/archiveSession` is one-way (it
    /// accepts `archived: false` and ignores it, and there is no unarchive
    /// method), so a button here would be a lie. Nothing is deleted — the
    /// session is only taken out of the workspace surfaces, and the desktop
    /// client can put it back.
    private func archivedNotice(_ session: SessionSummary) -> some View {
        HStack(spacing: DSHTheme.Spacing.tight) {
            Text("已归档「\(session.displayTitle)」")
                .font(DSHTheme.Typography.caption)
                .foregroundStyle(DSHTheme.labelPrimary)
                .lineLimit(1)
                // Identifiers do not stay put when set on a container: SwiftUI
                // pushes them down to the children, which overwrote the undo
                // button's own id and made it unaddressable.
                .accessibilityIdentifier("session.archive.banner")
            Spacer(minLength: 0)
            Text("可在电脑端找回")
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelTertiary)
                .accessibilityIdentifier("session.archive.hint")
        }
        .padding(.horizontal, DSHTheme.Spacing.loose)
        .padding(.vertical, DSHTheme.Spacing.tight)
        .background(DSHTheme.layer1)
        .overlay(alignment: .top) { Hairline() }
    }

    // MARK: - Rows

    /// A session the user might be working on, with its subagent count.
    ///
    /// The disclosure is a separate tap target from the row itself, so opening
    /// the session and unfolding its subagents never fight over one gesture.
    private func parentRow(session: SessionSummary) -> some View {
        HStack(spacing: DSHTheme.Spacing.hairline) {
            NavigationLink(value: session.sessionId) {
                SessionRow(session: session, rowState: model.state(of: session),
                           home: store.hostHome,
                           isJustCreated: session.sessionId == model.lastCreatedSessionId)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(session.sessionId == model.lastCreatedSessionId
                                     ? "session.row.created"
                                     : "session.row.\(session.sessionId)")
            .swipeActions(edge: .trailing) {
                Button {
                    archive(session)
                } label: {
                    Label("归档", systemImage: "archivebox")
                }
                .tint(DSHTheme.brand)
                .accessibilityIdentifier("session.archive.\(session.sessionId)")
            }

        }
        .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }


    /// A row inside the archived section: readable, and marked as archived.
    private func archivedRow(_ session: SessionSummary) -> some View {
        NavigationLink(value: session.sessionId) {
            SessionRow(session: session, rowState: model.state(of: session),
                       home: store.hostHome, isChild: true)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 10))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityIdentifier("session.archived.row.\(session.sessionId)")
    }

    /// A subagent row, or a session shown inside the collapsed reference group.
    ///
    /// `archivable` separates the two: a loose session is exactly the old work
    /// this list needs tidying of, while a subagent row belongs to its parent
    /// and is not the user's to file away.
    private func childRow(_ session: SessionSummary, archivable: Bool = false) -> some View {
        NavigationLink(value: session.sessionId) {
            SessionRow(session: session, rowState: model.state(of: session),
                       home: store.hostHome, isChild: true,
                       isJustCreated: session.sessionId == model.lastCreatedSessionId)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 10))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityIdentifier(session.sessionId == model.lastCreatedSessionId
                                 ? "session.row.created"
                                 : "session.row.\(session.sessionId)")
        // A swipe reveals the button; it does not archive by itself. Filing
        // something away should take two deliberate gestures, not one long one.
        .swipeActions(edge: .trailing) {
            if archivable {
                Button {
                    archive(session)
                } label: {
                    Label("归档", systemImage: "archivebox")
                }
                .tint(DSHTheme.brand)
                .accessibilityIdentifier("session.archive.\(session.sessionId)")
            }
        }
    }
}

// MARK: - Section headers

/// The collapsed home for archived sessions.
///
/// Same shape as the ungrouped header: one line until asked for. It exists so
/// archiving reads as "put away" rather than "gone" — the sessions are still
/// there, still openable, and say so.
private struct ArchivedHeader: View {
    let count: Int
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: DSHTheme.Spacing.hairline) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                Image(systemName: "archivebox")
                    .font(.system(size: 10, weight: .medium))
                Text("已归档")
                    .font(DSHTheme.Typography.micro)
                Text("\(count)")
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.labelDimmed)
                Spacer(minLength: 0)
            }
            .foregroundStyle(DSHTheme.labelTertiary)
            .textCase(nil)
            .padding(.top, DSHTheme.Spacing.tight)
            .padding(.horizontal, DSHTheme.Spacing.loose)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("session.archived")
        .accessibilityLabel(isExpanded ? "收起已归档 \(count) 个会话" : "展开已归档 \(count) 个会话")
    }
}

/// A workspace heading, matching the desktop sidebar's group label.
private struct WorkspaceHeader: View {
    let title: String
    let path: String
    let home: String?

    var body: some View {
        HStack(spacing: DSHTheme.Spacing.hairline) {
            Image(systemName: "folder")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DSHTheme.labelTertiary)
            Text(title)
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelTertiary)
                .lineLimit(1)
                // The identifier rides the visible label: an identifier on the
                // combined header container never reached the tree (the same
                // lesson as the row's state labels).
                .accessibilityIdentifier("session.group.\(title)")
            Spacer(minLength: 0)
        }
        .textCase(nil)
        .padding(.top, DSHTheme.Spacing.tight)
        .padding(.horizontal, DSHTheme.Spacing.loose)
        // A plain section header is decoration to the accessibility tree, which
        // is why the first version of TC-MOB-26 could not find a group at all.
        // Combined into one element so a run can name it and compare positions.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("工作区 \(PathFormat.short(path, home: home))")
    }
}

/// The collapsed home for sessions that are not part of a workspace.
///
/// These are rarely what the user is looking for, so they cost one line until
/// asked for, instead of a screenful of rows competing with live work.
private struct LooseHeader: View {
    let count: Int
    /// Running sessions inside the bucket, so folding it cannot hide them.
    let running: Int
    /// Sessions inside the bucket that are waiting on the user — folding those
    /// away would hide the one thing the list exists to surface.
    var waiting: Int = 0
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: DSHTheme.Spacing.hairline) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                Image(systemName: "tray")
                    .font(.system(size: 10, weight: .medium))
                Text("未分组")
                    .font(DSHTheme.Typography.micro)
                Text("\(count)")
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.labelDimmed)
                if waiting > 0 {
                    Badge(text: String(localized: "\(waiting) 等你回应"), tone: .attention)
                }
                if running > 0 {
                    Badge(text: String(localized: "\(running) 运行中"), tone: .brand)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(DSHTheme.labelTertiary)
            .textCase(nil)
            .padding(.top, DSHTheme.Spacing.tight)
            .padding(.horizontal, DSHTheme.Spacing.loose)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("session.ungrouped")
        .accessibilityLabel(isExpanded ? "收起未分组 \(count) 个会话" : "展开未分组 \(count) 个会话")
    }
}

// MARK: - Session row

/// Marks the session the app just created, so it can be told apart from the
/// other untitled rows.
struct CreatedBadge: View {
    var body: some View {
        Text("刚创建")
            .font(DSHTheme.Typography.micro)
            .foregroundStyle(DSHTheme.brand)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(DSHTheme.brandSubtle, in: Capsule())
    }
}

/// One session row: what it is, when it last moved, and how much it has cost.
///
/// The model name and full path deliberately do not appear here — both are
/// available on the session itself, where they are relevant, and repeating them
/// on every row is what made the list feel dense.
struct SessionRow: View {
    let session: SessionSummary
    /// What the leading dot says. Passed in rather than read from the model:
    /// the row is a pure view, and the model needs the phone's own view-log to
    /// answer it.
    var rowState: SessionRowState = .finishedSeen
    let home: String?
    var isChild: Bool = false
    /// Whether this is the session the app just created in this run.
    var isJustCreated: Bool = false

    private var projections: SessionProjectionValues? { session.projections?.values }

    var body: some View {
        HStack(spacing: DSHTheme.Spacing.tight) {
            if isChild {
                // An elbow keeps the parent/child relationship legible without
                // spending horizontal space on a disclosure control.
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(DSHTheme.labelDimmed)
                    .frame(width: 10)
            }

            // A read session draws nothing, but still reserves the dot's width:
            // without the spacer every title in the list shifts by 8pt when a
            // row is read.
            //
            // 待答和运行中共用这个圆点，区分交给整行底色与左侧竖条（见行底那两处）：
            // 圆点只负责"这一行有状态"，脉冲与否才是"它在不在动"。
            Group {
                if rowState == .finishedSeen {
                    Color.clear
                } else {
                    // 只有真在跑的才脉冲：等用户回应的那个是不动的。
                    StatusDot(level: statusLevel, animated: session.running && rowState == .running)
                }
            }
            .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DSHTheme.Spacing.hairline) {
                    Text(session.displayTitle)
                        .font(DSHTheme.Typography.bodyStrong)
                        .foregroundStyle(session.blank ? DSHTheme.labelTertiary : DSHTheme.labelPrimary)
                        .lineLimit(1)
                    if isJustCreated {
                        CreatedBadge()
                    }
                }

                HStack(spacing: DSHTheme.Spacing.hairline) {
                    if rowState == .waitingForYou {
                        // 灰色小字容易被扫过去，而这一条是"你不回答它就不动"，
                        // 所以用徽标把它从"运行中"里拎出来。
                        Badge(text: "等你回应", tone: .attention)
                            // 与其它状态同一个命名法（session.state.<rawValue>），
                            // 用例断言用的是 model.stateIdentifier(of:)。
                            .accessibilityIdentifier("session.state.\(rowState.rawValue)")
                        Text("·")
                            .font(DSHTheme.Typography.micro)
                            .foregroundStyle(DSHTheme.labelDimmed)
                    } else if session.running {
                        Text("运行中")
                            .font(DSHTheme.Typography.micro)
                            .foregroundStyle(DSHTheme.brand)
                            // The identifier rides the visible label, not the
                            // dot: StatusDot is accessibility-hidden, so an id
                            // on it never reaches the tree.
                            .accessibilityIdentifier("session.state.running")
                        Text("·")
                            .font(DSHTheme.Typography.micro)
                            .foregroundStyle(DSHTheme.labelDimmed)
                    } else if rowState == .finishedUnseen {
                        Text("已完成")
                            .font(DSHTheme.Typography.micro)
                            .foregroundStyle(DSHTheme.success)
                            .accessibilityIdentifier("session.state.finishedUnseen")
                        Text("·")
                            .font(DSHTheme.Typography.micro)
                            .foregroundStyle(DSHTheme.labelDimmed)
                    }
                    Text(RelativeTime.string(from: session.updatedAtDate))
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelTertiary)
                    if let tokens = projections?.tokenUsage?.totalTokens, tokens > 0 {
                        Text("·")
                            .font(DSHTheme.Typography.micro)
                            .foregroundStyle(DSHTheme.labelDimmed)
                        Text(TokenFormat.compact(tokens))
                            .font(DSHTheme.Typography.micro)
                            .foregroundStyle(DSHTheme.labelTertiary)
                            .monospacedDigit()
                    }
                }
            }

            Spacer(minLength: DSHTheme.Spacing.hairline)

            if let fraction = projections?.contextPressure?.fraction, fraction > 0.75 {
                // Only surfaces when context is actually getting tight, so the
                // row stays quiet in the common case. Small text rather than the
                // 34pt bar this used to be: nobody could tell what a bare bar
                // next to a session meant, and "上下文 82%" says it in one line.
                Text("上下文 \(Int((fraction * 100).rounded()))%")
                    .font(DSHTheme.Typography.micro)
                    // Always tertiary: the dot is the row's one coloured
                    // signal, and a second one competes with it.
                    .foregroundStyle(DSHTheme.labelTertiary)
                    .monospacedDigit()
                    .accessibilityIdentifier("session.context")
            }
        }
        .padding(.horizontal, DSHTheme.Spacing.tight)
        .padding(.vertical, 7)
        // 待答那一行整行换底并加一道左侧竖条：与普通行（layer2 灰底）在结构上就不同，
        // 不依赖色相也能一眼扫出来。蓝色沿用 App 里"该你动作"的语义（琥珀留给出错）。
        .background(
            RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous)
                .fill(rowState == .waitingForYou ? DSHTheme.brandSubtle : DSHTheme.layer2)
        )
        .overlay(alignment: .leading) {
            if rowState == .waitingForYou {
                Capsule(style: .continuous)
                    .fill(DSHTheme.brand)
                    .frame(width: 3)
                    .padding(.vertical, 7)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var statusLevel: StatusDot.Level {
        switch rowState {
        case .waitingForYou: return .attention
        case .running: return .busy
        case .finishedUnseen: return .unseen
        case .finishedSeen: return .ok
        case .blank: return .idle
        }
    }
}

// MARK: - Connection status

/// The toolbar button that shows link health and opens the connection sheet.
struct ConnectionStatusButton: View {
    let store: ConnectionStore

    var body: some View {
        HStack(spacing: DSHTheme.Spacing.hairline) {
            StatusDot(level: level, size: 7, animated: isBusy)
            Text(label)
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelSecondary)
                .lineLimit(1)
                // The navigation bar squeezes leading items; without this the
                // status label truncates to a single character.
                .fixedSize()
        }
        .accessibilityLabel("连接状态：\(label)")
    }

    private var isBusy: Bool {
        if case .connecting = store.state { return true }
        return false
    }

    private var level: StatusDot.Level {
        switch store.state {
        case .connected: return .ok
        case .connecting: return .busy
        case .failed: return .error
        case .disconnected: return .idle
        }
    }

    private var label: String {
        switch store.state {
        case .connected: return String(localized: "已连接")
        case .connecting: return String(localized: "连接中…")
        case .failed: return String(localized: "连接失败")
        case .disconnected: return String(localized: "未连接")
        }
    }
}


/// A one-line notice that a newer build is published.
///
/// Deliberately at the top of the list: this is the one place a user looks
/// every time they open the app, and the update has to be installable from the
/// phone alone.
private struct UpdateBanner: View {
    let published: UpdateChecker.Published
    let onInstall: () -> Void

    var body: some View {
        Button(action: onInstall) {
            HStack(spacing: DSHTheme.Spacing.tight) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                VStack(alignment: .leading, spacing: 1) {
                    Text("有新版本可安装")
                        .font(DSHTheme.Typography.caption)
                        .foregroundStyle(DSHTheme.labelPrimary)
                    Text("当前 \(UpdateChecker.currentBuild) → \(published.build)")
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelSecondary)
                }
                Spacer(minLength: 0)
                Text("去更新")
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.brand)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DSHTheme.brand)
            }
            .padding(.horizontal, DSHTheme.Spacing.loose)
            .padding(.vertical, DSHTheme.Spacing.tight)
            .background(DSHTheme.brand.opacity(0.12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("update.banner")
        .accessibilityLabel("有新版本 \(published.build)，点此更新")
    }
}
