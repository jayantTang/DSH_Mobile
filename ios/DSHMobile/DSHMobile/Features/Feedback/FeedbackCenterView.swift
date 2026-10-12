import RelayKit
import SwiftUI

/// 记录页能打开的两样东西：一条线程，或一条通知。
///
/// 线程还带着"从哪一栏点开的"：两栏看的是同一条线程，但详情只呈现其中的**一封**
/// ——收件箱点开是我们回的那封，已发送点开是我发的那封（FR-033）。
private enum FeedbackDestination: Hashable {
    case thread(String, FeedbackThreadSide)
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

/// 记录页：一栏「收件箱」（回信与通知混排，未读标蓝点），一栏「已发送」。
///
/// 两栏是同一套邮件式排版、同一个发件人名，靠"你在哪个箱子"区分（FR-032）；都不写
/// "我们回没回"（FR-032 后半）。两栏读的都是 ``FeedbackCenter/shared``，
/// 所以离线时显示的是上次拉到的镜像，而不是空白。
struct FeedbackCenterView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var tab: FeedbackTab = .inbox
    @State private var isComposing = false

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
                case .thread(let threadId, let side):
                    FeedbackThreadView(threadId: threadId, side: side)
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
            // （`test/cases/current/49-*.steps` 第 13 步等的是 `feedback.row.` 出现）。
            FeedbackComposerView { tab = .sent }
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
                Text(emptyLine("还没有发过反馈"))
                    .font(DSHTheme.Typography.caption)
                    .foregroundStyle(DSHTheme.labelSecondary)
                    .accessibilityIdentifier("feedback.center.emptySent")
            }
            ForEach(sentThreads) { thread in
                NavigationLink(value: FeedbackDestination.thread(thread.threadId, .sent)) {
                    FeedbackSentRow(thread: thread)
                }
                .accessibilityIdentifier("feedback.row.\(thread.threadId)")
            }
        }
    }

    /// 发件箱按**我发信的时间**倒序：`center.threads` 是按 `lastMessageAt` 排的，收到回信之后
    /// 那封信会往前跳，看起来像"我刚发了一封"（2026-10-12 改成单封信模型后一并修）。
    private var sentThreads: [FeedbackThread] {
        center.threads.sorted { sentAt($0) > sentAt($1) }
    }

    /// 空态**只留一行**（owner：参考一般邮箱，无谓的小字不要有）。
    ///
    /// 拉不到内容时把这一行换成"连不上服务器"：离线且镜像为空时，否则看不出是没拉到还是真没有，
    /// 而多写一行说明就又不是邮箱的样子了。
    private func emptyLine(_ normal: LocalizedStringKey) -> LocalizedStringKey {
        center.lastError == nil ? normal : "现在连不上服务器"
    }

    private func sentAt(_ thread: FeedbackThread) -> Date {
        thread.messages.last { $0.author == .user }?.createdAt ?? thread.createdAt ?? .distantPast
    }

    // MARK: - 收件箱

    private var inboxRows: some View {
        Section {
            if inboxItems.isEmpty {
                Text(emptyLine("没有新消息"))
                    .font(DSHTheme.Typography.caption)
                    .foregroundStyle(DSHTheme.labelSecondary)
                    .accessibilityIdentifier("feedback.center.emptyReceived")
            }
            ForEach(inboxItems) { item in
                switch item {
                case .reply(let thread, let message):
                    NavigationLink(value: FeedbackDestination.thread(thread.threadId, .inbox)) {
                        FeedbackMailRow(firstLine: String(localized: "DSH Mobile 团队"),
                                        // 主题优先用线程自己的 `subject`；没有就退到
                                        // 「关于你的反馈：<用户那句>」，而不是把回信的
                                        // 「你好：」顶到标题行（见 `FeedbackSubject.replyLine`）。
                                        subject: FeedbackSubject.replyLine(
                                            threadSubject: thread.subject,
                                            userBody: thread.messages.first { $0.author == .user }?.body,
                                            replyBody: message.body),
                                        snippet: FeedbackSubject.snippet(of: message.body),
                                        createdAt: message.createdAt,
                                        unread: center.isUnread(messageId: message.messageId))
                    }
                    .accessibilityIdentifier("feedback.row.\(thread.threadId)")
                case .notice(let notice):
                    NavigationLink(value: FeedbackDestination.notice(notice.noticeId)) {
                        FeedbackMailRow(firstLine: String(localized: "服务通知"),
                                        subject: FeedbackSubject.line(subject: notice.subject,
                                                                      body: notice.body),
                                        snippet: FeedbackSubject.snippet(of: notice.body),
                                        createdAt: notice.createdAt,
                                        unread: center.isUnread(noticeId: notice.noticeId))
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
}

// MARK: - Rows

/// 记录页里的一行（收件箱与已发送共用）：首行 + 主题 + 一行摘要 + 时间 [+ 未读蓝点]。
///
/// 首行两栏都写「DSH Mobile 团队」——收件箱里它是发件人，已发送里它是收件人，同一份
/// 排版、同一个字，靠你在哪个箱子区分（FR-032）。
/// 回信与通知也共用这一行——它们都是"我们发给你的"，分开排只会让人来回找。
private struct FeedbackMailRow: View {

    let firstLine: String
    let subject: String
    let snippet: String
    let createdAt: Date?
    /// 没传 = 这一栏没有未读这回事（已发送），只留出与收件箱对齐的空位，不画点。
    var unread: Bool?

    private var isUnread: Bool { unread == true }

    var body: some View {
        HStack(alignment: .top, spacing: DSHTheme.Spacing.tight) {
            Circle()
                .fill(isUnread ? DSHTheme.attention : .clear)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: DSHTheme.Spacing.tight) {
                    Text(firstLine)
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

/// 已发送的一条：与收件箱**同一个组件、同一个首行**（FR-032）。
///
/// 不写"我们回没回"：不一定会逐封回复，这一栏不该看起来像待办列表。
private struct FeedbackSentRow: View {

    let thread: FeedbackThread

    var body: some View {
        FeedbackMailRow(
            firstLine: String(localized: "DSH Mobile 团队"),
            subject: subject,
            snippet: summary,
            // 发件箱里显示的是**我发信那一刻**：`lastMessageAt` 在收到回信之后会变成回信时间，
            // 挂在"我发出的"那一行上就成了错的时间（2026-10-12 owner 要求发件箱也按邮件的样子）。
            createdAt: myLetter?.createdAt ?? thread.createdAt
        )
    }

    /// 主题：用户没写就退到正文首句（与详情、收件箱同一个函数）。
    private var subject: String {
        let line = FeedbackSubject.line(subject: thread.subject, body: myLetter?.body)
        return line.isEmpty ? String(localized: "已提交，正在同步") : line
    }

    /// 摘要：我发出的那封的正文（跳过问候与署名那几行）；刚提交、正文还没同步回来时
    /// 就不显示这一行。取"最后一封我发的"，而不是线程里最后一条——后者可能是回信。
    private var summary: String {
        FeedbackSubject.snippet(of: myLetter?.body)
    }

    private var myLetter: FeedbackMessage? {
        thread.messages.last { $0.author == .user }
    }
}
