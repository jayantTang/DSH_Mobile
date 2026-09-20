import Foundation

/// When this phone last had each session open.
///
/// Lives beside `SessionAlerts` in `UserDefaults` on purpose: it is the same
/// kind of fact — local UI state about a remote session, not something the host
/// owns or needs. The host has no read/unread concept at all (`SessionSummary`
/// carries `running` and `updatedAt`, nothing about attention), so "finished
/// while you were away" can only be answered here, by comparing the session's
/// last activity with the last time this phone showed it.
///
/// Keys are session ids. Entries are capped: a phone that has opened thousands
/// of sessions should not grow a plist forever, and the oldest ids are the ones
/// whose rows will read as seen either way.
@MainActor
@Observable
final class SessionViewLog {

    /// Session id → when it was last opened, in milliseconds.
    private(set) var viewedAt: [String: Double]

    private let defaults: UserDefaults
    private static let key = "list.sessionViewedAt"
    private static let limit = 400

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.key) as? [String: Double]
        self.viewedAt = stored ?? [:]
    }

    /// When this session was last opened, or `nil` if it never was.
    func lastViewed(_ sessionId: String) -> Double? {
        viewedAt[sessionId]
    }

    /// Records that the session is on screen right now.
    ///
    /// Called when the transcript opens, not when a row scrolls past: "viewed"
    /// has to mean the user looked at it, or the marker clears itself.
    func markViewed(_ sessionId: String, at stamp: Double = Date().timeIntervalSince1970 * 1000) {
        // Monotonic per session: a clock that steps backwards must not resurrect
        // an unseen marker for something the user just read.
        if let existing = viewedAt[sessionId], existing >= stamp { return }
        viewedAt[sessionId] = stamp
        trim()
        persist()
    }

    /// Forgets sessions the list no longer shows.
    func prune(keeping ids: Set<String>) {
        let kept = viewedAt.filter { ids.contains($0.key) }
        guard kept.count != viewedAt.count else { return }
        viewedAt = kept
        persist()
    }

    private func trim() {
        guard viewedAt.count > Self.limit else { return }
        let oldest = viewedAt.sorted { $0.value < $1.value }.prefix(viewedAt.count - Self.limit)
        for (id, _) in oldest { viewedAt.removeValue(forKey: id) }
    }

    private func persist() {
        defaults.set(viewedAt, forKey: Self.key)
    }
}
