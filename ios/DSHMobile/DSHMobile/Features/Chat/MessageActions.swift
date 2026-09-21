import DSHKit
import SwiftUI
import UIKit

/// The long-press menu a transcript row gets when it holds copyable text.
///
/// Rows without text (dividers, notices, events this build does not render)
/// deliberately answer with no menu at all: a menu that opens onto nothing is a
/// worse answer than no menu.
struct MessageActions: ViewModifier {
    let item: TimelineItem
    /// Opens the message on its own page, where its text can be selected.
    let onOpen: (MessageSelection) -> Void

    func body(content: Content) -> some View {
        if let payload = item.selectableMessage {
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
