import RelayKit
import SwiftUI

/// 服务器强制的正文上限（`specs/014-feedback-channel/data-model.md` 第一节）。
/// 界面上先拦一次，超长的提交服务器也会拒；两处用的是同一个数。
enum FeedbackLimits {
    static let maxBodyLength = 4000
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

/// 发送窗口：写正文、看将要一并提交的技术信息、知道内容去了哪里，然后提交。
///
/// 取消不产生任何上传（连幂等键一起丢掉，下一次是一条新的）；提交失败**保留正文**，
/// 并给出一句按 `FeedbackClientError` 分类的话，用户可以直接再点一次发送。
struct FeedbackComposerView: View {

    /// 提交成功后调用：记录页据此把刚发出去的那条立刻显示出来。
    var onSent: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var text = ""
    @State private var failure: String?

    private var center: FeedbackCenter { .shared }

    private var remaining: Int { FeedbackLimits.maxBodyLength - text.count }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && remaining >= 0
            && !center.isSubmitting
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSHTheme.Spacing.standard) {
                    editor
                    if let failure { failureBanner(failure) }
                    techInfo
                    destination
                }
                .padding(DSHTheme.Spacing.loose)
            }
            .background(DSHTheme.background)
            .accessibilityIdentifier("feedback.composeSheet")
            .navigationTitle("发送反馈")
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
                        Text("说说遇到的问题，或者你希望增加的功能…")
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

    /// 剩余字数。超了就变色并说"精简"，不是等提交被服务器拒了才说。
    @ViewBuilder
    private var counter: some View {
        if remaining < 0 {
            Text("已超出 4000 字上限，请精简后再发")
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelError)
        } else {
            Text("还可以输入 \(remaining) 字")
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelTertiary)
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

    private var techInfo: some View {
        let info = FeedbackCenter.technicalInfo
        return VStack(alignment: .leading, spacing: DSHTheme.Spacing.hairline) {
            Text("会一并提交的技术信息")
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelTertiary)
            row(String(localized: "App 版本"), info.appVersion)
            row(String(localized: "机型"), info.deviceModel)
            row(String(localized: "iOS 版本"), info.systemVersion)
        }
        .padding(DSHTheme.Spacing.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSHTheme.layer1,
                    in: RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous))
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

    private var destination: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.tight) {
            Text("内容会存到我们的服务器，不公开；只用来看问题和回信给你，不会附带你的对话内容。")
                .font(DSHTheme.Typography.caption)
                .foregroundStyle(DSHTheme.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                guard let url = URL(string: "https://github.com/jayantTang/DSH_Mobile/blob/main/docs/PRIVACY.md")
                else { return }
                openURL(url)
            } label: {
                HStack(spacing: DSHTheme.Spacing.hairline) {
                    Image(systemName: "lock.shield")
                    Text("查看隐私说明")
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
            try await center.submit(text: body)
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
