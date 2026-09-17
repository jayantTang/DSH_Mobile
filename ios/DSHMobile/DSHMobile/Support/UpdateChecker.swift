import Foundation
import Observation

/// Tells the user when a newer build has been published.
///
/// Without this the only way to answer "is my app current?" is to open the
/// install page on the phone and compare numbers by eye — and an install that
/// silently did nothing looks exactly like one that was never needed. That is
/// not hypothetical: every build used to carry the same version, so iOS treated
/// each update as "already installed" and skipped it, and there was no way to
/// notice from the phone.
@MainActor
@Observable
final class UpdateChecker {

    /// What the install page advertises.
    struct Published: Sendable, Decodable {
        let shortVersion: String
        let build: String
        let installPage: String
    }

    /// Set when the published build is newer than the one running.
    private(set) var available: Published?

    private let feed: URL
    /// Guards against overlapping fetches, not against checking again: the
    /// check has to repeat, because a user who updated while the app was in the
    /// background would otherwise keep seeing "update available" for a build
    /// they already installed.
    private var isChecking = false

    /// 地址来自构建配置（Config.xcconfig / 本机 Config.local.xcconfig），见 AppConfig。
    init(feed: URL = URL(string: AppConfig.updateFeed)!) {
        self.feed = feed
    }

    /// The build this process was launched from.
    static var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    /// Fetches the published stamp and updates what the banner should say.
    func refresh() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        var request = URLRequest(url: feed)
        // The stamp is tiny, but it must never be served from a cache: a stale
        // answer here is the whole failure mode this exists to prevent.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let published = try? JSONDecoder().decode(Published.self, from: data)
        else { return }

        // Assigned either way: once the installed build catches up the banner
        // must come down, which it could never do while this only ever set.
        if Self.isNewer(published.build, than: Self.currentBuild) {
            available = published
        } else {
            available = nil
        }
    }

    /// Build numbers are `yyyyMMdd.HHmm` stamps; older builds were a single
    /// 12-digit stamp. Both order by comparing their numeric parts one by one,
    /// which is how iOS itself reads a `CFBundleVersion`.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard !candidate.isEmpty, !current.isEmpty else { return false }
        let lhs = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = current.split(separator: ".").map { Int($0) ?? 0 }
        guard !lhs.isEmpty, !rhs.isEmpty else { return candidate != current }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}
