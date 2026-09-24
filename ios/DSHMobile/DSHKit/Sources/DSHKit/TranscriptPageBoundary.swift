import Foundation

/// Working around a host-side mismatch in `session/page`: the client asks for a
/// window *ending before seq N*, but the host applies that number in **log-offset
/// space** (`dsh-session`'s `SessionLogOffset`), and a session's offsets are not
/// always equal to its seqs — `agent/inbox/spliced` and friends advance the log
/// without advancing the seq.
///
/// Measured 2026-09-24 on two real sessions:
///
/// | session | request → returned | pages |
/// |---|---|---|
/// | `session-5f074487…` (dense log) | `12968 → 12676..12967`, `12676 → 12381..12675` | abut (bias 1) |
/// | `session-5eed8e99…` (21_X) | `12616 → 12087..12380` | **235 seqs skipped** |
///
/// The second case is what a reader sees as "history jumped a paragraph". The
/// phone cannot fix the host, but it can notice the shortfall and ask again with
/// a corrected boundary: the difference between what was requested and what came
/// back *is* the local offset↔seq divergence, so adding it lands the next page
/// exactly on the seq the reader was waiting for.
public enum TranscriptPageBoundary {

    /// How many corrected retries a single page is allowed before the phone
    /// gives up and stops offering older history. Two is plenty: the first
    /// correction is the divergence itself, the second absorbs rounding in a
    /// log where several offset-only entries sit next to each other.
    public static let maxAttempts = 3

    /// The next request boundary, or `nil` when the page arrived contiguous.
    ///
    /// - Parameters:
    ///   - requested: the number that was sent as `beforeSeq`.
    ///   - returnedLast: the newest seq the host actually returned.
    ///   - wanted: the seq the phone needs the page to end *before* (its oldest
    ///     row), i.e. a contiguous page ends at `wanted - 1`.
    /// - Returns: the corrected `beforeSeq` to retry with, or `nil` if the page
    ///   already reaches `wanted - 1` (or overshoots it, which is harmless).
    public static func corrected(
        requested: Int,
        returnedLast: Int,
        wanted: Int
    ) -> Int? {
        let target = wanted - 1
        guard returnedLast < target else { return nil }
        let shortfall = target - returnedLast
        let next = requested + shortfall
        // 校正后若没有前进就放弃：说明 host 的边界已经"顶住"了，再问也是同一页。
        return next > requested ? next : nil
    }

    /// Whether a hole is left between `newest` (what we just loaded) and `oldest`
    /// (what we already had): `true` means the reader would see a jump.
    public static func hasHole(newest: Int, oldest: Int) -> Bool {
        newest < oldest - 1
    }
}
