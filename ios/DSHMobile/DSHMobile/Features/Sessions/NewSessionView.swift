import DSHKit
import SwiftUI

/// Starts a new session, either in a workspace that already has live work or in
/// any directory on the computer.
///
/// The sheet is two blocks, and they answer two different questions:
///
/// - **On top**, the workspaces that still hold a live session — "continue in
///   one of these". Its labels count live sessions, not the workspace's whole
///   history, because a group labelled with every conversation it has ever held
///   says nothing about what is in it now.
/// - **Below**, a browser for the computer's own directories, because a project
///   the phone has never seen is exactly the case the known-workspace list
///   cannot serve.
///
/// Both halves confirm before creating: a session is bound to its directory for
/// good, and a mistap on a phone is one thumb wide.
struct NewSessionView: View {
    let model: SessionListModel
    /// The connection is the browser's data source: the host walks its own
    /// filesystem, one level per call.
    let store: ConnectionStore
    /// Called with the created session's id, so the caller can open it.
    var onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var browser = DirectoryBrowserModel()
    @State private var creating: String?
    @State private var failure: String?
    /// The directory waiting for the user to confirm it.
    @State private var pending: PendingCreation?
    @State private var isNamingFolder = false
    @State private var folderName = ""
    /// Whether the path field holds the keyboard.
    ///
    /// Typing a path is a jump, not a compose: leaving the keyboard up would
    /// cover the very list the jump was for, and on a sheet this size it covers
    /// half of it.
    @FocusState private var isEditingPath: Bool

