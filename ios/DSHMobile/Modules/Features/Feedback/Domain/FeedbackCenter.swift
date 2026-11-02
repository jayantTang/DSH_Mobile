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

    /// 入口角标：**只读服务端**（`/feedback/inbox` 与 `/feedback/read` 回包给的那个数），
    /// 落盘在镜像里。不再与本机重算值取最大——那会让服务端事实被永久压住（P1-5）。
    public private(set) var unreadCount = 0
    /// 显示用列表；内容来自镜像，所以离线打开也有东西可看。
    public var threads: [FeedbackThread] { mirror.displayThreads }

    /// 调用方是不是团队账号（服务端判定）：只作账号级提示与旧服务端缺 `mySide` 时的
    /// 推导依据；两栏方向、未读归属、回信入口一律看每线程的 `mySide`。
    public var teamPerspective: Bool { mirror.teamPerspective }
    public var notices: [FeedbackNotice] { mirror.displayNotices }
    /// 正文长度上限：服务端下发的值，旧服务端没有就退编译期默认。
    /// 发送窗口与回信输入框都读这一个（全 App 只有这一处兜底）。
    ///
    /// DEBUG 下若用 `-DSHFeedbackAttachmentsFile` 注入了额度，它优先——截图时服务端
    /// 还没部署附件能力，不注入的话附件区按设计整块不显示。发布构建里没有这一段。
    public var limits: FeedbackLimits {
        #if DEBUG
        if let injectedLimits { return injectedLimits }
        #endif
        return mirror.limits ?? .fallback
    }
    public private(set) var isRefreshing = false
    public private(set) var isSubmitting = false
    /// 底部"加载更早"那一次请求在飞；两栏共用同一个入口。
    public private(set) var isLoadingEarlier = false
    /// 上一次"加载更早"失败了（底部那行据此变成可重试）。
    public private(set) var loadEarlierFailed = false
    /// 最近一次失败的分类；成功一次即清空。
    public private(set) var lastError: FeedbackClientError?
    /// 附件的加载器（§5.1-8：取回后用 sha256 自校验、命中缓存不再请求）。
    /// 它是字节缓存的唯一读口；清理走 ``clearLocalMirror()`` 那一个入口。
    public let attachmentCache: FeedbackAttachmentCache
    public private(set) var lastRefreshedAt: Date?

    // MARK: - 依赖

    private let store: FeedbackLocalStore
    /// 附件字节的唯一所有者（下载缓存 + 发送暂存；清理入口只有一个，见 ``clearLocalMirror()``）。
    private let attachmentDisk: FeedbackAttachmentDisk
    /// 待上传队列（按信件级 `clientRef` 归集，跨重启可重试、7 天过期）。
    private let pendingUploads: FeedbackPendingUploadStore
    /// 镜像两条列表的行数上限（评审 A1 之前是两条都 300，满 300 后翻页变空操作）。
    public let rowLimits: FeedbackMirrorLimits
    private let minimumRefreshInterval: TimeInterval
    private let endpointProvider: () -> Endpoint?
    /// 待投递的崩溃报告（MetricKit 在下次启动交给我们）。
    private let crashArchive: CrashReportArchive
    private var mirror: FeedbackMirror
    /// 镜像文件不存在（首次安装、换机、刚清过缓存）：下一次拉取要以服务端补种已读。
    private var needsSeed: Bool
    /// 同一条草稿重试时复用的幂等键，见 ``clientRefForRetry()``。
    private var draftRef: String?

    #if DEBUG
    /// 截图钩子注入的额度（`-DSHFeedbackAttachmentsFile`）；发布构建里不存在这个属性。
    private var injectedLimits: FeedbackLimits?
    /// 截图钩子播过镜像之后，启动阶段的自动拉取一律跳过（否则线上真数据会把要截的
    /// 内容盖掉）；用户主动下拉（`force`）一次才恢复。仅 DEBUG。
    private var skipSeededRefresh = false
    #endif

    init(
        store: FeedbackLocalStore = FeedbackLocalStore(),
        minimumRefreshInterval: TimeInterval = 15,
        endpointProvider: (() -> Endpoint?)? = nil,
        crashArchive: CrashReportArchive = CrashReportArchive(),
        rowLimits: FeedbackMirrorLimits? = nil,
        attachmentDisk: FeedbackAttachmentDisk = FeedbackAttachmentDisk(),
        pendingUploads: FeedbackPendingUploadStore = FeedbackPendingUploadStore()
    ) {
        self.store = store
        self.attachmentDisk = attachmentDisk
        self.pendingUploads = pendingUploads
        self.rowLimits = rowLimits ?? Self.automationRowLimits() ?? .default
        self.minimumRefreshInterval = minimumRefreshInterval
        let resolvedEndpoint = endpointProvider ?? { FeedbackCenter.systemEndpoint() }
        self.endpointProvider = resolvedEndpoint
        self.attachmentCache = FeedbackAttachmentCache(
            disk: attachmentDisk,
            fetch: { attachmentId in
                guard let endpoint = resolvedEndpoint() else {
                    throw FeedbackClientError.network("no-relay-endpoint")
                }
                return try await FeedbackCenter.makeClient(endpoint)
                    .fetchAttachment(attachmentId: attachmentId)
            }
        )
        self.crashArchive = crashArchive
        self.mirror = store.mirror()
        self.needsSeed = !store.mirrorExists
        #if DEBUG
        // 截图钩子（设计 M18）：注入附件额度 + 用给定镜像播种。两件都只在 DEBUG。
        if let injected = Self.automationAttachmentLimits() {
            injectedLimits = FeedbackLimits(attachments: injected)
        }
        if let seed = Self.automationSeedMirror(), store.seedMirror(from: seed) {
            // 同目录下的 `attachments/<sha256>` 一并拷进下载缓存：运行器每次重装 App
            // 都会清缓存，只播镜像的话图片会显示"附件没有取到"。
            attachmentDisk.seedCache(
                from: seed.deletingLastPathComponent()
                    .appendingPathComponent("attachments", isDirectory: true))
            mirror = store.mirror()
            needsSeed = false
            skipSeededRefresh = true
        }
        #endif
        recomputeUnread()
    }

    #if DEBUG
    /// 仿真器截图钩子（设计 M18）：`-DSHFeedbackAttachmentsFile <绝对路径>` 注入附件额度。
    ///
    /// 文件内容就是 v2 `limits.attachments` 的形状：
    /// `{"maxPerMessage":8,"maxFileBytes":8388608,"maxTotalBytes":25165824,
    ///   "types":["jpeg","png","heic","pdf","txt","log","csv","json"]}`。
    ///
    /// 为什么是**文件**而不是命令行里的一串数字：测试运行器把 `args=` 按逗号切成多个
    /// 启动参数，带逗号的写法一定被切碎。文件路径是单个 token，不含逗号。
    ///
    /// 文件不存在、读不出、JSON 形状不对——一律返回 nil（**不补默认值**，也绝不弹窗），
    /// 只往日志里记一行。发布构建里没有这一段。
    static func automationAttachmentLimits() -> FeedbackAttachmentLimits? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DSHFeedbackAttachmentsFile"),
              index + 1 < arguments.count
        else { return nil }
        let path = arguments[index + 1]
        guard path.hasPrefix("/") else { return nil }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return try JSONDecoder().decode(FeedbackAttachmentLimits.self, from: data)
        } catch {
            feedbackLog("attachment limits seed unreadable: \(error)")
            return nil
        }
    }

    /// 仿真器截图钩子（设计 M18）：`-DSHFeedbackSeedMirror <绝对路径>`。
    ///
    /// 把这份 JSON 覆盖到本机镜像位置，并把它**同目录下**的 `attachments/<sha256>`
    /// 一并拷进下载缓存（运行器每次重装 App 都会清缓存，只播镜像的话附件会显示
    /// "附件没有取到"）。播种成功的这次启动会跳过自动拉取（见 ``refreshInbox(force:)``），
    /// 否则线上真数据会把要展示的内容盖掉。
    ///
    /// 返回 nil = 没给参数、路径不是绝对路径，或镜像文件读不出来。
    static func automationSeedMirror() -> URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DSHFeedbackSeedMirror"),
              index + 1 < arguments.count
        else { return nil }
        let path = arguments[index + 1]
        guard path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            feedbackLog("seed mirror missing at \(path)")
            return nil
        }
        return url
    }

    /// 仿真器截图钩子：`-DSHFeedbackRowLimits 5,5` 把镜像上限调小，让"触顶"的终止态
    /// 在几十条数据内可见。发布构建里这一整段被编译掉（与 `DSH_FEEDBACK_STORE_DIR`
    /// 的测试重定向同一性质）。
    static func automationRowLimits() -> FeedbackMirrorLimits? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-DSHFeedbackRowLimits"),
              index + 1 < arguments.count
        else { return nil }
        let joined = arguments[index + 1]
        let parts = joined.split(separator: ",").compactMap { Int($0) }
        if parts.count == 2 {
            guard parts[0] > 0, parts[1] > 0 else { return nil }
            return FeedbackMirrorLimits(threads: parts[0], notices: parts[1])
        }
        // 运行器把 `-DSHFeedbackRowLimits 5,5` 拆成两个独立参数（`5` `5`）。
        guard index + 2 < arguments.count,
              let threads = Int(joined), let notices = Int(arguments[index + 2]),
              threads > 0, notices > 0
        else { return nil }
        return FeedbackMirrorLimits(threads: threads, notices: notices)
    }
    #else
    static func automationRowLimits() -> FeedbackMirrorLimits? { nil }
    #endif

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
    /// 提交一条反馈；带附件时**先逐个上传、全部成功后再提交**（v4 契约）。
    ///
    /// 四种结局都落到可见状态：成功返回票据；失败抛 ``FeedbackClientError`` 并保留
    /// 待上传队列（同一个 `clientRef` 重试，已 `stored` 的附件不重传）；用户取消由
    /// ``FeedbackSendJob/cancel()`` 在 job 层收尾。附件失败时**绝不自动降级**成
    /// "只发正文"——那要用户点"只发正文"再走一次。
    @discardableResult
    public func submit(
        text: String,
        subject: String? = nil,
        attachments: [FeedbackOutgoingAttachment] = []
    ) async throws -> FeedbackTicket {
        guard let endpoint = endpointProvider() else {
            throw FeedbackClientError.network("no-relay-endpoint")
        }
        isSubmitting = true
        defer { isSubmitting = false }
        let info = Self.technicalInfo
        let title = subject?.trimmingCharacters(in: .whitespacesAndNewlines)
        let kept = (title?.isEmpty ?? true) ? nil : title
        let job = FeedbackSendJob(
            client: client(endpoint), clientRef: clientRefForRetry(),
            text: text, subject: kept, attachments: attachments,
            limits: limits, disk: attachmentDisk, pendingStore: pendingUploads,
            technical: (info.appVersion, info.deviceModel, info.systemVersion)
        )
        switch await job.run() {
        case .sent(let receipt):
            let ticket = FeedbackTicket(
                threadId: receipt.threadId,
                ticketKey: receipt.ticketKey ?? "",
                createdAt: receipt.createdAt,
                messageId: receipt.messageId.isEmpty ? nil : receipt.messageId,
                attachmentsBound: receipt.attachmentsBound
            )
            draftRef = nil
            if !ticket.ticketKey.isEmpty {
                do {
                    try store.save(ticket)
                } catch {
                    // 凭据没进 Keychain：这条反馈已经发出去了，但重装后本机取不回来。
                    feedbackLog("ticket store failed: \(error)")
                }
            }
            mirror.insert(threadId: ticket.threadId, subject: kept,
                          createdAt: ticket.createdAt ?? Date())
            persistMirror()
            lastError = nil
            return ticket
        case .failed(let failure):
            let error = FeedbackSendJob.clientError(for: failure)
            lastError = error
            throw error
        case .cancelled:
            let error = FeedbackClientError.network("send-cancelled")
            lastError = error
            throw error
        }
    }

    /// 把待投递的崩溃报告交出去（每次进前台都可以调）。
    ///
    /// 一次崩溃一封信，靠 ``CrashReport/id`` 去重：同一构建上的同一个崩溃只发一次，
    /// 不会因为「每次启动都崩」而把收件箱刷满。网络不通就整批留在本地等下次——
    /// 这是与传统上报 SDK 的区别：这里没有重试风暴，最多留 20 条。
    ///
    /// 返回这次真正投出去的条数，供用例与日志判断。
    @discardableResult
    public func flushCrashReports() async -> Int {
        let pending = crashArchive.pending()
        guard !pending.isEmpty else { return 0 }
        guard let endpoint = endpointProvider() else { return 0 }
        var sent = 0
        for report in pending {
            do {
                _ = try await client(endpoint).submit(
                    text: CrashReportDigest.body(for: report),
                    subject: CrashReportDigest.subject(for: report),
                    appVersion: report.appVersion,
                    deviceModel: report.deviceModel,
                    systemVersion: report.systemVersion,
                    clientRef: report.id
                )
                crashArchive.markSent(id: report.id)
                sent += 1
            } catch {
                // 一条发不出去，后面的同样发不出去（同一个端点）；留到下次，
                // 不在这里重试，免得把"上报"变成新的重连来源。
                feedbackLog("crash report queued: \(error)")
                break
            }
        }
        return sent
    }

    /// 团队回信（030 二期 FR-5）：往既有线程追加一封回信。
    ///
    /// 团队账号在服务端免 `ticketKey`（授权判据是「调用方是线程的团队侧」）；
    /// 成功后刷新让该线程回到最新口径。失败按现有 ``FeedbackClientError`` 抛出。
    public func reply(to threadId: String, text: String,
                      attachments: [FeedbackOutgoingAttachment] = []) async throws {
        guard let endpoint = endpointProvider() else {
            lastError = .network("no-relay-endpoint")
            throw FeedbackClientError.network("no-relay-endpoint")
        }
        do {
            let info = Self.technicalInfo
            let job = FeedbackSendJob(
                client: client(endpoint), clientRef: clientRefForRetry(),
                text: text, attachments: attachments,
                limits: limits, disk: attachmentDisk, pendingStore: pendingUploads,
                reply: (threadId: threadId, ticketKey: nil),
                technical: (info.appVersion, info.deviceModel, info.systemVersion)
            )
            switch await job.run() {
            case .sent:
                break
            case .failed(let failure):
                throw FeedbackSendJob.clientError(for: failure)
            case .cancelled:
                throw FeedbackClientError.network("send-cancelled")
            }
        } catch {
            // 用户可见文案在 Domain 层产出：界面只读 `lastError`，不必认识协议层的错误映射。
            if let classified = error as? FeedbackClientError {
                lastError = classified
            } else {
                lastError = .network(LinkErrors.describe(error))
            }
            throw error
        }
        lastError = nil
        await refreshInbox(force: true)
    }

    /// 回信失败时给用户看的一句话（界面只读这个，不引协议层的错误映射）。
    public func replyFailureText(_ error: any Error) -> String {
        if let classified = error as? FeedbackClientError {
            switch classified {
            case .notFound: return String(localized: "这条记录在服务器上已不存在，可能已被删除。")
            case .server(let status, let code):
                return String(localized: "服务器拒绝了这次回信（\(status)\(code.map { " · " + $0 } ?? "")）")
            case .network: return String(localized: "网络不通，回信没有发出去，正文已保留。")
            case .rateLimited: return String(localized: "发送太频繁，请稍后重试。")
            case .tooLong: return String(localized: "内容太长了，请精简后重试。")
            // 附件相关的两分类本轮只落到"技术描述"，用户文案在 UI 轮补：
            // 现在加文案会引入未成对的本地化键（`check:i18n` 会判红）。
            case .unsupportedType, .storageFull: return LinkErrors.describe(error)
            case .decoding: return String(localized: "服务器返回了无法识别的内容，请稍后重试。")
            }
        }
        return LinkErrors.describe(error)
    }

    /// 组一次发送（界面层用它拿到可观察的 job：进度、每槽状态、失败原因）。
    ///
    /// 没有地址就没有 job——界面据 `nil` 直接落"网络不通"的失败态。
    public func makeSendJob(
        text: String,
        subject: String? = nil,
        attachments: [FeedbackOutgoingAttachment] = [],
        reply: (threadId: String, ticketKey: String?)? = nil
    ) -> FeedbackSendJob? {
        guard let endpoint = endpointProvider() else { return nil }
        let info = Self.technicalInfo
        let title = subject?.trimmingCharacters(in: .whitespacesAndNewlines)
        return FeedbackSendJob(
            client: client(endpoint), clientRef: clientRefForRetry(),
            text: text, subject: (title?.isEmpty ?? true) ? nil : title,
            attachments: attachments,
            limits: limits, disk: attachmentDisk, pendingStore: pendingUploads,
            reply: reply,
            technical: (info.appVersion, info.deviceModel, info.systemVersion)
        )
    }

    /// 发送窗口在 job 成功之后调它：记镜像、存凭据、清幂等键（一处收口）。
    public func recordSent(_ receipt: FeedbackSendReceipt, subject: String?) {
        draftRef = nil
        let ticket = FeedbackTicket(
            threadId: receipt.threadId,
            ticketKey: receipt.ticketKey ?? "",
            createdAt: receipt.createdAt,
            messageId: receipt.messageId.isEmpty ? nil : receipt.messageId,
            attachmentsBound: receipt.attachmentsBound
        )
        if !ticket.ticketKey.isEmpty {
            do {
                try store.save(ticket)
            } catch {
                feedbackLog("ticket store failed: \(error)")
            }
        }
        mirror.insert(threadId: ticket.threadId, subject: subject,
                      createdAt: ticket.createdAt ?? Date())
        persistMirror()
        lastError = nil
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
        #if DEBUG
        // 截图钩子播过镜像是为了**截图**：启动阶段的自动拉取直接跳过，否则线上数据
        // 会把要展示的那几封信盖掉；用户主动下拉（`force == true`）时才放行并恢复。
        // 命令行参数与这一段都只在 DEBUG 构建里存在。
        if skipSeededRefresh {
            guard force else { return }
            skipSeededRefresh = false
        }
        #endif
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
            mirror = mirror.refreshing(with: inbox, seedingReadState: needsSeed, rowLimits: rowLimits)
            if !inbox.isVersion2 {
                // v1 回落（旧服务端、或服务端单侧回滚到 v1）：响应里没有分页字段，
                // 不能沿用它上次 v2 的游标——清掉，底部"加载更早"随之消失（设计 §2.5）。
                mirror.clearPageCursors()
            }
            needsSeed = false
            persistMirror()
            lastError = nil
            loadEarlierFailed = false
            lastRefreshedAt = Date()
        } catch let error as FeedbackClientError {
            // 离线：保留上一次拉到的镜像与未读，不清、不崩。
            lastError = error
        } catch {
            lastError = .network(String(describing: error))
        }
        recomputeUnread()
    }

    /// 往回翻一页（设计 §M6）。**同一个入口服务两栏**：比较两条列表已加载的最旧边界，
    /// 只推进"边界更靠后（更新）"的那一路，直到两路 `more` 都为 false。
    ///
    /// 旧服务端没有分页（两路游标都是 nil），此方法不发请求，`hasEarlier` 为 false。
    public func loadEarlier() async {
        guard !isLoadingEarlier, let kind = earlierPage else { return }
        guard let endpoint = endpointProvider() else {
            lastError = .network("no-relay-endpoint")
            loadEarlierFailed = true
            return
        }
        isLoadingEarlier = true
        loadEarlierFailed = false
        defer { isLoadingEarlier = false }
        do {
            let inbox = try await client(endpoint).inbox(
                tickets: store.tickets(),
                // 每页都带两路首页（协议 §2.3.4 的约定）。F10：这里曾经只取线程那一路
                // （`notices:false`），服务端于是回一个"通知没有更多"的页，把本地通知
                // 游标覆盖成到底；现在按文档口径两路都取，游标更新由 `covering` 限定。
                threadsPage: kind == .threads
                    ? FeedbackPageRequest(before: mirror.threadsPage?.nextBefore) : nil,
                noticePage: kind == .notices
                    ? FeedbackPageRequest(before: mirror.noticesPage?.nextBefore) : nil
            )
            mirror = mirror.refreshing(with: inbox, seedingReadState: false, rowLimits: rowLimits,
                                       covering: kind == .threads ? .threads : .notices)
            persistMirror()
            lastError = nil
            recomputeUnread()
        } catch let error as FeedbackClientError {
            lastError = error
            loadEarlierFailed = true
        } catch {
            lastError = .network(String(describing: error))
            loadEarlierFailed = true
        }
    }

    /// 还能不能往回翻（两路任一路有下一页）。
    public var hasEarlier: Bool { earlierPage != nil }

    /// App 回到前台时调用（`ScenePhase` 变成 `.active`）。
    public func applicationBecameActive() async {
        // 崩溃报告先走：它不依赖收件箱拉取，网络不通时留在本地等下次。
        await flushCrashReports()
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

    /// 用户真正打开了某条通知（正文已经拿到之后才调；取正文失败时不要调它——
    /// 不能因为网络失败把未读吃掉）。
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
            mirror.serverUnreadCount = remaining
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

    /// 这条通知的正文是否已经在镜像里（离线可读）。`nil` = 还没取过。
    public func cachedNoticeBody(_ noticeId: String) -> String? {
        mirror.cachedBody(of: noticeId)
    }

    /// 取一条通知的正文（v2 按需路由）：成功即写进镜像，之后离线也能读。
    ///
    /// 失败按 ``FeedbackClientError`` 抛出——`notFound` 是"这条已经不在了"，
    /// 其余（含网络不通）都算"还能重试"。调用方**不得**在失败后标记已读。
    @discardableResult
    public func fetchNotice(_ noticeId: String) async throws -> FeedbackNotice {
        guard let endpoint = endpointProvider() else {
            lastError = .network("no-relay-endpoint")
            throw FeedbackClientError.network("no-relay-endpoint")
        }
        do {
            let notice = try await client(endpoint).notice(noticeId: noticeId)
            // F7：详情没带正文是契约异常，按失败处理——不能把"空正文"缓存成
            // `bodyCached = true`，那会把这封通知永久记成一封空信。
            guard let body = notice.body else {
                throw FeedbackClientError.decoding("feedback/notice answered without a body")
            }
            mirror.storeBody(of: notice, cachedBody: body, noticeLimit: rowLimits.notices)
            persistMirror()
            lastError = nil
            return notice
        } catch {
            if let classified = error as? FeedbackClientError {
                lastError = classified
            } else {
                lastError = .network(LinkErrors.describe(error))
            }
            throw error
        }
    }

    /// 单条回信的未读：列表按「哪封信没看过」标蓝点，服务端的 `unread` 只到线程粒度。
    public func isUnread(messageId: String) -> Bool {
        mirror.isUnread(messageId: messageId)
    }

    /// 单条通知的未读。
    public func isUnread(noticeId: String) -> Bool {
        mirror.isUnread(noticeId: noticeId)
    }

    /// 一条线程的取件凭据（用户侧回信要用它证明归属；团队侧没有也能回）。
    public func ticket(for threadId: String) -> FeedbackTicket? {
        store.ticket(for: threadId)
    }

    /// 本机保存了几条取件凭据。0 表示这台手机没有历史记录可取（换机且未配对）。
    public var storedTicketCount: Int { store.tickets().count }

    /// 设置页「清除本地缓存」调用：清镜像与已读标记，**保留** Keychain 凭据；
    /// 下次拉取按服务端的已读状态补种，记录会自己回来。
    public func clearLocalMirror() {
        store.clearMirror()
        // 附件的两份字节（下载缓存 + 发送暂存）与待上传队列一起清：这是**唯一**入口。
        attachmentDisk.clear()
        attachmentCache.clear()
        pendingUploads.save(FeedbackPendingUploads())
        mirror = FeedbackMirror()
        needsSeed = true
        lastRefreshedAt = nil
        loadEarlierFailed = false
        recomputeUnread()
    }

    // MARK: - 内部

    /// 底部"加载更早"这次该推哪一路。
    private enum EarlierPage { case threads, notices }

    /// 这一路还能不能翻：服务端有下一页 **且** 本机镜像还没到保存上限。
    private func pageCanAdvance(_ page: FeedbackPage?, rows: Int, limit: Int) -> Bool {
        (page?.more ?? false) && page?.nextBefore != nil && rows < limit
    }

    /// 这一路"服务端还有、但本机已满"：触顶后不再发请求，改为可见的终止状态。
    private func pageIsCapped(_ page: FeedbackPage?, rows: Int, limit: Int) -> Bool {
        (page?.more ?? false) && rows >= limit
    }

    private var threadsCanAdvance: Bool {
        pageCanAdvance(mirror.threadsPage, rows: mirror.threads.count, limit: rowLimits.threads)
    }

    private var noticesCanAdvance: Bool {
        pageCanAdvance(mirror.noticesPage, rows: mirror.notices.count, limit: rowLimits.notices)
    }

    /// 两路都还有下一页时，只推"已加载边界更靠后（更新）"的那一路——把两栏合并列表
    /// 里 T1..T2 之间的洞压小（设计 §M6.3；残余缺口见设计第七节第 12 条）。
    /// 已触顶的那一路不参与：它再翻也只会把刚取回的行立刻裁掉（评审 F1）。
    private var earlierPage: EarlierPage? {
        switch (threadsCanAdvance, noticesCanAdvance) {
        case (true, true):
            let threadsBoundary = mirror.threadsPage?.nextBefore?.boundary ?? .distantFuture
            let noticesBoundary = mirror.noticesPage?.nextBefore?.boundary ?? .distantFuture
            return threadsBoundary >= noticesBoundary ? .threads : .notices
        case (true, false):
            return .threads
        case (false, true):
            return .notices
        default:
            return nil
        }
    }

    /// 服务端还有更早的记录，但本机已达保存上限（两路都已无法推进）。
    /// 底部那行据此变成不可点的说明，而不是继续假装还能翻。
    public var earlierCapped: Bool {
        earlierPage == nil
            && (pageIsCapped(mirror.threadsPage, rows: mirror.threads.count, limit: rowLimits.threads)
                || pageIsCapped(mirror.noticesPage, rows: mirror.notices.count, limit: rowLimits.notices))
    }

    private func client(_ endpoint: Endpoint) -> RelayFeedbackClient {
        Self.makeClient(endpoint)
    }

    /// 构造协议客户端只有这一处（正文与附件共用同一份地址/令牌）。
    static func makeClient(_ endpoint: Endpoint) -> RelayFeedbackClient {
        RelayFeedbackClient(relayURL: endpoint.url, deviceToken: endpoint.deviceToken)
    }

    private func persistMirror() {
        do {
            try store.save(mirror)
        } catch {
            feedbackLog("mirror save failed: \(error)")
        }
    }

    /// 角标只认镜像里那个服务端值（刷新与已读回包各写一次）。
    private func recomputeUnread() {
        unreadCount = max(0, mirror.serverUnreadCount)
    }
}

/// 反馈通道的日志行。与 `DSHLog.push` 同一个过滤思路，但不改那个文件。
/// module 内共享：附件域（`FeedbackAttachments`/`FeedbackSendJob`）也写这一行。
func feedbackLog(_ message: String) {
    NSLog("[DSHMobile/feedback] %@", message)
}
