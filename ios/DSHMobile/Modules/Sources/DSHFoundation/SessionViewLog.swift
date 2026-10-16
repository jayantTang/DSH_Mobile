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
public final class SessionViewLog {

    /// Which computer these marks are about.
    ///
    /// Session ids are unique per host, not across them: two computers can both
    /// have a session `abc`, and "you already read that" must not carry over
    /// when the phone is pointed at the other one.
    private var scope: String?

    /// Session id → when it was last opened, in milliseconds.
    private(set) var viewedAt: [String: Double]

    private let defaults: UserDefaults
    private static let key = "list.sessionViewedAt"
    private static let limit = 400

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.key) as? [String: Double]
        self.viewedAt = stored ?? [:]
    }

    /// Points the log at one computer (or at nothing, when disconnected).
    public func useScope(_ scope: String?) {
        self.scope = scope
    }

    private func key(_ sessionId: String) -> String {
        scope.map { "\($0)|\(sessionId)" } ?? sessionId
    }

    /// When this session was last opened, or `nil` if it never was.
    public func lastViewed(_ sessionId: String) -> Double? {
        viewedAt[key(sessionId)]
    }

    /// Records that the session is on screen right now.
    ///
    /// Called when the transcript opens, not when a row scrolls past: "viewed"
    /// has to mean the user looked at it, or the marker clears itself.
    public func markViewed(_ sessionId: String, at stamp: Double = Date().timeIntervalSince1970 * 1000) {
        let key = key(sessionId)
        // Monotonic per session: a clock that steps backwards must not resurrect
        // an unseen marker for something the user just read.
        if let existing = viewedAt[key], existing >= stamp { return }
        viewedAt[key] = stamp
        trim()
        persist()
    }

    // MARK: - 账户级同步（032）

    /// 这个日志当前绑在哪台电脑上（拼账户状态的 key 用），没绑时为 nil。
    public var hostScope: String? { scope }

    /// 把远端读到的已读水位并进来：**逐会话取 max**。
    ///
    /// 为什么是 max 而不是"远端覆盖本地"：两台设备各读各的，谁也不能把别人读过的标记抹掉；
    /// 而一台设备时钟慢一拍时，它的旧时间戳也不该让已读回退。返回是否有变化（调用方据此决定要不要落盘/刷新）。
    @discardableResult
    public func mergeRemote(viewedAt remote: [String: Double]) -> Bool {
        var changed = false
        for (sessionId, stamp) in remote {
            let target = key(sessionId)
            if let existing = viewedAt[target], existing >= stamp { continue }
            viewedAt[target] = stamp
            changed = true
        }
        guard changed else { return false }
        trim()
        persist()
        return true
    }

    /// 上传用的快照：只含当前这台电脑的会话，键是**裸 sessionId**（去掉 scope 前缀）。
    public func accountSnapshot() -> [String: Double] {
        guard let scope else { return [:] }
        let prefix = "\(scope)|"
        return viewedAt.reduce(into: [:]) { result, pair in
            guard pair.key.hasPrefix(prefix) else { return }
            result[String(pair.key.dropFirst(prefix.count))] = pair.value
        }
    }

    /// Forgets sessions the list no longer shows.
    public func prune(keeping ids: Set<String>) {
        let wanted = Set(ids.map(key))
        let kept = viewedAt.filter { wanted.contains($0.key) }
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
