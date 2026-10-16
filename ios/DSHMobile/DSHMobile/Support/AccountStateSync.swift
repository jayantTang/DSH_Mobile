import DSHConnectionAPI
import DSHCore
import DSHFeedbackDomain
import DSHFoundation
import DSHKit
import Foundation

/// 账户级状态的 App 侧协调器（032）。
///
/// 它管"一台设备改了、同账户其他设备要跟着变"的那几项，现在有两项：**会话已读水位**
/// 与**信件（邮件）状态**。规则很窄，但要说清楚：
///
/// * **写**：用户打开某个会话 → 本地先记（`SessionViewLog`，界面立刻不闪）→ 400ms 后
///   把整份水位 PUT 上去。用"整份快照"而不是"单个会话增量"，是因为合并规则是**取 max**，
///   整份快照天然幂等：晚到的旧快照不会把别人的已读抹掉（中转那一层还挡一次倒退）。
/// * **读**：中转推来 `accountState{keys:[sessionRead.…]}` → 拉一次 → 按 max 并进本地。
///   值不在推送里（中转只推 key），所以收到通知要自己去拉。
/// * **兜底**：回前台再拉一次。推送是尽力而为的（丢了不重试），最终一致靠这一下。
///
/// 信件那一项形状相同、但方向相反：中转推来 `accountState{keys:["feedback"]}` 时，本机的
/// 信件未读角标要**去 mail 服务拉一次**（`FeedbackCenter.refreshInbox(force:)`）。
/// 这条帧是 mail 服务在"新信落库"与"标记已读"之后借中转的在线连接扇过来的（032 FR-009）；
/// 在此之前 App 只在回前台/打开记录页时拉，所以角标总是慢一拍。
///
/// 为什么住在 App 层：它要同时碰协议客户端（DSHKit）、会话状态（DSHFoundation）与连接门面
/// （DSHConnectionAPI）；这三样同时可见的位置只有装配层。Domain 层不该认识 HTTP。
@MainActor
final class AccountStateSync {

    static let shared = AccountStateSync()

    /// 会话已读在账户状态里的 key 前缀；`sessionRead.<hostScope>`。
    static let sessionReadPrefix = "sessionRead."

    /// 信件状态的 key（mail 服务发出来的那个）；`feedback` 以及将来的 `feedback.<kind>`。
    static let feedbackKey = "feedback"

    /// 这一批 key 里有没有信件状态。抽成静态函数是为了能在宿主单测里单独验，不必起整条链路。
    static func mentionsFeedback(_ keys: [String]) -> Bool {
        keys.contains { $0 == feedbackKey || $0.hasPrefix(feedbackKey + ".") }
    }

    private var viewLog: SessionViewLog?
    private var alertPrefs: SessionAlertPrefs?
    private var answerLog: PromptAnswerLog?
    private var hub: HostEventHub?
    private var linkProvider: (@MainActor () -> (any LinkService)?)?

    private var subscription: Task<Void, Never>?
    private var pushTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    private init() {}

