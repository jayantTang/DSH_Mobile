import RelayKit
import SwiftUI

/// 记录页能打开的两样东西：一条线程，或一条通知。
private enum FeedbackDestination: Hashable {
    case thread(String)
    case notice(String)
}

/// 收件箱里混排的两样东西：我们回的某条线程，或一条通知。同一个"收"栏，按时间排先后。
private enum InboxItem: Identifiable {
    case reply(FeedbackThread, FeedbackMessage)
    case notice(FeedbackNotice)

    var id: String {
        switch self {
        case .reply(let thread, _): return thread.threadId
        case .notice(let notice): return notice.noticeId
        }
    }

    var createdAt: Date {
        switch self {
        case .reply(_, let message): return message.createdAt ?? .distantPast
        case .notice(let notice): return notice.createdAt ?? .distantPast
        }
    }
}

/// 记录页的两栏。
private enum FeedbackTab: Hashable {
    case inbox
    case sent
}

/// 记录页：一栏「收件箱」（回信与通知混排，未读标蓝点），一栏「已发送」
/// （主题、时间、待回复/已回复、摘要）。两栏读的都是 ``FeedbackCenter/shared``，
/// 所以离线时显示的是上次拉到的镜像，而不是空白。
struct FeedbackCenterView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var tab: FeedbackTab = .inbox
    @State private var isComposing = false
    @State private var isConfirmingRemove = false
    /// 服务端说这条线程已经不在了。只标这一条，其余记录照常显示（不整页清空）。
    @State private var unavailable: Set<String> = []

    private var center: FeedbackCenter { .shared }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabPicker
                List {
                    switch tab {
                    case .inbox: inboxRows
                    case .sent: sentRows
                    }
                    if hasLocalRecords { localSection }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(DSHTheme.background)
                .accessibilityIdentifier("feedback.center")
            }
            .background(DSHTheme.background)
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
            // 发送成功后关窗，并把记录页切到「已发送」：刚写完的那条就在眼前
            // （`test/cases/current/48-*.steps` 第 8 步等的是 `feedback.row.` 出现）。
            FeedbackComposerView { tab = .sent }
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

    // MARK: - 分栏

    /// 收件箱带未读数（与入口角标同一个口径）。已发送那栏不写条数：那是"我发过几条"，
    /// 不是需要处理的事，写上去反而把两栏看成一回事。
    private var tabPicker: some View {
        Picker("栏目", selection: $tab) {
            Text(center.unreadCount > 0 ? "收件箱 \(center.unreadCount)" : "收件箱")
                .tag(FeedbackTab.inbox)
                .accessibilityIdentifier("feedback.tab.inbox")
            Text("已发送")
                .tag(FeedbackTab.sent)
                .accessibilityIdentifier("feedback.tab.sent")
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, DSHTheme.Spacing.loose)
        .padding(.vertical, DSHTheme.Spacing.tight)
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

    // MARK: - 已发送

    private var sentRows: some View {
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
                    FeedbackSentRow(thread: thread, isUnavailable: unavailable.contains(thread.threadId))
                }
                .accessibilityIdentifier("feedback.row.\(thread.threadId)")
            }
        }
    }

    /// 没有记录时要说清"为什么没有"：凭据丢了就是丢了，这台手机不是某个账号的客户端
    /// （spec 边界情况）。没凭据但有设备身份时是另一种来源，文案也不一样。
    private var sentEmptyText: LocalizedStringKey {
        center.storedTicketCount == 0
            ? "这台手机还没有反馈记录；取件凭据丢失后历史无法恢复，重新配对也换不回匿名提交的那部分。"
            : "还没有发出过反馈。点右上角的笔，写下第一条。"
    }

    // MARK: - 收件箱

    private var inboxRows: some View {
        Section {
            if inboxItems.isEmpty {
                VStack(alignment: .leading, spacing: DSHTheme.Spacing.hairline) {
                    Text("还没有收到消息。我们回信或发通知时，都会出现在这里。")
                        .font(DSHTheme.Typography.caption)
                        .foregroundStyle(DSHTheme.labelSecondary)
                        .accessibilityIdentifier("feedback.center.emptyReceived")
                    if center.lastError != nil {
                        Text("现在连不上服务器，这里只显示已经拉到这台手机上的内容。")
                            .font(DSHTheme.Typography.micro)
                            .foregroundStyle(DSHTheme.labelTertiary)
                    }
                }
            }
            ForEach(inboxItems) { item in
                switch item {
                case .reply(let thread, let message):
                    NavigationLink(value: FeedbackDestination.thread(thread.threadId)) {
                        FeedbackInboxRow(sender: String(localized: "DSH Mobile 团队"),
                                         // 主题优先用线程自己的 `subject`；没有就退到
                                         // 「关于你的反馈：<用户那句>」，而不是把回信的
                                         // 「你好：」顶到标题行（见 `FeedbackSubject.replyLine`）。
                                         subject: FeedbackSubject.replyLine(
                                             threadSubject: thread.subject,
                                             userBody: thread.messages.first { $0.author == .user }?.body,
                                             replyBody: message.body),
                                         snippet: FeedbackSubject.snippet(of: message.body),
                                         createdAt: message.createdAt,
                                         isUnread: center.isUnread(messageId: message.messageId))
                    }
                    .accessibilityIdentifier("feedback.row.\(thread.threadId)")
                case .notice(let notice):
                    NavigationLink(value: FeedbackDestination.notice(notice.noticeId)) {
                        FeedbackInboxRow(sender: String(localized: "服务通知"),
                                         subject: FeedbackSubject.line(subject: notice.subject,
                                                                       body: notice.body),
                                         snippet: FeedbackSubject.snippet(of: notice.body),
                                         createdAt: notice.createdAt,
                                         isUnread: center.isUnread(noticeId: notice.noticeId))
                    }
                    .accessibilityIdentifier("feedback.row.\(notice.noticeId)")
                }
            }
        }
    }

    /// 回信＝某条线程里最后一次 owner 留言；与通知混排，按时间倒序看先后。
    private var inboxItems: [InboxItem] {
        let replies = center.threads.compactMap { thread in
            thread.messages.last { $0.author == .owner }.map { InboxItem.reply(thread, $0) }
        }
        let notices = center.notices.map { InboxItem.notice($0) }
        return (replies + notices).sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - 本机记录

    /// 「从这台手机移除」降到页脚：它是清理，不是日常动作，不该占着列表中间一行。
    private var hasLocalRecords: Bool {
        center.storedTicketCount > 0 || !center.threads.isEmpty || !center.notices.isEmpty
    }

    private var localSection: some View {
        Section {
            Button {
                isConfirmingRemove = true
            } label: {
                Text("从这台手机移除记录…")
                    .font(DSHTheme.Typography.caption)
                    .foregroundStyle(DSHTheme.labelTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .accessibilityIdentifier("feedback.removeLocal")
        }
    }
}

// MARK: - Rows

/// 收件箱的一条：发件人 + 主题 + 一行摘要 + 时间 + 未读蓝点。
///
/// 回信与通知共用一行——它们都是"我们发给你的"，分开排只会让人来回找。
private struct FeedbackInboxRow: View {

    let sender: String
    let subject: String
    let snippet: String
    let createdAt: Date?
    let isUnread: Bool

    var body: some View {
        HStack(alignment: .top, spacing: DSHTheme.Spacing.tight) {
            Circle()
                .fill(isUnread ? DSHTheme.attention : .clear)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: DSHTheme.Spacing.tight) {
                    Text(sender)
                        .font(DSHTheme.Typography.body.weight(isUnread ? .semibold : .regular))
                        .foregroundStyle(isUnread ? DSHTheme.labelPrimary : DSHTheme.labelSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(FeedbackTime.text(createdAt))
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelTertiary)
                }
                if !subject.isEmpty {
                    Text(subject)
                        .font(DSHTheme.Typography.body.weight(isUnread ? .semibold : .regular))
                        .foregroundStyle(DSHTheme.labelPrimary)
                        .lineLimit(1)
                }
                if !snippet.isEmpty {
                    Text(snippet)
                        .font(DSHTheme.Typography.caption)
                        .foregroundStyle(DSHTheme.labelTertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// 已发送的一条：主题 + 时间 + 待回复/已回复 + 摘要。
private struct FeedbackSentRow: View {

    let thread: FeedbackThread
    var isUnavailable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if isUnavailable {
                Text("这条记录在服务器上已不存在，可能已被删除。")
                    .font(DSHTheme.Typography.body)
                    .foregroundStyle(DSHTheme.labelError)
                    .lineLimit(3)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: DSHTheme.Spacing.tight) {
                    Text(subject)
                        .font(DSHTheme.Typography.body.weight(.semibold))
                        .foregroundStyle(DSHTheme.labelPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(FeedbackTime.text(thread.lastMessageAt ?? thread.createdAt))
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelTertiary)
                }
                HStack(spacing: DSHTheme.Spacing.tight) {
                    status
                    if !summary.isEmpty {
                        Text(summary)
                            .font(DSHTheme.Typography.caption)
                            .foregroundStyle(DSHTheme.labelTertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// 主题：用户没写就退到正文首句（与详情、收件箱同一个函数）。
    private var subject: String {
        let line = FeedbackSubject.line(subject: thread.subject, body: thread.messages.first?.body)
        return line.isEmpty ? String(localized: "已提交，正在同步") : line
    }

    /// 摘要：最近一条留言的正文（跳过问候与署名那几行）；刚提交、正文还没同步回来时就不显示这一行。
    private var summary: String {
        FeedbackSubject.snippet(of: thread.messages.last?.body)
    }

    @ViewBuilder
    private var status: some View {
        if thread.isReplied {
            Text("已回复")
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.success)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(DSHTheme.success.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: DSHTheme.Radius.small, style: .continuous))
        } else {
            Text("待回复")
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.black.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: DSHTheme.Radius.small, style: .continuous))
        }
    }
}
