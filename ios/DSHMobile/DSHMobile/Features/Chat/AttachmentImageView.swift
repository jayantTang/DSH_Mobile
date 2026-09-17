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

    private var aspectRatio: CGFloat? {
        guard let width = attachment.width, let height = attachment.height,
              width > 0, height > 0
        else { return nil }
        return CGFloat(width) / CGFloat(height)
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
                        .frame(maxHeight: maxHeight)
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
        .task(id: attachment.attachmentId) {
            await images.load(attachment.attachmentId)
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

    /// A sane box to occupy while the bytes arrive.
    private var placeholderHeight: CGFloat {
        guard let aspectRatio, aspectRatio > 0 else { return 160 }
        // Assume roughly a phone-width column, then clamp so a tall screenshot
        // does not reserve the whole screen.
        return min(maxHeight, max(120, 320 / aspectRatio))
    }

    @ViewBuilder
    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous)
                .fill(DSHTheme.codeBackground)
            if images.hasFailed(attachment.attachmentId) {
                VStack(spacing: DSHTheme.Spacing.hairline) {
                    Image(systemName: "photo.badge.exclamationmark")
                    Text("图片加载失败")
                        .font(DSHTheme.Typography.micro)
                }
                .foregroundStyle(DSHTheme.labelTertiary)
            } else {
                ProgressView()
            }
        }
        // A concrete height, not `maxWidth: .infinity` combined with
        // `aspectRatio`: that pair asks the layout for an infinite width and
        // then derives the height from it, which is a feedback loop — it locked
        // the main thread and left the transcript blank.
        .frame(maxWidth: .infinity)
        .frame(height: placeholderHeight)
        .accessibilityIdentifier("attachment.image.loading")
    }
}

/// The image on its own, zoomable, dismissible.
///
/// Reads as a photo viewer rather than a sheet of controls: pinch or double tap
/// to zoom, drag to pan, and a single tap on the backdrop to close.
struct ImagePreview: View {
    let image: UIImage
    let label: String

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
                .accessibilityIdentifier("attachment.preview")
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
                .accessibilityIdentifier("attachment.preview.done")
            Spacer()
            Text(label)
                .font(DSHTheme.Typography.caption)
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
            Spacer()
            Button {
                saveToPhotos()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .accessibilityIdentifier("attachment.preview.save")
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
