import SwiftUI
import UIKit

/// One transcript message opened for reading on its own.
///
/// Why a separate page instead of long-press selection inside the transcript:
/// the transcript is a `List`, whose cells take the long press before the text
/// ever sees it — selection declared on the rows is selection the user cannot
/// reach. Rather than trade away the container that fixed the blank-screen
/// failures, the message opens here, where the text is the only thing on
/// screen and a text view owns every gesture.
struct MessageSelection: Identifiable {
    /// The transcript row this came from, so the sheet is keyed by identity.
    let id: String
    let title: String
    /// The message as plain text: no markdown decoration, nothing re-flowed.
    let text: String
    /// Tool output and code are read as they were written, so they keep the
    /// monospaced face.
    let isMonospaced: Bool
}

struct MessageTextSheet: View {
    let message: MessageSelection

    @Environment(\.dismiss) private var dismiss
    /// 文本自己的高度：短消息让页面贴住文字，长消息才铺满并滚动。
    ///
    /// 这不是审美问题：一页只有一行字的界面里，如果文本框铺满整屏，手指按在
    /// "中间"就落在文字下面的空白上，长按既选不中、也弹不出菜单。
    @State private var fittedHeight: CGFloat = 0

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                SelectableMessageText(
                    text: message.text,
                    isMonospaced: message.isMonospaced,
                    fittedHeight: $fittedHeight
                )
                .frame(height: min(max(fittedHeight, 1), proxy.size.height))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .background(DSHTheme.background)
            .navigationTitle(message.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

/// A message rendered as selectable text, with one behaviour iOS does not have.
///
/// Long-pressing a token — a build stamp, a path, a session id, `key=value` —
/// selects that whole token instead of the word iOS would guess at. The guess is
/// wrong exactly where copying matters most: `20260922.0` comes back as
/// `20260922`, and an id with dashes comes back in pieces a person then has to
/// drag handles to fix. The rule is deliberately narrow (see `TokenRule`), and
/// when it does not apply the system's own selection stands.
private struct SelectableMessageText: UIViewRepresentable {
    let text: String
    let isMonospaced: Bool
    @Binding var fittedHeight: CGFloat

    func makeUIView(context: Context) -> UITextView {
        let view = FittingTextView()
        context.coordinator.onFittedHeight = { height in
            guard abs(height - fittedHeight) > 0.5 else { return }
            fittedHeight = height
        }
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 32, right: 12)
        view.adjustsFontForContentSizeCategory = true
        view.delegate = context.coordinator
        view.accessibilityIdentifier = "messageText.body"

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.selectTokenUnderFinger(_:))
        )
        longPress.minimumPressDuration = 0.35
        // Our recogniser runs alongside the text view's own selection gesture:
        // it does not replace it, it only re-points the selection at the token.
        longPress.delegate = context.coordinator
        view.addGestureRecognizer(longPress)

