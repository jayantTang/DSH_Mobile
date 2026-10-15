import DSHConnectionAPI
import DSHCore
import DSHFoundation
import DSHKit
import Foundation
import Observation
import RelayKit


/// 反馈通道在 App 侧的状态与动作：地址与令牌的来源、提交、拉取、未读口径。
///
/// 拉取时机只有两个：App 回到前台、打开记录页（``applicationBecameActive()`` /
/// ``recordsAppeared()``，两者都带节流）。**没有轮询**，首版也不接推送——这是 spec
/// 的取舍，不是缺漏。
///
/// 这里不放任何面向用户的文案：失败以 ``FeedbackClientError`` 交给界面层分类处理。
/// 本机已读是"用户真正打开过"才算，离线时角标保持原样（FR-012）。
@MainActor
@Observable
public final class FeedbackCenter {

    public static let shared = FeedbackCenter()

    /// 一次请求要用的中转地址与设备令牌。
    struct Endpoint: Sendable {
        let url: URL
        /// 已配对手机有；未配对手机为 nil，接口按匿名处理（令牌过期也走这条路，
        /// relay 不会因此回 401，用户照样能提意见）。
        let deviceToken: String?
    }

    // MARK: - 可观察状态

    /// 入口角标：服务端 `unreadCount` 与本机已读口径取较大者。
    public private(set) var unreadCount = 0
    /// 显示用列表；内容来自镜像，所以离线打开也有东西可看。
    public var threads: [FeedbackThread] { mirror.displayThreads }
    public var notices: [FeedbackNotice] { mirror.displayNotices }
    public private(set) var isRefreshing = false
    public private(set) var isSubmitting = false
    /// 最近一次失败的分类；成功一次即清空。
    public private(set) var lastError: FeedbackClientError?
    public private(set) var lastRefreshedAt: Date?

    // MARK: - 依赖

    private let store: FeedbackLocalStore
    private let minimumRefreshInterval: TimeInterval
    private let endpointProvider: () -> Endpoint?
    private var mirror: FeedbackMirror
    private var serverUnreadCount = 0
    /// 镜像文件不存在（首次安装、换机、刚清过缓存）：下一次拉取要以服务端补种已读。
    private var needsSeed: Bool
    /// 同一条草稿重试时复用的幂等键，见 ``clientRefForRetry()``。
    private var draftRef: String?

    init(
        store: FeedbackLocalStore = FeedbackLocalStore(),
        minimumRefreshInterval: TimeInterval = 15,
        endpointProvider: (() -> Endpoint?)? = nil
    ) {
        self.store = store
        self.minimumRefreshInterval = minimumRefreshInterval
        self.endpointProvider = endpointProvider ?? { FeedbackCenter.systemEndpoint() }
        self.mirror = store.mirror()
        self.needsSeed = !store.mirrorExists
        recomputeUnread()
    }

    // MARK: - 地址与令牌

    /// 有 profile 就用最近连过的那个的地址与设备令牌（取法与
    /// `APNSRegistrar.currentRelay()` 一致）；没有 profile 就用编译期注入的默认地址、
    /// 匿名提交——这正是"没走中转的用户也能提意见"那条路径。
    static func systemEndpoint() -> Endpoint? {
        if let paired = pairedRelay() {
            return Endpoint(url: paired.url, deviceToken: paired.token)
        }
        guard let url = URL(string: AppConfig.relayURL) else { return nil }
        return Endpoint(url: url, deviceToken: nil)
    }

