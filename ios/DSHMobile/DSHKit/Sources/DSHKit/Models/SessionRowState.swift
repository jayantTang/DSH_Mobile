import Foundation

/// What a session-list row is telling the user at a glance.
///
/// Three states the list cares about, plus the empty session that is none of
/// them:
///
/// - `running` — the host says a turn is in flight.
/// - `finishedUnseen` — it ran and finished *since this phone last had it open*.
/// - `finishedSeen` — everything else, including a session that has not changed
///   since it was first listed.
/// - `blank` — never ran a turn; "unseen" would be meaningless for it.
///
/// The rule lives here rather than in the view because it is the part worth
/// testing: the difference between "finished" and "finished while you were
/// looking away" is one comparison, and getting it backwards would mark the
/// whole list as unread or nothing at all.
public enum SessionRowState: String, Sendable, Hashable, CaseIterable {
    case running
    case finishedUnseen
    case finishedSeen
    case blank

    /// Order the list puts states in, most urgent first.
    ///
    /// A blank session sorts last on purpose: it is something the user just
    /// created and is about to open, not something that finished without them.
    public var rank: Int {
        switch self {
        case .running: return 0
        case .finishedUnseen: return 1
        case .finishedSeen: return 2
        case .blank: return 3
        }
    }

    /// - Parameters:
    ///   - running: the host's own flag for this session.
    ///   - blank: no turn has ever run here.
    ///   - updatedAt: the session's last activity, in milliseconds.
    ///   - lastViewedAt: when this phone last opened it, in milliseconds, or
    ///     `nil` when it has never been opened. `nil` counts as *seen*: a
    ///     session that was already finished the first time the list was ever
    ///     read is not something the user is behind on — and treating it as
    ///     unseen would light up the entire list the moment a phone pairs.
    public static func of(
        running: Bool,
        blank: Bool,
        updatedAt: Double,
        lastViewedAt: Double?
    ) -> SessionRowState {
        if running { return .running }
        if blank { return .blank }
        guard let lastViewedAt else { return .finishedSeen }
        return updatedAt > lastViewedAt ? .finishedUnseen : .finishedSeen
    }
}
