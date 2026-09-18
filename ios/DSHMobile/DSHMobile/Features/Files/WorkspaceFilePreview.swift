import DSHKit
import QuickLook
import SwiftUI
import UIKit

/// What "下载" hands the file to, drawn as the system's own share button.
///
/// The phone has no other way *out*: saving into the Files app, AirDropping a
/// screenshot to a Mac and sending a deck to a colleague are all the same sheet,
/// and it is the one place iOS decides what a file of this type can be given to.
///
/// `ShareLink`, not a wrapped `UIActivityViewController`: the wrapped controller
/// presented nothing at all from inside the reader's sheet — the tap fired, the
/// state flipped, and no sheet and no elements ever appeared.
struct ShareFileButton: View {
    let url: URL
    var title: String = "分享"
    var identifier: String = "files.action.share"
    var prominent = false

    var body: some View {
        if prominent {
            ShareLink(item: url) { Label(title, systemImage: "square.and.arrow.up") }
                .buttonStyle(.borderedProminent)
                .tint(DSHTheme.brand)
                .frame(minHeight: 44)
                .accessibilityIdentifier(identifier)
        } else {
            ShareLink(item: url) { Label(title, systemImage: "square.and.arrow.up") }
                .accessibilityIdentifier(identifier)
        }
    }
}

/// One local file in the system's own preview.
///
/// QuickLook is the phone's answer to "open more types": pdf, Word, Excel,
/// Keynote, zip contents, audio and video are all things it already draws, and
/// none of them need a renderer in this app.
struct QuickLookSheet: UIViewControllerRepresentable {
    let url: URL

    /// Whether the system has anything to draw for this file.
    ///
    /// Asked before presenting, so a format QuickLook cannot render gets this
    /// app's own card (name, size, share) instead of QuickLook's empty screen.
    static func canPreview(_ url: URL) -> Bool {
        QLPreviewController.canPreview(url as NSURL)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> any QLPreviewItem {
            url as NSURL
        }
    }
}

/// How far the file has got from the computer, and what can be done about it.
///
/// Shown for every state on purpose: a download that finished is the proof the
/// bytes are all here, and the byte count is what makes a truncated file visible
/// rather than a picture that "just looks odd".
///
/// Stopping is not failing. `暂停` keeps what arrived and offers `继续`, because
/// on a phone the link *will* drop mid-file and the only thing that must never
/// happen is paying for the same bytes twice.
struct WorkspaceFileTransferStatus: View {
    let model: WorkspaceFilesModel
    let path: String

    var body: some View {
        switch model.transferPhase(for: path) {
        case .idle:
            EmptyView()

        case .running(let received, let total):
            VStack(alignment: .leading, spacing: DSHTheme.Spacing.hairline) {
                HStack(spacing: DSHTheme.Spacing.tight) {
                    ProgressView()
                        .controlSize(.small)
                    Text(runningText(received: received, total: total))
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelSecondary)
                        .accessibilityIdentifier("files.transfer.running")
                    Spacer(minLength: 0)
                    Button("暂停") { model.pauseDownload(path: path) }
                        .font(DSHTheme.Typography.micro)
                        .buttonStyle(.plain)
                        .foregroundStyle(DSHTheme.brand)
                        .accessibilityIdentifier("files.transfer.pause")
                }
                if let total, total > 0 {
                    ProgressView(value: Double(received), total: Double(total))
                        .tint(DSHTheme.brand)
                }
            }
            .padding(.horizontal, DSHTheme.Spacing.standard)
            .padding(.vertical, DSHTheme.Spacing.tight)

        case .paused(let bytes, let total, let reason):
            VStack(alignment: .leading, spacing: DSHTheme.Spacing.hairline) {
                HStack(alignment: .firstTextBaseline, spacing: DSHTheme.Spacing.tight) {
                    Image(systemName: "arrow.down.circle.dotted")
                        .font(.system(size: 12))
                        .foregroundStyle(DSHTheme.attention)
                    Text(pausedText(bytes: bytes, total: total, reason: reason))
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelSecondary)
                        .accessibilityIdentifier("files.transfer.paused")
                    Spacer(minLength: 0)
                    Button("继续") { Task { await model.download(path: path) } }
                        .font(DSHTheme.Typography.micro)
                        .buttonStyle(.plain)
                        .foregroundStyle(DSHTheme.brand)
                        .accessibilityIdentifier("files.transfer.resume")
                    Button("放弃") { Task { await model.discardDownload(path: path) } }
                        .font(DSHTheme.Typography.micro)
                        .buttonStyle(.plain)
                        .foregroundStyle(DSHTheme.labelTertiary)
                        .accessibilityIdentifier("files.transfer.discard")
                }
                if let total, total > 0 {
                    // The bar keeps its progress, so a resumed download visibly
                    // picks up where it stopped instead of starting over.
                    ProgressView(value: Double(bytes), total: Double(total))
                        .tint(DSHTheme.attention)
                }
            }
            .padding(.horizontal, DSHTheme.Spacing.standard)
            .padding(.vertical, DSHTheme.Spacing.tight)

