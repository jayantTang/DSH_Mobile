#if os(iOS)
import DSHKit
import SwiftUI
import UIKit
import DSHChatDomain

/// 转写行的长按入口。
///
/// 两条宿主分工不同（2026-10-12，spec 013）：
///
/// - **UIKit 宿主（默认）**：长按由宿主自己的 `UILongPressGestureRecognizer` 认（见
///   `TranscriptListHost`），行这里**不挂** `contextMenu`。理由是两条实测：这个宿主里
///   `UIHostingConfiguration` 的 SwiftUI `onLongPressGesture` 收不到长按；系统 `contextMenu`
///   的预览/背板几何是错的——被长按的一行常常比屏幕还高，抬起来压住导航栏、遮罩只盖一部分。
///   动作单改由 `ChatView` 自己画（见 `MessageActionSheet`）。
/// - **SwiftUI `List` 分支**（`-DSHProbeVariants` 才会走到）：宿主那一层没有手势，所以还是
///   挂 `contextMenu`，否则这条分支上的长按入口就没了。
struct MessageActions: ViewModifier {
    let item: TimelineItem
    /// 这一条宿主是不是"手势归宿主管"。true 时这里什么都不挂。
    let hostOwnsLongPress: Bool
    /// Opens the message on its own page, where its text can be selected.
    let onOpen: (MessageSelection) -> Void

    func body(content: Content) -> some View {
        if let payload = item.selectableMessage, !hostOwnsLongPress {
            content.contextMenu {
                Button {
                    onOpen(
                        MessageSelection(
                            id: item.id,
                            title: payload.title,
                            text: payload.text,
                            isMonospaced: payload.isMonospaced
                        )
                    )
                } label: {
                    Label("选择文本", systemImage: "text.cursor")
                }

                Button {
                    UIPasteboard.general.string = payload.text
                } label: {
                    Label("拷贝整条消息", systemImage: "doc.on.doc")
                }
            }
        } else {
            content
        }
    }
}

extension TimelineItem {
    /// 动作单里「选择文本」要的那一份载荷（全文页用）。
    var messageSelection: MessageSelection? {
        guard let payload = selectableMessage else { return nil }
        return MessageSelection(
            id: id,
            title: payload.title,
            text: payload.text,
            isMonospaced: payload.isMonospaced
        )
    }

    /// 动作单里「拷贝整条消息」：正文进剪贴板。
    ///
    /// 放在这里而不是 `ChatView`，是为了不让 UIKit 的 `UIPasteboard` 渗进视图层
    /// （`ChatView` 只 `import SwiftUI`）。
    func copyTextToPasteboard() {
        guard let payload = selectableMessage else { return }
        UIPasteboard.general.string = payload.text
    }
}
#endif
