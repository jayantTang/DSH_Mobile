import DSHKit
import SwiftUI

/// 变更: the working tree against HEAD, grouped by directory.
///
/// Grouped because that is how a person reviews a change set — "everything under
/// `ios/DSHMobile`" is one thought, not seven — and because a phone has no room
/// for a full path on every row. Read-only, like everything git here.
struct GitChangesPane: View {
    let model: GitModel
    let store: ConnectionStore

    @State private var openDiff: DiffRequest?

    private struct DiffRequest: Identifiable {
        let path: String
        let staged: Bool
        let title: String
        var id: String { "\(staged)-\(path)" }
    }

    var body: some View {
        changeList
            .task {
                model.attach(to: store)
                if case .idle = model.phase { await model.start() }
            }
            .sheet(item: $openDiff) { request in
                GitDiffSheet(model: model, path: request.path, staged: request.staged, title: request.title)
            }
    }

    @ViewBuilder
    private var changeList: some View {
        switch model.phase {
        case .idle, .loading:
            GitPaneStyle.centered { GitPaneStyle.loading("正在读取 git 状态…") }
                .refreshable { await model.loadStatus() }

        case .notARepository:
            GitPaneStyle.centered {
                EmptyStateView(
                    icon: "arrow.triangle.branch",
                    title: "这不是一个 git 仓库",
                    message: "工作区目录 \(model.scope.workspaceRoot ?? "") 里没有 git 仓库，"
                        + "所以没有可以对比的基线。让 agent 初始化仓库后，这里会列出改动。",
                    action: ("重新读取", { Task { await model.loadStatus() } })
                )
            }
            .refreshable { await model.loadStatus() }

        case .unsupported:
            GitPaneStyle.centered {
                EmptyStateView(
                    icon: "exclamationmark.triangle",
                    title: "连接器版本较旧",
                    message: "查看 git 需要电脑上的连接器支持 git 桥。升级连接器并重启 DSH 之后可用。",
                    action: ("重新读取", { Task { await model.loadStatus() } })
                )
            }
            .refreshable { await model.loadStatus() }

        case .failed(let message):
            GitPaneStyle.centered {
                ErrorStateView(message: message) { Task { await model.loadStatus() } }
            }
            .refreshable { await model.loadStatus() }

        case .loaded:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    branchHeader
                    if model.visibleFiles.isEmpty {
                        emptyChanges
                    } else {
                        ForEach(model.directoryGroups, id: \.directory) { group in
                            Section {
                                ForEach(group.files) { file in
                                    fileRow(file, group: group.directory)
                                }
                            } header: {
                                directoryHeader(group.directory, count: group.files.count)
                            }
                        }
                    }
                    if model.status?.truncated == true {
                        GitPaneStyle.footnote("改动太多，主机只返回了前一部分。")
                    }
                }
                .padding(.bottom, DSHTheme.Spacing.loose)
            }
            .refreshable { await model.loadStatus() }
        }
    }

    private var branchHeader: some View {
        HStack(spacing: DSHTheme.Spacing.tight) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 12))
                .foregroundStyle(DSHTheme.brand)
            Text(model.status?.branch.label ?? "—")
                .font(DSHTheme.Typography.code)
                .foregroundStyle(DSHTheme.labelPrimary)
            if let branch = model.status?.branch {
                if branch.ahead > 0 { Badge(text: "领先 \(branch.ahead)", tone: .brand) }
                if branch.behind > 0 { Badge(text: "落后 \(branch.behind)", tone: .attention) }
            }
            Spacer(minLength: 0)
            Text("\(model.visibleFiles.count) 处改动")
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelTertiary)
                .accessibilityIdentifier("git.change.count")
        }
        .padding(.horizontal, DSHTheme.Spacing.standard)
        .frame(minHeight: 40)
        .background(DSHTheme.layer1)
        .accessibilityIdentifier("git.branch")
    }

    private var emptyChanges: some View {
        VStack(spacing: DSHTheme.Spacing.standard) {
            EmptyStateView(
                icon: "checkmark.circle",
                title: "工作区是干净的",
                message: "没有未提交的改动。历史标签里有最近的提交。",
                action: nil
            )
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 320)
        .accessibilityIdentifier("git.clean")
    }

    private func directoryHeader(_ directory: String, count: Int) -> some View {
        HStack(spacing: DSHTheme.Spacing.tight) {
            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(DSHTheme.labelTertiary)
            Text(directory.isEmpty ? "仓库根目录" : directory)
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelSecondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            Text("\(count)")
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelTertiary)
        }
        .padding(.horizontal, DSHTheme.Spacing.standard)
        .frame(minHeight: 30)
        .background(DSHTheme.layer2)
    }

    private func fileRow(_ file: GitFileChange, group: String) -> some View {
        Button {
            openDiff = DiffRequest(path: file.path, staged: file.staged && !file.unstaged, title: file.name)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: DSHTheme.Spacing.tight) {
                Text(file.statusLabel)
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(color(for: file))
                    .frame(width: 52, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.name)
                        .font(DSHTheme.Typography.code)
                        .foregroundStyle(DSHTheme.labelPrimary)
                        .lineLimit(1)
                    if let original = file.originalPath {
                        Text("原路径 \(original)")
                            .font(DSHTheme.Typography.micro)
                            .foregroundStyle(DSHTheme.labelTertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    } else if file.staged, file.unstaged {
                        Text("已暂存 + 未暂存都有改动")
                            .font(DSHTheme.Typography.micro)
                            .foregroundStyle(DSHTheme.labelTertiary)
                    }
                }
                Spacer(minLength: DSHTheme.Spacing.tight)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DSHTheme.labelDimmed)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(file.kind == .deleted && file.unstaged && !file.staged)
        .padding(.horizontal, DSHTheme.Spacing.standard)
        .accessibilityIdentifier("git.change.\(file.path)")
    }

    private func color(for file: GitFileChange) -> Color {
        switch file.kind {
        case .deleted: return DSHTheme.danger
        case .untracked, .added: return DSHTheme.success
        case .conflicted: return DSHTheme.attention
        default: return DSHTheme.brand
        }
    }

}