        case .ready(let bytes, _):
            HStack(spacing: DSHTheme.Spacing.tight) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(DSHTheme.success)
                // `String(bytes)`: plain digits on purpose. SwiftUI would group
                // them ("3,211,264"), which reads fine but stops the number being
                // the one the host reported.
                Text("已下载 \(ByteFormat.compact(bytes))（\(String(bytes)) 字节），已可分享")
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.labelSecondary)
                    .accessibilityIdentifier("files.transfer.ready")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DSHTheme.Spacing.standard)
            .padding(.vertical, DSHTheme.Spacing.tight)

        case .failed(let message):
            HStack(alignment: .firstTextBaseline, spacing: DSHTheme.Spacing.tight) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(DSHTheme.attention)
                Text(message)
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.labelSecondary)
                    .accessibilityIdentifier("files.transfer.failed")
                Spacer(minLength: 0)
                Button("重试") { Task { await model.download(path: path) } }
                    .font(DSHTheme.Typography.micro)
                    .buttonStyle(.plain)
                    .foregroundStyle(DSHTheme.brand)
                    .accessibilityIdentifier("files.transfer.retry")
            }
            .padding(.horizontal, DSHTheme.Spacing.standard)
            .padding(.vertical, DSHTheme.Spacing.tight)
        }
    }

    private func runningText(received: Int, total: Int?) -> String {
        guard let total, total > 0 else { return "正在从电脑读取…（已读取 \(ByteFormat.compact(received))）" }
        let percent = Int((Double(received) / Double(total) * 100).rounded(.down))
        return "正在从电脑读取… \(ByteFormat.compact(received)) / \(ByteFormat.compact(total))（\(percent)%）"
    }

    private func pausedText(bytes: Int, total: Int?, reason: String?) -> String {
        let saved = "\(ByteFormat.compact(bytes))（\(String(bytes)) 字节）"
        let percent: String
        if let total, total > 0 {
            percent = "，已完成 \(Int((Double(bytes) / Double(total) * 100).rounded(.down)))%"
        } else {
            percent = ""
        }
        guard let reason, !reason.isEmpty else {
            return "下载已暂停：已保存 \(saved)\(percent)，可继续"
        }
        return "下载中断：\(reason)（已保存 \(saved)\(percent)）"
    }
}

/// A file the system preview cannot draw: everything worth knowing, and the way
/// to still get it off the computer.
struct WorkspaceFileCard: View {
    let title: String
    let url: URL
    let bytes: Int

    var body: some View {
        VStack(spacing: DSHTheme.Spacing.standard) {
            Image(systemName: "doc.fill")
                .font(.system(size: 44))
                .foregroundStyle(DSHTheme.labelTertiary)
            Text(title)
                .font(DSHTheme.Typography.body)
                .foregroundStyle(DSHTheme.labelPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .accessibilityIdentifier("files.preview.card")
            Text("\(ByteFormat.compact(bytes)) · \(url.pathExtension.uppercased().isEmpty ? "未知类型" : url.pathExtension.uppercased())")
                .font(DSHTheme.Typography.caption)
                .foregroundStyle(DSHTheme.labelSecondary)
            // The exact count, not just the rounded size: it is the one reading
            // that shows the whole file arrived, where a download that stopped
            // early is otherwise just a file that "looks about right".
            Text("已完整读取 \(String(bytes)) 字节")
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.success)
            Text("系统预览打不开这种格式。可以分享到「文件」或其他 App 再打开。")
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelTertiary)
                .multilineTextAlignment(.center)
            ShareFileButton(url: url, identifier: "files.card.share", prominent: true)
        }
        .padding(DSHTheme.Spacing.loose)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The reader sheet's branch for anything that is not text or a web page.
///
/// Opening the file *is* fetching it: the whole file comes down, then the system
/// preview draws it. Nothing here is paged, because a pdf or a deck is read as
/// one thing — which is also why the size is fetched before a single byte moves.
struct WorkspaceFilePreviewContent: View {
    let model: WorkspaceFilesModel
    let path: String
    let title: String

