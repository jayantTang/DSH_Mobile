import RelayKit
import SwiftUI

/// 记录页能打开的两样东西：一条线程，或一条通知。
private enum FeedbackDestination: Hashable {
    case thread(String)
    case notice(String)
}

/// 「收到的」里的一条回信：某条线程最后一次 owner 留言。
private struct FeedbackReply: Identifiable {
    let thread: FeedbackThread
    let message: FeedbackMessage
    var id: String { thread.threadId }
}

/// 记录页：左边一栏「我发出的」（时间、摘要、待回复/已回复），右边一栏「收到的」
/// （回信与通知，未读标出）。两栏读的都是 ``FeedbackCenter/shared``，所以离线时
/// 显示的是上次拉到的镜像，而不是空白。
struct FeedbackCenterView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var isComposing = false
    @State private var isConfirmingRemove = false
    /// 服务端说这条线程已经不在了。只标这一条，其余记录照常显示（不整页清空）。
    @State private var unavailable: Set<String> = []

    private var center: FeedbackCenter { .shared }

    var body: some View {
        NavigationStack {
            List {
                sentSection
                receivedSection
                if center.storedTicketCount > 0 || !center.threads.isEmpty { localSection }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(DSHTheme.background)
            .accessibilityIdentifier("feedback.center")
            .navigationTitle("反馈")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .navigationDestination(for: FeedbackDestination.self) { destination in
                switch destination {
                case .thread(let threadId):
                    FeedbackThreadView(threadId: threadId) { unavailable.insert(threadId) }
                case .notice(let noticeId):
                    FeedbackNoticeView(noticeId: noticeId)
                }
            }
            .refreshable { await center.refreshInbox(force: true) }
            // 打开记录页拉一次；拉取本身不动已读（FR-012），角标只在真正看过之后才少。
            .task { await center.recordsAppeared() }
        }
        .sheet(isPresented: $isComposing) {
            FeedbackComposerView { }
        }
        .confirmationDialog("移除本机记录？", isPresented: $isConfirmingRemove, titleVisibility: .visible) {
            Button("从这台手机移除", role: .destructive) {
                center.removeLocalRecords()
                unavailable = []
            }
            .accessibilityIdentifier("feedback.removeLocal.confirm")
            Button("取消", role: .cancel) {}
        } message: {
            Text("移除后这台手机再也取不回这些记录；服务器上的副本要另行联系我们删除。")
        }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("关闭") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { isComposing = true } label: {
                Label("发送反馈", systemImage: "square.and.pencil")
            }
            .accessibilityIdentifier("feedback.compose")
        }
    }

    // MARK: - 我发出的

    private var sentSection: some View {
        Section {
            if center.threads.isEmpty {
                VStack(alignment: .leading, spacing: DSHTheme.Spacing.hairline) {
                    Text(sentEmptyText)
                        .font(DSHTheme.Typography.caption)
                        .foregroundStyle(DSHTheme.labelSecondary)
                        .accessibilityIdentifier("feedback.center.emptySent")
                    // 空列表加上"这次没拉到"才不是假话：镜像里没有，不代表服务器上没有。
                    if center.lastError != nil {
                        Text("现在连不上服务器，这里只显示已经拉到这台手机上的内容。")
                            .font(DSHTheme.Typography.micro)
                            .foregroundStyle(DSHTheme.labelTertiary)
                    }
                }
            }
            ForEach(center.threads) { thread in
                NavigationLink(value: FeedbackDestination.thread(thread.threadId)) {
                    FeedbackThreadRow(thread: thread, isUnavailable: unavailable.contains(thread.threadId))
                }
                .accessibilityIdentifier("feedback.row.\(thread.threadId)")
            }
        } header: {
            Text("我发出的")
        }
    }

    /// 没有记录时要说清"为什么没有"：凭据丢了就是丢了，这台手机不是某个账号的客户端
    /// （spec 边界情况）。没凭据但有设备身份时是另一种来源，文案也不一样。
    private var sentEmptyText: LocalizedStringKey {
        center.storedTicketCount == 0
            ? "这台手机还没有反馈记录；取件凭据丢失后历史无法恢复，重新配对也换不回匿名提交的那部分。"
            : "还没有发出过反馈。"
    }

    // MARK: - 收到的

    private var receivedSection: some View {
        Section {
            if replies.isEmpty && center.notices.isEmpty {
                Text("还没有收到消息。我们回信或发通知时，都会出现在这里。")
                    .font(DSHTheme.Typography.caption)
                    .foregroundStyle(DSHTheme.labelSecondary)
                    .accessibilityIdentifier("feedback.center.emptyReceived")
            }
            ForEach(replies) { reply in
                NavigationLink(value: FeedbackDestination.thread(reply.thread.threadId)) {
                    FeedbackReplyRow(reply: reply)
                }
                .accessibilityIdentifier("feedback.row.\(reply.thread.threadId)")
            }
            ForEach(center.notices) { notice in
                NavigationLink(value: FeedbackDestination.notice(notice.noticeId)) {
                    FeedbackNoticeRow(notice: notice)
                }
                .accessibilityIdentifier("feedback.row.\(notice.noticeId)")
            }
        } header: {
            Text("收到的")
        }
    }

    /// 回信＝某条线程里最后一次 owner 留言；按时间倒序，与通知混排看先后。
    private var replies: [FeedbackReply] {
        center.threads
            .compactMap { thread in
                thread.messages.last { $0.author == .owner }.map { FeedbackReply(thread: thread, message: $0) }
            }
            .sorted { ($0.message.createdAt ?? .distantPast) > ($1.message.createdAt ?? .distantPast) }
    }

    // MARK: - 本机记录

    private var localSection: some View {
        Section {
            Button(role: .destructive) {
                isConfirmingRemove = true
            } label: {
                Text("从这台手机移除")
            }
            .accessibilityIdentifier("feedback.removeLocal")
        } footer: {
            Text("移除后这台手机再也取不回这些记录；服务器上的副本要另行联系我们删除。")
        }
    }
}