    /// One "create here?" request, from either half of the sheet.
    private struct PendingCreation: Identifiable {
        let path: String
        let title: String
        var id: String { path }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !model.liveWorkspaces.isEmpty { workspaceBlock }
                browserBlock
            }
            .background(DSHTheme.background)
            .navigationTitle("新建会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .overlay {
                if creating != nil {
                    VStack(spacing: DSHTheme.Spacing.tight) {
                        ProgressView()
                        Text("正在新建…")
                            .font(DSHTheme.Typography.caption)
                            .foregroundStyle(DSHTheme.labelSecondary)
                    }
                    .padding(DSHTheme.Spacing.loose)
                    .background(DSHTheme.layer1, in: RoundedRectangle(cornerRadius: DSHTheme.Radius.large))
                }
            }
            .task {
                browser.attach(to: store)
                await browser.start()
            }
            .alert(
                "在「\(pending?.title ?? "")」新建会话？",
                isPresented: Binding(
                    get: { pending != nil },
                    set: { if !$0 { pending = nil } }
                ),
                presenting: pending
            ) { request in
                Button("确认新建") { create(in: request.path) }
                Button("取消", role: .cancel) {}
            } message: { request in
                Text("\(request.path)\n\n会先把它登记为一个工作区，电脑端侧栏会多出一组。")
            }
            .alert("新建文件夹", isPresented: $isNamingFolder) {
                TextField("文件夹名", text: $folderName)
                    .accessibilityIdentifier("newSession.browser.folderName")
                Button("取消", role: .cancel) { folderName = "" }
                Button("创建") {
                    let name = folderName
                    folderName = ""
                    Task { await browser.createFolder(named: name) }
                }
            } message: {
                Text("在当前目录下新建一个文件夹。只能是一层名字，不能带「/」。")
            }
            .alert("新建失败", isPresented: Binding(
                get: { failure != nil },
                set: { if !$0 { failure = nil } }
            )) {
                Button("好", role: .cancel) { failure = nil }
            } message: {
                Text(failure ?? "")
            }
        }
    }

    // MARK: - Live workspaces

    /// The workspaces that still have something to continue.
    ///
    /// Hidden entirely when there are none: an empty "工作区" heading over an
    /// empty list reads as a bug, and the browser below is the whole answer in
    /// that case.
    private var workspaceBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("工作区")
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelTertiary)
                .padding(.horizontal, DSHTheme.Spacing.loose)
                .padding(.top, DSHTheme.Spacing.tight)
                .padding(.bottom, DSHTheme.Spacing.hairline)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.liveWorkspaces) { workspace in
                        workspaceRow(workspace)
                    }
                }
                .padding(.horizontal, DSHTheme.Spacing.tight)
                .padding(.bottom, DSHTheme.Spacing.tight)
            }
            // Bounded on purpose: this block is a shortcut, and letting it grow
            // would push the browser — the part that can reach anywhere — off
            // the screen.
            .frame(maxHeight: 190)

            Hairline()
        }
    }

    private func workspaceRow(_ workspace: SessionListModel.LiveWorkspace) -> some View {
        Button {
            pending = PendingCreation(path: workspace.path, title: workspace.title)
        } label: {
            HStack(spacing: DSHTheme.Spacing.tight) {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DSHTheme.labelTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(workspace.title)
                        .font(DSHTheme.Typography.bodyStrong)
                        .foregroundStyle(DSHTheme.labelPrimary)
                    Text(model.displayPath(workspace.path))
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if workspace.runningCount > 0 {
                    Badge(text: "\(workspace.runningCount) 运行中", tone: .brand)
                } else {
                    Text("\(workspace.sessions.count) 个会话")
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelDimmed)
                }
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(DSHTheme.brand)
            }
            .padding(.horizontal, DSHTheme.Spacing.tight)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous)
                    .fill(DSHTheme.layer2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(creating != nil)
        .accessibilityIdentifier("newSession.row.\(workspace.title)")
        .accessibilityLabel("在 \(workspace.title) 新建会话")
    }

    // MARK: - Directory browser

    private var browserBlock: some View {
        VStack(spacing: 0) {
            browserBar
            pathRow
            crumbRow
            Hairline()
            entryList
        }
    }

    private var browserBar: some View {
        HStack(spacing: DSHTheme.Spacing.tight) {
            Text("电脑目录")
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelTertiary)
            Spacer(minLength: 0)
            Button {
                folderName = ""
                isNamingFolder = true
            } label: {
                Label("新建文件夹", systemImage: "folder.badge.plus")
                    .font(DSHTheme.Typography.micro)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DSHTheme.brand)
            .disabled(browser.currentPath == nil || creating != nil)
            .accessibilityIdentifier("newSession.browser.newFolder")

            Button {
                Task { await browser.goUp() }
            } label: {
                Label("上级", systemImage: "arrow.up")
                    .font(DSHTheme.Typography.micro)
            }
            .buttonStyle(.plain)
            .foregroundStyle(browser.canGoUp ? DSHTheme.brand : DSHTheme.labelDimmed)
            .disabled(!browser.canGoUp || creating != nil)
            .accessibilityIdentifier("newSession.browser.up")
        }
        .padding(.horizontal, DSHTheme.Spacing.loose)
        .padding(.top, DSHTheme.Spacing.tight)
        .padding(.bottom, DSHTheme.Spacing.hairline)
    }

    /// The path field: a label that is also a jump target.
    ///
    /// Deep directories are the reason it exists — walking from the home
    /// directory to `~/Bspace/project/...` one level per round trip is the
    /// difference between one step and twelve.
    private var pathRow: some View {
        HStack(spacing: DSHTheme.Spacing.hairline) {
            TextField("输入电脑上的路径", text: $browser.pathDraft)
                .font(DSHTheme.Typography.code)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($isEditingPath)
                .onSubmit { jump() }
                .onChange(of: isEditingPath) { _, editing in
                    // Tapping the location bar means "type a new path": leaving
                    // the old one in place turns every jump into an edit of the
                    // current path, and the head of a long path is exactly what
                    // the caret sits against. Tapping away without typing puts
                    // the current directory back, so the field never lies about
                    // where the browser is.
                    if editing {
                        browser.pathDraft = ""
                    } else if browser.pathDraft.trimmingCharacters(in: .whitespaces).isEmpty {
                        browser.pathDraft = browser.currentPath ?? ""
                    }
                }
                .padding(.horizontal, DSHTheme.Spacing.tight)
                .padding(.vertical, 6)
                .background(DSHTheme.layer3, in: RoundedRectangle(cornerRadius: DSHTheme.Radius.small))
                .accessibilityIdentifier("newSession.browser.path")

            Button("跳转") { jump() }
                .font(DSHTheme.Typography.caption)
                .foregroundStyle(DSHTheme.brand)
                .disabled(creating != nil)
                .accessibilityIdentifier("newSession.browser.go")
        }
        .padding(.horizontal, DSHTheme.Spacing.loose)
        .padding(.bottom, DSHTheme.Spacing.hairline)
    }

    /// Reads whatever the path field says and puts the keyboard away.
    private func jump() {
        isEditingPath = false
        Task { await browser.submitDraft() }
    }

    /// Ancestors as jump targets, so a wrong turn costs one tap to undo.
    private var crumbRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DSHTheme.Spacing.hairline) {
                ForEach(Array(browser.crumbs.enumerated()), id: \.element.path) { index, crumb in
                    if index > 0 {
                        Text("/")
                            .font(DSHTheme.Typography.micro)
                            .foregroundStyle(DSHTheme.labelDimmed)
                    }
                    Button {
                        Task { await browser.open(crumb.path) }
                    } label: {
                        // The root crumb carries its own full path in `name`;
                        // every other crumb is a base name.
                        Text(crumb.name)
                            .font(DSHTheme.Typography.micro)
                            .foregroundStyle(index == browser.crumbs.count - 1
                                             ? DSHTheme.labelPrimary : DSHTheme.brand)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("newSession.browser.crumb.\(index)")
                }
            }
            .padding(.horizontal, DSHTheme.Spacing.loose)
            .padding(.bottom, DSHTheme.Spacing.tight)
        }
        .frame(height: 22)
    }

    private var entryList: some View {
        List {
            Section {
                createHereRow
                if browser.entries.isEmpty && !browser.isLoading {
                    Text(browser.listing == nil
                         ? "还没读到目录。"
                         : "这个目录下没有子目录。")
                        .font(DSHTheme.Typography.caption)
                        .foregroundStyle(DSHTheme.labelTertiary)
                        .listRowBackground(Color.clear)
                }
                ForEach(browser.entries) { entry in
                    entryRow(entry)
                }
            } footer: {
                if let failure = browser.failure {
                    Text(failure)
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelError)
                } else if browser.truncated {
                    Text("这个目录的子目录太多，只列出了前面一部分。可以直接在上面输入完整路径。")
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelTertiary)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        // The browser's list is also the sheet's addressable root: an
        // identifier on the enclosing stack is pushed down onto its children and
        // overwrote theirs, which is how the path field and the buttons became
        // unaddressable. The block above it is optional, this list is not.
        .accessibilityIdentifier("newSession.root")
        .overlay {
            if browser.isLoading && browser.listing == nil {
                ProgressView().controlSize(.small)
            }
        }
    }

    /// The one row that creates a session: the level on screen is the choice.
    ///
    /// Tapping a directory row walks into it; this row is what "start here"
    /// means, which is why the path is printed on it in full.
    private var createHereRow: some View {
        Button {
            guard let path = browser.currentPath else { return }
            isEditingPath = false
            pending = PendingCreation(path: path, title: (path as NSString).lastPathComponent)
        } label: {
            HStack(spacing: DSHTheme.Spacing.tight) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(browser.currentPath == nil ? DSHTheme.labelDimmed : DSHTheme.brand)
                VStack(alignment: .leading, spacing: 1) {
                    Text("在此新建会话")
                        .font(DSHTheme.Typography.bodyStrong)
                        .foregroundStyle(DSHTheme.labelPrimary)
                    if let path = browser.currentPath {
                        Text(path)
                            .font(DSHTheme.Typography.micro)
                            .foregroundStyle(DSHTheme.labelTertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DSHTheme.Spacing.tight)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous)
                    .fill(DSHTheme.brandSubtle)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(browser.currentPath == nil || creating != nil)
        .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityIdentifier("newSession.browser.createHere")
    }

    private func entryRow(_ entry: HostDirectoryEntry) -> some View {
        Button {
            Task { await browser.open(entry) }
        } label: {
            HStack(spacing: DSHTheme.Spacing.tight) {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DSHTheme.labelTertiary)
                Text(entry.name)
                    .font(DSHTheme.Typography.body)
                    .foregroundStyle(entry.hidden ? DSHTheme.labelTertiary : DSHTheme.labelPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DSHTheme.labelDimmed)
            }
            .padding(.horizontal, DSHTheme.Spacing.tight)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(creating != nil)
        .listRowInsets(EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 10))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityIdentifier("newSession.browser.entry.\(entry.name)")
    }

    // MARK: - Confirmation

    /// Starts the session the user just confirmed.
    ///
    /// The alert is the confirm step both halves share: it names the directory
    /// in full and says what creating there also does — the directory is
    /// registered as a workspace, which the desktop sidebar then shows. A person
    /// who only wanted one throwaway conversation deserves to know that before
    /// it happens, not after.
    private func create(in directory: String) {
        guard creating == nil else { return }
        creating = directory
        Task {
            do {
                let id = try await model.startSession(directory: directory)
                creating = nil
                onCreated(id)
                dismiss()
            } catch {
                creating = nil
                failure = ConnectionStore.describe(error)
            }
        }
    }
}
