import DSHConnectionAPI
import DSHFoundation
import DSHKit
import Foundation
import Observation
import OSLog

/// 活动可见性的**适配层**（spec 018 Phase 6）。
///
/// 这一层只做四件事：把连接器的输入喂给 ``ActivityStore``、把 `link/jobs`
/// 推帧解出来、把 `job/follow` 的输出累积起来、把操作（停止 / 打断）转给
/// `DSHClient`。判定口径全部在 DSHKit 的状态机里，这里**不重算**任何
/// `isBusy` / 计数；视图读到的每个数字都来自 `ActivityStore`。
///
/// 为装配层减负：本类型是应用级单例（与 `SessionAlerts` / `FeedbackCenter`
/// 同一约定），由出现的界面在 `.task` 里 `attach`；`RootView` 不需要改。
@MainActor
@Observable
public final class ActivityModel {

    /// 应用级唯一实例（同时只维护一份名单，`ActivityStore` 的设计前提）。
    public static let shared = ActivityModel()

    // MARK: - State

    private let logger = Logger(subsystem: "com.jayanttang.dsh", category: "activity")
    private var store = ActivityStore()
    /// 任何活动状态变化的单调计数：列表父视图读它来强制重算，
    /// 避免行内 snapshot 的变化要等到下一次列表刷新才上屏。
    public private(set) var revision = 0
    private weak var hub: HostEventHub?
    private weak var service: (any LinkService)?
    private var eventTask: Task<Void, Never>?
    /// 连接期间的名单轮询（推送不可靠时的兜底）。
    private var autoRefreshTask: Task<Void, Never>?
    private var outputTask: Task<Void, Never>?
    private var isAttached = false

    /// 聊天页当前打开的会话：`.turnOpen` 用 `timeline.isTurnOpen` 覆盖列表的
    /// `running`，并把它钉成 `currentSessionId`（工具栏计数按它取）。
    private var chatSessionId: String?
    private var chatTurnOpen = false

    /// 输出面板的状态：同一时刻只保留一个 job 的流。
    public struct OutputFeed: Identifiable, Equatable {
        public let id: String
        public let sessionId: String
        public var jobLabel: String
        /// 已经收到 `opened` 帧：用来区分「还没开流」与「开了但暂时没有输出」。
        public var hasOpened = false
        public var chunks: [JobChunk] = []
        /// 宿主明确说过"中间有一段被丢了"。
        public var isLossy = false
        /// `outputLost` / `earliest > 0`：最老的那段被 ring 抽走了。
        public var outputLost = false
        public var isFinished = false
        public var detail: String?
        public var error: String?
    }

    public private(set) var outputFeed: OutputFeed?

    /// 本机清除过的"已结束"计数（只影响本机展示，`activity-ui.md` §3）。
    private var clearedSettled: Set<String> = []

    /// 一行性的提示（"任务已不在列表里"等），由视图消费后清空。
    public private(set) var notice: String?

    // MARK: - Fixture (DEBUG)

    /// 旧连接器已明确答过 `link/unsupported`：断线重连前不再问。
    private var rosterUnsupported = false
    /// 子智能体计数来自 `session/list` 摘要；聊天页打开时列表不会刷新，
    /// 所以活动层自己低频对账一次（20 秒），不依赖列表页生命周期。
    private var lastSessionSync = Date.distantPast

    #if DEBUG
    private var fixture: ActivityFixture.Content?
    #endif

    public init() {
        #if DEBUG
        enableFixtureIfAsked()
        #endif
    }

    // MARK: - Derived outputs（全部转发 ActivityStore）

    /// 连接器是否声明了 `jobs-roster`；false 时面板、计数、卡片新行整块不出现。
    public var isAvailable: Bool { store.isAvailable }

    /// 断线后还在展示上次已知的数据。
    public var lastKnown: Bool { store.lastKnown }

    /// 工具栏计数：当前会话在跑的任务 + 子智能体（不含轮次本身）。
    public var activeCount: Int { store.activeCount }

