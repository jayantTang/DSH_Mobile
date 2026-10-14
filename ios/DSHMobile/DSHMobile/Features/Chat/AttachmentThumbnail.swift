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
    @State private var isShowingPreview = false
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
                    isShowingPreview = true
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
        .task(id: attachment.attachmentId) {
            await images.load(attachment.attachmentId, variant: attachment.cacheVariant)
        }
        .fullScreenCover(isPresented: $isShowingPreview) {
            if let resolved {
                ImagePreview(image: resolved, label: attachmentLabel)
            }
        }
    }

    private var attachmentLabel: String {
        // Never surfaces the agent marker: it is a routing signal, not a name.
        ChatTimeline.displayName(attachment) ?? "图片"
    }

    /// The box the picture will occupy: a failure with a way out, or a spinner.
    ///
    /// Split into two top-level views rather than one container with a branch
    /// inside: an identifier on the container swallows the identifiers of what
    /// it contains (the retry button's id never reached the accessibility tree,
    /// and the case could not find it).
    @ViewBuilder
    private var placeholder: some View {
        if images.hasFailed(attachment.attachmentId) {
            Button {
                Task { await images.retry(attachment.attachmentId) }
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
            .accessibilityLabel("图片加载失败，点按重试")
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
            .accessibilityIdentifier("attachment.image.loading")
        }
    }
}

/// The image on its own, zoomable, dismissible.
///
/// Reads as a photo viewer rather than a sheet of controls: pinch or double tap
/// to zoom, drag to pan, and a single tap on the backdrop to close.
struct ImagePreview: View {
    let image: UIImage
    let label: String
    /// The file behind the picture, when there is one on this phone.
    ///
    /// A workspace picture arrives as a file the browser downloaded, and the
    /// share sheet is how it leaves the phone again — the same viewer serving the
    /// transcript (which has bytes and no file) and the browser (which has both).
    var shareURL: URL?
    /// Prefix for the automation identifiers, so a run can tell the workspace
    /// viewer and the transcript viewer apart.
    var identifierPrefix: String = "attachment.preview"

    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    private static let maximumScale: CGFloat = 6

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(magnification.simultaneously(with: pan))
                .onTapGesture(count: 2) { toggleZoom() }
                .onTapGesture { dismiss() }
                .accessibilityIdentifier(identifierPrefix)
                .accessibilityLabel(label)
        }
        .overlay(alignment: .top) {
            toolbar
        }
        .statusBarHidden()
    }

    private var toolbar: some View {
        HStack {
            Button("完成") { dismiss() }
                .accessibilityIdentifier("\(identifierPrefix).done")
            Spacer()
            Text(label)
                .font(DSHTheme.Typography.caption)
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
            Spacer()
            if let shareURL {
                ShareLink(item: shareURL) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityIdentifier("\(identifierPrefix).share")
                .accessibilityLabel(shareURL.lastPathComponent)
            }
            Button {
                saveToPhotos()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .accessibilityIdentifier("\(identifierPrefix).save")
        }
        .padding(.horizontal, DSHTheme.Spacing.loose)
        .padding(.vertical, DSHTheme.Spacing.tight)
        .background(.black.opacity(0.35))
    }

    private var magnification: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(committedScale * value.magnification, 1), Self.maximumScale)
            }
            .onEnded { _ in
                committedScale = scale
                if scale <= 1 { resetPan() }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                // Panning is only meaningful once the picture is bigger than
                // the screen; at fit size a drag should not slide it around.
                guard scale > 1 else { return }
                offset = CGSize(
                    width: committedOffset.width + value.translation.width,
                    height: committedOffset.height + value.translation.height
                )
            }
            .onEnded { _ in committedOffset = offset }
    }

    private func toggleZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            if scale > 1 {
                scale = 1
                committedScale = 1
                resetPan()
            } else {
                scale = 2.5
                committedScale = 2.5
            }
        }
    }

    private func resetPan() {
        offset = .zero
        committedOffset = .zero
    }

    private func saveToPhotos() {
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
    }
}
