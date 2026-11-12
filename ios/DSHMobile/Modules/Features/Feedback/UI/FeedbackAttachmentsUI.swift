import RelayKit
#if os(iOS)
import DSHDesign
import DSHFeedbackDomain
import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// 附件区的共用零件：写信页的队列（C4/C7/C8）与详情页的呈现（D1/D2/D3）都用这一套。
///
/// 状态词、图标、大小文案只在这里各写一次——两个界面不会漂成两种说法。

enum FeedbackAttachmentStatus {
    static func text(_ phase: FeedbackSendJob.SlotPhase) -> String {
        switch phase {
        case .waiting: return String(localized: "等待上传")
        case .uploading: return String(localized: "正在上传")
        case .uploaded: return String(localized: "已上传")
        case .failed: return String(localized: "没有传上去")
        case .cancelled: return String(localized: "已取消")
        }
    }

    static func isFailure(_ phase: FeedbackSendJob.SlotPhase) -> Bool {
        phase == .failed || phase == .cancelled
    }
}

enum FeedbackAttachmentSize {
    /// 附件大小的显示：单文件/合计的"实际字节"用这一种（KB/MB 的十进制口径）。
    ///
    /// 小于 1 KB 按**字节**说：`ByteCountFormatter` 会把 81 字节写成「0 KB」，
    /// 那既不是真话也不像话。
    static func text(_ bytes: Int) -> String {
        let value = max(0, bytes)
        if value < 1024 {
            return String(localized: "\(value) 字节")
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB]
        return formatter.string(fromByteCount: Int64(value))
    }

    /// **上限**的显示：按 MiB 整数口径（8,388,608 → `8 MiB`）。
    ///
    /// 上限是 1024 进制的服务端约定（8 MiB / 24 MiB）；用十进制格式化会写成
    /// 「8.4 MB」，既和「单个不超过 8 MB」自相矛盾，也让人以为额度多了 4%。
    /// 不能整除 MiB 时才退回带一位小数的 MiB，仍不换单位。
    static func limitText(_ bytes: Int) -> String {
        let mib = 1024 * 1024
        guard bytes > 0 else { return "" }
        if bytes % mib == 0 { return "\(bytes / mib) MiB" }
        return String(format: "%.1f MiB", Double(bytes) / Double(mib))
    }
}

enum FeedbackAttachmentIcon {
    static func name(_ contentType: String) -> String {
        if contentType == "application/pdf" { return "doc.richtext" }
        if contentType.hasPrefix("text/") || contentType == "application/json" {
            return "doc.text"
        }
        return "doc"
    }
}

/// 附件角标（设计 §5 A4）：这笔钱真的带了原图，还是只有预览。
///
/// 文字与无障碍标识各只有一处；判据来自 `FeedbackAttachmentPlan`，不在这里重算。
enum AttachmentBadge: Equatable {
    case highDefinition
    case previewOnly

    var text: String {
        switch self {
        case .highDefinition: return String(localized: "含高清")
        case .previewOnly: return String(localized: "仅预览")
        }
    }

    var identifier: String {
        switch self {
        case .highDefinition: return "feedback.attach.badge.hd"
        case .previewOnly: return "feedback.attach.badge.preview"
        }
    }
}

/// 图条里的一张（还没上传的本地草稿）。
struct FeedbackStripItem: Identifiable, Equatable {
    let id: UUID
    let name: String
    let bytes: Int
    let phase: FeedbackSendJob.SlotPhase
    let thumbnail: UIImage?
    var badge: AttachmentBadge?

    init(id: UUID, name: String, bytes: Int, phase: FeedbackSendJob.SlotPhase,
         thumbnail: UIImage?, badge: AttachmentBadge? = nil) {
        self.id = id
        self.name = name
        self.bytes = bytes
        self.phase = phase
        self.thumbnail = thumbnail
        self.badge = badge
    }
}