    public func snapshot(sessionId: String) -> SessionActivity? {
        guard store.isAvailable else { return nil }
        return store.snapshot(sessionId: sessionId)
    }

    public func counts(sessionId: String) -> (agents: Int, jobs: Int) {
        store.counts(sessionId: sessionId)
    }

    public func settledCount(sessionId: String) -> Int {
        guard !clearedSettled.contains(sessionId) else { return 0 }
        return store.settledCount(sessionId: sessionId)
    }

    public func children(of parentSessionId: String) -> [SessionSummary] {
        store.children(of: parentSessionId)
    }

    public func liveJobs(sessionId: String) -> [Job] {
        store.liveJobs(sessionId: sessionId)
    }

    /// 会话行（含已结束的子会话，卡片据此绑定"已完成"与计时）。
    ///
    /// 读状态机里那一份（`.sessions` 唯一的整份输入），本层不再存第二份。
    public func summary(sessionId: String) -> SessionSummary? {
        store.row(sessionId)
    }

    /// 正在跑的子会话行（只认 `subagentTiming.active`，判定在 `SessionSummary`）。
    public func activeChild(sessionId: String) -> SessionSummary? {
        guard let row = store.row(sessionId), row.isSubagentActive else { return nil }
        return row
    }

    // MARK: - Wiring