    /// 装配：链路可用时把订阅接上。重复调用只保留最后一次（RootView 的前后台钩子会调多次）。
    func attach(viewLog: SessionViewLog,
                alertPrefs: SessionAlertPrefs,
                answerLog: PromptAnswerLog,
                hub: HostEventHub,
                link: @escaping @MainActor () -> (any LinkService)?) {
        self.viewLog = viewLog
        self.alertPrefs = alertPrefs
        self.answerLog = answerLog
        self.hub = hub
        // 本机答掉一条 → 推账户级；别的设备答掉的 → 拉回来从待回应里去掉。
        hub.onPromptAnswered = { [weak self] promptId in
            await self?.promptAnswered(promptId)
        }
        self.linkProvider = link
        // 用户在本机改开关 → 推到账户级（远端并进来的值不会走到这里，见 SessionAlertPrefs）。
        alertPrefs.onLocalChange = { [weak self] in await self?.pushAlertPrefs() }
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
                    if keys.contains(Self.alertPrefsKey) {
                        await self.pullAlertPrefs()
                    }
                    if keys.contains(Self.answeredPromptsKey) {
                        await self.pullAnsweredPrompts()
                    }
                    if Self.mentionsFeedback(keys) {
                        await self.refreshFeedback()
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

    /// 收到信件的账户状态帧：立刻去 mail 服务拉一次收件箱（角标与列表都跟着变）。
    ///
    /// 不复用 `minimumRefreshInterval` 那道节流：这帧本来就是"刚刚变了"的信号，
    /// 而且次数很少（一封信一次），节流只会在连收两封时吃掉第二封。
    private func refreshFeedback() async {
        await FeedbackCenter.shared.refreshInbox(force: true)
    }

    /// 回前台/刚连上时拉一次，兜住丢掉的推送。
    func refresh() async {
        guard currentClient() != nil else {
            // 档案还没定下来（刚配对、正在连）：有界重试几次，别就此放弃。
            pullWithRetry { [weak self] in
                guard let self, self.currentClient() != nil else { return false }
                await self.pullSessionRead()
                await self.pullAlertPrefs()
                return true
            }
            return
        }
        await pullSessionRead()
        await pullAlertPrefs()
        await pullAnsweredPrompts()
    }

    // MARK: - 收发

    private func pullSessionRead() async {
        guard let client = currentClient(),
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

    /// 提醒开关在账户状态里的 key。
    static let alertPrefsKey = "alertPrefs"
    /// 已作答的待回应提示（032 FR-008）。
    static let answeredPromptsKey = "answeredPrompts"

    /// 本机答掉一条提示：记台账 → 推账户级（**带全量台账**，因为 PUT 是整体替换）。
    func promptAnswered(_ promptId: String) async {
        answerLog?.markAnswered(promptId)
        await pushAnsweredPrompts()
    }

    func pushAnsweredPrompts() async {
        guard let client = currentClient(), let log = answerLog else { return }
        let snapshot = log.accountSnapshot()
        guard !snapshot.isEmpty else { return }
        let entry = AccountStateClient.Entry(
            key: Self.answeredPromptsKey,
            value: .object(snapshot.mapValues { .double($0) }),
            updatedAt: Int(Date().timeIntervalSince1970 * 1000)
        )
        _ = try? await client.put([entry])
    }

    private func pullAnsweredPrompts() async {
        guard let client = currentClient(), let log = answerLog, let hub else { return }
        guard let entries = try? await client.fetch(keys: [Self.answeredPromptsKey]) else { return }
        guard case .object(let map)? = entries[Self.answeredPromptsKey]?.value else {
            ViewportProbe.note("answeredPrompts.pull", ["result": "absent"])
            return
        }
        let remote = map.compactMapValues { $0.doubleValue }
        log.mergeRemote(answeredAt: remote)
        // 把账户里已知答过的从本机待回应里去掉（宿主没撤回的那条也一并清掉）。
        let changed = hub.applyRemoteAnswers(Set(remote.keys))
        ViewportProbe.note("answeredPrompts.pull",
                           ["result": "ok", "count": String(remote.count),
                            "dropped": changed ? "1" : "0"])
    }

    private func pullAlertPrefs() async {
        guard let client = currentClient(), let prefs = alertPrefs else { return }
        do {
            let entries = try await client.fetch(keys: [Self.alertPrefsKey])
            guard case .object(let map)? = entries[Self.alertPrefsKey]?.value else {
                ViewportProbe.note("accountState.pull", ["key": Self.alertPrefsKey, "result": "absent"])
                return
            }
            ViewportProbe.note("accountState.pull",
                               ["key": Self.alertPrefsKey, "result": "ok",
                                "turnEnd": String(map["turnEnd"]?.boolValue ?? true)])
            let turnEnd = map["turnEnd"]?.boolValue ?? prefs.notifyOnTurnEnd
            let attention = map["attention"]?.boolValue ?? prefs.notifyOnAttention
            prefs.applyRemote(turnEnd: turnEnd, attention: attention)
            return
        } catch {
            ViewportProbe.note("accountState.pull",
                               ["key": Self.alertPrefsKey, "result": "failed",
                                "error": String(describing: error)])
            return
        }
    }

    /// 用户在本机改了开关：推到账户级。时间戳用本机现在，配合中转"只前进"。
    func pushAlertPrefs() async {
        guard let client = currentClient(), let prefs = alertPrefs else { return }
        let snapshot = prefs.accountSnapshot
        let entry = AccountStateClient.Entry(
            key: Self.alertPrefsKey,
            value: .object(["turnEnd": .bool(snapshot.turnEnd),
                            "attention": .bool(snapshot.attention)]),
            updatedAt: Int(Date().timeIntervalSince1970 * 1000)
        )
        _ = try? await client.put([entry])
    }

    private func pushSessionRead() async {
        guard let client = currentClient(),
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

    /// 当前该跟哪台中转说话：**先用这条链路正在用的档案**，没有才退回"最近连过的那个"。
    ///
    /// 为什么不能只用"最近连过"：切到另一个中转（或刚配对完正在连）时，`lastConnectedAt`
    /// 还是上一个档案的，于是状态会被写到**另一台中转**的同一个账户号上——2026-10-16 的
    /// 仿真器端到端就是这么发现的（本地中转预置了 `alertPrefs.turnEnd=false`，App 却把它
    /// 拉到了生产档案上，开关没变）。
    private func currentClient() -> AccountStateClient? {
        guard let link = linkProvider?() else { return nil }
        // **有链路门面时只认它当前用的档案**：档案还没定下来（刚配对、正在切换）就等下一次，
        // 不回退到"最近连过的那个"——那会把状态写到另一台中转上去（2026-10-16 端到端实测：
        // 本地中转预置了开关，App 却拉到了生产档案）。
        guard let profile = link.activeProfile,
              case .relay(let relayURL, _) = profile.transport,
              let secret = Keychain.get(profile.secretAccount), !secret.isEmpty
        else {
            ViewportProbe.note("accountState.client", ["source": "waiting"])
            return nil
        }
        ViewportProbe.note("accountState.client", ["source": "active", "url": relayURL.absoluteString])
        return AccountStateClient(relayURL: relayURL, deviceToken: secret)
    }

    /// 档案还没定下来时，隔一会儿再试几次（连上之后 `activeProfile` 才会被写）。
    /// 次数有界：这是一次对齐，不是常驻轮询——真拿不到就等回前台那次。
    private func pullWithRetry(_ operation: @escaping () async -> Bool) {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            for _ in 0..<6 {
                if Task.isCancelled { break }
                if await operation() { break }
                try? await Task.sleep(for: .seconds(2))
            }
            self?.retryTask = nil
        }
    }

    /// 退回用：最近连过的那个中转档案（与 `FeedbackCenter` 取法一致）。
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
        retryTask?.cancel()
        retryTask = nil
        subscription = nil
        pushTask = nil
    }
}
