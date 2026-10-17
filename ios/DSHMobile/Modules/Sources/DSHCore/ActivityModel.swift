import DSHConnectionAPI
import DSHFoundation
import DSHKit
import Foundation
import Observation

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

    private var store = ActivityStore()
    private weak var hub: HostEventHub?
    private weak var service: (any LinkService)?
    private var eventTask: Task<Void, Never>?
    /// 连接期间的名单轮询（推送不可靠时的兜底）。
    private var autoRefreshTask: Task<Void, Never>?
    private var outputTask: Task<Void, Never>?
    private var isAttached = false

    /// 最近一次 `session/list` 的会话行（子会话卡片读标签 / 模式 / 计时）。
    public private(set) var summaries: [String: SessionSummary] = [:]

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
    public func summary(sessionId: String) -> SessionSummary? {
        summaries[sessionId]
    }

    /// 正在跑的子会话行（只认 `subagentTiming.active`，判定在 `SessionSummary`）。
    public func activeChild(sessionId: String) -> SessionSummary? {
        guard let summary = summaries[sessionId], summary.isSubagentActive else { return nil }
        return summary
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
        store.apply(.connection(connected))
        if connected {
            Task { await refresh() }
            startAutoRefresh()
        } else {
            closeOutput()
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

    /// 重读能力位与整份名单（建连 / 重连 / 下拉 / 回到前台）。
    public func refresh() async {
        #if DEBUG
        // 夹具优先：UI 用例要的是确定性名单，不让真实链路把它覆盖掉。
        if fixture != nil { return }
        #endif
        guard let service, let client = service.client else { return }
        let capabilities = service.capabilities
        store.apply(.capabilities(capabilities))
        store.setCurrentSession(chatSessionId)
        guard store.isAvailable else { return }
        do {
            let roster = try await client.activityRoster()
            store.apply(.roster(roster))
        } catch {
            // 旧连接器/无 jobs 服务：整块降级，界面与升级前一致。
            if let failure = error as? DSHRPCFailure,
               failure.code == "link/unsupported" || failure.code == "unsupported" {
                DSHLog.push("activity: connector answered \(failure.code); activity surfaces hidden")
                store.apply(.capabilities(capabilities.subtracting([LinkHandshake.Capability.jobsRoster])))
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
        var next: [String: SessionSummary] = [:]
        for session in sessions { next[session.sessionId] = session }
        summaries = next
        store.apply(.sessions(sessions))
        for session in sessions where session.sessionId != chatSessionId {
            store.apply(.turnOpen(session.sessionId, session.running))
        }
        if let chatSessionId {
            store.apply(.turnOpen(chatSessionId, chatTurnOpen))
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
            var next: [String: SessionSummary] = [:]
            for summary in content.sessions { next[summary.sessionId] = summary }
            summaries = next
        }
        #endif
        if let sessionId {
            store.apply(.turnOpen(sessionId, isTurnOpen))
        }
        store.setCurrentSession(sessionId)
    }

    // MARK: - Actions

    /// 停止一个后台任务。**不改本地状态**：只等名单回流（契约 §3）。
    public func killJob(sessionId: String, jobId: String) async {
        #if DEBUG
        if fixture != nil {
            killFixtureJob(sessionId: sessionId, jobId: jobId)
            return
        }
        #endif
        guard let client = service?.client else { return }
        do {
            let value = try await client.jobKill(sessionId: sessionId, jobId: jobId)
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
        guard let client = service?.client else { return }
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
    public func openOutput(sessionId: String, job: Job) {
        closeOutput()
        var feed = OutputFeed(
            id: job.id,
            sessionId: sessionId,
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
        guard let client = service?.client else { return }
        let jobId = job.id
        outputTask = Task { [weak self] in
            do {
                for try await frame in await client.jobFollow(sessionId: sessionId, jobId: jobId) {
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
        guard let client = service?.client, !isLoadingSettled else { return }
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
        summaries.values
            .filter { $0.parentSessionId == parentSessionId && !$0.isSubagentActive && $0.subagentTiming?.lastTurnCompleted != nil }
            .sorted { ($0.projections?.values?.subagentTiming?.settledMs ?? 0) > ($1.projections?.values?.subagentTiming?.settledMs ?? 0) }
            .prefix(5)
            .map { $0 }
    }

    // MARK: - Internals

    private func handle(_ event: HostEvent) {
        guard case .unknown(let type, let raw) = event, type == LinkJobsFrame.frameType else { return }
        guard let value = raw["value"],
              let frame = try? value.decoded(as: LinkJobsFrame.self)
        else { return }
        store.apply(.frame(frame))
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
        var next: [String: SessionSummary] = [:]
        for session in content.sessions { next[session.sessionId] = session }
        summaries = next
    }

    /// 夹具行为（`activity-ui.md` §8）：不发真实停止请求，行直接收敛。
    private func killFixtureJob(sessionId: String, jobId: String) {
        let remaining = store.liveJobs(sessionId: sessionId).filter { $0.id != jobId }
        let settled = store.settledCount(sessionId: sessionId) + 1
        store.apply(.frame(LinkJobsFrame(
            at: Date().timeIntervalSince1970 * 1000,
            sessionId: sessionId,
            running: remaining,
            settled: settled
        )))
        notice = String(localized: "任务已经结束了")
    }
    #endif
}
