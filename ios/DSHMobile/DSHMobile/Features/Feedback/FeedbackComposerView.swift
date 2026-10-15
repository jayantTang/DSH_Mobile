import DSHDesign
import RelayKit
import SwiftUI

/// 服务器强制的正文上限（`specs/014-feedback-channel/data-model.md` 第一节）。
/// 界面上先拦一次，超长的提交服务器也会拒；两处用的是同一个数。
enum FeedbackLimits {
    static let maxBodyLength = 4000
    /// 主题上限（契约：`subject` ≤80 字符）。超过就拦住，不去赌服务端截断。
    static let maxSubjectLength = 80
}

/// 把 `FeedbackClientError` 翻成一句用户能照做的话。
///
/// `.network` / `.decoding` 带的是诊断串（`invalid-relay-url`、解码报错原文），
/// 只进日志、**不**给用户看：用户看到 `typeMismatch(...)` 什么都做不了。
enum FeedbackErrorText {

    static func text(for error: FeedbackClientError) -> String {
        switch error {
        case .network:
            return String(localized: "网络不通，正文还在，可以再点一次发送。")
        case .rateLimited:
            return String(localized: "提交太频繁了，稍等一会儿再试。")
        case .tooLong:
            return String(localized: "正文太长了，请精简到 4000 字以内。")
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
struct FeedbackComposerView: View {

    /// 提交成功后调用：记录页据此把刚发出去的那条立刻显示出来。
    var onSent: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var text = ""
    @State private var subject = ""
    @State private var failure: String?
    @State private var isShowingTech = false

    private var center: FeedbackCenter { .shared }

    private var remaining: Int { FeedbackLimits.maxBodyLength - text.count }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && remaining >= 0
            && subject.count <= FeedbackLimits.maxSubjectLength
            && !center.isSubmitting
    }

    var body: some View {
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
                    // 超上限就当场截断：契约是 ≤80 字符，截断比"发出去被拒"好。
                    .onChange(of: subject) { _, value in
                        if value.count > FeedbackLimits.maxSubjectLength {
                            subject = String(value.prefix(FeedbackLimits.maxSubjectLength))
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
            counter
        }
    }

    /// 剩余字数：只剩 500 字以内才出现，平时不占地方；超了就变色并说"精简"，
    /// 不是等提交被服务器拒了才说。
    @ViewBuilder
    private var counter: some View {
        if remaining < 0 {
            Text("已超出 4000 字上限，请精简后再发")
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelError)
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else if remaining <= 500 {
            Text("还能输入 \(remaining) 字")
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelTertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
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
        guard !body.isEmpty, body.count <= FeedbackLimits.maxBodyLength else { return }
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
