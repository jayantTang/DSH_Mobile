import Foundation

/// 一个会话的活动快照（`specs/018-mobile-activity-visibility/data-model.md` §1）。
///
/// 视图只读它，不再二次计算：`isBusy` 的判定口径只此一份。
public struct SessionActivity: Sendable, Hashable {
    public let sessionId: String
    /// 轮次是否进行中。聊天页 = `timeline.isTurnOpen`；列表行 = `session/list.running`
    /// （两者都由调用方喂进 ``ActivityStore/Input/turnOpen(_:_:)``）。
    public let turnOpen: Bool
    /// 还活着的任务（终态永远不在这里）。
    public let liveJobs: [Job]
    /// 正在跑的子会话个数。
    public let liveChildCount: Int

    public init(sessionId: String, turnOpen: Bool, liveJobs: [Job], liveChildCount: Int) {
        self.sessionId = sessionId
        self.turnOpen = turnOpen
        self.liveJobs = liveJobs
        self.liveChildCount = liveChildCount
    }

    /// `turnOpen ∪ liveJobs ∪ liveChildren`（`research.md` R3）。
    public var isBusy: Bool { turnOpen || !liveJobs.isEmpty || liveChildCount > 0 }

    /// 列表行右侧两行小字（`activity-ui.md` §1）：为 0 的那行不出现。
    public var counts: (agents: Int, jobs: Int) { (liveChildCount, liveJobs.count) }
}

/// 活动派生状态机：**纯 Swift、无 UI、无网络、无单例**，可完整回放。
///
/// 手机同时只维护一份名单（应用级）。所有输入都由应用层喂进来：
///
/// ```
/// .capabilities(LinkHandshake.capabilities)   // 缺 jobs-roster → 整块不可用
/// .roster(ActivityRoster)                     // _link/jobRoster 首答 / 重连后重问
/// .frame(LinkJobsFrame)                       // link/jobs 推帧（单会话整格替换）
/// .sessions([SessionSummary])                 // session/list（子会话 + subagentTiming）
/// .connection(true/false)                     // 断线 / 重连
/// .turnOpen(sessionId, Bool)                  // 该会话的轮次是否进行中
/// ```
///
/// 顺序有两条硬要求（都是"不把过期数据当实时"）：
/// 1. **重连后先喂 `.connection(true)`，再喂新名单**：断线期间到达的帧、名单与会话
///    一律丢弃（不变式 4：断线后不再由本地推断更新 `isBusy`）。
/// 2. **能力变化即换代**：`.capabilities` 的集合一旦不同，就清空上一代名单并
///    `generation += 1`（不变式 5）。
///
/// 读到 `_link/jobRoster` 回 `link/unsupported` 时，应用层喂一份**去掉
/// `jobs-roster`** 的能力集即可：这同样是一次换代，`isAvailable` 变 false，
/// 面板、计数与卡片新行整块不出现（`activity-ui.md` §6）。
public struct ActivityStore: Sendable {

    /// 应用层喂进来的输入（`data-model.md` §6）。
    public enum Input: Sendable {
        case capabilities(Set<String>)
        case roster(ActivityRoster)
        case frame(LinkJobsFrame)
        case sessions([SessionSummary])
        case connection(Bool)
        case turnOpen(String, Bool)
    }

    // MARK: - State

    private var capabilities: Set<String> = []
    private var jobsBySession: [String: [Job]] = [:]
    /// 每个会话那一格最后被谁写过（毫秒）：乱序保护用（不变式 1）。
    private var cellAt: [String: Double] = [:]
    private var settledBySession: [String: Int] = [:]
    private var childrenByParent: [String: [SessionSummary]] = [:]
    private var turnOpenBySession: [String: Bool] = [:]

    /// 每次连接重建 / 能力重协商 +1（`data-model.md` §1）。
    public private(set) var generation: Int = 0
    /// 最后一次拿到名单的采样时刻（毫秒）。
    public private(set) var sampledAt: Double?
    /// 连接是否在（`false` 起一切本地推断冻结）。
    public private(set) var isOnline: Bool = true
    /// 是否在展示"上次已知"的数据（断线后为 true，直到新名单到达）。
    public private(set) var lastKnown: Bool = false
    /// 当前打开的会话：`.turnOpen` 顺带记录它，工具栏计数按它取。
    public private(set) var currentSessionId: String?

    public init() {}

    // MARK: - Derived outputs

    /// 连接器是否声明了 `jobs-roster`。
    public var isAvailable: Bool { capabilities.contains(LinkHandshake.Capability.jobsRoster) }

    /// 该会话的活动快照；`nil` 表示这份名单里根本没有它的痕迹（按"没有活"渲染）。
    public func snapshot(sessionId: String) -> SessionActivity? {
        let open = turnOpenBySession[sessionId]
        // 能力位缺失时，"还有多少活"这件事根本不可知：只保留轮次（列表行今天就看它），
        // 任务与子智能体一律按 0 呈现，界面因此与升级前一致（FR-020 / 不变式 3）。
        guard isAvailable else {
            guard let open else { return nil }
            return SessionActivity(sessionId: sessionId, turnOpen: open, liveJobs: [], liveChildCount: 0)
        }
        let jobs = jobsBySession[sessionId]
        let children = childrenByParent[sessionId]
        guard jobs != nil || children != nil || open != nil else { return nil }
        return SessionActivity(
            sessionId: sessionId,
            turnOpen: open ?? false,
            liveJobs: jobs ?? [],
            liveChildCount: children?.count ?? 0
        )
    }

