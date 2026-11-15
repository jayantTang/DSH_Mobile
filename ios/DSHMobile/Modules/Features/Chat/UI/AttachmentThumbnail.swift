#if os(iOS)
import DSHDesign
import SwiftUI
import UIKit
import DSHKit

/// A picture in the transcript, drawn from its durable attachment.
///
/// The block only carries a reference, so this loads the bytes on appearance
/// and shows a placeholder the size the image will be — the transcript must not
/// jump when a screenshot finishes arriving.
struct AttachmentThumbnail: View {
    let attachment: ContentBlock.ImageAttachment
    /// Longest side on screen, so a tall phone screenshot does not take over.
    var maxHeight: CGFloat = 260

    @Environment(AttachmentImages.self) private var images
    /// The picture being previewed, with its bytes already in hand.
    ///
    /// 呈现项自己持有 `UIImage`，不再在呈现时回头查缓存：缓存是可变且会被系统
    /// 回收的（NSCache 在内存压力下随时清空），而全屏模态的生命周期比一次查找长。
    /// 以前这里只有 `isShowingPreview` 一个 Bool，内容靠 `if let resolved` 现查——
    /// 查不到时仍然呈现出**一个空的**全屏模态，没有工具栏也没有侧滑关闭，用户只能
    /// 杀进程。一个状态只能有一个所有者：打开哪张图由这里决定，内容由它一起带着走。
    @State private var preview: PresentedImage?
    /// 行内容宽，量到之前先按经验值估；T029 后它只影响占位精度，
    /// 高度由「宽度 ÷ 宽高比」一次算定，解码完成不再改。
    @State private var columnWidth: CGFloat = 320

    /// 协议事件没带宽高时的占位比例（4:3）。真实尺寸解码后由
    /// `AttachmentImages` 写进尺寸缓存，之后同一附件直接按真实比例定高。
    private static let fallbackAspect: CGFloat = 4.0 / 3.0

    /// 宽高比来源优先级：事件元数据 → 尺寸缓存（上次解码记录）→ 4:3 占位。
    private var aspectRatio: CGFloat {
        if let width = attachment.width, let height = attachment.height,
           width > 0, height > 0 {
            return CGFloat(width) / CGFloat(height)
        }
        if let size = images.knownSize(attachment.attachmentId),
           let ratio = size.aspectRatio {
            return CGFloat(ratio)
        }
        return Self.fallbackAspect
    }

    /// T029：占位即最终尺寸——行高按宽高比 + 可用宽度**定死**，
    /// 解码完成只换内容、不改高度。
    private var reservedSize: CGSize {
        let height = min(maxHeight, max(120, columnWidth / aspectRatio))
        return CGSize(width: min(columnWidth, height * aspectRatio), height: height)
    }

    private var resolved: UIImage? {
        images.cached(attachment.attachmentId)
    }

    var body: some View {
        Group {
            if let resolved {
                Button {
                    openPreview(resolved)
                } label: {
                    Image(uiImage: resolved)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: reservedSize.width, height: reservedSize.height)
                        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous)
                                .strokeBorder(DSHTheme.border2, lineWidth: 0.5)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("attachment.image")
                .accessibilityLabel(attachmentLabel)
                .accessibilityHint("打开查看大图")
            } else {
                placeholder
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
            if width > 0 { columnWidth = width }
        }
        // 任务身份只按附件 id：重试由状态机自己安排，视图不再拿"链路代数"当身份。
        // 行滚出屏幕 → 这个 task 被取消 → 驱动停止，退避的等待也不会在后台空转。
        .task(id: attachment.attachmentId) {
            await images.begin(attachment)
        }
        .fullScreenCover(item: $preview) { item in
            AttachmentPreviewScreen(attachment: attachment,
                                    preview: item.image,
                                    label: item.label)
        }
    }

    /// 记下要显示的那张图。先取图、再（在调试钩子里）清缓存：呈现项从此与缓存无关。
    private func openPreview(_ image: UIImage) {
        preview = PresentedImage(
            id: attachment.attachmentId, image: image, label: attachmentLabel)
        #if DEBUG
        // `-DSHDropImageCacheOnPreview`：把「点下去之后缓存立刻被清空」固定下来。
        // 真机上 NSCache 何时淘汰由内存压力决定，用例等不来这一刻；注入之后走的是
        // 真实的呈现路径。Release 里没有这个字符串。
        if Self.dropsCacheOnPreview { images.clearAllCached() }
        #endif
    }

    /// 全屏预览的呈现项：身份用于 `fullScreenCover(item:)`，图片随项一起持有。
    private struct PresentedImage: Identifiable {
        let id: String
        let image: UIImage
        let label: String
    }

    #if DEBUG
    /// 只在调试构建里读一次启动参数；Release 里连这个属性都不存在。
    private static let dropsCacheOnPreview =
        ProcessInfo.processInfo.arguments.contains("-DSHDropImageCacheOnPreview")
    #endif

    private var attachmentLabel: String {
        // Never surfaces the agent marker: it is a routing signal, not a name.
        ChatTimeline.displayName(attachment) ?? "图片"
    }

