import DSHKit
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
///
/// 只对 **OTA 装法**成立：这个 feed 描述的是 OTA 包，横幅也指回 OTA 安装页。
/// TestFlight / App Store 装的包是苹果分发签名，装不上 OTA 包，点了横幅只会被要求先删
/// 掉 App（2026-10-11 的 TestFlight 反馈），所以那些装法连查都不查（见 `InstallChannel`）。
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
    /// 这份安装是靠哪条路来的；不是 OTA 就不查也不提示（见类型注释）。
    private let channel: InstallChannel
    /// Guards against overlapping fetches, not against checking again: the
    /// check has to repeat, because a user who updated while the app was in the
    /// background would otherwise keep seeing "update available" for a build
    /// they already installed.
    private var isChecking = false

    /// 地址来自构建配置（Config.xcconfig / 本机 Config.local.xcconfig），见 AppConfig。
    init(feed: URL = URL(string: AppConfig.updateFeed)!, channel: InstallChannel = .current) {
        self.feed = feed
        self.channel = channel
    }

    /// The build this process was launched from.
    static var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    /// Fetches the published stamp and updates what the banner should say.
    func refresh() async {
        // 先看装法再看别的：TestFlight / App Store 装法下这份 feed 无论说什么都不该
        // 变成一条提示，连请求也不发。
        guard channel.acceptsInAppUpdate else {
            available = nil
            return
        }
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
        if BuildStamp.isNewer(published.build, than: Self.currentBuild) {
            available = published
        } else {
            available = nil
        }
    }

    // 构建号比较已收进 DSHKit 的 `BuildStamp`（同一类判断只留一份）：见 BuildStamp.swift 的头注。
}