/// 历史: the commits on the current branch, newest first.
struct GitHistoryPane: View {
    let model: GitModel
    let store: ConnectionStore

    @State private var openCommit: GitCommit?

    var body: some View {
        historyList
            .task {
                model.attach(to: store)
                if case .idle = model.logPhase { await model.loadLog(reset: true) }
            }
            .sheet(item: $openCommit) { commit in
                GitCommitView(model: model, commit: commit)
            }
    }

    @ViewBuilder
    private var historyList: some View {
        switch model.logPhase {
        case .idle, .loading:
            GitPaneStyle.centered { GitPaneStyle.loading("正在读取提交历史…") }
                .refreshable { await model.loadLog(reset: true) }

        case .notARepository:
            GitPaneStyle.centered {
                EmptyStateView(icon: "clock", title: "没有历史", message: "这个目录不在 git 仓库里。")
            }
            .refreshable { await model.loadLog(reset: true) }

        case .failed(let message):
            GitPaneStyle.centered {
                ErrorStateView(message: message) { Task { await model.loadLog(reset: true) } }
            }
            .refreshable { await model.loadLog(reset: true) }

        case .loaded, .unsupported:
            if model.commits.isEmpty {
                GitPaneStyle.centered {
                    EmptyStateView(
                        icon: "clock",
                        title: "还没有提交",
                        message: "这个仓库还没有任何提交，历史为空。",
                        action: ("重新读取", { Task { await model.loadLog(reset: true) } })
                    )
                }
                .refreshable { await model.loadLog(reset: true) }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.commits) { commit in
                            commitRow(commit)
                        }
                        if model.logHasMore {
                            Button("加载更多") {
                                Task { await model.loadLog() }
                            }
                            .font(DSHTheme.Typography.caption)
                            .buttonStyle(.bordered)
                            .tint(DSHTheme.brand)
                            .frame(minHeight: 44)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, DSHTheme.Spacing.tight)
                            .accessibilityIdentifier("git.log.more")
                        }
                    }
                    .padding(.bottom, DSHTheme.Spacing.loose)
                }
                .refreshable { await model.loadLog(reset: true) }
            }
        }
    }

    private func commitRow(_ commit: GitCommit) -> some View {
        Button {
            openCommit = commit
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(commit.subject.isEmpty ? "(没有提交信息)" : commit.subject)
                    .font(DSHTheme.Typography.body)
                    .foregroundStyle(DSHTheme.labelPrimary)
                    .lineLimit(2)
                HStack(spacing: DSHTheme.Spacing.tight) {
                    Text(commit.short)
                        .font(DSHTheme.Typography.code)
                        .foregroundStyle(DSHTheme.brand)
                    Text(commit.author)
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelTertiary)
                        .lineLimit(1)
                    Text(GitDateText.short(commit.date))
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelTertiary)
                    ForEach(commit.refs, id: \.self) { ref in
                        Badge(text: ref, tone: .neutral)
                    }
                }
            }
            .frame(minHeight: 52)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DSHTheme.Spacing.standard)
        .accessibilityIdentifier("git.commit.\(commit.short)")
    }

}