// MARK: - Rows

/// 我发出的一条：摘要、最近活动时间、待回复/已回复。
private struct FeedbackThreadRow: View {

    let thread: FeedbackThread
    var isUnavailable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(isUnavailable
                 ? String(localized: "这条记录在服务器上已不存在，可能已被删除。")
                 : summary)
                .font(DSHTheme.Typography.body)
                .foregroundStyle(isUnavailable ? DSHTheme.labelError : DSHTheme.labelPrimary)
                .lineLimit(3)
            HStack(spacing: DSHTheme.Spacing.hairline) {
                Text(FeedbackTime.text(thread.lastMessageAt ?? thread.createdAt))
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.labelTertiary)
                Text("·")
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.labelDimmed)
                if thread.isReplied {
                    Text("已回复")
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.success)
                } else {
                    Text("待回复")
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelTertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// 刚提交、正文还没从服务器同步回来时也要有一行字，不能是空白行。
    private var summary: String {
        let body = thread.messages.last?.body.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return body.isEmpty ? String(localized: "已提交，正在同步") : body
    }
}

/// 收到的一条回信：正文摘要、时间、未读标出。
private struct FeedbackReplyRow: View {

    let reply: FeedbackReply

    private var isUnread: Bool { reply.thread.unread > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(reply.message.body)
                .font(DSHTheme.Typography.body)
                .foregroundStyle(DSHTheme.labelPrimary)
                .lineLimit(3)
            HStack(spacing: DSHTheme.Spacing.hairline) {
                Text("DSH Mobile 团队")
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.labelTertiary)
                Text("·")
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.labelDimmed)
                Text(FeedbackTime.text(reply.message.createdAt))
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.labelTertiary)
                if isUnread { UnreadMark() }
            }
        }
        .padding(.vertical, 2)
    }
}

/// 收到的一条通知。
private struct FeedbackNoticeRow: View {

    let notice: FeedbackNotice

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: DSHTheme.Spacing.hairline) {
                Text(subject)
                    .font(DSHTheme.Typography.bodyStrong)
                    .foregroundStyle(DSHTheme.labelPrimary)
                    .lineLimit(1)
                if !notice.read { UnreadMark() }
            }
            Text(notice.body)
                .font(DSHTheme.Typography.caption)
                .foregroundStyle(DSHTheme.labelSecondary)
                .lineLimit(3)
            Text(FeedbackTime.text(notice.createdAt))
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelTertiary)
        }
        .padding(.vertical, 2)
    }

    private var subject: String {
        notice.subject.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "服务通知")
    }
}

/// 未读的小标记。用文字而不是圆点：这一栏的未读不止一处，说清楚比好看重要。
private struct UnreadMark: View {
    var body: some View {
        Text("未读")
            .font(DSHTheme.Typography.micro)
            .foregroundStyle(DSHTheme.attention)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(DSHTheme.attention.opacity(0.13), in: Capsule())
    }
}
