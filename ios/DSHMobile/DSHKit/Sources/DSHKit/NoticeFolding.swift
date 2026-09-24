import Foundation

/// How much of a notice is shown before the reader asks for more.
///
/// Notices are the transcript's catch-all for host prose: compaction summaries,
/// error text, and — until 2026-09-24 — whole tool results whose call was not
/// loaded. An uncapped one is a wall the reader cannot fold: a 703-line file
/// dump filled the whole phone screen with no way back. The rule lives here, in
/// the protocol package, so it can be tested without a simulator; the view only
/// draws what this decides.
public enum NoticeFolding {

    /// Lines shown while folded. Twelve is roughly half a phone screen: enough
    /// to recognise the message, short enough to scroll past.
    public static let lineLimit = 12

    /// Characters shown while folded, for a notice that is one enormous line —
    /// a JSON blob or a minified file — where counting lines shortens nothing.
    public static let characterLimit = 1200

    public struct Result: Equatable, Sendable {
        /// What to render while folded.
        public let text: String
        /// Lines hidden behind the disclosure; `0` when nothing is hidden by
        /// line count (the text may still be clipped by characters).
        public let hiddenLines: Int
        /// True when the folded form shows less than the whole notice.
        public let isTruncated: Bool
    }

    /// Folds `text` for display. The full text is never lost — the caller keeps
    /// it and shows it when the reader expands the row.
    public static func fold(_ text: String) -> Result {
        let lines = text.components(separatedBy: .newlines)
        let hiddenLines = max(0, lines.count - lineLimit)
        var head = lines.prefix(lineLimit).joined(separator: "\n")
        if head.count > characterLimit {
            head = String(head.prefix(characterLimit)) + "…"
        }
        return Result(
            text: head,
            hiddenLines: hiddenLines,
            isTruncated: hiddenLines > 0 || head.count < text.count
        )
    }
}
