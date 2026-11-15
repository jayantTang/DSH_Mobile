import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// 图片预览（spec 024 / S2：从 Features/Chat 抽出到共享呈现层）。
//
// 为什么在共享层：它被三个模块用（会话的图片附件、工作区的文件预览与文件列表），
// 留在任何一个功能域里都会造成"功能域互相引用"（`npm run arch` 里 Chat ↔ Files 的双向边）。
// 它只依赖 UIKit 的 UIImage 与 SwiftUI，不引用任何业务类型。
#if canImport(UIKit)
public struct ImagePreview: View {
    public let image: UIImage
    public let label: String
    /// The file behind the picture, when there is one on this phone.
    ///
    /// A workspace picture arrives as a file the browser downloaded, and the
    /// share sheet is how it leaves the phone again — the same viewer serving the
    /// transcript (which has bytes and no file) and the browser (which has both).
    public var shareURL: URL?
    /// Prefix for the automation identifiers, so a run can tell the workspace
    /// viewer and the transcript viewer apart.
    public var identifierPrefix: String = "attachment.preview"
    /// 分享按钮的文字；nil 时只画图标（会话与信件保持原样）。
    ///
    /// 工作区图片给它「下载原文件」：那里的 `shareURL` 就是电脑上的原文件，
    /// 分享面板拿到的字节与文件一致，不经过任何重编码。
    public var shareTitle: String?
    /// 图片下方的说明（例如「原图 4288×2848」）。
    ///
    /// 为什么需要它：预览上限是 2560/400 万像素，手机屏幕在 1 倍时两者看起来
    /// **一样清楚**——原图的差别只有放大以后才看得到。没有这行字，用户点完
    /// 「查看原图」无法确认自己看的到底是哪一份；有了像素尺寸，切换是可见的。
    public var caption: String?
    /// 会话图片的「查看原图 / 保存原图」入口（可缺省）。
    ///
    /// 预览与原图是两份字节：查看器默认拿到的 `image` 永远是预览，原图按需下载，
    /// 状态与动作由调用方（`AttachmentImages` / 信件缓存）提供——查看器只画状态。
    public var original: ImagePreviewOriginal?
    /// 工具栏里夹在 label 与 share 之间的附加控件。
    ///
    /// 信件附件的「原图 7.2 MB / 下载中 / 重试」按钮走这里（设计 §5 A5）：查看器本身
    /// 只负责显示一张图，下载状态归 `FeedbackAttachmentCache`，所以这里只收一个视图。
    public var accessory: AnyView?

    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero
    @State private var saveMessage: String?
    @State private var showsPermissionAlert = false

    public init(image: UIImage, label: String, shareURL: URL? = nil,
                identifierPrefix: String = "attachment.preview",
                shareTitle: String? = nil,
                accessory: AnyView? = nil,
                original: ImagePreviewOriginal? = nil,
                caption: String? = nil) {
        self.image = image
        self.label = label
        self.shareURL = shareURL
        self.identifierPrefix = identifierPrefix
        self.shareTitle = shareTitle
        self.accessory = accessory
        self.original = original
        self.caption = caption
    }

    private static let maximumScale: CGFloat = 6