    /// 接上一条链路。重复调用是幂等的；换了实现（重连换 carrier）也安全。
    public func attach(service: any LinkService, hub: HostEventHub) {
        let sameService = (self.service as AnyObject?) === (service as AnyObject)
        if isAttached, sameService, self.hub === hub { return }
        self.service = service
        self.hub = hub
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in hub.events() {
                guard let self else { return }
                self.handle(event)
            }
        }
        isAttached = true
        setConnected(service.state.isConnected)
    }

    /// 连接态变化（视图在 `store.state.isConnected` 变化时调）。
    public func setConnected(_ connected: Bool) {
        applyToStore(.connection(connected))
        if connected {
            rosterUnsupported = false
            // 一次连接协商一次：握手能力位只在这里进状态机。它只是**提示**——
            // 名单应答才是证据，所以拿不到能力位也照问（见 `refresh()`）。
            // 反过来，连接期内不再重喂：每轮重喂会在握手缺能力位时把升好的档位
            // 打回去，任务与子会话随换代清空。
            applyToStore(.capabilities(service?.capabilities ?? []))
            Task { await refresh() }
            startAutoRefresh()
        } else {
            // 断线不清掉已经读到的输出：读者正看着它，清空等于把页面变成一块
            // 永远转圈的空白（`JobOutputView` 对 nil 的渲染就是加载态）。已读到的
            // 内容留着，页脚给一句"连接断了"，与面板的「上次已知」同一种口径。
            markOpenOutputUnavailable(String(localized: "连接已断开，读到的输出可能不是最新的"))
            stopAutoRefresh()
        }
    }

    /// 连接期间每 10 秒重读一次名单。
    ///
    /// 为什么不能只靠 `link/jobs` 推帧：推帧依赖连接器订阅宿主任务事件，任何一个环节
    /// 断掉（旧连接器、宿主升级、订阅被释放），手机就会一直停在建连那一刻的名单上——
    /// 2026-10-17 owner 报的就是"任务已经结束，手机还显示在跑"。轮询是兜底，
    /// 服务端读数是一次内存遍历（实测 60 会话 / 180 个活任务 ≈ 0.02ms）。
    private func startAutoRefresh() {
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self else { return }
                await self.refresh()
            }
        }
    }

    private func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    /// 重读整份名单（建连 / 重连 / 下拉 / 回到前台）。
    ///
    /// **只问名单、只喂 `.roster`**，不碰可用性档位。档位有三个写入口，全在连接边界上：
    /// `setConnected(true)` 的握手集合（`setConnected`）、名单答出后的一次升档（本方法
    /// 的 `!store.isAvailable` 分支）、连接器明确答 `link/unsupported` 时的降档（本方法的
    /// catch）。轮询、刷新、推帧一处也没有。握手能力位只作提示：偶尔拿不到
    /// capabilities（实测 relay 建连 caps=0），但连接器其实能回答名单；名单答出即以
    /// 回应为准**升档一次**，连接期内不再降。
    public func refresh() async {
        #if DEBUG
        // 夹具优先：UI 用例要的是确定性名单，不让真实链路把它覆盖掉。
        if fixture != nil { return }
        #endif
        guard let service, let client = service.activityHost else { return }
        let capabilities = service.capabilities
        store.setCurrentSession(chatSessionId)
        guard !rosterUnsupported else { return }
        do {
            let roster = try await client.activityRoster()
            let live = roster.sessions.values.reduce(0) { $0 + $1.liveJobs.count }
            logger.info("roster sessions=\(roster.sessions.count, privacy: .public) jobs=\(live, privacy: .public)")
            if !store.isAvailable {
                applyToStore(.capabilities(capabilities.union([LinkHandshake.Capability.jobsRoster])))
                store.setCurrentSession(chatSessionId)
            }
            applyToStore(.roster(roster))
        } catch {
            // 旧连接器/无 jobs 服务：整块降级，界面与升级前一致。降档只有这一条路
            // （档位不许在连接期内因别的错误变化），且 `rosterUnsupported` 只答一次。
            if let failure = error as? DSHRPCFailure,
               failure.code == "link/unsupported" || failure.code == "unsupported" {
                rosterUnsupported = true
                DSHLog.push("activity: connector answered \(failure.code); activity surfaces hidden")
                applyToStore(.capabilities(capabilities.subtracting([LinkHandshake.Capability.jobsRoster])))
                return
            }
            DSHLog.push("activity: roster failed \(error)")
        }
        store.setCurrentSession(chatSessionId)
    }

    /// `session/list` 回来时喂一次会话行。
    ///
    /// 列表行的轮次口径沿用 `summary.running`；聊天页当前会话改喂
    /// `timeline.isTurnOpen`（契约与 owner 口径），所以这里跳过那个会话。
    public func applySessions(_ sessions: [SessionSummary]) {
        #if DEBUG
        if fixture != nil { return }
        #endif
        applyToStore(.sessions(sessions))
        for session in sessions where session.sessionId != chatSessionId {
            applyToStore(.turnOpen(session.sessionId, session.running))
        }
        if let chatSessionId {
            applyToStore(.turnOpen(chatSessionId, chatTurnOpen))
        }
        store.setCurrentSession(chatSessionId)
    }

    /// 聊天页绑定当前会话与轮次（`timeline.isTurnOpen`）。
    public func bindChat(sessionId: String?, isTurnOpen: Bool) {
        chatSessionId = sessionId
        chatTurnOpen = isTurnOpen
        #if DEBUG
        // 夹具挂在"当前打开的会话"上：UI 用例开的是运行器新建的临时会话，
        // 固定 id 的夹具在那一屏是空的，点不到任何行（`activity-ui.md` §8）。
        if fixture != nil, let sessionId {
            let content = ActivityFixture.canned(parentSessionId: sessionId)
            fixture = content
            store = content.applied()
        }
        #endif
        if let sessionId {
            applyToStore(.turnOpen(sessionId, isTurnOpen))
        }
        store.setCurrentSession(sessionId)
    }

    // MARK: - Actions

    /// 停止一个后台任务。**不改本地状态**：只等名单回流（契约 §3）。
    ///
    /// 宿主按任务的 `owner` 隔离任务，所以请求要回到任务**自己那一格**：父行面板上停一个
    /// 子会话起的任务时，用父行 id 去停会答 `job/not-found`。owner 缺失（无主任务，连接器
    /// 把它放进每一格）时退回行 id，与聚合之前的口径一致。
    public func killJob(sessionId: String, jobId: String) async {
        let target = jobCell(in: sessionId, jobId: jobId)
        #if DEBUG
        if fixture != nil {
            killFixtureJob(sessionId: target, jobId: jobId)
            return
        }
        #endif
        guard let client = service?.activityHost else { return }
        do {
            let value = try await client.jobKill(sessionId: target, jobId: jobId)
            if value.outcome == .alreadyFinished {
                notice = String(localized: "任务已经结束了")
            }
            await refresh()
        } catch {
            if let failure = error as? DSHRPCFailure, failure.code == "job/not-found" {
                notice = String(localized: "任务已不在列表里")
                await refresh()
            } else {
                notice = LinkErrors.describe(error)
            }
        }
    }

    /// 停掉一个可持续子智能体（一次性子智能体没有独立入口，宿主 schema 只认
    /// `continuable`）。
    public func stopSubagent(childSessionId: String, parentSessionId: String) async {
        guard let client = service?.activityHost else { return }
        do {
            let value = try await client.subagentInterrupt(
                childSessionId: childSessionId,
                parentSessionId: parentSessionId
            )
            if !value.accepted {
                notice = String(localized: "停止请求没有被接受")
            }
            await refresh()
        } catch {
            notice = LinkErrors.describe(error)
        }
    }

    // MARK: - Job output

    /// 展开输出：订阅 `job/follow`。再展开另一条会先退订上一条。
    ///
    /// 订阅同样要回到任务**自己那一格**（`owner`）：读的是宿主按 owner 隔离的那份输出。
    public func openOutput(sessionId: String, job: Job) {
        closeOutput()
        let target = job.owner ?? sessionId
        var feed = OutputFeed(
            id: job.id,
            sessionId: target,
            jobLabel: job.label,
            outputLost: job.headOutputLost
        )
        #if DEBUG
        if fixture != nil {
            feed.chunks = fixture?.output ?? []
            feed.isFinished = true
            outputFeed = feed
            return
        }
        #endif
        outputFeed = feed
        guard let client = service?.activityHost else {
            // 没有链路就没有流：这一步必须**落到可见结局**，不能把 feed 留在
            // "还没开流"那一格——视图对它的渲染是加载态，读者会一直转圈。
            markOpenOutputUnavailable(String(localized: "尚未连接，读不到这个任务的输出"))
            return
        }
        let jobId = job.id
        outputTask = Task { [weak self] in
            do {
                for try await frame in await client.jobFollow(sessionId: target, jobId: jobId) {
                    guard let self, self.outputFeed?.id == jobId else { return }
                    self.applyOutput(frame)
                }
            } catch {
                guard let self, self.outputFeed?.id == jobId else { return }
                if self.outputFeed?.chunks.isEmpty == true {
                    self.outputFeed?.error = LinkErrors.describe(error)
                }
                self.outputFeed?.isFinished = true
            }
        }
    }

    /// 收起输出即退订（省一条流）。
    public func closeOutput() {
        outputTask?.cancel()
        outputTask = nil
        outputFeed = nil
    }

    /// 流开不下去（没链路 / 断线）：把当前这份 feed 落成错误终态。
    ///
    /// 只改**已经展开的那一份**：视图的四种结局（有输出 / 已结束 / 错误 / 加载中）
    /// 里，只有错误态能在"没有流"时给出确定信息；保留已读到的 chunks 是为了
    /// 让断线后仍能看完手里的内容，`error` 由页脚呈现。
    private func markOpenOutputUnavailable(_ message: String) {
        outputTask?.cancel()
        outputTask = nil
        guard outputFeed != nil else { return }
        if outputFeed?.error == nil { outputFeed?.error = message }
        outputFeed?.isFinished = true
    }

    /// 本机清除「已结束 N 个」。
    public func clearSettled(sessionId: String) {
        clearedSettled.insert(sessionId)
    }

    public func clearNotice() {
        notice = nil
    }


    // MARK: - 已结束（面板里展开那一段）

    /// 已结束的任务行（展开「已结束」时按需读一次 `job/list`）。
    ///
    /// 名单帧只带"活着的任务 + 已结算计数"，不带明细；面板要让人看见"哪些已经结束、
    /// 为什么结束"，所以展开时读一次 `job/list`（宿主会回整份名单，含终态），取最近若干条。
    public private(set) var settledJobs: [Job] = []
    public private(set) var isLoadingSettled = false

    public func loadSettledJobs(sessionId: String) async {
        guard let client = service?.activityHost, !isLoadingSettled else { return }
        isLoadingSettled = true
        defer { isLoadingSettled = false }
        settledJobs = []
        var first: [Job] = []
        do {
            for try await frame in await client.jobList(sessionId: sessionId) {
                first = frame.jobs
                break
            }
        } catch {
            DSHLog.push("activity: settled jobs read failed \(error)")
        }
        settledJobs = first
            .filter { !$0.isLive }
            .sorted { ($0.finishedAt ?? $0.startedAt) > ($1.finishedAt ?? $1.startedAt) }
            .prefix(8)
            .map { $0 }
    }

    /// 已结束的子智能体（最近 5 个），来自 `session/list` 的 `subagentTiming`。
    public func finishedChildren(parentSessionId: String) -> [SessionSummary] {
        store.rows
            .filter { $0.parentSessionId == parentSessionId && !$0.isSubagentActive && $0.subagentTiming?.lastTurnCompleted != nil }
            .sorted { ($0.projections?.values?.subagentTiming?.settledMs ?? 0) > ($1.projections?.values?.subagentTiming?.settledMs ?? 0) }
            .prefix(5)
            .map { $0 }
    }

    // MARK: - Internals

    /// 一个任务在宿主侧的归属会话：任务自己带 `owner` 就用它，否则用所在行的 id。
    ///
    /// 父行上的任务可能是子会话起的（归属派生自状态机，见 `ActivityStore`），
    /// 停它必须回到子会话那一格；无主任务的 `owner` 为空，按行 id 处理（与聚合前一致）。
    private func jobCell(in sessionId: String, jobId: String) -> String {
        store.liveJobs(sessionId: sessionId).first { $0.id == jobId }?.owner ?? sessionId
    }

    private func applyToStore(_ input: ActivityStore.Input) {
        store.apply(input)
        revision &+= 1
    }

    private func handle(_ event: HostEvent) {
        guard case .unknown(let type, let raw) = event, type == LinkJobsFrame.frameType else { return }
        guard let value = raw["value"],
              let frame = try? value.decoded(as: LinkJobsFrame.self)
        else { return }
        logger.info("frame session=\(frame.sessionId, privacy: .public) running=\(frame.running.count, privacy: .public) settled=\(frame.settled, privacy: .public) at=\(frame.at, privacy: .public)")
        applyToStore(.frame(frame))
    }

    private func applyOutput(_ frame: JobFollowFrame) {
        switch frame {
        case .opened(let job, _):
            outputFeed?.hasOpened = true
            outputFeed?.jobLabel = job.label
            outputFeed?.outputLost = job.headOutputLost
        case .output(let chunks, _, let lossy):
            outputFeed?.chunks.append(contentsOf: chunks)
            if lossy { outputFeed?.isLossy = true }
        case .status(let job):
            outputFeed?.isFinished = true
            outputFeed?.detail = job.detail
            if job.headOutputLost { outputFeed?.outputLost = true }
        case .unknown:
            break
        }
    }

    #if DEBUG
    private func enableFixtureIfAsked() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-DSHActivityFixture"),
              args.indices.contains(index + 1),
              args[index + 1] == "canned"
        else { return }
        let content = ActivityFixture.canned()
        fixture = content
        store = content.applied()
    }

    /// 夹具行为（`activity-ui.md` §8）：不发真实停止请求，行直接收敛。
    private func killFixtureJob(sessionId: String, jobId: String) {
        let remaining = store.liveJobs(sessionId: sessionId).filter { $0.id != jobId }
        let settled = store.settledCount(sessionId: sessionId) + 1
        applyToStore(.frame(LinkJobsFrame(
            at: Date().timeIntervalSince1970 * 1000,
            sessionId: sessionId,
            running: remaining,
            settled: settled
        )))
        notice = String(localized: "任务已经结束了")
    }
    #endif
}