    /// The box the picture will occupy: a failure with a way out, or a spinner.
    ///
    /// Which one is decided by the loader's state machine, never by the clock in
    /// this view: a failed attempt now schedules its own retry, so the failure
    /// tile is a state a picture *passes through*, not one it is stuck in.
    ///
    /// Split into two top-level views rather than one container with a branch
    /// inside: an identifier on the container swallows the identifiers of what
    /// it contains (the retry button's id never reached the accessibility tree,
    /// and the case could not find it).
    @ViewBuilder
    private var placeholder: some View {
        if case .failed(let reason) = images.state(attachment.attachmentId) {
            Button {
                images.retry(attachment.attachmentId)
            } label: {
                VStack(spacing: DSHTheme.Spacing.hairline) {
                    Image(systemName: "arrow.clockwise")
                    Text("图片加载失败")
                        .font(DSHTheme.Typography.micro)
                    Text("点按重试")
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.brand)
                }
                .foregroundStyle(DSHTheme.labelTertiary)
                .frame(width: reservedSize.width, height: reservedSize.height)
                .background(
                    RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous)
                        .fill(DSHTheme.codeBackground)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("attachment.image.retry")
            // 失败原因只进无障碍标签与诊断，不铺在界面上。
            .accessibilityLabel(String(localized: "图片加载失败，点按重试（\(reason)）"))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous)
                    .fill(DSHTheme.codeBackground)
                ProgressView()
            }
            // A concrete height, not `maxWidth: .infinity` combined with
            // `aspectRatio`: that pair asks the layout for an infinite width and
            // then derives the height from it, which is a feedback loop — it locked
            // the main thread and left the transcript blank.
            .frame(width: reservedSize.width, height: reservedSize.height)
            // 显式成为一个无障碍元素：否则这层容器的标识会被里面的 `ProgressView`
            // 吞掉，VoiceOver 与用例都拿不到"这张图正在加载"这件事。
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "正在加载图片"))
            .accessibilityIdentifier("attachment.image.loading")
        }
    }
}

/// 全屏查看这一张附件：预览已到手，原图**按需**。
///
/// 为什么单独一层而不是在缩略图里直接放 `ImagePreview`：查看器要能随着原图下载
/// 完成把画面从预览切成原图，还要把「原图 12.3 MB / 进度 / 重试」的状态接到
/// `AttachmentImages` 上。呈现项（`PresentedImage`）只带预览字节，下载状态归
/// `AttachmentImages` 所有，所以查看器必须自己观察它，而不是在打开时快照一次。
///
/// **查询只发生一次**：打开全屏时查一次元数据；不可用（旧数据、Host 已清理、
/// 旧连接器）落在终态，不再重试；下载失败停在可重试，绝不自动重来。
private struct AttachmentPreviewScreen: View {
    let attachment: ContentBlock.ImageAttachment
    let preview: UIImage
    let label: String

    @Environment(AttachmentImages.self) private var images

    private var state: AttachmentImages.OriginalState {
        images.originalState(attachment.attachmentId)
    }

    /// 已经下载并校验过的原图；没有就继续显示预览。
    private var originalImage: UIImage? {
        images.originalImage(attachment.attachmentId)
    }

    private var shown: UIImage { originalImage ?? preview }

    /// 「原图 4288×2848」：切换是否真的发生，用像素尺寸说清楚。
    ///
    /// 预览上限 2560/400 万像素，手机在 1 倍时原本就看不出差别；尺寸是唯一
    /// 不靠放大就能核对的证据（也顺手回答了"我保存的是哪一份"）。
    private var caption: String? {
        guard let cg = originalImage?.cgImage else { return nil }
        // 尺寸先拼成文本再走既有的「原图 %@」键：数字不进格式化串，既不会按
        // 本地化规则插千位分隔符（用户要对照的是原图真实像素），也复用现有文案键。
        let pixels = "\(cg.width)×\(cg.height)"
        return String(localized: "原图 \(pixels)")
    }

    var body: some View {
        ImagePreview(
            image: shown,
            label: label,
            original: ImagePreviewOriginal(
                phase: phase,
                bytes: bytes,
                onRequest: {
                    Task { await images.downloadOriginal(attachment) }
                },
                onCancel: {},
                data: { images.originalData(attachment.attachmentId) }
            ),
            caption: caption
        )
        .task {
            // 只在用户真的打开全屏时查一次；列表滚动与首帧都不走到这里。
            await images.lookupOriginal(attachment)
        }
    }

    /// 状态机 → 查看器：`.ready` 只在字节已经到手时才是「在看原图」，
    /// 元数据已知但还没下载仍然是「查看原图」按钮。
    private var phase: ImagePreviewOriginal.Phase {
        if originalImage != nil { return .ready }
        switch state {
        case .idle:
            return .idle
        case .ready:
            return .idle
        case .loading(let progress):
            let total = bytes
            let received = total.map { Int(Double($0) * max(0, min(1, progress))) }
            return .downloading(received: received ?? 0, total: total)
        case .failed:
            return .failed
        case .unavailable:
            return .unavailable
        }
    }

    private var bytes: Int? {
        if case .ready(let metadata) = state { return metadata.bytes }
        return nil
    }
}
#endif