/// 图片横向条（C4-3）：高 72（56 + 上下 8），56×56 裁切，右上角移除。
struct FeedbackAttachmentStrip: View {
    let items: [FeedbackStripItem]
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DSHTheme.Spacing.tight) {
                ForEach(items) { item in
                    thumbnail(item)
                }
            }
            .padding(.vertical, DSHTheme.Spacing.tight)
        }
        .accessibilityIdentifier("feedback.attach.strip")
    }

    @ViewBuilder
    private func thumbnail(_ item: FeedbackStripItem) -> some View {
        VStack(spacing: 2) {
            thumbnailImage(item)
            if let badge = item.badge {
                Text(badge.text)
                    .font(.system(size: 10))
                    .foregroundStyle(DSHTheme.labelSecondary)
                    .lineLimit(1)
                    .accessibilityIdentifier(badge.identifier)
            }
        }
    }

    @ViewBuilder
    private func thumbnailImage(_ item: FeedbackStripItem) -> some View {
        ZStack {
            if let image = item.thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                DSHTheme.layer2
            }
            if item.phase == .uploading {
                Color.white.opacity(0.62)
                ProgressView()
                    .controlSize(.small)
            } else if FeedbackAttachmentStatus.isFailure(item.phase) {
                Color.white.opacity(0.86)
                Text(String(localized: "没有传上去"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DSHTheme.labelError)
                    .multilineTextAlignment(.center)
                    .padding(2)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.small, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button {
                onRemove(item.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white, DSHTheme.labelPrimary.opacity(0.7))
            }
            .padding(2)
            .frame(width: 44, height: 44, alignment: .topTrailing)
            .accessibilityIdentifier("feedback.attach.remove")
            .accessibilityLabel(String(localized: "移除"))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("feedback.attach.thumb")
        .accessibilityLabel(item.name)
        .accessibilityHint(String(localized: "点按移除"))
    }
}

/// 文件行（C4-4）：40×40 图标块 + 文件名 + `大小 · 状态` + 右侧动作。
struct FeedbackAttachmentFileRow: View {
    let name: String
    let bytes: Int
    let contentType: String
    let phase: FeedbackSendJob.SlotPhase
    var badge: AttachmentBadge?
    let onRemove: () -> Void
    var onRetry: (() -> Void)?

    var body: some View {
        HStack(spacing: DSHTheme.Spacing.tight) {
            Image(systemName: FeedbackAttachmentIcon.name(contentType))
                .font(.system(size: 18))
                .foregroundStyle(DSHTheme.labelSecondary)
                .frame(width: 40, height: 40)
                .background(DSHTheme.layer2,
                            in: RoundedRectangle(cornerRadius: DSHTheme.Radius.medium,
                                                 style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous)
                        .strokeBorder(DSHTheme.border2)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(DSHTheme.Typography.body)
                    .foregroundStyle(DSHTheme.labelPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(DSHTheme.Typography.caption)
                    .foregroundStyle(FeedbackAttachmentStatus.isFailure(phase)
                                     ? DSHTheme.labelError : DSHTheme.labelTertiary)
                    .lineLimit(1)
                    .accessibilityIdentifier("feedback.attach.state")
            }
            Spacer(minLength: DSHTheme.Spacing.hairline)
            if phase == .uploading {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(String(localized: "正在上传附件"))
            } else if phase == .failed, let onRetry {
                Button(String(localized: "重试"), action: onRetry)
                    .font(DSHTheme.Typography.caption)
                    .foregroundStyle(DSHTheme.brand)
                    .frame(minHeight: 44)
            } else if phase == .waiting || phase == .uploaded {
                Button(String(localized: "移除"), action: onRemove)
                    .font(DSHTheme.Typography.caption)
                    .foregroundStyle(DSHTheme.brand)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("feedback.attach.remove")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("feedback.attach.row")
        .accessibilityLabel("\(name)，\(FeedbackAttachmentSize.text(bytes))，\(FeedbackAttachmentStatus.text(phase))")
    }

    private var detail: String {
        var parts = [FeedbackAttachmentSize.text(bytes), FeedbackAttachmentStatus.text(phase)]
        if let badge { parts.append(badge.text) }
        return parts.joined(separator: " · ")
    }
}

/// 详情页的附件区（D2/D3）：图片单图或 2 列宫格，文件逐个一行（点「打开」用 QuickLook）。
struct FeedbackAttachmentGrid: View {
    let attachments: [FeedbackAttachment]
    @State private var previewFile: URL?

    private var images: [FeedbackAttachment] {
        attachments.filter { $0.contentType.hasPrefix("image/") }
    }

    private var files: [FeedbackAttachment] {
        attachments.filter { !$0.contentType.hasPrefix("image/") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.tight) {
            if !images.isEmpty {
                imageGrid
            }
            ForEach(files) { attachment in
                fileRow(attachment)
            }
        }
        .sheet(item: $previewFile) { url in
            FileQuickLook(url: url)
        }
    }

    private var imageGrid: some View {
        // 单图：按原始宽高比铺满卡内宽度，高度封顶 260（超高的裁切，不把页面撑长）。
        // 多图：2 列 1:1 宫格。占位块的尺寸也在这里定死，绝不随图片元数据膨胀。
        if let single = images.first, images.count == 1 {
            return AnyView(
                FeedbackAttachmentImage(attachment: single, layout: .fillWidth(maxHeight: 260))
                    .frame(maxWidth: .infinity))
        }
        // 列表**只读预览**（有 `preview` 用预览子对象，旧信件用本地缩略图）；
        // 原图只有打开全屏之后才会被请求一次。
        let columns = [GridItem(.flexible(), spacing: DSHTheme.Spacing.tight),
                       GridItem(.flexible(), spacing: DSHTheme.Spacing.tight)]
        return AnyView(
            LazyVGrid(columns: columns, spacing: DSHTheme.Spacing.tight) {
                ForEach(images) { attachment in
                    FeedbackAttachmentImage(attachment: attachment, layout: .square)
                }
            })
    }

    private func fileRow(_ attachment: FeedbackAttachment) -> some View {
        Button {
            Task { await openFile(attachment) }
        } label: {
            HStack(spacing: DSHTheme.Spacing.tight) {
                Image(systemName: FeedbackAttachmentIcon.name(attachment.contentType))
                    .font(.system(size: 18))
                    .foregroundStyle(DSHTheme.labelSecondary)
                    .frame(width: 40, height: 40)
                    .background(DSHTheme.layer2,
                                in: RoundedRectangle(cornerRadius: DSHTheme.Radius.medium,
                                                     style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.name)
                        .font(DSHTheme.Typography.body)
                        .foregroundStyle(DSHTheme.labelPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(FeedbackAttachmentSize.text(attachment.byteSize))
                        .font(DSHTheme.Typography.caption)
                        .foregroundStyle(DSHTheme.labelTertiary)
                }
                Spacer(minLength: DSHTheme.Spacing.hairline)
                Text(String(localized: "打开"))
                    .font(DSHTheme.Typography.caption)
                    .foregroundStyle(DSHTheme.brand)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 56)
        .accessibilityIdentifier("feedback.attachment.file")
    }

    private func openFile(_ attachment: FeedbackAttachment) async {
        guard let bytes = await FeedbackCenter.shared.attachmentCache
            .load(attachment, variant: .original) else { return }
        let name = attachment.name.isEmpty ? attachment.attachmentId : attachment.name
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(attachment.attachmentId + "-" + name)
        try? bytes.write(to: url, options: .atomic)
        previewFile = url
    }
}

/// 一张附件图：所有状态都读 ``FeedbackAttachmentCache``，视图里不再存副本。
///
/// 三种读法（与 wire 一致）：
///
/// - 有 `preview` 子对象：列表读 `.preview`；
/// - `compressed == true`：主对象就是预览，列表也读 `.preview`；
/// - 旧信件（两者都没有）：列表读 `.thumbnail`（本地生成并缓存，长边 ≤320）。
///
/// 列表**绝不**请求 `.original`：原图只有用户点开全屏之后才按需下载。
struct FeedbackAttachmentImage: View {
    /// 这一格的尺寸口径。两种都由容器决定，不看图片本身多大。
    enum Layout: Equatable {
        /// 铺满可用宽度，按宽高比定高，超过 `maxHeight` 裁切。
        case fillWidth(maxHeight: CGFloat)
        /// 1:1 方格（宫格用）。
        case square
    }

    let attachment: FeedbackAttachment
    var layout: Layout = .square

    @State private var isPreviewing = false

    private var cache: FeedbackAttachmentCache { FeedbackCenter.shared.attachmentCache }

    /// 列表读哪一份：只在 `.preview` 与 `.thumbnail` 之间选，**不含** `.original`。
    private var variant: FeedbackAttachmentCache.LoadVariant {
        (attachment.preview != nil || attachment.compressed) ? .preview : .thumbnail
    }

    private var state: FeedbackAttachmentCache.LoadState {
        cache.state(for: attachment, variant: variant)
    }

    private var bytes: Data? { cache.cached(attachment, variant: variant) }

    /// 列表这一份是不是压缩版：判据只有 `compressed`（同一个域类型）。
    private var badge: FeedbackAttachmentCompressedBadge {
        FeedbackAttachmentCompressedBadge(attachment)
    }

    private var corner: CGFloat { DSHTheme.Radius.medium }

    var body: some View {
        ZStack {
            // 占位块必须**不透明**：加载中透出下层页面，看起来就像整块空白。
            DSHTheme.codeBackground
            if let bytes, let image = UIImage(data: bytes) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if case .failed = state {
                Button {
                    Task { await cache.load(attachment, variant: variant) }
                } label: {
                    VStack(spacing: DSHTheme.Spacing.hairline) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(String(localized: "附件没有取到，点按重试"))
                            .font(DSHTheme.Typography.micro)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(DSHTheme.labelError)
                    .padding(DSHTheme.Spacing.tight)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("feedback.attachment.retry")
            } else {
                ProgressView()
                    .accessibilityLabel(String(localized: "正在加载附件…"))
            }
        }
        .modifier(FeedbackAttachmentFrame(layout: layout, aspect: aspectRatio))
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(DSHTheme.border2)
        }
        // 正文/列表也要标「压缩版」：这一份主对象本身就是预览，用户不该以为原图丢了。
        // 同一个标记类型、同一个标识（用例 TC-MOB-143 的第 3 步在列表查它）。
        .overlay(alignment: .bottomLeading) {
            FeedbackCompressedMark(badge: badge)
                .padding(DSHTheme.Spacing.hairline)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if bytes != nil { isPreviewing = true }
        }
        .task(id: "\(attachment.attachmentId)|\(variant.rawValue)") {
            await cache.load(attachment, variant: variant)
        }
        .fullScreenCover(isPresented: $isPreviewing) {
            FeedbackAttachmentViewer(attachment: attachment, variant: variant)
        }
        // 这一层是**容器**：不加 `.contain`，子元素的标识（`feedback.attachment.compressed`、
        // 失败重试）会被容器的 `feedback.attachment.image` 吞掉——2026-10 的「重试按钮标识
        // 被容器吞掉」同一条坑。加 `children: .contain` 之后容器自身与子元素都留在无障碍树里。
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("feedback.attachment.image")
    }

    /// 有图用真实宽高比；没有图时单图退回元数据 / 16:9 的占位比例（宫格恒为 1）。
    private var aspectRatio: CGFloat {
        switch layout {
        case .square:
            return 1
        case .fillWidth:
            if let bytes, let image = UIImage(data: bytes), image.size.height > 0 {
                return image.size.width / image.size.height
            }
            if let width = attachment.width, let height = attachment.height,
               width > 0, height > 0 {
                return CGFloat(width) / CGFloat(height)
            }
            return 16.0 / 9.0
        }
    }
}

/// 「压缩版」标记（设计 §5 A5）：正文/列表一处、全屏一处，**同一个判定类型**。
///
/// 判据在 `FeedbackAttachmentCompressedBadge`（只读 wire 的 `compressed`），
/// 这里只负责画；文案与无障碍标识也都从那个类型取，不在视图里另写一份。
struct FeedbackCompressedMark: View {
    let badge: FeedbackAttachmentCompressedBadge
    /// 全屏在深色底上，正文在图片上——两处的底色不同，字号与配色由调用方给。
    var onDarkBackground = false

    var body: some View {
        if badge.isVisible {
            Text(badge.text)
                .font(onDarkBackground ? DSHTheme.Typography.caption : .system(size: 11, weight: .medium))
                .foregroundStyle(onDarkBackground ? .white.opacity(0.8) : .white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(onDarkBackground ? 0 : 0.55), in: Capsule())
                .accessibilityIdentifier(badge.identifier)
        }
    }
}

/// 全屏附件查看器：先显示预览，原图按需下载。
///
/// 它从 cache 派生两样东西——当前展示的那张图（原图已加载就用原图，否则用预览）
/// 与右上角的 accessory；原图字节**不**另存进视图（设计 §5 A5）。
struct FeedbackAttachmentViewer: View {
    let attachment: FeedbackAttachment
    let variant: FeedbackAttachmentCache.LoadVariant

    private var cache: FeedbackAttachmentCache { FeedbackCenter.shared.attachmentCache }

    /// 读 `state` 是为了让视图**可观察**：原图下载完成会改状态，重绘之后下面的
    /// `cached(.original)` 才拿得到新字节（只读缓存不会触发重画，评审 P1-2）。
    private var originalState: FeedbackAttachmentCache.LoadState {
        cache.state(for: attachment, variant: .original)
    }

    private var hasCachedOriginal: Bool {
        cache.cached(attachment, variant: .original) != nil
    }

    private var shownBytes: Data? {
        let variant = FeedbackAttachmentOriginalDisplay.shownVariant(
            previewVariant: variant, state: originalState, hasCachedOriginal: hasCachedOriginal)
        return cache.cached(attachment, variant: variant)
    }

    var body: some View {
        Group {
            if let shownBytes, let image = UIImage(data: shownBytes) {
                ImagePreview(image: image, label: attachment.name,
                             identifierPrefix: "feedback.attachment",
                             accessory: AnyView(FeedbackOriginalAccessory(attachment: attachment)))
            } else {
                ProgressView()
                    .task { await cache.load(attachment, variant: variant) }
            }
        }
    }
}

/// 全屏右上角的原图入口：四种结局各一个可见状态。
///
/// - `compressed`（只有预览）：标「压缩版」，没有原图按钮；
/// - 旧信件（没有 `preview`）：主对象就是原图，已经在显示，不给按钮；
/// - 有原图：`idle` 按钮 → `loading` 进度 + 取消 → `failed` 重试 → `loaded` 按钮消失。
struct FeedbackOriginalAccessory: View {
    let attachment: FeedbackAttachment

    private var cache: FeedbackAttachmentCache { FeedbackCenter.shared.attachmentCache }

    private var state: FeedbackAttachmentCache.LoadState {
        cache.state(for: attachment, variant: .original)
    }

    /// 只读 `compressed` 字段（不从 preview 有无反推）。
    private var badge: FeedbackAttachmentCompressedBadge {
        FeedbackAttachmentCompressedBadge(attachment)
    }

    /// 原图是否已经就绪（状态是 loaded，或磁盘上已经有那份字节）。
    private var originalReady: Bool {
        FeedbackAttachmentOriginalDisplay.isAvailable(
            state: state, hasCachedOriginal: cache.cached(attachment, variant: .original) != nil)
    }

    var body: some View {
        if badge.isVisible {
            FeedbackCompressedMark(badge: badge, onDarkBackground: true)
        } else if attachment.preview == nil {
            EmptyView()
        } else if originalReady {
            EmptyView()
        } else {
            switch state {
            case .idle:
                Button(String(localized: "原图 \(FeedbackAttachmentSize.text(attachment.byteSize))")) {
                    Task { await cache.requestOriginal(attachment) }
                }
                .accessibilityIdentifier("feedback.attachment.original")
            case .loading(let received, let total):
                HStack(spacing: DSHTheme.Spacing.hairline) {
                    ProgressView()
                        .controlSize(.small)
                    Text(progressText(received: received, total: total))
                        .font(DSHTheme.Typography.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .accessibilityIdentifier("feedback.attachment.original.progress")
                    Button(String(localized: "取消")) { cache.cancelOriginal(attachment) }
                        .accessibilityIdentifier("feedback.attachment.original.cancel")
                }
            case .failed:
                Button(String(localized: "原图下载失败，点按重试")) {
                    Task { await cache.requestOriginal(attachment) }
                }
                .accessibilityIdentifier("feedback.attachment.original.retry")
            case .loaded:
                EmptyView()
            }
        }
    }

    private func progressText(received: Int, total: Int?) -> String {
        guard let total, total > 0 else {
            return String(localized: "正在下载原图")
        }
        let percent = min(100, Int(Double(received) / Double(total) * 100))
        // 百分号留在本地化串之外：带插值的键是格式串，裸 `%` 会让格式化失效。
        return String(localized: "正在下载原图") + " \(percent)%"
    }
}

/// 按 ``FeedbackAttachmentImage/Layout`` 定死尺寸的修饰器（宽高都不交给图片自己撑）。
private struct FeedbackAttachmentFrame: ViewModifier {
    let layout: FeedbackAttachmentImage.Layout
    let aspect: CGFloat

    func body(content: Content) -> some View {
        switch layout {
        case .square:
            content.aspectRatio(1, contentMode: .fit)
        case .fillWidth(let maxHeight):
            // `Color.clear.aspectRatio` 让容器先按比例占位（宽由卡片给），再把高度封顶；
            // 图片铺在它上面，多余部分裁掉——宽度始终撑满，高度永不越过 maxHeight。
            Color.clear
                .aspectRatio(aspect, contentMode: .fit)
                .frame(maxHeight: maxHeight)
                .overlay { content }
                .clipped()
        }
    }
}

/// 回信里的原文引用（D10）：灰色、默认折叠、只读，不计入正文字数。
struct FeedbackQuoteBlock: View {
    @Environment(FeedbackServices.self) private var services

    let text: String
    var format: FeedbackBodyFormat = .text
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.hairline) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: DSHTheme.Spacing.hairline) {
                    Text(String(localized: "以下是更早的信"))
                        .font(DSHTheme.Typography.caption)
                        .foregroundStyle(DSHTheme.labelTertiary)
                    Spacer(minLength: 0)
                    Text(expanded ? String(localized: "收起") : String(localized: "展开"))
                        .font(DSHTheme.Typography.caption)
                        .foregroundStyle(DSHTheme.labelTertiary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelTertiary)
                }
            }
            .buttonStyle(.plain)
            if expanded {
                quoteBody
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(DSHTheme.Spacing.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSHTheme.layer1,
                    in: RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous))
        .accessibilityIdentifier("feedback.quote")
    }

    /// 引用正文：`text` 与当前这封正文走同一条渲染路；`html` 仍是纯文本（不嵌第二个 WebKit）。
    @ViewBuilder
    private var quoteBody: some View {
        switch format {
        case .text:
            services.renderMarkdown(text)
                .foregroundStyle(DSHTheme.labelSecondary)
        case .html:
            Text(text)
                .font(DSHTheme.Typography.caption)
                .foregroundStyle(DSHTheme.labelSecondary)
        }
    }
}

/// QuickLook 预览（文件类附件「打开」）。放在反馈单元内，避免依赖 Files 单元。
struct FileQuickLook: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
#endif
