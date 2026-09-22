import Foundation

/// How this open should reconcile a locally cached transcript tail with the host.
///
/// The phone keeps the tail of every session it has seen; the host answers an
/// open with the *last N messages* of the journal (`session/follow`'s opening
/// snapshot, `paginate(events, nil, maxMessages)`). Those two only add up when
/// they overlap: if the local tail ends at seq 1000 and the host is at 1500, a
/// 60-message snapshot comes back starting at 1411, and merging it would leave
/// 1001–1410 missing from the middle of the transcript — a hole that scrolling
/// can never fill, because "load older" walks back from the *oldest* row the
/// phone has. Worse, that hole is what gets written to disk next, so the next
/// cold start shows it too.
///
/// So the window is chosen from the gap, and when the gap cannot be covered the
/// local tail is *re-based* on the snapshot instead of merged. The older history
/// is not lost — it is still on the computer, and scrolling up fetches it back
/// through the ordinary paging path, contiguously.
public struct TranscriptSyncPlan: Equatable, Sendable {

    /// Messages to ask for. Always enough to cover the gap (each message carries
    /// at least one event, so a window of N messages reaches back at least N
    /// events), but never so large that opening a session pulls half a journal.
    public let maxMessages: Int

    /// Whether the local tail must be thrown away and replaced by the snapshot.
    public let reBase: Bool

    /// The floor: opening a session the phone has never seen still wants a screenful.
    public static let minWindow = 20

    /// The ceiling: one open may cost at most this many messages. DSH's own web
    /// client uses the same number for its biggest read.
    public static let maxWindow = 200

    /// Extra messages beyond the gap, to absorb the message↔event accounting
    /// difference without another round trip.
    public static let margin = 10

    /// - Parameters:
    ///   - localThrough: the cursor the local tail was saved at (`nil` when there
    ///     is no local tail).
    ///   - hostCursor: the host's current committed cursor (`asOfSeq`).
    public static func plan(localThrough: Int?, hostCursor: Int) -> TranscriptSyncPlan {
        guard let localThrough else {
            return TranscriptSyncPlan(maxMessages: minWindow, reBase: true)
        }
        // A local tail that claims to be *ahead* of the host means the two do not
        // describe the same journal any more (the host compacted or was restored
        // from a backup). Trust the host and start over rather than showing rows
        // it no longer has.
        if localThrough > hostCursor {
            return TranscriptSyncPlan(maxMessages: minWindow, reBase: true)
        }
        let gap = hostCursor - localThrough
        let wanted = gap + margin
        if wanted > maxWindow {
            // Too far behind to bridge in one read: take the tail and re-base.
            return TranscriptSyncPlan(maxMessages: maxWindow, reBase: true)
        }
        return TranscriptSyncPlan(maxMessages: max(minWindow, wanted), reBase: false)
    }

    /// The belt-and-braces check, run once the snapshot is in hand.
    ///
    /// The window is chosen from cursors, which count events, while the snapshot
    /// counts messages: the arithmetic above should always bridge the gap, but if
    /// it did not, merging would punch a hole — so the phone asks the snapshot
    /// itself whether it reaches back far enough.
    public static func stillNeedsReBase(localLastSeq: Int?, snapshotFirstSeq: Int?) -> Bool {
        guard let localLastSeq, let snapshotFirstSeq else { return false }
        return snapshotFirstSeq > localLastSeq + 1
    }
}