    /// 列表行右侧两行蓝字的数字（`activity-ui.md` §1）。
    ///
    /// 能力位缺失时恒为 `(0, 0)`（不变式 3）：视图因此不渲染任何计数，
    /// 也不会把"降级"显示成"0 个"。
    public func counts(sessionId: String) -> (agents: Int, jobs: Int) {
        guard isAvailable else { return (0, 0) }
        return (childrenByParent[sessionId]?.count ?? 0, jobsBySession[sessionId]?.count ?? 0)
    }

    /// 工具栏计数：当前打开会话的在跑件数（不含轮次本身，`activity-ui.md` §2）。
    public var activeCount: Int {
        guard isAvailable, let currentSessionId else { return 0 }
        let counts = counts(sessionId: currentSessionId)
        return counts.agents + counts.jobs
    }

    /// 该会话已结算的任务数（面板「已结束 N 个」）。
    public func settledCount(sessionId: String) -> Int {
        guard isAvailable else { return 0 }
        return settledBySession[sessionId] ?? 0
    }

    /// 该会话正在跑的子会话行（面板逐行渲染用，含 label 与 mode）。
    public func children(of parentSessionId: String) -> [SessionSummary] {
        guard isAvailable else { return [] }
        return childrenByParent[parentSessionId] ?? []
    }

    /// 该会话还活着的任务（面板逐行渲染用）。
    public func liveJobs(sessionId: String) -> [Job] {
        guard isAvailable else { return [] }
        return jobsBySession[sessionId] ?? []
    }

    /// 显式指定"当前会话"。`.turnOpen` 也会顺带设置它；列表行若也喂 `.turnOpen`，
    /// 应用层应在渲染聊天页时用这个方法把当前会话钉回去。
    public mutating func setCurrentSession(_ sessionId: String?) {
        currentSessionId = sessionId
    }

    // MARK: - Inputs

    public mutating func apply(_ inputs: [Input]) {
        for input in inputs { apply(input) }
    }

    public mutating func apply(_ input: Input) {
        switch input {
        case .capabilities(let value):
            // 同一份能力集重复喂（例如一次连接里两次握手）不算换代：换代的条件是
            // "集合变了"，否则每次重喂都会把刚拿到的名单清掉。
            guard value != capabilities else { return }
            capabilities = value
            beginNewGeneration()

        case .connection(let online):
            guard online != isOnline else { return }
            isOnline = online
            // 断线：冻结本地推断，界面进入"上次已知"（只改标志，不清数据——
            // 清掉会让列表计数瞬间变 0，而契约要求"按最后一份名单显示"）。
            if !online { lastKnown = true }

        case .roster(let roster):
            guard isOnline else { return }
            applyRoster(roster)

        case .frame(let frame):
            guard isOnline else { return }
            applyFrame(frame)

        case .sessions(let summaries):
            guard isOnline else { return }
            applySessions(summaries)

        case .turnOpen(let sessionId, let open):
            turnOpenBySession[sessionId] = open
            currentSessionId = sessionId
        }
    }

    // MARK: - Mutation details

    /// 换代：上一代的数据一律作废，不把旧名单当实时（不变式 5）。
    private mutating func beginNewGeneration() {
        generation += 1
        jobsBySession.removeAll()
        cellAt.removeAll()
        settledBySession.removeAll()
        childrenByParent.removeAll()
        sampledAt = nil
        lastKnown = false
    }

    /// 名单是**整份替换**：没出现在 `sessions` 里的会话就是"没有活"（§2 字段规则）。
    ///
    /// 每一格仍受 `cellAt` 保护：如果某一格已经被一条**更新**的推帧改过（名单在
    /// 路上时帧先到），保留帧的结果，不让名单把它退回去。
    private mutating func applyRoster(_ roster: ActivityRoster) {
        var jobs: [String: [Job]] = [:]
        var settled: [String: Int] = [:]
        for (sessionId, cell) in roster.sessions {
            if let held = cellAt[sessionId], roster.at < held {
                if let current = jobsBySession[sessionId] { jobs[sessionId] = current }
                if let current = settledBySession[sessionId] { settled[sessionId] = current }
                continue
            }
            // 空数组也写：它表示"这一格已知没有活"，与"根本没听说过这个会话"不同
            // （后者 snapshot 返回 nil）。
            jobs[sessionId] = cell.liveJobs
            settled[sessionId] = cell.settled
            cellAt[sessionId] = roster.at
        }
        jobsBySession = jobs
        settledBySession = settled
        sampledAt = roster.at
        lastKnown = false
    }

    private mutating func applyFrame(_ frame: LinkJobsFrame) {
        if let held = cellAt[frame.sessionId], frame.at < held { return }  // 不变式 1
        jobsBySession[frame.sessionId] = frame.liveJobs
        settledBySession[frame.sessionId] = frame.settled
        cellAt[frame.sessionId] = frame.at
        sampledAt = max(sampledAt ?? 0, frame.at)
        lastKnown = false
    }

    /// 会话行的更新**只**影响子会话计数与子会话运行态，不清空任务名单（不变式 6）。
    private mutating func applySessions(_ summaries: [SessionSummary]) {
        var next: [String: [SessionSummary]] = [:]
        for summary in summaries {
            guard summary.isSubagent,
                  let parent = summary.parentSessionId,
                  summary.isSubagentActive
            else { continue }
            next[parent, default: []].append(summary)
        }
        childrenByParent = next
    }
}
