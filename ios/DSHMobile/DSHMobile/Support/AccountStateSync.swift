import DSHConnectionAPI
import DSHFoundation
import DSHKit
import Foundation

/// 账户级状态的 App 侧协调器（032）。
///
/// 它管的是"一台设备改了、同账户其他设备要跟着变"的那几项里**第一项**：会话已读水位。
/// 规则很窄，但要说清楚：
///
/// * **写**：用户打开某个会话 → 本地先记（`SessionViewLog`，界面立刻不闪）→ 400ms 后
///   把整份水位 PUT 上去。用"整份快照"而不是"单个会话增量"，是因为合并规则是**取 max**，
///   整份快照天然幂等：晚到的旧快照不会把别人的已读抹掉（中转那一层还挡一次倒退）。
/// * **读**：中转推来 `accountState{keys:[sessionRead.…]}` → 拉一次 → 按 max 并进本地。
///   值不在推送里（中转只推 key），所以收到通知要自己去拉。
/// * **兜底**：回前台再拉一次。推送是尽力而为的（丢了不重试），最终一致靠这一下。
///
/// 为什么住在 App 层：它要同时碰协议客户端（DSHKit）、会话状态（DSHFoundation）与连接门面
/// （DSHConnectionAPI）；这三样同时可见的位置只有装配层。Domain 层不该认识 HTTP。
@MainActor
final class AccountStateSync {

    static let shared = AccountStateSync()

    /// 会话已读在账户状态里的 key 前缀；`sessionRead.<hostScope>`。
    static let sessionReadPrefix = "sessionRead."

    private var viewLog: SessionViewLog?
    private var linkProvider: (@MainActor () -> (any LinkService)?)?
    private var subscription: Task<Void, Never>?
    private var pushTask: Task<Void, Never>?

    private init() {}

    /// 装配：链路可用时把订阅接上。重复调用只保留最后一次（RootView 的前后台钩子会调多次）。
    func attach(viewLog: SessionViewLog, link: @escaping @MainActor () -> (any LinkService)?) {
        self.viewLog = viewLog
        self.linkProvider = link
        startSubscription()
    }

    /// 订阅 `accountState` 帧。断线时流会结束，这里隔一会儿再订阅一次——不是重试风暴：
    /// 每次重订阅都由"流结束"驱动，且固定 3 秒一次，与连接自身的重连无关。
    private func startSubscription() {
        subscription?.cancel()
        subscription = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let link = self.linkProvider?() else {
                    try? await Task.sleep(for: .seconds(3))
                    continue
                }
                let stream = await link.accountStateStream()
                for await keys in stream {
                    guard !Task.isCancelled else { return }
                    if keys.contains(where: { $0.hasPrefix(Self.sessionReadPrefix) }) {
                        await self.pullSessionRead()
                    }
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// 用户打开了一个会话（在 `SessionViewLog.markViewed` 之后调）。
    func sessionViewed() {
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            // 400ms 去抖：连着点几个会话只发一次，且不挡界面。
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.pushSessionRead()
        }
    }

    /// 回前台/刚连上时拉一次，兜住丢掉的推送。
    func refresh() async {
        await pullSessionRead()
    }

    // MARK: - 收发

    private func pullSessionRead() async {
        guard let client = Self.activeRelayClient(),
              let log = viewLog,
              let scope = log.hostScope
        else { return }
        let key = Self.sessionReadPrefix + scope
        guard let entries = try? await client.fetch(keys: [key]),
              let entry = entries[key],
              case .object(let map) = entry.value
        else { return }
        let watermarks = map.compactMapValues { $0.doubleValue }
        // `mergeRemote` 内部取 max 并落盘；界面观察 `SessionViewLog`，所以这里不用再通知谁。
        log.mergeRemote(viewedAt: watermarks)
    }

    private func pushSessionRead() async {
        guard let client = Self.activeRelayClient(),
              let log = viewLog,
              let scope = log.hostScope
        else { return }
        let snapshot = log.accountSnapshot()
        guard !snapshot.isEmpty else { return }
        let value = JSONValue.object(snapshot.mapValues { JSONValue.double($0) })
        let entry = AccountStateClient.Entry(
            key: Self.sessionReadPrefix + scope,
            value: value,
            updatedAt: Int(Date().timeIntervalSince1970 * 1000)
        )
        _ = try? await client.put([entry])
    }

    /// 当前配对的中转凭据（与 `FeedbackCenter` 取法一致：最近连过的那个档案）。
    ///
    /// 拿不到（没配对、钥匙串里没有令牌）就返回 nil——账户级同步是**增强**，
    /// 没有它，本地已读照旧工作。
    static func activeRelayClient() -> AccountStateClient? {
        guard let credential = activeRelayCredential() else { return nil }
        return AccountStateClient(relayURL: credential.url, deviceToken: credential.token)
    }

    static func activeRelayCredential() -> (url: URL, token: String)? {
        let candidates: [(URL, String, ConnectionProfile)] = ConnectionProfile.persistedProfiles()
            .compactMap { profile -> (URL, String, ConnectionProfile)? in
                guard case .relay(let relayURL, _) = profile.transport,
                      let secret = Keychain.get(profile.secretAccount),
                      !secret.isEmpty
                else { return nil }
                return (relayURL, secret, profile)
            }
        let newest = candidates.sorted {
            ($0.2.lastConnectedAt ?? .distantPast) > ($1.2.lastConnectedAt ?? .distantPast)
        }.first
        return newest.map { (url: $0.0, token: $0.1) }
    }

    /// 测试与退出用：停掉订阅与待发的推送。
    func stop() {
        subscription?.cancel()
        pushTask?.cancel()
        subscription = nil
        pushTask = nil
    }
}
