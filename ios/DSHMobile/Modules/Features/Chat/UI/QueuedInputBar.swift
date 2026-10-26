#if os(iOS)
import DSHChatDomain
import DSHDesign
import DSHKit
import SwiftUI

/// 输入区上方的排队条（设计 `20261026-排队输入-设计.md` §2）。
///
/// 宿主排队的消息**不进转写**：这里逐行显示，44pt 一行，无标题行、无汇总行、
/// 无「全部插入」。每行独立插入（steer）与删除（remove）；点正文 = 撤回并放回
/// 输入框编辑。图片给 30pt 缩略图，纯图片写「N 张图片」。
struct QueuedInputBar: View {
    let model: ChatModel

    private static let rowHeight: CGFloat = 44
    private static let thumbnail: CGFloat = 30

    private var items: [QueuedInput] { model.queuedInputs }

    var body: some View {
        if !items.isEmpty {
            VStack(spacing: 0) {
                ForEach(items) { item in
                    row(item)
                }
            }
            .padding(.horizontal, DSHTheme.Spacing.standard)
            .padding(.bottom, DSHTheme.Spacing.tight)
            .background(DSHTheme.background)
            .accessibilityIdentifier("chat.queue")
        }
    }

    // MARK: - 行

    private func row(_ item: QueuedInput) -> some View {
        HStack(spacing: DSHTheme.Spacing.tight) {
            Image(systemName: "clock")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(DSHTheme.processLabel)
                .accessibilityHidden(true)

            if model.queueControlAvailable {
                // 点正文 = 撤回并把内容放回输入框（桌面铅笔同义）。
                Button {
                    withdraw(item, restoreText: true)
                } label: {
                    rowLabel(item)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.queue.row")
                .accessibilityLabel(Text(String(localized: "排队中的消息：\(previewText(item))")))
            } else {
                // 旧连接器没有 `session/control`：只显示本地乐观队列，不给动作
                //（插入/删除要宿主 id 才生效，见设计 §3）。
                rowLabel(item)
                    .accessibilityIdentifier("chat.queue.row")
                    .accessibilityLabel(Text(String(localized: "排队中的消息：\(previewText(item))")))
            }

            if model.queueControlAvailable {
                steerButton(item)
                removeButton(item)
            }
        }
        .padding(.horizontal, DSHTheme.Spacing.standard)
        .frame(minHeight: Self.rowHeight)
        .background(DSHTheme.layer2)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(DSHTheme.border1, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func rowLabel(_ item: QueuedInput) -> some View {
        HStack(spacing: DSHTheme.Spacing.tight) {
            if !item.draftImages.isEmpty || !item.images.isEmpty {
                thumbnails(item)
            }
            Text(previewText(item))
                .font(DSHTheme.Typography.processLabel)
                .foregroundStyle(DSHTheme.labelPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
    }

    private func previewText(_ item: QueuedInput) -> String {
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        let count = item.images.count + item.draftImages.count
        return String(format: String(localized: "%lld 张图片"), count)
    }

    @ViewBuilder
    private func thumbnails(_ item: QueuedInput) -> some View {
        HStack(spacing: DSHTheme.Spacing.hairline) {
            ForEach(Array(item.draftImages.prefix(2))) { image in
                localThumbnail(image)
            }
            ForEach(Array(item.images.prefix(2).enumerated()), id: \.offset) { _, attachment in
                AttachmentThumbnail(attachment: attachment, maxHeight: Self.thumbnail)
            }
        }
    }

    @ViewBuilder
    private func localThumbnail(_ image: ComposerDraftImage) -> some View {
        if let uiImage = image.preview as? UIImage {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: Self.thumbnail, height: Self.thumbnail)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func steerButton(_ item: QueuedInput) -> some View {
        Button {
            Task { @MainActor in await model.steerQueuedInput(item) }
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DSHTheme.brand)
                .frame(width: Self.rowHeight, height: Self.rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.queue.steer")
        .accessibilityLabel(Text("插入当前轮次"))
    }

    private func removeButton(_ item: QueuedInput) -> some View {
        Button {
            withdraw(item, restoreText: false)
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(DSHTheme.processLabel)
                .frame(width: Self.rowHeight, height: Self.rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.queue.remove")
        .accessibilityLabel(Text("删除排队消息"))
    }

    private func withdraw(_ item: QueuedInput, restoreText: Bool) {
        Task { @MainActor in
            let removed = await model.removeQueuedInput(item)
            if restoreText, removed { model.restoreQueuedText(item.text) }
        }
    }
}
#endif
