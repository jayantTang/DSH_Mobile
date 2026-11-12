import RelayKit
#if os(iOS)
import DSHDesign
import DSHFeedbackDomain
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

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
            return String(localized: "这封信在服务器上已经不在了。")
        case .unsupportedType:
            return String(localized: "服务器不收这种附件，请换一张图片或一个文件。")
        case .storageFull:
            return String(localized: "服务器空间不足，附件暂时传不上去")
        case .server(let status, _):
            return String(localized: "服务器没能保存这封信（错误码 \(status)），正文还在，可以再试。")
        case .decoding:
            return String(localized: "服务器返回了看不懂的内容，正文还在，可以再试。")
        }
    }
}

/// 回信上下文（v6：回信与写信是**同一个** `FeedbackComposerView`，只有三处初始值
/// 与一处发送路由不同）。
public struct FeedbackReplyContext: Hashable {
    public let threadId: String
    public let ticketKey: String?
    /// 固定收件人（用户侧＝团队；团队侧＝该线程的来信署名）。
    public let recipient: String
    /// 原主题（用于 `Re: …`）；空则退到"关于你的来信"那句。
    public let subject: String?
    /// 正文下方灰色折叠的原信（只读，不计入正文字数）。
    public let quotedText: String
    /// 原信的格式：`text` 走与正文同一条 markdown 渲染，`html` 仍按纯文本（不嵌第二个 WebKit）。
    public let quotedFormat: FeedbackBodyFormat

    public init(threadId: String, ticketKey: String?, recipient: String,
                subject: String?, quotedText: String,
                quotedFormat: FeedbackBodyFormat = .text) {
        self.threadId = threadId
        self.ticketKey = ticketKey
        self.recipient = recipient
        self.subject = subject
        self.quotedText = quotedText
        self.quotedFormat = quotedFormat
    }

    /// 回信窗口的主题初值：`Re: <原主题>`，原主题为空时 `Re: 关于你的来信：<首句>`。
    var replySubject: String {
        let base = subject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "Re: " + (base.isEmpty ? String(localized: "关于你的来信") : base)
    }
}

/// 发送窗口：邮件式——收件人、可选主题、正文、附件，下面折叠着会一并提交的技术信息。
///
/// v4/v6：附件**先传后发**（上传在点发送之后）；回信复用这一个视图，只换标题、收件人、
/// 主题初值与发送路由（`append`）。取消不产生任何提交；失败保留正文、主题与附件，
/// 并给「重试 / 只发正文 / 取消」三个动作。
public struct FeedbackComposerView: View {

    /// 提交成功后调用：记录页据此把刚发出去的那条立刻显示出来。
    public var onSent: () -> Void = {}

    private let reply: FeedbackReplyContext?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var text = ""
    @State private var subject = ""
    @State private var drafts: [DraftAttachment] = []
    @State private var failure: String?
    @State private var isShowingTech = false
    @State private var job: FeedbackSendJob?
    @State private var alert: ComposerAlert?
    @State private var isPickingPhotos = false
    @State private var isPickingFiles = false
    @State private var pickedPhotos: [PhotosPickerItem] = []

    private var center: FeedbackCenter { .shared }

    public init(replyTo: FeedbackReplyContext? = nil, onSent: @escaping () -> Void = {}) {
        self.reply = replyTo
        self.onSent = onSent
        _subject = State(initialValue: replyTo?.replySubject ?? "")
    }

    /// 正文长度上限：服务端下发的值，旧服务端退编译期默认（与回信输入框同一份）。
    private var limits: FeedbackLimits { center.limits }

    private var attachmentLimits: FeedbackAttachmentLimits? { limits.attachments }

    private var isSending: Bool { job?.isRunning == true }

    private var canSend: Bool {
        FeedbackSendPolicy.canSend(text: text, subject: subject,
                                   attachments: plan.flattened,
                                   limits: limits)
            && !isSending
    }

    /// 这封信的附件计划：预览永远带上，原图按 24 MiB 额度与选择顺序分配。
    ///
    /// 它是**纯函数的即时结果**（不从 @State 里另存一份）：增删附件后自动跟上，
    /// 不会出现"界面上的角标与真正发出去的字节不一致"。
    private var plan: FeedbackAttachmentPlan {
        guard let attachmentLimits else { return FeedbackAttachmentPlan() }
        return FeedbackAttachmentAllocation.plan(drafts.map(\.prepared), limits: attachmentLimits)
    }