/// Small shared pieces for both git panes.
enum GitPaneStyle {
    static func centered<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity)
                .frame(minHeight: 360)
        }
    }

    static func loading(_ text: String) -> some View {
        VStack(spacing: DSHTheme.Spacing.standard) {
            ProgressView()
            Text(text)
                .font(DSHTheme.Typography.caption)
                .foregroundStyle(DSHTheme.labelSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func footnote(_ text: String) -> some View {
        Text(text)
            .font(DSHTheme.Typography.micro)
            .foregroundStyle(DSHTheme.labelTertiary)
            .padding(.horizontal, DSHTheme.Spacing.standard)
            .padding(.top, DSHTheme.Spacing.tight)
    }
}

/// One file's patch.
struct GitDiffSheet: View {
    let model: GitModel
    let path: String
    let staged: Bool
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading
    @State private var patch: GitPatch?
    @State private var diff: UnifiedDiff?

    private enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    VStack(spacing: DSHTheme.Spacing.standard) {
                        ProgressView()
                        Text("正在读取差异…")
                            .font(DSHTheme.Typography.caption)
                            .foregroundStyle(DSHTheme.labelSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .failed(let message):
                    ErrorStateView(message: message) { Task { await load() } }

                case .loaded:
                    content
                }
            }
            .background(DSHTheme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(title)
                            .font(DSHTheme.Typography.caption)
                            .foregroundStyle(DSHTheme.labelPrimary)
                            .lineLimit(1)
                        Text(staged ? "已暂存的改动" : "工作区改动")
                            .font(DSHTheme.Typography.micro)
                            .foregroundStyle(DSHTheme.labelTertiary)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let patch {
                    if patch.binary {
                        note("二进制文件，git 不展开内容。")
                    } else if patch.isEmpty {
                        note(patch.untracked
                             ? "未跟踪的文件，还没有基线可以比较。"
                             : "这个文件没有文本差异（可能只是权限或换行符变了）。")
                    } else if let diff {
                        UnifiedDiffView(diff: diff, onOpenFile: nil)
                        if patch.truncated {
                            note("差异过长，只显示了前一部分。")
                        }
                    }
                }
            }
            .padding(.vertical, DSHTheme.Spacing.tight)
        }
        .accessibilityIdentifier("git.diff")
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(DSHTheme.Typography.caption)
            .foregroundStyle(DSHTheme.labelSecondary)
            .padding(DSHTheme.Spacing.standard)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load() async {
        phase = .loading
        do {
            let value = try await model.diff(path: path, staged: staged)
            patch = value
            diff = value.binary ? nil : UnifiedDiff.parse(value.text)
            phase = .loaded
        } catch {
            phase = .failed(GitModel.describe(error))
        }
    }
}

/// One commit: who, when, what, and which files.
struct GitCommitView: View {
    let model: GitModel
    let commit: GitCommit

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading
    @State private var detail: GitCommitDetail?
    @State private var openDiff: DiffRequest?

    private struct DiffRequest: Identifiable {
        let path: String
        var id: String { path }
    }

    private enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    ErrorStateView(message: message) { Task { await load() } }
                case .loaded:
                    list
                }
            }
            .background(DSHTheme.background)
            .navigationTitle(commit.short)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task { await load() }
        .sheet(item: $openDiff) { request in
            GitCommitFileSheet(model: model, sha: commit.sha, path: request.path)
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: DSHTheme.Spacing.hairline) {
                    Text(commit.subject)
                        .font(DSHTheme.Typography.body)
                        .foregroundStyle(DSHTheme.labelPrimary)
                    Text("\(commit.author) · \(GitDateText.long(commit.date))")
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelTertiary)
                    Text(commit.sha)
                        .font(DSHTheme.Typography.code)
                        .foregroundStyle(DSHTheme.labelDimmed)
                        .textSelection(.enabled)
                }
                .padding(DSHTheme.Spacing.standard)
                .accessibilityIdentifier("git.commit.header")

                Hairline()

                ForEach(detail?.files ?? []) { file in
                    Button {
                        openDiff = DiffRequest(path: file.path)
                    } label: {
                        HStack(spacing: DSHTheme.Spacing.tight) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(file.path)
                                    .font(DSHTheme.Typography.code)
                                    .foregroundStyle(DSHTheme.labelPrimary)
                                    .lineLimit(2)
                                if let original = file.originalPath {
                                    Text("原路径 \(original)")
                                        .font(DSHTheme.Typography.micro)
                                        .foregroundStyle(DSHTheme.labelTertiary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: DSHTheme.Spacing.tight)
                            if file.binary {
                                Badge(text: "二进制", tone: .neutral)
                            } else if let additions = file.additions, let deletions = file.deletions {
                                Text("+\(additions)")
                                    .font(DSHTheme.Typography.micro)
                                    .foregroundStyle(DSHTheme.success)
                                Text("−\(deletions)")
                                    .font(DSHTheme.Typography.micro)
                                    .foregroundStyle(DSHTheme.danger)
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, DSHTheme.Spacing.standard)
                    .accessibilityIdentifier("git.commit.file.\(file.path)")
                }

                if (detail?.files ?? []).isEmpty {
                    Text("这次提交没有文件改动（可能是空提交或合并）。")
                        .font(DSHTheme.Typography.caption)
                        .foregroundStyle(DSHTheme.labelSecondary)
                        .padding(DSHTheme.Spacing.standard)
                }
            }
        }
        .accessibilityIdentifier("git.commit.body")
    }

    private func load() async {
        phase = .loading
        do {
            detail = try await model.commit(sha: commit.sha)
            phase = .loaded
        } catch {
            phase = .failed(GitModel.describe(error))
        }
    }
}

