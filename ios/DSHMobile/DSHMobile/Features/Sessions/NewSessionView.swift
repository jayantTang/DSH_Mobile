import DSHKit
import SwiftUI

/// Starts a new session in a project directory that already exists.
///
/// A DSH session is bound to a working folder, so "new session" on a phone is
/// never "somewhere": it is another conversation inside a project the user
/// already works in. The list therefore offers the directories the host already
/// knows — its workspaces, plus every directory an existing session runs in —
/// rather than a file browser the phone would have to walk from the root.
struct NewSessionView: View {
    let model: SessionListModel
    /// Called with the created session's id, so the caller can open it.
    var onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var creating: String?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            List {
                if !model.workspaces.isEmpty {
                    Section("工作区") {
                        ForEach(model.workspaces) { workspace in
                            row(title: workspace.title, path: workspace.path,
                                detail: "\(workspace.sessionIds.count) 个会话")
                        }
                    }
                }

                let others = otherDirectories
                if !others.isEmpty {
                    Section {
                        ForEach(others, id: \.self) { path in
                            row(title: (path as NSString).lastPathComponent, path: path,
                                detail: nil)
                        }
                    } header: {
                        Text("其他项目目录")
                    } footer: {
                        Text("来自现有会话的工作目录。新会话会在这个目录里开始，并登记为一个工作区，这样它会归到这个目录下而不是「未分组」。")
                    }
                }

                if model.workspaces.isEmpty && otherDirectories.isEmpty {
                    Section {
                        Text("还没有可用的项目目录。先在电脑端开始一个会话，或用一个已有会话。")
                            .font(DSHTheme.Typography.caption)
                            .foregroundStyle(DSHTheme.labelTertiary)
                    }
                }
            }
            .navigationTitle("新建会话")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("newSession.root")
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

    private func row(title: String, path: String, detail: String?) -> some View {
        Button {
            create(in: path)
        } label: {
            HStack(spacing: DSHTheme.Spacing.tight) {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DSHTheme.labelTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(DSHTheme.Typography.bodyStrong)
                        .foregroundStyle(DSHTheme.labelPrimary)
                    Text(model.displayPath(path))
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelTertiary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if let detail {
                    Text(detail)
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelDimmed)
                }
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(DSHTheme.brand)
            }
        }
        .buttonStyle(.plain)
        .disabled(creating != nil)
        .accessibilityIdentifier("newSession.row.\(title)")
    }

    /// Project directories that exist but are not filed as a workspace, most
    /// recently used first.
    ///
    /// Recency, not the alphabet: the directory someone wants to continue in is
    /// almost always one they touched recently, and an alphabetical list buries
    /// it under every stale path the host still remembers.
    private var otherDirectories: [String] {
        let known = Set(model.workspaces.map(\.path))
        var newest: [String: Double] = [:]
        for session in model.allSessions {
            guard let cwd = session.cwd, !cwd.isEmpty, !known.contains(cwd) else { continue }
            newest[cwd] = max(newest[cwd] ?? 0, session.updatedAt)
        }
        return newest.sorted { $0.value > $1.value }.map(\.key)
    }

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
                failure = error.localizedDescription
            }
        }
    }
}