    private static func pairedRelay() -> (url: URL, token: String)? {
        // 026：跨模块后这条链推导变慢，分两段（与 025 的断点同理）。
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

    /// 提交前给用户看的三项技术信息；提交时用的也是这三项，两处不会漂移。
    public static var technicalInfo: (appVersion: String, deviceModel: String, systemVersion: String) {
        (DeviceInfo.appVersion, DeviceInfo.deviceModel, systemVersion)
    }

    static var systemVersion: String { DeviceInfo.systemVersion }

    // MARK: - 提交

    /// 提交一条反馈。网络超时后**重复调用是安全的**：同一条草稿复用同一个 `clientRef`，
    /// 服务端按它幂等，重试只产生一条反馈。失败即抛错，绝不假装成功。
    ///
    /// `subject` 是可选的标题行；空白按未填处理（服务端此刻可能还没有这个字段，
    /// 缺字段不会让解析失败）。
    @discardableResult
    public func submit(text: String, subject: String? = nil) async throws -> FeedbackTicket {
        guard let endpoint = endpointProvider() else {
            throw FeedbackClientError.network("no-relay-endpoint")
        }
        isSubmitting = true
        defer { isSubmitting = false }
        let info = Self.technicalInfo
        let title = subject?.trimmingCharacters(in: .whitespacesAndNewlines)
        let kept = (title?.isEmpty ?? true) ? nil : title
        let ticket = try await client(endpoint).submit(
            text: text,
            subject: kept,
            appVersion: info.appVersion,
            deviceModel: info.deviceModel,
            systemVersion: info.systemVersion,
            clientRef: clientRefForRetry()
        )
        draftRef = nil
        do {
            try store.save(ticket)
        } catch {
            // 凭据没进 Keychain：这条反馈已经发出去了，但重装后本机取不回来。
            feedbackLog("ticket store failed: \(error)")
        }
        mirror.insert(threadId: ticket.threadId, subject: kept, createdAt: ticket.createdAt ?? Date())
        persistMirror()
        lastError = nil
        return ticket
    }

    /// 重试用的幂等键。草稿在被用户放弃前（或提交成功前）保持不变；界面层不需要
    /// 理解它，只要重试时再调一次 ``submit(text:)`` 即可。
    public func clientRefForRetry() -> String {
        if let draftRef { return draftRef }
        let ref = UUID().uuidString
        draftRef = ref
        return ref
    }

    /// 用户放弃草稿时调用，下一次提交换一个新的幂等键。
    public func discardDraftRef() {
        draftRef = nil
    }

    // MARK: - 拉取

    /// 拉一次收件箱。服务端这个接口不改任何已读状态，所以刷新本身永远不会清未读。
    ///
    /// - Parameter force: 忽略节流。前台恢复与打开记录页用默认值即可。
    public func refreshInbox(force: Bool = false) async {
        guard !isRefreshing else { return }
        if !force, let last = lastRefreshedAt,
           Date().timeIntervalSince(last) < minimumRefreshInterval { return }
        guard let endpoint = endpointProvider() else {
            lastError = .network("no-relay-endpoint")
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let inbox = try await client(endpoint).inbox(tickets: store.tickets())
            mirror = mirror.refreshing(with: inbox, seedingReadState: needsSeed)
            needsSeed = false
            serverUnreadCount = inbox.unreadCount
            persistMirror()
            lastError = nil
            lastRefreshedAt = Date()
        } catch let error as FeedbackClientError {
            // 离线：保留上一次拉到的镜像与未读，不清、不崩。
            lastError = error
        } catch {
            lastError = .network(String(describing: error))
        }
        recomputeUnread()
    }

    /// App 回到前台时调用（`ScenePhase` 变成 `.active`）。
    public func applicationBecameActive() async {
        await refreshInbox()
    }

    /// 记录页出现时调用。
    public func recordsAppeared() async {
        await refreshInbox()
    }

    // MARK: - 已读

    /// 用户真正打开了某条线程：此时才标记已读并记本机已读。
    public func openThread(_ threadId: String) async {
        await markRead(threadIds: [threadId], noticeIds: [],
                       tickets: [store.ticket(for: threadId)].compactMap { $0 })
    }

    /// 用户真正打开了某条通知。
    public func openNotice(_ noticeId: String) async {
        await markRead(threadIds: [], noticeIds: [noticeId], tickets: [])
    }

    /// 服务端确认过才算读过；离线或失败时**不动**本机已读集合，角标保持原样。
    private func markRead(threadIds: [String], noticeIds: [String], tickets: [FeedbackTicket]) async {
        guard let endpoint = endpointProvider() else { return }
        do {
            let remaining = try await client(endpoint).markRead(
                threadIds: threadIds, noticeIds: noticeIds, tickets: tickets
            )
            serverUnreadCount = remaining
        } catch let error as FeedbackClientError {
            lastError = error
            return
        } catch {
            lastError = .network(String(describing: error))
            return
        }
        mirror.markRead(threadIds: threadIds, noticeIds: noticeIds)
        persistMirror()
        lastError = nil
        recomputeUnread()
    }

    // MARK: - 查询与清理

    public func thread(_ threadId: String) -> FeedbackThread? {
        threads.first { $0.threadId == threadId }
    }

    public func notice(_ noticeId: String) -> FeedbackNotice? {
        notices.first { $0.noticeId == noticeId }
    }

    /// 单条回信的未读：列表按「哪封信没看过」标蓝点，服务端的 `unread` 只到线程粒度。
    public func isUnread(messageId: String) -> Bool {
        mirror.isUnread(messageId: messageId)
    }

    /// 单条通知的未读。
    public func isUnread(noticeId: String) -> Bool {
        mirror.isUnread(noticeId: noticeId)
    }

    /// 本机保存了几条取件凭据。0 表示这台手机没有历史记录可取（换机且未配对）。
    public var storedTicketCount: Int { store.tickets().count }

    /// 设置页「清除本地缓存」调用：清镜像与已读标记，**保留** Keychain 凭据；
    /// 下次拉取按服务端的已读状态补种，记录会自己回来。
    public func clearLocalMirror() {
        store.clearMirror()
        mirror = FeedbackMirror()
        serverUnreadCount = 0
        needsSeed = true
        lastRefreshedAt = nil
        recomputeUnread()
    }

    // MARK: - 内部

    private func client(_ endpoint: Endpoint) -> RelayFeedbackClient {
        RelayFeedbackClient(relayURL: endpoint.url, deviceToken: endpoint.deviceToken)
    }

    private func persistMirror() {
        do {
            try store.save(mirror)
        } catch {
            feedbackLog("mirror save failed: \(error)")
        }
    }

    private func recomputeUnread() {
        unreadCount = max(serverUnreadCount, mirror.localUnreadCount)
    }
}

/// 反馈通道的日志行。与 `DSHLog.push` 同一个过滤思路，但不改那个文件。
private func feedbackLog(_ message: String) {
    NSLog("[DSHMobile/feedback] %@", message)
}