        context.coordinator.render(text: text, isMonospaced: isMonospaced, in: view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.render(text: text, isMonospaced: isMonospaced, in: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// 一条消息的文本视图：把自己"刚好装下文字"的高度报给 SwiftUI。
    ///
    /// `UITextView` 没有内在高度，铺满容器时短消息的可见文字只占顶部一条；把实测
    /// 高度交回上层，页面才会贴着文字——手指按在中间也就按在字上（见 `MessageTextSheet`
    /// 里那段关于长按落点的注释）。
    final class FittingTextView: UITextView {
        var onFittedHeight: ((CGFloat) -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.width > 0 else { return }
            let fitted = sizeThatFits(
                CGSize(width: bounds.width, height: .greatestFiniteMagnitude)
            ).height
            onFittedHeight?(fitted)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        private var rendered: String?
        private var renderedMonospaced: Bool?
        /// 手指下那个 token 的选区；长按期间系统的选词会被它按回去。
        private var pendingTokenRange: NSRange?
        var onFittedHeight: ((CGFloat) -> Void)?

        /// Sets the text once per content change.
        ///
        /// Reassigning `attributedText` on every SwiftUI update would drop the
        /// selection the user is in the middle of making — the view updates on
        /// every transcript event, so "only when the content differs" is the
        /// difference between a usable selection and one that vanishes.
        func render(text: String, isMonospaced: Bool, in view: UITextView) {
            guard rendered != text || renderedMonospaced != isMonospaced else { return }
            rendered = text
            renderedMonospaced = isMonospaced

            let style = NSMutableParagraphStyle()
            style.lineSpacing = 2
            let font = isMonospaced
                ? UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                : UIFont.preferredFont(forTextStyle: .body)
            view.attributedText = NSAttributedString(
                string: text,
                attributes: [
                    .font: font,
                    .foregroundColor: UIColor(DSHTheme.labelPrimary),
                    .paragraphStyle: style,
                ]
            )
        }

        // MARK: - Token selection

        @objc func selectTokenUnderFinger(_ gesture: UILongPressGestureRecognizer) {
            guard let view = gesture.view as? UITextView else { return }
            switch gesture.state {
            case .began:
                guard let range = TokenRule.tokenRange(at: gesture.location(in: view), in: view) else { return }
                // Recorded, not just applied: the text view's own long-press
                // recogniser resolves *its* selection a moment later and would
                // overwrite ours (`uitest-scratch` instead of the whole
                // `/tmp/dsh-uitest-scratch`). While this is set, every selection
                // change is pushed back onto the token.
                pendingTokenRange = range
                view.selectedRange = range
                view.becomeFirstResponder()
            default:
                // The finger is up (or the press was cancelled): from here on the
                // user owns the selection, handles and all.
                pendingTokenRange = nil
            }
        }

        /// Puts the selection back on the token while our long press is live.
        ///
        /// The system's selection lands after ours — that is simply the order the
        /// two recognisers settle in — so reacting to its change is the only
        /// reliable place to correct it, rather than racing it with a delay.
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard let range = pendingTokenRange, textView.selectedRange != range else { return }
            textView.selectedRange = range
        }

        /// Lets our recogniser coexist with the text view's built-in gestures.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }

        // MARK: - Menu

        /// Adds "copy the whole message" to the selection menu.
        ///
        /// The system menu can only copy what is selected; the thing a person
        /// often wants after long-pressing a long answer is all of it, without
        /// dragging two handles to the ends first.
        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            let whole = UIAction(title: "拷贝整条消息") { [weak self] _ in
                guard let self, let text = rendered else { return }
                UIPasteboard.general.string = text
            }
            whole.accessibilityLabel = "拷贝整条消息"
            return UIMenu(children: suggestedActions + [whole])
        }
    }
}

/// Which run of characters counts as one copyable token.
///
/// The set is ASCII alphanumerics plus the punctuation that appears *inside*
/// the things people copy off a transcript — `.` in `20260922.0`, `-` in a
/// session id, `/` and `~` in a path, `=` and `:` in `key=value` and a URL.
/// Chinese is left to the system: its word segmentation is better than a
/// character-class rule, and widening this set to CJK would select whole
/// sentences.
enum TokenRule {
    /// Worked in UTF-16 units on purpose: that is the unit `NSRange` and the
    /// text view's own offsets speak in, so a Chinese paragraph or an emoji
    /// earlier in the message cannot shift the selection off by one.
    static func isTokenUnit(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        // . _ - / @ : ~ + =
        case 0x2E, 0x5F, 0x2D, 0x2F, 0x40, 0x3A, 0x7E, 0x2B, 0x3D: return true
        default: return false
        }
    }

    /// Punctuation that only reads as part of a token when something is on both
    /// sides of it: a sentence-ending `.` or a trailing `=` must not be dragged
    /// into the selection.
    private static let trimmable: Set<UInt16> = [
        0x2E, 0x2C, 0x3A, 0x3B, 0x3D, 0x2B, 0x2D, 0x5F,
    ]

    static func isAlphanumeric(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        default: return false
        }
    }

    /// The token range under one point, or nil when there is nothing to widen.
    static func tokenRange(at point: CGPoint, in textView: UITextView) -> NSRange? {
        let text = textView.attributedText?.string ?? ""
        guard !text.isEmpty else { return nil }
        let units = Array(text.utf16)

        guard let position = textView.closestPosition(to: point) else { return nil }
        let offset = textView.offset(from: textView.beginningOfDocument, to: position)
        guard offset >= 0, offset <= units.count else { return nil }

        // The touch lands *between* characters; either neighbour may be the one
        // the finger meant, so a non-token hit is looked at from both sides.
        var start: Int?
        var end: Int?
        for candidate in [offset, offset - 1] where candidate >= 0 && candidate < units.count {
            guard isTokenUnit(units[candidate]) else { continue }
            var low = candidate
            var high = candidate + 1
            while low > 0, isTokenUnit(units[low - 1]) { low -= 1 }
            while high < units.count, isTokenUnit(units[high]) { high += 1 }
            start = low
            end = high
            break
        }
        guard var low = start, var high = end else { return nil }

        while low < high, trimmable.contains(units[low]) { low += 1 }
        while high > low, trimmable.contains(units[high - 1]) { high -= 1 }
        // A run with no letter or digit in it ("--", "…") is not a token worth
        // selecting: leave the system's own selection alone.
        guard (low..<high).contains(where: { isAlphanumeric(units[$0]) }) else { return nil }

        return NSRange(location: low, length: high - low)
    }
}
