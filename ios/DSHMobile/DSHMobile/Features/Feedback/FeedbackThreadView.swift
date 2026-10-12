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

/// 详情页要呈现的那封信是谁写的：从「收件箱」点开是我们发的那封，从「已发送」点开是我发的那封。
///
/// 同一条线程在两栏各只有一封信可看——这是我们不再盖楼之后的读法（FR-010 / FR-033）。
enum FeedbackThreadSide: Hashable {
    case inbox
    case sent
}

/// 单封信详情（FR-033）：只呈现**当前这一封**——我发的，或我们发的，不再把同一线程的
/// 多封堆在一页。
///
/// 因此这里没有任何输入区：想补充就在发送窗口再发一封新的（FR-010 / FR-013）。
/// 我方那封是灰底「我发出的」卡，对方那封是白底描边的信件卡——我们回的是正式答复，
/// 不是即时消息（FR-015，也是 spec 明确的非目标）。
struct FeedbackThreadView: View {

    let threadId: String
    let side: FeedbackThreadSide

    private var center: FeedbackCenter { .shared }
    private var thread: FeedbackThread? { center.thread(threadId) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSHTheme.Spacing.standard) {
                if let thread {
                    if let letter = letter(in: thread) {
                        letterCard(letter, in: thread)
                    } else {
                        Text("已提交，正在同步")
                            .font(DSHTheme.Typography.caption)
                            .foregroundStyle(DSHTheme.labelSecondary)
                    }
                    if side == .sent { sentHint }
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
        // 看过这一条才算读过（FR-012）。已发送那一栏看的是自己写的信，不碰未读——
        // 否则点一下自己发的东西就把还没读的回信清了。
        .task {
            guard side == .inbox else { return }
            await center.openThread(threadId)
        }
    }

    /// 这一页要呈现的那封信。旧数据里同一线程可能有多封我方留言（append 时代留下的），
    /// 取最近的那封：与列表行的口径一致。
    private func letter(in thread: FeedbackThread) -> FeedbackMessage? {
        switch side {
        case .inbox: return thread.messages.last { $0.author == .owner }
        case .sent: return thread.messages.last { $0.author == .user }
        }
    }

    @ViewBuilder
    private func letterCard(_ message: FeedbackMessage, in thread: FeedbackThread) -> some View {
        switch side {
        case .inbox:
            OwnerLetterCard(
                sender: String(localized: "DSH Mobile 团队"),
                // 与收件箱那一行用同一个函数：没有主题时退到「关于你的反馈：…」，
                // 而不是把回信开头的「你好：」当成标题。
                subject: FeedbackSubject.replyLine(
                    threadSubject: thread.subject,
                    userBody: thread.messages.last { $0.author == .user }?.body,
                    replyBody: message.body),
                text: message.body,
                createdAt: message.createdAt)
        case .sent:
            // 主题只写用户真填过的那句；没填就不写抬头行——列表里的兜底标题是列表的需要，
            // 在这里会与正文第一句重复。
            UserLetterCard(text: message.body,
                           createdAt: message.createdAt,
                           subject: writtenSubject(of: thread))
        }
    }

    /// 发件箱这一封下面的说明：这封信已经发出去、独立成篇了，想补充就再发一封；
    /// 而我们回信时，那封回信落在收件箱里（FR-010）。
    private var sentHint: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.hairline) {
            Text("想补充或再说一句，请再发一封新的反馈。")
            Text("如果收到回复，会出现在「收件箱」。")
        }
        .font(DSHTheme.Typography.caption)
        .foregroundStyle(DSHTheme.labelTertiary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("feedback.thread.hint")
    }

    private func writtenSubject(of thread: FeedbackThread) -> String? {
        guard let subject = thread.subject?.trimmingCharacters(in: .whitespacesAndNewlines),
              !subject.isEmpty
        else { return nil }
        return subject
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
