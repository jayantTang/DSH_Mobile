import Foundation

/// Keeps the list host's single displacement anchor alive across a display
/// projection change.
///
/// When a turn folds, the row the reader was looking at can disappear from the
/// visible list. Re-measuring with a missing anchor silently applies a zero
/// correction and the viewport drifts. This resolver maps the old row to the
/// process node that now stands for it (or to the nearest surviving row).
public enum TranscriptAnchorResolver {

    /// Resolve the row the host should measure after a projection change.
    ///
    /// - Parameters:
    ///   - anchorID: The row the host measured before the change.
    ///   - anchorSeq: That row's journal sequence, when it had one.
    ///   - rows: The new visible rows.
    /// - Returns: An id present in `rows`, or nil only when `rows` is empty.
    public static func resolve(anchorID: String?, anchorSeq: Int?,
                               in rows: [TimelineItem]) -> String? {
        if let anchorID, rows.contains(where: { $0.id == anchorID }) {
            return anchorID
        }
        if let anchorSeq {
            // A process node covers a contiguous seq range. It is the exact
            // replacement for any member that just became hidden.
            if let covering = rows.first(where: { item in
                guard case .processHeader(let header) = item.kind else { return false }
                return anchorSeq >= header.startSeq && anchorSeq <= header.endSeq
            }) {
                return covering.id
            }
            // No node covers it (for example a gap row was replaced): the
            // nearest row at or after the old sequence is the visual successor.
            if let next = rows.first(where: { $0.seq >= anchorSeq }) {
                return next.id
            }
            if let previous = rows.last(where: { $0.seq < anchorSeq }) {
                return previous.id
            }
        }
        return rows.first?.id
    }

    /// The sequence number of a row, if it is a data row. Gap rows carry the
    /// sequence they cover; the host still uses it for ordering.
    public static func seq(of item: TimelineItem) -> Int { item.seq }
}