/// One file inside one commit.
struct GitCommitFileSheet: View {
    let model: GitModel
    let sha: String
    let path: String

    @Environment(\.dismiss) private var dismiss
    @State private var showsFileAtRevision = false
    @State private var phase: Phase = .loading
    @State private var patch: GitPatch?
    @State private var diff: UnifiedDiff?

    private enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    ErrorStateView(message: message) { Task { await load() } }
                case .loaded:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if let patch {
                                if patch.binary {
                                    note("二进制文件，git 不展开内容。")
                                } else if patch.isEmpty {
                                    note("这次提交没有改动这个文件的内容。")
                                } else if let diff {
                                    UnifiedDiffView(diff: diff, onOpenFile: nil)
                                }
                            }
                        }
                        .padding(.vertical, DSHTheme.Spacing.tight)
                    }
                    .accessibilityIdentifier("git.commit.diff")
                }
            }
            .background(DSHTheme.background)
            .navigationTitle((path as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text((path as NSString).lastPathComponent)
                            .font(DSHTheme.Typography.caption)
                            .lineLimit(1)
                        Text("\(sha.prefix(7)) 中的改动")
                            .font(DSHTheme.Typography.micro)
                            .foregroundStyle(DSHTheme.labelTertiary)
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("该版本文件") { showsFileAtRevision = true }
                        .accessibilityIdentifier("git.commit.fileAtRev")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showsFileAtRevision) {
            GitFileReaderView(model: model, rev: sha, path: path)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(DSHTheme.Typography.caption)
            .foregroundStyle(DSHTheme.labelSecondary)
            .padding(DSHTheme.Spacing.standard)
    }

    private func load() async {
        phase = .loading
        do {
            let value = try await model.commitPatch(sha: sha, path: path)
            patch = value
            diff = value.binary ? nil : UnifiedDiff.parse(value.text)
            phase = .loaded
        } catch {
            phase = .failed(GitModel.describe(error))
        }
    }
}