    /// 汇总行（附件区末尾）：`3 个附件 · 含高清 2 · 仅预览 1 · 合计 12.4 MiB`。
    private var summary: FeedbackAttachmentSummary { FeedbackAttachmentSummary(plan: plan) }

    private static let uploadTimeout = RelayFeedbackClient.uploadTimeout

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSHTheme.Spacing.standard) {
                    if let failure { failureBanner(failure) }
                    mailHead
                    editor
                    attachmentSection
                    if let reply {
                        FeedbackQuoteBlock(text: reply.quotedText, format: reply.quotedFormat)
                    }
                    techInfo
                    privacy
                }
                .padding(DSHTheme.Spacing.loose)
            }
            .background(DSHTheme.background)
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("feedback.composeSheet")
            .navigationTitle(reply == nil ? "写一封信" : "回信")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .photosPicker(isPresented: $isPickingPhotos, selection: $pickedPhotos,
                          maxSelectionCount: remainingSlots, matching: .images)
            .fileImporter(isPresented: $isPickingFiles,
                          allowedContentTypes: [.pdf, .plainText, .commaSeparatedText,
                                                .json, .image],
                          allowsMultipleSelection: true) { result in
                handleFiles(result)
            }
            .onChange(of: pickedPhotos) { _, items in
                guard !items.isEmpty else { return }
                Task { await addPhotos(items) }
            }
            .alert(item: $alert) { alert in
                switch alert {
                case .tooMany(let limit):
                    return Alert(title: Text(String(localized: "附件放不下了")),
                                 message: Text(String(localized: "最多 \(limit) 个附件")),
                                 dismissButton: .default(Text(String(localized: "好"))))
                case .imageFailed(let name):
                    return Alert(title: Text(String(localized: "这张图处理失败")),
                                 message: Text(String(localized: "\(name) 没能转成可发送的图片")),
                                 dismissButton: .default(Text(String(localized: "好"))))
                case .fileTooLarge(let name, let limit):
                    return Alert(title: Text(String(localized: "这个文件太大了")),
                                 message: Text(String(localized: "\(name) 超过了单个不超过 \(FeedbackAttachmentSize.limitText(limit))")),
                                 dismissButton: .default(Text(String(localized: "好"))))
                case .totalTooLarge(let limit):
                    return Alert(title: Text(String(localized: "附件总量超了")),
                                 message: Text(String(localized: "附件合计不能超过 \(FeedbackAttachmentSize.limitText(limit))")),
                                 dismissButton: .default(Text(String(localized: "好"))))
                case .unsupportedType(let name):
                    return Alert(title: Text(String(localized: "这种文件发不了")),
                                 message: Text(String(localized: "\(name) 不是附件支持的类型")),
                                 dismissButton: .default(Text(String(localized: "好"))))
                case .textOnly(let failed):
                    return Alert(title: Text(String(localized: "还有 \(failed) 个附件没有传上去，只发正文？")),
                                 primaryButton: .default(Text(String(localized: "只发正文"))) {
                                     Task { await sendTextOnly() }
                                 },
                                 secondaryButton: .cancel(Text(String(localized: "取消"))))
                }
            }
        }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("取消") {
                // 放弃草稿：尽力 discard 已传的草稿，下一次是一条新信。
                let current = job
                center.discardDraftRef()
                if let current {
                    Task { _ = await current.cancel() }
                }
                dismiss()
            }
            .disabled(isSending)
            .accessibilityIdentifier("feedback.cancel")
        }
        ToolbarItem(placement: .confirmationAction) {
            if isSending && job?.phase != .submitting {
                Button(String(localized: "停止发送")) { Task { await stopSending() } }
                    .accessibilityIdentifier("feedback.send")
            } else if job?.phase == .submitting {
                HStack(spacing: DSHTheme.Spacing.hairline) {
                    ProgressView().controlSize(.small)
                    Text("发送").font(DSHTheme.Typography.body)
                }
                .accessibilityIdentifier("feedback.send")
            } else {
                Button("发送") { Task { await send() } }
                    .disabled(!canSend)
                    .accessibilityIdentifier("feedback.send")
            }
        }
    }

    // MARK: - 收件人与主题

    private var mailHead: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: DSHTheme.Spacing.tight) {
                Text("收件人")
                    .font(DSHTheme.Typography.body)
                    .foregroundStyle(DSHTheme.labelTertiary)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 52, alignment: .leading)
                Text(reply?.recipient ?? String(localized: "DSH Mobile 团队"))
                    .font(DSHTheme.Typography.body)
                    .foregroundStyle(DSHTheme.labelPrimary)
                    .lineLimit(1)
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
                    .disabled(isSending)
                    .accessibilityIdentifier("feedback.subject")
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
                .disabled(isSending)
                .accessibilityIdentifier("feedback.text")
            FeedbackLengthHint(text: text, limits: limits)
        }
    }

    // MARK: - 附件区（C4/C7/C8）

    /// 附件区：标题行（限额）+ 图片条 + 文件行 + 添加行。
    ///
    /// 服务端没有 `limits.attachments` 时整块不出现（附件功能关闭，不拿常量兜底）。
    @ViewBuilder
    private var attachmentSection: some View {
        if attachmentLimits != nil {
            VStack(alignment: .leading, spacing: DSHTheme.Spacing.tight) {
                header
                let images = drafts.filter(\.isImage)
                if !images.isEmpty {
                    FeedbackAttachmentStrip(items: images.map(stripItem)) { id in
                        remove(id)
                    }
                }
                ForEach(drafts.filter { !$0.isImage }) { draft in
                    FeedbackAttachmentFileRow(
                        name: draft.name, bytes: draft.byteSize,
                        contentType: draft.primary.contentType,
                        phase: phase(of: draft),
                        badge: badge(of: draft),
                        onRemove: { remove(draft.id) },
                        onRetry: FeedbackAttachmentStatus.isFailure(phase(of: draft))
                            ? { Task { await send() } } : nil
                    )
                }
                addRow
                if !drafts.isEmpty {
                    Text(summary.text)
                        .font(DSHTheme.Typography.caption)
                        .foregroundStyle(DSHTheme.labelSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("feedback.attach.summary")
                }
            }
            .accessibilityIdentifier("feedback.attach.section")
        }
    }

    private var header: some View {
        HStack(spacing: DSHTheme.Spacing.tight) {
            Text("附件")
                .font(DSHTheme.Typography.caption.weight(.semibold))
                .foregroundStyle(DSHTheme.labelSecondary)
            Spacer(minLength: 0)
            if let progress = progressText {
                Text(progress)
                    .font(DSHTheme.Typography.caption)
                    .foregroundStyle(DSHTheme.labelSecondary)
                    .accessibilityIdentifier("feedback.attach.progress")
            } else if let attachmentLimits {
                Text(String(localized: "最多 \(attachmentLimits.maxPerMessage) 个附件 · 单个不超过 \(FeedbackAttachmentSize.limitText(attachmentLimits.maxFileBytes))"))
                    .font(DSHTheme.Typography.caption)
                    .foregroundStyle(DSHTheme.labelTertiary)
            }
        }
    }

    private var progressText: String? {
        switch job?.phase {
        case .uploading(let done, let total):
            return String(localized: "正在上传 \(done)/\(total)")
        case .submitting:
            return String(localized: "正在提交")
        default:
            return nil
        }
    }

    @ViewBuilder
    private var addRow: some View {
        let full = drafts.count >= (attachmentLimits?.maxPerMessage ?? 0)
        Menu {
            Button {
                isPickingPhotos = true
            } label: {
                Label("照片图库", systemImage: "photo.on.rectangle")
            }
            .accessibilityIdentifier("feedback.attach.menu.photo")
            Button {
                isPickingFiles = true
            } label: {
                Label("文件", systemImage: "folder")
            }
            .accessibilityIdentifier("feedback.attach.menu.file")
        } label: {
            HStack(spacing: DSHTheme.Spacing.hairline) {
                Image(systemName: "paperclip")
                Text("添加附件")
            }
            .font(DSHTheme.Typography.body)
            .foregroundStyle(full ? DSHTheme.labelTertiary : DSHTheme.brand)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, DSHTheme.Spacing.standard)
            // 设计 C4-5：44 高、`layer2` 底、1pt 虚线 `border3`、圆角 10。
            .background(DSHTheme.layer2,
                        in: RoundedRectangle(cornerRadius: DSHTheme.Radius.medium,
                                             style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous)
                    .strokeBorder(DSHTheme.border3,
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .contentShape(Rectangle())
        }
        .disabled(isSending)
        .accessibilityIdentifier("feedback.attach.add")
        .onTapGesture {
            if full { alert = .tooMany(limit: attachmentLimits?.maxPerMessage ?? 0) }
        }
    }

    private var remainingSlots: Int {
        max(1, (attachmentLimits?.maxPerMessage ?? 1) - drafts.count)
    }

    // MARK: - 附件队列

    /// 队列里的一项（本地草稿）：一个逻辑附件，可能是"预览 + 原图"两份字节。
    ///
    /// 字节在点发送之后才会离开这台手机；`slot` 是这一封信里的稳定序号（0 起，按添加
    /// 顺序），同一个 slot 的两份字节共享它。
    private struct DraftAttachment: Identifiable, Equatable {
        let id: UUID
        let slot: Int
        let name: String
        /// 主对象（图片是预览；文件是本体）。角色只存在它的 `role` 上。
        let primary: FeedbackOutgoingAttachment
        /// 可选的另一份字节（图片原图）。
        let original: FeedbackOutgoingAttachment?
        /// 图片条里那一格的小图（预览字节解出来的）。
        let thumbnail: UIImage?

        var isImage: Bool { primary.contentType.hasPrefix("image/") }
        var byteSize: Int { primary.byteSize + (original?.byteSize ?? 0) }

        var prepared: FeedbackPreparedAttachment {
            FeedbackPreparedAttachment(slot: slot, primary: primary, original: original)
        }
    }

    private enum ComposerAlert: Identifiable {
        case tooMany(limit: Int)
        case fileTooLarge(name: String, limit: Int)
        case totalTooLarge(limit: Int)
        case unsupportedType(name: String)
        case imageFailed(name: String)
        case textOnly(failed: Int)

        var id: String {
            switch self {
            case .imageFailed(let name): return "image-failed-\(name)"
            case .tooMany: return "too-many"
            case .fileTooLarge(let name, _): return "file-too-large-\(name)"
            case .totalTooLarge: return "total-too-large"
            case .unsupportedType(let name): return "unsupported-\(name)"
            case .textOnly: return "text-only"
            }
        }
    }

    private func phase(of draft: DraftAttachment) -> FeedbackSendJob.SlotPhase {
        job?.slotPhases[draft.slot] ?? .waiting
    }

    private func stripItem(_ draft: DraftAttachment) -> FeedbackStripItem {
        FeedbackStripItem(id: draft.id, name: draft.name, bytes: draft.byteSize,
                          phase: phase(of: draft), thumbnail: draft.thumbnail,
                          badge: badge(of: draft))
    }

    /// 附件角标：含高清（这笔钱真的带了原图）/ 仅预览（有原图但被预算降级）。
    /// 文字与判据都只在这一个函数里；`nil` = 不标（文件、单文件模式）。
    private func badge(of draft: DraftAttachment) -> AttachmentBadge? {
        guard let item = plan.items.first(where: { $0.slot == draft.slot }) else { return nil }
        if item.includeOriginal { return .highDefinition }
        if item.isPreviewOnly { return .previewOnly }
        return nil
    }

    // MARK: - 选附件

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        pickedPhotos = []
        guard attachmentLimits != nil else { return }
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            // 相册给不出文件名：用稳定前缀 + 探测到的类型（转码器只认字节）。
            await prepareAndAdd(data: data, name: "photo.jpg", contentType: "image/jpeg")
        }
    }

    private func handleFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, attachmentLimits != nil else { return }
        // **一条串行任务**处理整批：多选图片各起一个 Task 会并发解码（内存峰值不受控），
        // 而条数检查在 await 之前，并发入列还会超过上限（评审 P1-3）。
        Task { await addFiles(urls) }
    }

    private func addFiles(_ urls: [URL]) async {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let contentType = Self.contentType(of: url)
            guard Self.isSupported(contentType) else {
                alert = .unsupportedType(name: url.lastPathComponent)
                continue
            }
            if contentType.hasPrefix("image/") {
                // **两个入口共用一条规范化**（设计 §2.2）：文件入口的图片也走转码器，
                // 不再把原字节直接塞进草稿。
                await prepareAndAdd(data: data, name: url.lastPathComponent,
                                    contentType: contentType)
            } else {
                addFile(data: data, name: url.lastPathComponent, contentType: contentType)
            }
        }
    }

    /// 图片的唯一入口（相册与文件两个来源都走它）：转码 → 按能力协商配对 → 入列。
    ///
    /// 它不再判断"文件太大了"：图片只可能因为**处理失败**（不是图片 / 编不出来）失败，
    /// 体积由 ``FeedbackImageBudget`` 在转码时解决。
    private func prepareAndAdd(data: Data, name: String, contentType: String) async {
        guard let attachmentLimits else { return }
        guard FeedbackAttachmentSlotCapacity.canAdd(
            currentCount: drafts.count, limit: attachmentLimits.maxPerMessage) else {
            alert = .tooMany(limit: attachmentLimits.maxPerMessage)
            return
        }
        let prepared: FeedbackPreparedImage
        do {
            prepared = try await FeedbackImageTranscoder.prepare(
                data: data, name: name, limits: attachmentLimits)
        } catch {
            alert = .imageFailed(name: name)
            return
        }
        let primary: FeedbackOutgoingAttachment
        let original: FeedbackOutgoingAttachment?
        if attachmentLimits.supportsPairs {
            // 配对模式：主对象是预览（列表用），原图作为同一 slot 的第二份字节。
            primary = FeedbackOutgoingAttachment(
                name: name, contentType: prepared.preview.contentType,
                data: prepared.preview.data,
                width: prepared.preview.pixelWidth, height: prepared.preview.pixelHeight,
                role: .preview)
            original = prepared.original.map {
                FeedbackOutgoingAttachment(
                    name: name, contentType: $0.contentType, data: $0.data,
                    width: $0.pixelWidth, height: $0.pixelHeight, role: .original)
            }
        } else {
            // 单文件模式（旧服务端 / 回滚开关）：只发一份，角色一律 original。
            // 优先原图；没有原图就用预览——**不把一份可能是原图的字节标成压缩版**。
            let chosen = prepared.original ?? prepared.preview
            primary = FeedbackOutgoingAttachment(
                name: name, contentType: chosen.contentType, data: chosen.data,
                width: chosen.pixelWidth, height: chosen.pixelHeight, role: .original)
            original = nil
        }
        append(DraftAttachment(id: UUID(), slot: drafts.count, name: name,
                               primary: primary, original: original,
                               thumbnail: UIImage(data: primary.data)),
               limits: attachmentLimits)
    }

    /// 文件类附件（PDF / 文本族）：没有预览，仍按 8 MiB 的**单文件**判据拒收。
    private func addFile(data: Data, name: String, contentType: String) {
        guard let attachmentLimits else { return }
        guard FeedbackAttachmentSlotCapacity.canAdd(
            currentCount: drafts.count, limit: attachmentLimits.maxPerMessage) else {
            alert = .tooMany(limit: attachmentLimits.maxPerMessage)
            return
        }
        guard data.count <= attachmentLimits.maxFileBytes else {
            alert = .fileTooLarge(name: name, limit: attachmentLimits.maxFileBytes)
            return
        }
        append(DraftAttachment(id: UUID(), slot: drafts.count, name: name,
                               primary: FeedbackOutgoingAttachment(
                                   name: name, contentType: contentType, data: data,
                                   role: .original),
                               original: nil, thumbnail: nil),
               limits: attachmentLimits)
    }

    /// 入列前用**同一份计划**判一次总量：预览永远放得下，放不下的只有"主对象都超了"。
    private func append(_ draft: DraftAttachment, limits attachmentLimits: FeedbackAttachmentLimits) {
        // 入列前**再查一次**条数：预检与真正入列之间隔着一次 await（转码/读盘），
        // 期间别的入口可能已经加过附件了（评审 P1-3）。
        guard FeedbackAttachmentSlotCapacity.canAdd(
            currentCount: drafts.count, limit: attachmentLimits.maxPerMessage) else {
            alert = .tooMany(limit: attachmentLimits.maxPerMessage)
            return
        }
        var candidate = drafts + [draft]
        // slot 必须连续（0…n-1）：删过附件之后再添加要重新编号，否则汇总与上传会对不上。
        candidate = candidate.enumerated().map { index, item in
            DraftAttachment(id: item.id, slot: index, name: item.name, primary: item.primary,
                            original: item.original, thumbnail: item.thumbnail)
        }
        let prospective = FeedbackAttachmentAllocation.plan(candidate.map(\.prepared),
                                                            limits: attachmentLimits)
        guard prospective.totalBytes <= attachmentLimits.maxTotalBytes else {
            alert = .totalTooLarge(limit: attachmentLimits.maxTotalBytes)
            return
        }
        drafts = candidate
    }

    private func remove(_ id: UUID) {
        drafts.removeAll { $0.id == id }
        // 槽位重新连续编号：上传按 slot 幂等，空洞会让服务端的"第几个附件"与界面不一致。
        drafts = drafts.enumerated().map { index, item in
            DraftAttachment(id: item.id, slot: index, name: item.name, primary: item.primary,
                            original: item.original, thumbnail: item.thumbnail)
        }
    }

    private static func contentType(of url: URL) -> String {
        let type = UTType(filenameExtension: url.pathExtension)
        return type?.preferredMIMEType ?? "application/octet-stream"
    }

    private static func isSupported(_ contentType: String) -> Bool {
        if contentType == "application/pdf" || contentType == "application/json" { return true }
        if contentType.hasPrefix("image/") { return true }
        return contentType.hasPrefix("text/")
    }

    // MARK: - 发送（C7/C8）

    private func send() async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FeedbackSendPolicy.canSend(text: body, subject: subject,
                                          attachments: plan.flattened,
                                          limits: limits) else { return }
        failure = nil
        let outgoing = plan.flattened
        guard let job = center.makeSendJob(
            text: body, subject: subject, attachments: outgoing,
            reply: reply.map { ($0.threadId, $0.ticketKey) }
        ) else {
            failure = FeedbackErrorText.text(for: .network("no-relay-endpoint"))
            return
        }
        self.job = job
        let outcome = await job.run()
        handle(outcome, job: job)
    }

    private func stopSending() async {
        guard let job else { return }
        let outcome = await job.cancel()
        handle(outcome, job: job)
    }

    private func sendTextOnly() async {
        if let job {
            let outcome = await job.sendTextOnly()
            handle(outcome, job: job)
            return
        }
        // 还没发过：只发正文就是"不带附件再发一次"。
        let saved = drafts
        drafts = []
        await send()
        drafts = saved
    }

    private func handle(_ outcome: FeedbackSendOutcome, job: FeedbackSendJob) {
        switch outcome {
        case .sent(let receipt):
            center.recordSent(receipt, subject: subject.isEmpty ? nil : subject)
            onSent()
            dismiss()
            Task { await center.refreshInbox(force: true) }
        case .failed(let reason):
            failure = Self.sentence(for: reason, job: job)
        case .cancelled:
            failure = String(localized: "已经停止，信没有发出")
        }
    }

    /// C8 的四句失败原因（互斥）：网络/超时、服务器拒绝、空间不足、用户停止。
    private static func sentence(for reason: FeedbackSendFailure, job: FeedbackSendJob) -> String {
        let failed = job.slotPhases.values.filter {
            $0 == .failed || $0 == .cancelled
        }.count
        switch reason {
        case .client(.network):
            return String(localized: "网络不通或超时，\(max(1, failed)) 个附件没有传上去，信还没发出")
        case .client(.storageFull):
            return String(localized: "服务器空间不足，附件暂时传不上去")
        case .client(.unsupportedType):
            return String(localized: "服务器不收这种附件，请换一张图片或一个文件。")
        case .client(.server(let status, _)):
            return String(localized: "服务器拒收了这个附件（错误码 \(status)）")
        case .client(let other):
            return FeedbackErrorText.text(for: other)
        case .attachmentLimit, .fileTooLarge, .totalTooLarge, .attachmentsUnavailable:
            return String(localized: "这些附件发不了，信还没发出")
        case .boundMismatch:
            return String(localized: "有附件没有存到服务器上，信还没发出")
        }
    }

    private func failureBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.tight) {
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
            HStack(spacing: DSHTheme.Spacing.standard) {
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(String(localized: "只发正文")) {
                        alert = .textOnly(failed: failedDraftCount)
                    }
                    .font(DSHTheme.Typography.caption)
                    .foregroundStyle(DSHTheme.brand)
                    .accessibilityIdentifier("feedback.attach.textOnly")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(DSHTheme.Spacing.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSHTheme.labelError.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous))
    }

    private var failedDraftCount: Int {
        max(1, drafts.filter { FeedbackAttachmentStatus.isFailure(phase(of: $0)) }.count)
    }

    // MARK: - 会一并提交的技术信息

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
            Text("正文、你主动选择的图片或文件，以及随信附带的信息会存到我们的服务器；截图里可能包含会话内容。")
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