    public var body: some View {
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
        .overlay(alignment: .bottom) {
            if let caption {
                Text(caption)
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, DSHTheme.Spacing.tight)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.35), in: Capsule())
                    .padding(.bottom, DSHTheme.Spacing.loose)
                    .accessibilityIdentifier("\(identifierPrefix).caption")
            }
        }
        .overlay(alignment: .bottom) {
            if let saveMessage {
                Text(saveMessage)
                    .font(DSHTheme.Typography.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, DSHTheme.Spacing.standard)
                    .padding(.vertical, DSHTheme.Spacing.tight)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(.bottom, DSHTheme.Spacing.loose)
                    .transition(.opacity)
                    .accessibilityIdentifier("\(identifierPrefix).save.message")
            }
        }
        .alert(String(localized: "无法保存图片"), isPresented: $showsPermissionAlert) {
            Button(String(localized: "打开设置")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(String(localized: "相册权限未开启，无法保存图片。可在系统设置里允许访问相册。"))
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
            if let accessory {
                accessory
            }
            if let original {
                originalControl(original)
            }
            if let shareURL {
                ShareLink(item: shareURL) {
                    if let shareTitle {
                        Label(shareTitle, systemImage: "square.and.arrow.up")
                            .font(DSHTheme.Typography.caption)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .accessibilityIdentifier("\(identifierPrefix).share")
                .accessibilityLabel(shareURL.lastPathComponent)
            }
            saveControl
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

    /// 没有原图入口时保持原来的单按钮（信件、工作区、git 查看器都还走这一支）。
    @ViewBuilder
    private var saveControl: some View {
        if original == nil {
            Button {
                savePreview()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .accessibilityIdentifier("\(identifierPrefix).save")
        } else {
            Menu {
                Button(String(localized: "保存预览")) { savePreview() }
                    .accessibilityIdentifier("\(identifierPrefix).save.preview")
                Button(String(localized: "保存原图")) { saveOriginal() }
                    .accessibilityIdentifier("\(identifierPrefix).save.original")
                    .disabled(!originalReady)
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .accessibilityIdentifier("\(identifierPrefix).save")
        }
    }

    /// 五种状态的可见形态；`unavailable` 是明说而不是报错（SR-02.11）。
    @ViewBuilder
    private func originalControl(_ original: ImagePreviewOriginal) -> some View {
        switch original.phase {
        case .idle:
            Button(original.title) { original.onRequest() }
                .font(DSHTheme.Typography.caption)
                .accessibilityIdentifier("\(identifierPrefix).original")
        case .downloading(let received, let total):
            HStack(spacing: DSHTheme.Spacing.hairline) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text(progressText(received: received, total: total))
                    .font(DSHTheme.Typography.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .accessibilityIdentifier("\(identifierPrefix).original.progress")
                Button(String(localized: "取消")) { original.onCancel() }
                    .font(DSHTheme.Typography.caption)
                    .accessibilityIdentifier("\(identifierPrefix).original.cancel")
            }
        case .failed:
            Button(String(localized: "原图下载失败，点按重试")) { original.onRequest() }
                .font(DSHTheme.Typography.caption)
                .accessibilityIdentifier("\(identifierPrefix).original.retry")
        case .ready:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.white.opacity(0.8))
                .accessibilityLabel(String(localized: "原图已加载"))
                .accessibilityIdentifier("\(identifierPrefix).original.ready")
        case .unavailable:
            Text(String(localized: "原图不可用"))
                .font(DSHTheme.Typography.caption)
                .foregroundStyle(.white.opacity(0.6))
                .accessibilityIdentifier("\(identifierPrefix).original.unavailable")
        }
    }

    private var originalReady: Bool {
        guard let original else { return false }
        if original.phase.isReady, original.data() != nil { return true }
        // 工作区路径：没有原图变体，但 `shareURL` 就是原文件。
        if case .ready = original.phase { return true }
        return false
    }

    private func progressText(received: Int, total: Int?) -> String {
        guard let total, total > 0 else { return String(localized: "正在下载原图") }
        let percent = min(100, Int(Double(received) / Double(total) * 100))
        // 百分号留在本地化串之外：带插值的键是格式串，裸 `%` 会让格式化失效。
        return String(localized: "正在下载原图") + " \(percent)%"
    }

    private func savePreview() {
        Task { @MainActor in
            await handle(await PhotoLibrarySaver.save(image: image))
        }
    }

    private func saveOriginal() {
        Task { @MainActor in
            let data = original?.data() ?? shareURL.flatMap { try? Data(contentsOf: $0) }
            guard let data else {
                await handle(.failed(String(localized: "保存失败")))
                return
            }
            await handle(await PhotoLibrarySaver.save(data: data))
        }
    }

    private func handle(_ outcome: PhotoLibrarySaver.Outcome) async {
        switch outcome {
        case .saved:
            withAnimation { saveMessage = String(localized: "已保存") }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation { saveMessage = nil }
        case .denied:
            showsPermissionAlert = true
        case .failed:
            withAnimation { saveMessage = String(localized: "保存失败") }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { saveMessage = nil }
        }
    }
}
#endif