/// A file as it was at one commit.
///
/// Read-only by construction: these are bytes from git's object store, not a
/// file on the phone, so there is nothing to download or share — the point is to
/// read what the code said before it changed.
struct GitFileReaderView: View {
    let model: GitModel
    let rev: String
    let path: String

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading
    @State private var rendered: [AttributedString] = []
    @State private var lines: [String] = []
    @State private var image: UIImage?
    @State private var bytes: Int = 0

    private enum Phase: Equatable {
        case loading
        case text
        case image
        case binary
        case failed(String)
    }

    private var language: CodeLanguage { CodeLanguage.from(path: path) }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    VStack(spacing: DSHTheme.Spacing.standard) {
                        ProgressView()
                        Text("正在读取 \(rev.prefix(7)) 版本…")
                            .font(DSHTheme.Typography.caption)
                            .foregroundStyle(DSHTheme.labelSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .failed(let message):
                    ErrorStateView(message: message) { Task { await load() } }

                case .text:
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(rendered.enumerated()), id: \.offset) { index, line in
                                CodeLineRow(attributed: line, number: index + 1, gutter: gutter)
                            }
                        }
                        .padding(.vertical, DSHTheme.Spacing.tight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(DSHTheme.codeBackground)
                    .accessibilityIdentifier("git.file.text")

                case .image:
                    if let image {
                        ImagePreview(image: image, label: path, identifierPrefix: "git.file")
                    }

                case .binary:
                    VStack(spacing: DSHTheme.Spacing.standard) {
                        Image(systemName: "doc.badge.gearshape")
                            .font(.system(size: 40))
                            .foregroundStyle(DSHTheme.labelTertiary)
                        Text("这个版本不是文本文件")
                            .font(DSHTheme.Typography.body)
                            .foregroundStyle(DSHTheme.labelPrimary)
                        Text("\(ByteFormat.compact(bytes)) · \(rev.prefix(7))")
                            .font(DSHTheme.Typography.caption)
                            .foregroundStyle(DSHTheme.labelSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(DSHTheme.background)
            .navigationTitle((path as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text((path as NSString).lastPathComponent)
                            .font(DSHTheme.Typography.caption)
                            .lineLimit(1)
                        Text("历史版本 \(rev.prefix(7))")
                            .font(DSHTheme.Typography.micro)
                            .foregroundStyle(DSHTheme.attention)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("git.file")
        .task { await load() }
    }

    private var gutter: CGFloat {
        let digits = max(2, min(5, String(max(lines.count, 1)).count))
        return CGFloat(digits) * 8 + 6
    }

    private func load() async {
        phase = .loading
        do {
            let file = try await model.file(rev: rev, path: path)
            bytes = file.bytes
            guard let data = file.contents else {
                phase = .failed("这个版本的内容无法解码。")
                return
            }
            if let text = String(data: data, encoding: .utf8) {
                lines = text.components(separatedBy: "\n")
                rendered = CodeHighlighter.page(lines, language: language)
                phase = .text
                return
            }
            let decoded = await Task.detached(priority: .userInitiated) {
                Decoded(image: UIImage(data: data))
            }.value
            if let decoded = decoded.image {
                image = decoded
                phase = .image
            } else {
                phase = .binary
            }
        } catch {
            phase = .failed(GitModel.describe(error))
        }
    }

    private struct Decoded: @unchecked Sendable {
        let image: UIImage?
    }
}

/// Dates as git writes them: ISO 8601 with an offset.
///
/// `@MainActor` because the formatters are shared instances and are not
/// `Sendable`; a date string is only ever produced to draw a row.
@MainActor
enum GitDateText {
    private static let parser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let short: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    private static let long: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// `""` when the date is unparseable, rather than a raw ISO string in the UI.
    static func short(_ raw: String) -> String {
        guard let date = parser.date(from: raw) else { return "" }
        return short.string(from: date)
    }

    static func long(_ raw: String) -> String {
        guard let date = parser.date(from: raw) else { return raw }
        return long.string(from: date)
    }
}
