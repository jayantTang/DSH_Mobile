import RelayKit
#if os(iOS)
import DSHDesign
import SwiftUI
import DSHFeedbackDomain

/// 把 `FeedbackClientError` 翻成一句用户能照做的话。
///
/// `.network` / `.decoding` 带的是诊断串（`invalid-relay-url`、解码报错原文），
/// 只进日志、**不**给用户看：用户看到 `typeMismatch(...)` 什么都做不了。
///
/// 文案里**不写具体字数**：上限由服务端下发（`limits`），写死一个数字迟早第二次漂移。
public enum FeedbackErrorText {

    static func text(for error: FeedbackClientError) -> String {
        switch error {
        case .network:
            return String(localized: "网络不通，正文还在，可以再点一次发送。")
        case .rateLimited:
            return String(localized: "提交太频繁了，稍等一会儿再试。")
        case .tooLong:
            return String(localized: "正文太长了，请精简后再试。")
        case .notFound:
            return String(localized: "这条反馈在服务器上已经不在了。")
        case .server(let status, _):
            return String(localized: "服务器没能保存这条反馈（错误码 \(status)），正文还在，可以再试。")
        case .decoding:
            return String(localized: "服务器返回了看不懂的内容，正文还在，可以再试。")
        }
    }
}

/// 发送窗口：邮件式——收件人、可选主题、正文，下面折叠着会一并提交的技术信息。
///
/// 取消不产生任何上传（连幂等键一起丢掉，下一次是一条新的）；提交失败**保留正文与主题**，
/// 并给出一句按 `FeedbackClientError` 分类的话，用户可以直接再点一次发送。
public struct FeedbackComposerView: View {

    /// 提交成功后调用：记录页据此把刚发出去的那条立刻显示出来。
    public var onSent: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var text = ""
    @State private var subject = ""
    @State private var failure: String?
    @State private var isShowingTech = false

    private var center: FeedbackCenter { .shared }

    /// 正文长度上限：服务端下发的值，旧服务端退编译期默认（与回信输入框同一份）。
    private var limits: FeedbackLimits { center.limits }

