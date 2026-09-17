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
    @Environment(UpdateChecker.self) private var updates
    @Environment(\.openURL) private var openURL
    @Bindable var model: SessionListModel
    var onOpenConnections: () -> Void
    var onOpenSettings: () -> Void
    /// Called with a freshly created session's id so the caller can open it.
    var onOpenSession: (String) -> Void = { _ in }

    /// Parent sessions whose subagents are currently shown. Empty by default:
    /// a session that spawned five subagents should still read as one row.
    @State private var expandedParents: Set<String> = []
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
            NewSessionView(model: model) { sessionId in
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
                if model.runningCount > 0 {
                    Badge(text: "\(model.runningCount) 运行中", tone: .brand)
                }
                if model.ungroupedRunningCount > 0 {
                    Badge(text: "未分组 \(model.ungroupedRunningCount)", tone: .neutral)
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
                return "\(count) 个会话 · 工作区未加载，暂按目录分组"
            }
            return "\(count) 个会话"
        case .connecting(let message):
            return message
        case .failed(let message):
            return message
        case .disconnected:
            return "未连接"
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
                        let children = group.children[session.sessionId] ?? []
                        parentRow(session: session, children: children)
                        if expandedParents.contains(session.sessionId) {
                            ForEach(children) { child in
                                childRow(child)
                            }
                        }
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
    private func parentRow(session: SessionSummary, children: [SessionSummary]) -> some View {
        HStack(spacing: DSHTheme.Spacing.hairline) {
            NavigationLink(value: session.sessionId) {
                SessionRow(session: session, home: store.hostHome,
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

            if !children.isEmpty {
                SubagentDisclosure(
                    count: children.count,
                    isExpanded: expandedParents.contains(session.sessionId)
                ) {
                    withAnimation(.snappy(duration: 0.18)) {
                        if expandedParents.contains(session.sessionId) {
                            expandedParents.remove(session.sessionId)
                        } else {
                            expandedParents.insert(session.sessionId)
                        }
                    }
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }


    /// A row inside the archived section: readable, and marked as archived.
    private func archivedRow(_ session: SessionSummary) -> some View {
        NavigationLink(value: session.sessionId) {
            SessionRow(session: session, home: store.hostHome, isChild: true)
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
            SessionRow(session: session, home: store.hostHome, isChild: true,
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
            Spacer(minLength: 0)
        }
        .textCase(nil)
        .padding(.top, DSHTheme.Spacing.tight)
        .padding(.horizontal, DSHTheme.Spacing.loose)
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
                if running > 0 {
                    Badge(text: "\(running) 运行中", tone: .brand)
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

/// The subagent count chip that unfolds a session's children.
private struct SubagentDisclosure: View {
    let count: Int
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "person.2")
                    .font(.system(size: 9, weight: .medium))
                Text("\(count)")
                    .font(DSHTheme.Typography.micro)
                    .monospacedDigit()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(DSHTheme.labelTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(DSHTheme.layer3, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("session.subagents")
        .accessibilityLabel(isExpanded ? "收起 \(count) 个子代理" : "展开 \(count) 个子代理")
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

            StatusDot(level: statusLevel, animated: session.running)

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
                    if session.running {
                        Text("运行中")
                            .font(DSHTheme.Typography.micro)
                            .foregroundStyle(DSHTheme.brand)
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
                // row stays quiet in the common case.
                PressureBar(fraction: fraction)
                    .frame(width: 34)
            }
        }
        .padding(.horizontal, DSHTheme.Spacing.tight)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous)
                .fill(DSHTheme.layer2)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var statusLevel: StatusDot.Level {
        if session.running { return .busy }
        if session.blank { return .idle }
        return .ok
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
        case .connected: return "已连接"
        case .connecting: return "连接中"
        case .failed: return "连接失败"
        case .disconnected: return "未连接"
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
