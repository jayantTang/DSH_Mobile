import RelayKit
import SwiftUI

/// 记录页与详情页共用的一种时间写法：本地时区的年月日 + 时分。
///
/// 不用"几分钟前"：反馈是留言不是聊天，来回可能隔几天，用户要看的是**哪天**。
/// 时间戳缺失时镜像里退到纪元 0，那种值不显示。
enum FeedbackTime {
    static func text(_ date: Date?) -> String {
        guard let date, date.timeIntervalSince1970 > 0 else { return "" }
        return date.formatted(.dateTime.year().month().day().hour().minute())
    }
}

/// 线程详情：用户原文与 owner 的回信按时间往返，同一处看完（FR-010）。
///
/// owner 的消息渲染成**信件卡片**（顶部团队名、正文、底部时间），不是聊天气泡——
/// 我们回的是正式答复，不是即时消息（FR-015，也是 spec 明确的非目标）。
struct FeedbackThreadView: View {

    let threadId: String
    /// 服务端说这条线程已经不存在了：调用方把这一条标成不可用，其余记录不动。
    var onUnavailable: () -> Void = {}

    @State private var draft = ""
    @State private var failure: String?
    @State private var isAppending = false

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
                    ForEach(orderedMessages) { message in
                        if message.author == .owner {
                            OwnerLetterCard(message: message)
                        } else {
                            UserMessageBlock(message: message)
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
        .safeAreaInset(edge: .bottom, spacing: 0) { appendBar }
        // 打开这一条才算读过（FR-012）：标记动作在中心里，离线时角标保持原样。
        .task { await center.openThread(threadId) }
    }

    // MARK: - 追加一条补充（US5）

    /// 按时间正序。服务端返回的顺序不保证，而"往返"必须按发生的先后读。
    private var orderedMessages: [FeedbackMessage] {
        (thread?.messages ?? []).sorted {
            ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
        }
    }

    private var appendBar: some View {
        HStack(alignment: .bottom, spacing: DSHTheme.Spacing.tight) {
            TextField("补充一句…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .font(DSHTheme.Typography.body)
                .padding(.horizontal, DSHTheme.Spacing.tight)
                .padding(.vertical, 7)
                .background(DSHTheme.layer2,
                            in: RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous))
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
        .padding(.vertical, DSHTheme.Spacing.tight)
        .background(DSHTheme.layer1)
        .overlay(alignment: .top) { Hairline() }
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

/// owner 的回信：顶部团队名、正文、底部时间——一封信的样子。
///
/// 通知用同一张卡片（标题换成通知的主题），两种"我们发给用户的东西"外观一致。
struct OwnerLetterCard: View {

    let title: String
    /// 正文。不能叫 `body`：那是 `View` 的要求，同名会撞成重复声明。
    let text: String
    let createdAt: Date?

    init(message: FeedbackMessage) {
        self.title = String(localized: "DSH Mobile 团队")
        self.text = message.body
        self.createdAt = message.createdAt
    }

    init(title: String, text: String, createdAt: Date?) {
        self.title = title
        self.text = text
        self.createdAt = createdAt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.tight) {
            HStack(spacing: DSHTheme.Spacing.hairline) {
                Image(systemName: "envelope")
                    .font(DSHTheme.Typography.micro)
                Text(title)
                    .font(DSHTheme.Typography.micro)
                Spacer(minLength: 0)
            }
            .foregroundStyle(DSHTheme.labelSecondary)
            Hairline()
            Text(text)
                .font(DSHTheme.Typography.body)
                .foregroundStyle(DSHTheme.labelPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(FeedbackTime.text(createdAt))
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelTertiary)
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

/// 用户自己写的：一块浅底文字，与信件卡片在结构上就不一样（没有署名、没有边框）。
private struct UserMessageBlock: View {

    let message: FeedbackMessage

    var body: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.hairline) {
            Text(message.body)
                .font(DSHTheme.Typography.body)
                .foregroundStyle(DSHTheme.labelPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text(FeedbackTime.text(message.createdAt))
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelTertiary)
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
                        title: notice.subject.flatMap { $0.isEmpty ? nil : $0 }
                            ?? String(localized: "服务通知"),
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