    var body: some View {
        content
            // Only a file nobody has started on. Without the guard this task
            // re-runs whenever the branch below changes — and a failure changes
            // it — so a download that cannot succeed retried itself every minute
            // and showed "正在读取" forever instead of the reason it failed.
            .task {
                if model.transferPhase(for: path) == .idle {
                    await model.download(path: path)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let url = model.localCopy(for: path), case .ready(let bytes, _) = model.transferPhase(for: path) {
            // Two ways to decide "the system preview has nothing for this": the
            // formats measured to draw an empty page, and anything QuickLook
            // itself declines.
            if WorkspaceFileKind.of(path: path) != .binary, QuickLookSheet.canPreview(url) {
                QuickLookSheet(url: url)
                    .ignoresSafeArea(edges: .bottom)
                    .accessibilityIdentifier("files.preview.quicklook")
            } else {
                WorkspaceFileCard(title: title, url: url, bytes: bytes)
            }
        } else if case .failed(let message) = model.transferPhase(for: path) {
            ErrorStateView(message: message) {
                Task { await model.download(path: path) }
            }
        } else {
            // The reader's own status bar is above this view and already says
            // what is happening; a second one here read as two downloads.
            VStack(spacing: DSHTheme.Spacing.standard) {
                ProgressView()
                Text("正在准备预览…")
                    .font(DSHTheme.Typography.caption)
                    .foregroundStyle(DSHTheme.labelSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A picture from the workspace, opened the way a photo opens on a phone.
///
/// Fetched whole and decoded by the app rather than handed to the web view: a
/// screenshot is something to zoom into, and the chat transcript already opens
/// its pictures this way — one gesture vocabulary for pictures, whichever side
/// of the link they came from.
struct WorkspaceImagePreviewView: View {
    let model: WorkspaceFilesModel
    let path: String
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var failure: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let image, let url = model.localCopy(for: path) {
            ImagePreview(
                image: image,
                label: title,
                shareURL: url,
                identifierPrefix: "files.preview"
            )
        } else if let failure {
            VStack(spacing: DSHTheme.Spacing.standard) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.7))
                Text(failure)
                    .font(DSHTheme.Typography.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DSHTheme.Spacing.loose)
                    .accessibilityIdentifier("files.preview.error")
                HStack(spacing: DSHTheme.Spacing.standard) {
                    Button("重试") { Task { await load() } }
                        .accessibilityIdentifier("files.preview.retry")
                    if let url = model.localCopy(for: path) {
                        ShareLink(item: url) { Text("分享") }
                            .accessibilityIdentifier("files.action.share")
                    }
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("files.preview.done")
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .frame(minHeight: 44)
            }
        } else {
            VStack(spacing: DSHTheme.Spacing.standard) {
                ProgressView()
                    .tint(.white)
                Text(loadingText)
                    .font(DSHTheme.Typography.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .accessibilityIdentifier("files.preview.loading")
                Button("取消") {
                    model.pauseDownload(path: path)
                    dismiss()
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .frame(minHeight: 44)
                .accessibilityIdentifier("files.preview.cancel")
            }
        }
    }

    private var loadingText: String {
        guard case .running(let received, let total) = model.transferPhase(for: path) else {
            return "正在从电脑读取…"
        }
        guard let total, total > 0 else { return "正在从电脑读取…（已读取 \(ByteFormat.compact(received))）" }
        return "正在从电脑读取… \(ByteFormat.compact(received)) / \(ByteFormat.compact(total))"
    }

    private func load() async {
        failure = nil
        image = nil
        guard let url = await model.download(path: path) else {
            // A cancel is not a failure: the sheet was closed on purpose.
            if case .failed(let message) = model.transferPhase(for: path) {
                failure = message
            } else {
                dismiss()
            }
            return
        }
        // Decoding a full-size photograph is not main-thread work; the wrapper
        // exists only because `UIImage` is not `Sendable`.
        let decoded = await Task.detached(priority: .userInitiated) {
            DecodedImage(image: UIImage(contentsOfFile: url.path))
        }.value
        if let decoded = decoded.image {
            image = decoded
        } else {
            failure = "这台手机解不开这个图片格式，可以分享到其他 App 打开。"
        }
    }

    private struct DecodedImage: @unchecked Sendable {
        let image: UIImage?
    }
}
