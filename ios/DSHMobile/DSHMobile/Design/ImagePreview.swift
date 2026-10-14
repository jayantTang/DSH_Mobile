import SwiftUI
import UIKit

// 图片预览（spec 024 / S2：从 Features/Chat 抽出到共享呈现层）。
//
// 为什么在共享层：它被三个模块用（会话的图片附件、工作区的文件预览与文件列表），
// 留在任何一个功能域里都会造成"功能域互相引用"（`npm run arch` 里 Chat ↔ Files 的双向边）。
// 它只依赖 UIKit 的 UIImage 与 SwiftUI，不引用任何业务类型。
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