    private var canSend: Bool {
        FeedbackDraftLength.canSend(text, limits: limits)
            && subject.count <= limits.subjectChars
            && !center.isSubmitting
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSHTheme.Spacing.standard) {
                    mailHead
                    if let failure { failureBanner(failure) }
                    editor
                    techInfo
                    privacy
                }
                .padding(DSHTheme.Spacing.loose)
            }
            .background(DSHTheme.background)
            .accessibilityIdentifier("feedback.composeSheet")
            .navigationTitle("写反馈")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        // 放弃草稿：下次提交是一条新的反馈，而不是续用这次的幂等键。
                        center.discardDraftRef()
                        dismiss()
                    }
                    .accessibilityIdentifier("feedback.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发送") { Task { await send() } }
                        .disabled(!canSend)
                        .accessibilityIdentifier("feedback.send")
                }
            }
        }
    }

    // MARK: - 收件人与主题

    /// 两行抬头，跟写信一样：收件人是谁、这封信叫什么。
    private var mailHead: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: DSHTheme.Spacing.tight) {
                Text("收件人")
                    .font(DSHTheme.Typography.body)
                    .foregroundStyle(DSHTheme.labelTertiary)
                    // `fixedSize` + `minWidth`：中文两字对齐好看，英文 "Subject" 之类
                    // 不能被挤成两行（2026-10-12 英文截图上出现过 "Subjec/t"）。
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 52, alignment: .leading)
                Text("DSH Mobile 团队")
                    .font(DSHTheme.Typography.body)
                    .foregroundStyle(DSHTheme.labelPrimary)
            }
            .padding(.vertical, 10)
            Hairline()
            HStack(alignment: .firstTextBaseline, spacing: DSHTheme.Spacing.tight) {
                Text("主题")
                    .font(DSHTheme.Typography.body)
                    .foregroundStyle(DSHTheme.labelTertiary)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 52, alignment: .leading)
                TextField("一句话标题（可选）", text: $subject)
                    .font(DSHTheme.Typography.body)
                    .foregroundStyle(DSHTheme.labelPrimary)
                    .accessibilityIdentifier("feedback.subject")
                    // 超上限就当场截断：契约是主题 ≤ 服务端下发的字符数，截断比"发出去被拒"好。
                    .onChange(of: subject) { _, value in
                        if value.count > limits.subjectChars {
                            subject = String(value.prefix(limits.subjectChars))
                        }
                    }
            }
            .padding(.vertical, 10)
            Hairline()
        }
    }

    // MARK: - 正文

    private var editor: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.hairline) {
            TextEditor(text: $text)
                .font(DSHTheme.Typography.body)
                .foregroundStyle(DSHTheme.labelPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 168)
                .padding(DSHTheme.Spacing.tight)
                .background(DSHTheme.layer2,
                            in: RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous)
                        .strokeBorder(DSHTheme.border2)
                }
                // 空输入框里给一句提示：TextEditor 自己没有 placeholder。
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("描述你遇到的问题，或者你想要的功能…")
                            .font(DSHTheme.Typography.body)
                            .foregroundStyle(DSHTheme.labelTertiary)
                            .padding(.leading, 13)
                            .padding(.top, 13)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityIdentifier("feedback.text")
            FeedbackLengthHint(text: text, limits: limits)
        }
    }

    private func failureBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: DSHTheme.Spacing.tight) {
            Image(systemName: "exclamationmark.triangle")
                .font(DSHTheme.Typography.caption)
                .foregroundStyle(DSHTheme.labelError)
            Text(message)
                .font(DSHTheme.Typography.caption)
                .foregroundStyle(DSHTheme.labelPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("feedback.compose.failure")
        }
        .padding(DSHTheme.Spacing.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSHTheme.labelError.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous))
    }

    // MARK: - 会一并提交的技术信息

    /// 折叠区：默认收起，想看的人点开。全部内容仍在标签里，用例与无障碍都读得到。
    private var techInfo: some View {
        let info = FeedbackCenter.technicalInfo
        return VStack(alignment: .leading, spacing: DSHTheme.Spacing.tight) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { isShowingTech.toggle() }
            } label: {
                HStack(spacing: DSHTheme.Spacing.hairline) {
                    Text("随信附带")
                        .font(DSHTheme.Typography.caption.weight(.semibold))
                        .foregroundStyle(DSHTheme.labelSecondary)
                    Spacer(minLength: 0)
                    Text(isShowingTech ? "收起" : "展开")
                        .font(DSHTheme.Typography.caption)
                        .foregroundStyle(DSHTheme.labelTertiary)
                    Image(systemName: isShowingTech ? "chevron.up" : "chevron.down")
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelTertiary)
                }
            }
            .buttonStyle(.plain)
            if isShowingTech {
                row(String(localized: "App 版本"), info.appVersion)
                row(String(localized: "机型"), info.deviceModel)
                row(String(localized: "iOS"), info.systemVersion)
            }
        }
        .padding(DSHTheme.Spacing.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSHTheme.layer1,
                    in: RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous)
                .strokeBorder(DSHTheme.border2)
        }
        .accessibilityIdentifier("feedback.tech")
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: DSHTheme.Spacing.tight) {
            Text(label)
                .font(DSHTheme.Typography.caption)
                .foregroundStyle(DSHTheme.labelSecondary)
            Spacer(minLength: 0)
            Text(value)
                .font(DSHTheme.Typography.caption)
                .foregroundStyle(DSHTheme.labelPrimary)
                .lineLimit(1)
        }
    }

    // MARK: - 内容去向

    private var privacy: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.tight) {
            Text("正文与随信附带的信息会存到我们的服务器，不含会话内容。")
                .font(DSHTheme.Typography.caption)
                .foregroundStyle(DSHTheme.labelTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                guard let url = URL(string: "https://github.com/jayantTang/DSH_Mobile/blob/main/docs/PRIVACY.md")
                else { return }
                openURL(url)
            } label: {
                HStack(spacing: DSHTheme.Spacing.hairline) {
                    Image(systemName: "lock.shield")
                    Text("隐私说明")
                }
                .font(DSHTheme.Typography.caption)
                .foregroundStyle(DSHTheme.brand)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("feedback.privacy")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 提交

    private func send() async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FeedbackDraftLength.canSend(body, limits: limits) else { return }
        failure = nil
        do {
            // 主题跟着一起提交；空白由中心按未填处理。
            try await center.submit(text: body, subject: subject)
        } catch let error as FeedbackClientError {
            // 正文留在输入框里，用户可以直接再点一次发送（幂等键由中心复用）。
            failure = FeedbackErrorText.text(for: error)
            return
        } catch {
            failure = String(localized: "提交没有成功，正文还在，可以再试。")
            return
        }
        // 先关窗再拉正文：镜像里已经有这条线程了，列表立刻有行可看；
        // 这次拉取是为了把正文带回来（离线也无妨，下次打开记录页会补上）。
        onSent()
        dismiss()
        await center.refreshInbox(force: true)
    }
}

/// 正文长度提示：发送窗口与回信输入框共用同一份（同一条判定、同一套文案）。
///
/// 平时不占地方——只剩 500 字以内才显示剩余字数；触顶时按**哪个先触顶**分两句：
/// 字符超了说"字数"，字节先超了（表情等 4 字节字符）说"大小"。文案里不出现写死的
/// 数字：上限是服务端下发的。
struct FeedbackLengthHint: View {

    public let text: String
    public let limits: FeedbackLimits

    private var remaining: Int { FeedbackDraftLength.remaining(text, limits: limits) }

    public var body: some View {
        Group {
            switch FeedbackDraftLength.overflow(text, limits: limits) {
            case .characters:
                Text("已超出字数上限，请精简后再发")
                    .foregroundStyle(DSHTheme.labelError)
                    .accessibilityIdentifier("feedback.length.over.chars")
            case .bytes:
                Text("内容超出可发送大小（表情等字符按字节计）")
                    .foregroundStyle(DSHTheme.labelError)
                    .accessibilityIdentifier("feedback.length.over.bytes")
            case .none:
                if remaining <= 500 {
                    Text("还能输入 \(remaining) 字")
                        .foregroundStyle(DSHTheme.labelTertiary)
                        .accessibilityIdentifier("feedback.length.remaining")
                }
            }
        }
        .font(DSHTheme.Typography.micro)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
#endif
