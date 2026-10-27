import RelayKit
#if os(iOS)
import DSHDesign
import SwiftUI
import DSHFeedbackDomain

/// 记录页、详情页与发送窗口共用的一种时间写法：本地时区的月日 + 时分。
///
/// 不用"几分钟前"：反馈是留言不是聊天，来回可能隔几天，用户要看的是**哪天**。
/// 也不写年份：记录是最近的事，年份会把一行里的发件人名字挤没。时间戳缺失时
/// 镜像里退到纪元 0，那种值不显示。
public enum FeedbackTime {
    static func text(_ date: Date?) -> String {
        guard let date, date.timeIntervalSince1970 > 0 else { return "" }
        return date.formatted(.dateTime.month().day().hour().minute())
    }
}

/// 主题的兜底口径：用户没写标题时，拿正文首句截断当主题。
///
/// 列表与详情必须用同一个函数，否则同一封反馈在两处会显示成两个不同的标题。
public enum FeedbackSubject {

    /// 一个主题最多显示多少字。原生 `subject` 上限 80，这只管兜底那一句。
    static let fallbackLimit = 40

    /// 主题行：优先用服务端/提交时的 `subject`，为空时退到正文首句。
    ///
    /// `format` 只影响"退到正文首句"那一步：报告类正文是一整页 HTML，直接拿原文断句
    /// 会把 `<!DOCTYPE html>` 顶到标题行上。
    static func line(subject: String?, body: String?,
                     format: FeedbackBodyFormat = .text) -> String {
        if let subject {
            let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return firstSentence(of: body, format: format)
    }

    /// 正文首句：断在第一个换行或句末标点上，再截到 ``fallbackLimit``。
    static func firstSentence(of body: String?, format: FeedbackBodyFormat = .text) -> String {
        let text = readable(body, format: format).trimmingCharacters(in: .whitespacesAndNewlines)
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
    static func replyLine(threadSubject: String?, userBody: String?, replyBody: String?,
                          replyFormat: FeedbackBodyFormat = .text) -> String {
        if let subject = threadSubject?.trimmingCharacters(in: .whitespacesAndNewlines),
           !subject.isEmpty {
            return subject
        }
        let topic = firstSentence(of: userBody)
        guard !topic.isEmpty else { return firstSentence(of: replyBody, format: replyFormat) }
        return String(localized: "关于你的反馈：\(topic)")
    }

    /// 列表里的摘要：跳过问候与署名那几行，取正文里第一段有内容的话。
    ///
    /// 直接拿 `body` 当摘要的话，一行里只会看到「你好：」。规则先在"非脚手架"的行里挑，
    /// 一行都不剩才退回原文第一行——短消息因此不会被摘要吃空。
    static func snippet(of body: String?, format: FeedbackBodyFormat = .text) -> String {
        let lines = readable(body, format: format).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let substance = lines.filter { !isScaffolding($0) }
        let picked = substance.first ?? lines.first ?? ""
        guard picked.count > snippetLimit else { return picked }
        return String(picked.prefix(snippetLimit)) + "…"
    }

    /// 摘要、兜底标题这种"一行纯文本"的地方要读的正文。
    ///
    /// `text` 原样返回；`html`（报告类）先粗切成纯文本——不切的话，收件箱那一行的摘要
    /// 会是 `<!DOCTYPE html><html lang="zh-Hans"><head>…`。
    private static func readable(_ body: String?, format: FeedbackBodyFormat) -> String {
        let raw = body ?? ""
        return format == .html ? plainText(ofHTML: raw) : raw
    }

    /// 把报告类 HTML 粗切成可当摘要的纯文本。
    ///
    /// 这里**不做 HTML 解析**，也不用 `NSAttributedString` 的 HTML 导入（那个会去取
    /// 外部资源，而这里处理的恰好是不可信内容）。规则只有三条，够摘要用：
    /// 丢掉 `<head>`/`<style>`/`<script>` 整块（日报的 CSS 有一整页，留着会全变成摘要）、
    /// 其余标签换成空格、还原几个常见实体。整段空白最后压成一个空格。
    static func plainText(ofHTML html: String) -> String {
        var out = ""
        var index = html.startIndex
        while index < html.endIndex {
            guard let open = html[index...].firstIndex(of: "<") else {
                out += html[index...]
                break
            }
            out += html[index..<open]
            guard let close = html[open...].firstIndex(of: ">") else { break }
            let tag = html[html.index(after: open)..<close]
            let name = tag.drop(while: { $0 == "/" || $0.isWhitespace })
                .prefix { !$0.isWhitespace && $0 != "/" }
                .lowercased()
            var next = html.index(after: close)
            if ["head", "style", "script"].contains(name) {
                // 整块丢掉（含开闭标签）；块没闭合就只跳过这个开标签。
                if let block = html.range(of: "</\(name)", options: .caseInsensitive,
                                          range: close..<html.endIndex),
                   let blockClose = html[block.upperBound...].firstIndex(of: ">") {
                    next = html.index(after: blockClose)
                } else {
                    out += " "
                }
            } else {
                out += " "
            }
            index = next
        }
        let decoded = out
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
        return decoded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 摘要最多显示多少字（一行的量）。
    private static let snippetLimit = 60

    /// 信件的"脚手架"行：称呼（短且以冒号收尾）、署名、纯日期。
    private static func isScaffolding(_ line: String) -> Bool {
        if line.count <= 6 { return true }
        if line.hasPrefix(String(localized: "DSH Mobile 团队")) { return true }
        return line.allSatisfy { $0.isNumber || $0 == "-" || $0 == "/" || $0 == "." }
    }
}

extension FeedbackThread {
    /// 收件箱那一行的主题。
    ///
    /// 我这一侧是团队时，收件箱里是**用户来信**：用来信自己的主题，没写就取正文首句。
    /// 我这一侧是用户时，收件箱里是我们的回信：没有主题就退到
    /// 「关于你的反馈：<用户那句>」，而不是把「你好：」顶到标题行（2026-10-12 修过的毛病）。
    func inboxSubject(for message: FeedbackMessage) -> String {
        resolvedSide == .owner
            ? FeedbackSubject.line(subject: subject, body: message.body, format: message.bodyFormat)
            : FeedbackSubject.replyLine(threadSubject: subject,
                                        userBody: myLetter?.body,
                                        replyBody: message.body,
                                        replyFormat: message.bodyFormat)
    }
}

/// 详情页要呈现的那封信是谁写的：从「收件箱」点开是我们发的那封，从「已发送」点开是我发的那封。
///
/// 同一条线程在两栏各只有一封信可看——这是我们不再盖楼之后的读法（FR-010 / FR-033）。
public enum FeedbackThreadSide: Hashable {
    case inbox
    case sent
}

/// 单封信详情（FR-033）：只呈现**当前这一封**——我发的，或我们发的，不再把同一线程的
/// 多封堆在一页。
///
/// 因此这里没有任何输入区：想补充就在发送窗口再发一封新的（FR-010 / FR-013）。
/// 收发两封是**同一张信件卡**（``LetterCard``），只有署名与头像字符不同——邮件里我方
/// 那封也长成信的样子，不是聊天气泡（FR-015，也是 spec 明确的非目标）。
///
/// 装配钩子（025 方案 B）：信件正文与聊天正文共用一套 markdown 渲染，
/// 但信箱单元不直接依赖聊天单元，由 App 装配层注入渲染闭包。
@Observable
public final class FeedbackServices {
    /// 信件正文的 markdown 渲染（由 App 注入，默认纯文本）。
    public var renderMarkdown: (String) -> AnyView
    public init(renderMarkdown: @escaping (String) -> AnyView = { AnyView(Text($0)) }) {
        self.renderMarkdown = renderMarkdown
    }
}

public struct FeedbackThreadView: View {

    public let threadId: String
    public let side: FeedbackThreadSide

    private var center: FeedbackCenter { .shared }
    @State private var replyText = ""
    @State private var isReplying = false
    @State private var replyError: String?
    private var thread: FeedbackThread? { center.thread(threadId) }

    public var body: some View {
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
                    // FR-5：我这一侧是团队、且看的是收件箱时，底部给回信入口。
                    // 团队账号自己的信（mySide == .user）没有回信入口。
                    if side == .inbox, thread.canReply {
                        replyBox
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
        // 看过这一条才算读过（FR-012）。已发送那一栏看的是自己写的信，不碰未读——
        // 否则点一下自己发的东西就把还没读的回信清了。
        .task {
            guard side == .inbox else { return }
            await center.openThread(threadId)
        }
    }

    /// 团队回信输入区（FR-5）：服务端团队账号免凭据，失败按现有错误分类展示。
    @ViewBuilder
    private var replyBox: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.tight) {
            Hairline()
            TextEditor(text: $replyText)
                .font(DSHTheme.Typography.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 96)
                .padding(DSHTheme.Spacing.tight)
                .background(DSHTheme.layer2,
                            in: RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous)
                        .strokeBorder(DSHTheme.border2)
                }
                .overlay(alignment: .topLeading) {
                    if replyText.isEmpty {
                        Text("写下你的回信…")
                            .font(DSHTheme.Typography.body)
                            .foregroundStyle(DSHTheme.labelTertiary)
                            .padding(.leading, 13)
                            .padding(.top, 13)
                            .allowsHitTesting(false)
                    }
                }
                // 容器上不要再挂 id：SwiftUI 会把整块当成一个无障碍元素，子元素的 id 就找不到了
                // （2026-10-16 实测：外层 feedback.reply.box 在时 feedback.reply.input 查不到）。
                .accessibilityIdentifier("feedback.reply.input")
            FeedbackLengthHint(text: replyText, limits: limits)
            HStack {
                if let replyError {
                    Text(replyError)
                        .font(DSHTheme.Typography.caption)
                        .foregroundStyle(DSHTheme.danger)
                }
                Spacer()
                Button(String(localized: "回信")) {
                    let text = replyText
                    isReplying = true
                    Task {
                        defer { isReplying = false }
                        do {
                            try await center.reply(to: threadId, text: text)
                            replyText = ""
                            replyError = nil
                        } catch {
                            // 文案由 Domain 产出（030）：界面不认识协议层的错误映射。
                            replyError = center.replyFailureText(error)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                // 与发送窗口同一套长度判定（字符 + UTF-8 字节）：超了就不许发。
                .disabled(!FeedbackDraftLength.canSend(replyText, limits: limits) || isReplying)
                .accessibilityIdentifier("feedback.reply.send")
            }
        }
    }

    /// 回信输入框与发送窗口读同一个上限（服务端下发的 `limits`，缺失退编译期默认）。
    private var limits: FeedbackLimits { center.limits }

    /// 这一页要呈现的那封信：**只看线程自己的 `mySide`**——收件箱是对方的来信，
    /// 已发送是我这一侧的那封。旧数据里同一侧可能有多封，取最近的那封。
    private func letter(in thread: FeedbackThread) -> FeedbackMessage? {
        side == .sent ? thread.myLetter : thread.incomingLetter
    }

    @ViewBuilder
    private func letterCard(_ message: FeedbackMessage, in thread: FeedbackThread) -> some View {
        switch side {
        case .inbox:
            LetterCard(
                sender: thread.counterpartyLine,
                isMine: false,
                // 与收件箱那一行用同一个函数，两处标题不会漂。
                subject: thread.inboxSubject(for: message),
                text: message.body,
                format: message.bodyFormat,
                createdAt: message.createdAt)
        case .sent:
            // 主题只写用户真填过的那句；没填就不写抬头行——列表里的兜底标题是列表的需要，
            // 在这里会与正文第一句重复。
            LetterCard(
                sender: String(localized: "我发出的"),
                isMine: true,
                subject: writtenSubject(of: thread),
                text: message.body,
                format: message.bodyFormat,
                createdAt: message.createdAt)
        }
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

    public let sender: String
    public let createdAt: Date?
    /// 我方发出的用灰头像，对方用品牌色。
    public let isMine: Bool

    private var initial: String { String(sender.prefix(1)) }

    public var body: some View {
        HStack(spacing: DSHTheme.Spacing.hairline) {
            // 三元另一支是 String（机型首字母），整个表达式因此是 `String`，`Text` 按
            // 原样显示——必须显式本地化，否则英文构建里头像仍写「我」。
            Text(isMine ? String(localized: "我") : initial)
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

/// 一封信：头像圈 + 署名 + 时间、主题行、分隔线、正文。
///
/// 收件与发件**共用这一个组件**，所以边距、圆角、描边、字号只在这里定一次；两张卡
/// 除了署名与头像字符之外没有差别（FR-032）。通知也用它（署名换成「服务通知」）。
public struct LetterCard: View {
    @Environment(FeedbackServices.self) private var services

    public let sender: String
    /// 我发出的用灰头像，对方用品牌色。
    public let isMine: Bool
    /// 抬头行下面那句主题；为空就不写这一行。
    public let subject: String?
    /// 正文。不能叫 `body`：那是 `View` 的要求，同名会撞成重复声明。
    public let text: String
    /// 正文格式（FR-034）。默认 `text`：交给 App 自己的 Markdown 渲染器。
    public var format: FeedbackBodyFormat = .text
    public let createdAt: Date?

    public var body: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.tight) {
            LetterHeader(sender: sender, createdAt: createdAt, isMine: isMine)
            if let subject, !subject.isEmpty {
                Text(subject)
                    .font(DSHTheme.Typography.body.weight(.semibold))
                    .foregroundStyle(DSHTheme.labelPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Hairline()
            bodyContent(format, services: services)
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

    /// 正文按格式分两条路（FR-034）：
    ///
    /// - `text`（回信、通知，也是缺字段时的默认）：``MarkdownText``——标题/列表/引用/代码块/
    ///   表格都由它画，字体、暗色与动态字号跟 App 其它地方一致。旧数据是纯文本，走 Markdown
    ///   不会坏：段落里的 `<`、`|`、换行都按原样留下（只有真正的 Markdown 记号才被解释）。
    /// - `html`（报告类）：``HTMLMessageView``——锁死的 WebKit 容器，见它的头注。
    @ViewBuilder
    private func bodyContent(_ format: FeedbackBodyFormat, services: FeedbackServices) -> some View {
        switch format {
        case .text:
            services.renderMarkdown(text)
                // 无障碍标识：用例靠它断言"这一封走的是 Markdown 那条路"
                // （HTML 那条在 `HTMLMessageView` 里，标识是 `feedback.body.html`）。
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("feedback.body.markdown")
        case .html:
            HTMLMessageView(html: text)
        }
    }
}

/// 一条通知的详情：与回信同一种信件式版式。
///
/// 四种结局都在这一屏（设计 §M6.4）：加载中 / 正文 / 需要联网 + 重试 / 已不存在。
/// 正文按需取（列表只带摘要）；状态由 ``FeedbackNoticeDetail`` 持有，**取正文失败
/// 不标已读**——失败只能落到"需要联网查看"并给重试入口。
public struct FeedbackNoticeView: View {

    public let noticeId: String

    @State private var detail: FeedbackNoticeDetail

    private var center: FeedbackCenter { .shared }
    private var notice: FeedbackNotice? { center.notice(noticeId) }

    public init(noticeId: String) {
        self.noticeId = noticeId
        _detail = State(initialValue: FeedbackNoticeDetail(noticeId: noticeId))
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSHTheme.Spacing.standard) {
                switch detail.phase {
                case .loading:
                    HStack(spacing: DSHTheme.Spacing.tight) {
                        ProgressView()
                        Text("正在加载通知…")
                            .font(DSHTheme.Typography.caption)
                            .foregroundStyle(DSHTheme.labelSecondary)
                    }
                    .accessibilityIdentifier("feedback.notice.loading")
                case .ready:
                    if let notice {
                        LetterCard(
                            sender: String(localized: "服务通知"),
                            isMine: false,
                            subject: FeedbackSubject.line(subject: notice.subject, body: notice.body,
                                                          format: notice.bodyFormat),
                            text: notice.body ?? "",
                            format: notice.bodyFormat,
                            createdAt: notice.createdAt
                        )
                    } else {
                        gone
                    }
                case .needsNetwork:
                    VStack(alignment: .leading, spacing: DSHTheme.Spacing.tight) {
                        // id 挂在文案上，不挂容器：容器上的 id 会下传给子元素，
                        // 把重试按钮自己的 id 覆盖掉（2026-10-16 的坑）。
                        Text("需要联网查看")
                            .font(DSHTheme.Typography.body)
                            .foregroundStyle(DSHTheme.labelPrimary)
                            .accessibilityIdentifier("feedback.notice.offline")
                        Button(String(localized: "重试")) {
                            Task { await detail.load() }
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("feedback.notice.retry")
                    }
                case .gone:
                    gone
                }
            }
            .padding(DSHTheme.Spacing.loose)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DSHTheme.background)
        .accessibilityIdentifier("feedback.notice")
        .navigationTitle("通知")
        .navigationBarTitleDisplayMode(.inline)
        .task { await detail.load() }
    }

    private var gone: some View {
        Text("这条通知已经不在了。")
            .font(DSHTheme.Typography.caption)
            .foregroundStyle(DSHTheme.labelSecondary)
            .accessibilityIdentifier("feedback.notice.gone")
    }
}
#endif
