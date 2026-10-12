import RelayKit
import SwiftUI

/// 记录页、详情页与发送窗口共用的一种时间写法：本地时区的月日 + 时分。
///
/// 不用"几分钟前"：反馈是留言不是聊天，来回可能隔几天，用户要看的是**哪天**。
/// 也不写年份：记录是最近的事，年份会把一行里的发件人名字挤没。时间戳缺失时
/// 镜像里退到纪元 0，那种值不显示。
enum FeedbackTime {
    static func text(_ date: Date?) -> String {
        guard let date, date.timeIntervalSince1970 > 0 else { return "" }
        return date.formatted(.dateTime.month().day().hour().minute())
    }
}

/// 主题的兜底口径：用户没写标题时，拿正文首句截断当主题。
///
/// 列表与详情必须用同一个函数，否则同一封反馈在两处会显示成两个不同的标题。
enum FeedbackSubject {

    /// 一个主题最多显示多少字。原生 `subject` 上限 80，这只管兜底那一句。
    static let fallbackLimit = 40

    /// 主题行：优先用服务端/提交时的 `subject`，为空时退到正文首句。
    static func line(subject: String?, body: String?) -> String {
        if let subject {
            let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return firstSentence(of: body)
    }

    /// 正文首句：断在第一个换行或句末标点上，再截到 ``fallbackLimit``。
    static func firstSentence(of body: String?) -> String {
        let text = (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        let head = text.prefix { !$0.isNewline && !Self.endsSentence($0) }
        let sentence = head.trimmingCharacters(in: .whitespaces)
        let base = sentence.isEmpty ? text : String(sentence)
        guard base.count > fallbackLimit else { return base }
        return String(base.prefix(fallbackLimit)) + "…"
    }

    /// 句末标点：半角与全角的句号、问号、感叹号，外加分号。
    ///
    /// 写成 `switch` 而不是标点字面量集合：本地化检查器把含中日韩标点的字面量当文案，
    /// 而这是断句规则，不是给人看的话。
    private static func endsSentence(_ character: Character) -> Bool {
        switch character {
        case ".", "!", "?", ";": return true
        case "\u{3002}", "\u{FF01}", "\u{FF1F}", "\u{FF1B}": return true
        default: return false
        }
    }

    /// 收件箱里**回信**那一行的主题。
    ///
    /// 线程没有 `subject` 时不能拿回信正文首句顶上去：正式回信的开头是「你好：」，
    /// 顶到标题行就是我们自己在 2026-10-12 修过一次的那个毛病。退到**用户自己那句话**
    /// 更像邮件：`关于你的反馈：<用户首句>`。
    static func replyLine(threadSubject: String?, userBody: String?, replyBody: String?) -> String {
        if let subject = threadSubject?.trimmingCharacters(in: .whitespacesAndNewlines),
           !subject.isEmpty {
            return subject
        }
        let topic = firstSentence(of: userBody)
        guard !topic.isEmpty else { return firstSentence(of: replyBody) }
        return String(localized: "关于你的反馈：\(topic)")
    }

    /// 列表里的摘要：跳过问候与署名那几行，取正文里第一段有内容的话。
    ///
    /// 直接拿 `body` 当摘要的话，一行里只会看到「你好：」。规则先在"非脚手架"的行里挑，
    /// 一行都不剩才退回原文第一行——短消息因此不会被摘要吃空。
    static func snippet(of body: String?) -> String {
        let lines = (body ?? "").split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let substance = lines.filter { !isScaffolding($0) }
        let picked = substance.first ?? lines.first ?? ""
        guard picked.count > snippetLimit else { return picked }
        return String(picked.prefix(snippetLimit)) + "…"
    }

    /// 摘要最多显示多少字（一行的量）。
    private static let snippetLimit = 60

    /// 信件的"脚手架"行：称呼（短且以冒号收尾）、署名、纯日期。
    private static func isScaffolding(_ line: String) -> Bool {
        if line.count <= 6 { return true }
        if line.hasPrefix("DSH Mobile 团队") { return true }
        return line.allSatisfy { $0.isNumber || $0 == "-" || $0 == "/" || $0 == "." }
    }
}

/// 线程详情：按信件往返呈现（FR-010）。
///
/// 我方的每一条是灰底「我发出的」卡，owner 的回信是白底描边的信件卡——我们回的是
/// 正式答复，不是即时消息（FR-015，也是 spec 明确的非目标）。底部不再是常驻输入条：
/// 先是一颗「写回复」，点开才出现输入区，所以看信的界面就是看信的界面。
struct FeedbackThreadView: View {

    let threadId: String
    /// 服务端说这条线程已经不存在了：调用方把这一条标成不可用，其余记录不动。
    var onUnavailable: () -> Void = {}

    @State private var draft = ""
    @State private var failure: String?
    @State private var isAppending = false
    @State private var isReplying = false

    private var center: FeedbackCenter { .shared }
    private var thread: FeedbackThread? { center.thread(threadId) }

    private var canAppend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.count <= FeedbackLimits.maxBodyLength
            && !isAppending
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSHTheme.Spacing.standard) {
                if let failure { failureBanner(failure) }
                if let thread {
                    if thread.messages.isEmpty {
                        Text("已提交，正在同步")
                            .font(DSHTheme.Typography.caption)
                            .foregroundStyle(DSHTheme.labelSecondary)
                    }
                    ForEach(Array(orderedMessages.enumerated()), id: \.element.id) { index, message in
                        if message.author == .owner {
                            OwnerLetterCard(sender: String(localized: "DSH Mobile 团队"),
                                            subject: FeedbackSubject.line(subject: thread.subject,
                                                                          body: message.body),
                                            text: message.body,
                                            createdAt: message.createdAt)
                        } else {
                            // 主题只写在第一封上：那是用户写标题的地方，后面的补充不必重复。
                            UserLetterCard(text: message.body, createdAt: message.createdAt,
                                           subject: index == 0 ? thread.subject : nil)
                        }
                    }
                } else {
                    Text("这条记录在服务器上已不存在，可能已被删除。")
                        .font(DSHTheme.Typography.caption)
                        .foregroundStyle(DSHTheme.labelSecondary)
                }
            }
            .padding(DSHTheme.Spacing.loose)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DSHTheme.background)
        .accessibilityIdentifier("feedback.thread")
        .navigationTitle("反馈详情")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) { replyBar }
        // 打开这一条才算读过（FR-012）：标记动作在中心里，离线时角标保持原样。
        .task { await center.openThread(threadId) }
    }

    // MARK: - 写回复（US5）

    /// 按时间正序。服务端返回的顺序不保证，而"往返"必须按发生的先后读。
    private var orderedMessages: [FeedbackMessage] {
        (thread?.messages ?? []).sorted {
            ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
        }
    }

    /// 折叠着只有一颗「写回复」；展开后才出现输入区，旁边可以再收起来。
    @ViewBuilder
    private var replyBar: some View {
        VStack(spacing: 0) {
            Hairline()
            if isReplying {
                HStack(alignment: .bottom, spacing: DSHTheme.Spacing.tight) {
                    TextField("补充一句…", text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                        .font(DSHTheme.Typography.body)
                        .padding(.horizontal, DSHTheme.Spacing.tight)
                        .padding(.vertical, 7)
                        .background(DSHTheme.layer2,
                                    in: RoundedRectangle(cornerRadius: DSHTheme.Radius.medium,
                                                         style: .continuous))
                        .accessibilityIdentifier("feedback.appendText")
                    Button {
                        Task { await append() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(canAppend ? DSHTheme.brand : DSHTheme.labelDimmed)
                    }
                    .disabled(!canAppend)
                    .accessibilityIdentifier("feedback.append")
                    .accessibilityLabel("追加")
                }
                .padding(.horizontal, DSHTheme.Spacing.loose)
                .padding(.top, DSHTheme.Spacing.tight)
                Button("取消") {
                    draft = ""
                    isReplying = false
                }
                .font(DSHTheme.Typography.caption)
                .foregroundStyle(DSHTheme.labelSecondary)
                .padding(.vertical, DSHTheme.Spacing.hairline)
            } else {
                Button {
                    isReplying = true
                } label: {
                    Text("写回复")
                        .font(DSHTheme.Typography.bodyStrong)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(DSHTheme.brand)
                        .background(DSHTheme.layer1,
                                    in: RoundedRectangle(cornerRadius: DSHTheme.Radius.medium,
                                                         style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous)
                                .strokeBorder(DSHTheme.brand)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("feedback.reply")
                .padding(DSHTheme.Spacing.loose)
            }
        }
        .background(DSHTheme.layer1)
    }

    private func append() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, body.count <= FeedbackLimits.maxBodyLength else {
            failure = String(localized: "补充的内容不能为空，也不能超过 4000 字。")
            return
        }
        isAppending = true
        defer { isAppending = false }
        do {
            try await center.append(threadId: threadId, text: body)
            draft = ""
            failure = nil
            isReplying = false
            await center.refreshInbox(force: true)
        } catch let error as FeedbackClientError {
            failure = FeedbackErrorText.text(for: error)
            // 线程被删了：只把这一条标成不可用，不假装成功、也不清掉别的记录。
            if error == .notFound { onUnavailable() }
        } catch {
            failure = String(localized: "提交没有成功，内容还在，可以再试。")
        }
    }

    private func failureBanner(_ message: String) -> some View {
        Text(message)
            .font(DSHTheme.Typography.caption)
            .foregroundStyle(DSHTheme.labelError)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("feedback.thread.failure")
    }
}

// MARK: - 信件式卡片

/// 一封信的抬头：发件人（带一个小圆头像）+ 时间。往返里的每一封都有。
private struct LetterHeader: View {

    let sender: String
    let createdAt: Date?
    /// 我方发出的用灰头像，对方用品牌色。
    let isMine: Bool

    private var initial: String { String(sender.prefix(1)) }

    var body: some View {
        HStack(spacing: DSHTheme.Spacing.hairline) {
            Text(isMine ? "我" : initial)
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(isMine ? DSHTheme.labelSecondary : DSHTheme.brand)
                .frame(width: 20, height: 20)
                .background(isMine ? Color.black.opacity(0.06) : DSHTheme.brandSubtle, in: Circle())
            Text(sender)
                .font(DSHTheme.Typography.caption.weight(.semibold))
                .foregroundStyle(DSHTheme.labelPrimary)
                .lineLimit(1)
            Spacer(minLength: DSHTheme.Spacing.hairline)
            Text(FeedbackTime.text(createdAt))
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelTertiary)
        }
    }
}

/// owner 的回信：发件人 + 主题行 + 分隔线 + 正文。
///
/// 通知用同一张卡片（发件人换成「服务通知」），两种"我们发给用户的东西"外观一致。
struct OwnerLetterCard: View {

    let sender: String
    let subject: String
    /// 正文。不能叫 `body`：那是 `View` 的要求，同名会撞成重复声明。
    let text: String
    let createdAt: Date?

    init(message: FeedbackMessage) {
        self.sender = String(localized: "DSH Mobile 团队")
        self.subject = FeedbackSubject.line(subject: nil, body: message.body)
        self.text = message.body
        self.createdAt = message.createdAt
    }

    init(sender: String, subject: String, text: String, createdAt: Date?) {
        self.sender = sender
        self.subject = subject
        self.text = text
        self.createdAt = createdAt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.tight) {
            LetterHeader(sender: sender, createdAt: createdAt, isMine: false)
            if !subject.isEmpty {
                Text(subject)
                    .font(DSHTheme.Typography.body.weight(.semibold))
                    .foregroundStyle(DSHTheme.labelPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Hairline()
            Text(text)
                .font(DSHTheme.Typography.body)
                .foregroundStyle(DSHTheme.labelPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DSHTheme.Spacing.standard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSHTheme.layer1,
                    in: RoundedRectangle(cornerRadius: DSHTheme.Radius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DSHTheme.Radius.large, style: .continuous)
                .strokeBorder(DSHTheme.border2)
        }
    }
}

/// 我方发出的：灰底「我发出的」卡，带时间；比对方的信件卡轻，一眼分得出谁写的。
struct UserLetterCard: View {

    let text: String
    let createdAt: Date?

    /// 详情里只在最上面那封我方留言上写主题，其余按卡片重复反而更乱。
    var subject: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.hairline) {
            LetterHeader(sender: String(localized: "我发出的"), createdAt: createdAt, isMine: true)
            if let subject, !subject.isEmpty {
                Text(subject)
                    .font(DSHTheme.Typography.body.weight(.semibold))
                    .foregroundStyle(DSHTheme.labelPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            }
            Text(text)
                .font(DSHTheme.Typography.body)
                .foregroundStyle(DSHTheme.labelPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DSHTheme.Spacing.standard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSHTheme.layer2,
                    in: RoundedRectangle(cornerRadius: DSHTheme.Radius.large, style: .continuous))
    }
}

/// 一条通知的详情：与回信同一种信件式版式，打开即记已读。
struct FeedbackNoticeView: View {

    let noticeId: String

    private var center: FeedbackCenter { .shared }
    private var notice: FeedbackNotice? { center.notice(noticeId) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSHTheme.Spacing.standard) {
                if let notice {
                    OwnerLetterCard(
                        sender: String(localized: "服务通知"),
                        subject: FeedbackSubject.line(subject: notice.subject, body: notice.body),
                        text: notice.body,
                        createdAt: notice.createdAt
                    )
                } else {
                    Text("这条通知已经不在了。")
                        .font(DSHTheme.Typography.caption)
                        .foregroundStyle(DSHTheme.labelSecondary)
                }
            }
            .padding(DSHTheme.Spacing.loose)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DSHTheme.background)
        .accessibilityIdentifier("feedback.notice")
        .navigationTitle("通知")
        .navigationBarTitleDisplayMode(.inline)
        .task { await center.openNotice(noticeId) }
    }
}
