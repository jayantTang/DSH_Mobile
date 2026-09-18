import DSHKit
import SwiftUI

/// The workspace file browser, reached from the chat screen's toolbar.
///
/// Two modes share one screen: 浏览 walks the session workspace one directory at
/// a time through `workspaceFiles/list`, and 变更 shows the working-tree change
/// set the host observes. Both filter client-side from the same search field, and
/// both are pull-to-refresh.
struct WorkspaceFilesView: View {
    let store: ConnectionStore

    @State private var model: WorkspaceFilesModel
    @State private var openFile: FileOpenRequest?
    /// A picture opens the way a picture opens on a phone: full screen, zoomable,
    /// with the file already on the phone behind it.
    @State private var openImage: FileOpenRequest?
    /// A file to open as soon as the browser is up. The unattended run uses it
    /// to land on a report without walking the tree first; a person never sets
    /// it.
    ///
    /// A binding, not a value: the run resolves the path after the browser has
    /// already been built (it needs the session list to know the workspace), and
    /// a plain `String?` would be captured as nil and never looked at again.
    @Binding var openPath: String?

    init(
        store: ConnectionStore,
        scope: WorkspaceFileScope,
        openPath: Binding<String?> = .constant(nil),
        initialPath: String = ""
    ) {
        self.store = store
        _openPath = openPath
        // The host publishes its home on the event stream; the store is the
        // freshest source for abbreviating displayed paths.
        let resolved = WorkspaceFileScope(
            sessionId: scope.sessionId,
            workspaceRoot: scope.workspaceRoot,
            hostHome: scope.hostHome ?? store.hostHome
        )
        _model = State(initialValue: WorkspaceFilesModel(scope: resolved, initialPath: initialPath))
    }

    /// The usual entry point: the chat screen hands over its session summary.
    ///
    /// The scope id is the session's own id — see `WorkspaceFileScope` for why
    /// that is the value `workspaceFileScopeId` carries.
    init(store: ConnectionStore, summary: SessionSummary, hostHome: String? = nil) {
        self.init(store: store, scope: WorkspaceFileScope(summary: summary, hostHome: hostHome))
    }

    private struct FileOpenRequest: Identifiable {
        let path: String
        let title: String
        var id: String { path }
    }

    var body: some View {
        content
    }

    private var content: some View {
        VStack(spacing: 0) {
            modeBar
            searchBar
            if model.mode == .browse {
                breadcrumb
            }
            Hairline()
            main
        }
        .background(DSHTheme.background)
        // The page cannot be identified by its title: inside a sheet iOS
        // renders the title without exposing it as an element, so an
        // unattended run has no text to wait for. This is what the run looks
        // for, the same way it looks for `settings.root` on the settings page.
        .accessibilityIdentifier("files.root")
        .navigationTitle("工作区文件")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.mode == .browse, !model.browsingPath.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await model.goUp() }
                    } label: {
                        Label("上级目录", systemImage: "arrow.up")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("重新读取", systemImage: "arrow.clockwise")
                }
            }
        }
        .sheet(item: $openFile) { request in
            WorkspaceFileReaderView(model: model, path: request.path, title: request.title)
        }
        .fullScreenCover(item: $openImage) { request in
            WorkspaceImagePreviewView(model: model, path: request.path, title: request.title)
        }
        .task {
            model.attach(to: store)
            await model.start()
        }
        .task(id: openPath) {
            guard let wanted = openPath else { return }
            // Wait for the browser to have a listing: a file opened before the
            // scope is live would read against nothing.
            for _ in 0..<80 where model.listing == nil {
                try? await Task.sleep(for: .milliseconds(250))
            }
            openPath = nil
            openPath(wanted)
        }
        .onDisappear { model.stop() }
    }

    // MARK: - Chrome

    private var modeBar: some View {
        Picker("模式", selection: $model.mode) {
            ForEach(WorkspaceFilesModel.Mode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, DSHTheme.Spacing.standard)
        .padding(.top, DSHTheme.Spacing.tight)
        .padding(.bottom, DSHTheme.Spacing.hairline)
    }

    private var searchBar: some View {
        HStack(spacing: DSHTheme.Spacing.tight) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(DSHTheme.labelTertiary)
            TextField(model.mode == .browse ? "搜索当前目录" : "搜索变更路径", text: $model.searchText)
                .font(DSHTheme.Typography.caption)
                .foregroundStyle(DSHTheme.labelPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(DSHTheme.labelTertiary)
                        .frame(width: 24, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.leading, DSHTheme.Spacing.tight)
        .padding(.trailing, DSHTheme.Spacing.hairline)
        .frame(minHeight: 44)
        .background(DSHTheme.layer2, in: RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous)
                .stroke(DSHTheme.border2, lineWidth: 1)
        }
        .padding(.horizontal, DSHTheme.Spacing.standard)
        .padding(.bottom, DSHTheme.Spacing.hairline)
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DSHTheme.Spacing.hairline) {
                Button {
                    Task { await model.loadDirectory("") }
                } label: {
                    Text(model.scope.workspaceRoot.map { ($0 as NSString).lastPathComponent } ?? "工作区")
                        .font(DSHTheme.Typography.code)
                        .foregroundStyle(model.browsingPath.isEmpty ? DSHTheme.labelPrimary : DSHTheme.brand)
                }
                .buttonStyle(.plain)

                ForEach(Array(model.breadcrumbs.enumerated()), id: \.offset) { index, part in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(DSHTheme.labelDimmed)
                    Button {
                        Task { await model.jump(to: index) }
                    } label: {
                        Text(part)
                            .font(DSHTheme.Typography.code)
                            .foregroundStyle(index == model.breadcrumbs.count - 1 ? DSHTheme.labelPrimary : DSHTheme.brand)
                    }
                    .buttonStyle(.plain)
                }
                if model.listing?.truncated == true {
                    Badge(text: "条目太多，只显示了一部分。", tone: .brand)
                }
            }
            .padding(.horizontal, DSHTheme.Spacing.standard)
            .frame(minHeight: 36)
        }
        .frame(height: 36)
    }

    // MARK: - Content

    @ViewBuilder
    private var main: some View {
        switch model.mode {
        case .browse:
            browseContent
        case .changes:
            changesContent
        }
    }

    @ViewBuilder
    private var browseContent: some View {
        switch model.phase {
        case .idle, .loading:
            stateContainer { loadingState("正在读取目录…") }

        case .failed(let message):
            stateContainer {
                ErrorStateView(message: message) {
                    Task { await model.loadDirectory(model.browsingPath) }
                }
            }

        case .loaded:
            if model.visibleEntries.isEmpty {
                stateContainer {
                    if model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        EmptyStateView(
                            icon: "folder",
                            title: "空目录",
                            message: "这个目录里没有内容。",
                            action: ("重新读取", { Task { await model.refresh() } })
                        )
                    } else {
                        EmptyStateView(
                            icon: "magnifyingglass",
                            title: "没有匹配的条目",
                            message: "当前目录里没有名称包含「\(model.searchText)」的文件。",
                            action: ("清除搜索", { model.searchText = "" })
                        )
                    }
                }
            } else {
                List {
                    ForEach(model.visibleEntries) { entry in
                        Button {
                            open(entry)
                        } label: {
                            DirectoryEntryRow(entry: entry, displayName: entry.name)
                        }
                        .buttonStyle(.plain)
                        .disabled(!entry.isDirectory && !entry.isFile)
                        .accessibilityIdentifier("files.entry.\(entry.name)")
                        .listRowInsets(EdgeInsets(top: 0, leading: DSHTheme.Spacing.loose, bottom: 0, trailing: DSHTheme.Spacing.loose))
                        .listRowBackground(DSHTheme.layer1)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 44)
                .refreshable { await model.refresh() }
            }
        }
    }

    @ViewBuilder
    private var changesContent: some View {
        switch model.changesPhase {
        case .idle, .loading:
            stateContainer { loadingState("正在读取变更…") }

        case .failed(let message):
            stateContainer {
                ErrorStateView(message: message) {
                    Task { await model.loadChanges() }
                }
            }

        case .loaded:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !model.changeSet.entries.isEmpty {
                        Text("主机的变更集")
                            .font(DSHTheme.Typography.micro)
                            .foregroundStyle(DSHTheme.labelTertiary)
                            .padding(.horizontal, DSHTheme.Spacing.standard)
                            .padding(.top, DSHTheme.Spacing.tight)
                        ForEach(model.changeSet.entries) { entry in
                            changeSetRow(entry)
                        }
                        ForEach(Array(model.changeSet.diffs.enumerated()), id: \.offset) { _, diff in
                            UnifiedDiffView(diff: diff, onOpenFile: openDiffPath)
                        }
                    }

                    if !model.changes.isEmpty {
                        HStack(spacing: DSHTheme.Spacing.tight) {
                            Text("观测到的文件")
                                .font(DSHTheme.Typography.micro)
                                .foregroundStyle(DSHTheme.labelTertiary)
                            Badge(text: "\(model.visibleChanges.count) 个文件", tone: .neutral)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, DSHTheme.Spacing.standard)
                        .padding(.top, DSHTheme.Spacing.standard)

                        if model.visibleChanges.isEmpty {
                            Text("没有路径包含「\(model.searchText)」的变更。")
                                .font(DSHTheme.Typography.caption)
                                .foregroundStyle(DSHTheme.labelSecondary)
                                .padding(DSHTheme.Spacing.standard)
                        }

                        ForEach(model.visibleChanges) { change in
                            changeRow(change)
                        }
                    }

                    if model.changes.isEmpty, model.changeSet.entries.isEmpty {
                        VStack(spacing: DSHTheme.Spacing.standard) {
                            EmptyStateView(
                                icon: "arrow.triangle.2.circlepath",
                                title: "还没有观测到变更",
                                message: "DSH 只上报被它观测到的文件系统活动。运行一次修改文件的任务后，这里会列出相关路径。",
                                action: ("重新读取", { Task { await model.loadChanges() } })
                            )
                        }
                        .frame(minHeight: 420)
                    }

                    changeFootnotes
                }
                .padding(.bottom, DSHTheme.Spacing.loose)
            }
            .refreshable { await model.refresh() }
        }
    }

    private var changeFootnotes: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.hairline) {
            Text("主机上报的是文件系统观测结果（路径与版本号），不包含改动前的基线内容，因此没有基线就无法生成逐行差异。")
            Text("若主机在变更集中附带补丁文本，上面的「差异」会按新增 / 删除行着色显示。")
        }
        .font(DSHTheme.Typography.micro)
        .foregroundStyle(DSHTheme.labelTertiary)
        .padding(.horizontal, DSHTheme.Spacing.standard)
        .padding(.top, DSHTheme.Spacing.standard)
    }

    private func changeSetRow(_ entry: WorkspaceChangeSet.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DSHTheme.Spacing.tight) {
            Text(model.scope.displayPath(entry.path))
                .font(DSHTheme.Typography.code)
                .foregroundStyle(DSHTheme.labelPrimary)
                .lineLimit(2)
            Spacer(minLength: DSHTheme.Spacing.tight)
            if let additions = entry.additions, let deletions = entry.deletions {
                Text("+\(additions)")
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.success)
                Text("−\(deletions)")
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.danger)
            }
            Badge(text: entry.statusLabel, tone: entry.statusLabel == "已删除" ? .danger : .brand)
        }
        .padding(.horizontal, DSHTheme.Spacing.standard)
        .frame(minHeight: 44)
    }

    private func changeRow(_ change: WorkspaceChange) -> some View {
        Button {
            if !change.absent { openPath(change.absolutePath) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: DSHTheme.Spacing.tight) {
                Image(systemName: change.absent ? "minus.circle" : "pencil.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(change.absent ? DSHTheme.danger : DSHTheme.brand)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.scope.displayPath(change.absolutePath))
                        .font(DSHTheme.Typography.code)
                        .foregroundStyle(change.absent ? DSHTheme.labelTertiary : DSHTheme.labelPrimary)
                        .lineLimit(2)
                    if let version = change.version, !version.isEmpty {
                        Text("版本 \(version)")
                            .font(DSHTheme.Typography.micro)
                            .foregroundStyle(DSHTheme.labelTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: DSHTheme.Spacing.tight)
                Badge(text: change.statusLabel, tone: change.absent ? .danger : .neutral)
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(change.absent)
        .padding(.horizontal, DSHTheme.Spacing.standard)
    }

    private func stateContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity)
                .frame(minHeight: 420)
        }
        .refreshable { await model.refresh() }
    }

    private func loadingState(_ text: String) -> some View {
        VStack(spacing: DSHTheme.Spacing.standard) {
            ProgressView()
            Text(text)
                .font(DSHTheme.Typography.caption)
                .foregroundStyle(DSHTheme.labelSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func open(_ entry: WorkspaceDirectoryEntry) {
        if entry.isDirectory {
            Task { await model.open(entry) }
        } else if entry.isFile {
            openPath(entry.path(in: model.browsingPath))
        }
    }

    private func openPath(_ path: String) {
        let request = FileOpenRequest(path: path, title: (path as NSString).lastPathComponent)
        // A picture is not read as a document: it is fetched and shown, zoomable,
        // on its own screen.
        if WorkspaceFilesModel.kind(for: path) == .image {
            openImage = request
        } else {
            openFile = request
        }
    }

    private func openDiffPath(_ path: String) {
        // A patch names its file relative to the workspace; an absolute path (or
        // one without a known root) is used as it stands.
        guard !path.hasPrefix("/"), let root = model.scope.workspaceRoot, !root.isEmpty else {
            openPath(path)
            return
        }
        openPath("\(root)/\(path)")
    }
}

/// One directory row: type glyph, name, size.
private struct DirectoryEntryRow: View {
    let entry: WorkspaceDirectoryEntry
    let displayName: String

    private var glyph: String {
        switch entry.kind {
        case .directory: return "folder"
        case .file: return "fileGlyph"
        case .other: return "questionmark.square.dashed"
        }
    }

    /// The glyph a file row leads with, guessed the same way opening it is.
    private var fileGlyph: String {
        switch WorkspaceFileKind.of(path: entry.name) {
        case .image: return "photo"
        case .web: return "safari"
        case .preview: return "doc.richtext"
        case .binary: return "archivebox"
        case .text: return "doc.text"
        }
    }

    var body: some View {
        HStack(spacing: DSHTheme.Spacing.tight) {
            Image(systemName: entry.kind == .file ? fileGlyph : glyph)
                .font(.system(size: 14))
                .foregroundStyle(entry.isDirectory ? DSHTheme.brand : DSHTheme.labelTertiary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(DSHTheme.Typography.body)
                    .foregroundStyle(entry.kind == .other ? DSHTheme.labelTertiary : DSHTheme.labelPrimary)
                    .lineLimit(1)
                if entry.kind == .other {
                    // A disabled row with no reason reads as a broken app; the
                    // host refuses symlinks and sockets, so say so.
                    Text("特殊文件（符号链接等），主机不读取它的内容。")
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: DSHTheme.Spacing.tight)
            if let size = entry.sizeText {
                Text(size)
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.labelTertiary)
            }
            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DSHTheme.labelDimmed)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityLabel(entry.isDirectory ? "\(displayName)，目录" : "\(displayName)，\(entry.sizeText ?? "文件")")
    }
}
