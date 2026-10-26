import Foundation

/// One category of work a process node summarizes.
///
/// The names are stable enough to appear in diagnostics; user-facing labels are
/// minted by the UI layer so they can be localized.
public enum TimelineProcessActivity: String, Sendable, Hashable, CaseIterable {
    case read
    case write
    case edit
    case search
    case commands
    case code
    case web
    case subagents
    case questions
    case plan
    case tools

    /// Classify one durable tool name. Unknown names stay visible as `.tools`.
    public static func classify(_ toolName: String) -> TimelineProcessActivity {
        switch toolName {
        case "read", "read_file", "read_image":
            return .read
        case "write", "create_file":
            return .write
        case "edit", "str_replace_editor", "apply_patch":
            return .edit
        case "glob", "grep", "search":
            return .search
        case "bash", "shell", "pwsh":
            return .commands
        case "run_code", "execute_code":
            return .code
        case "web_search", "web_fetch":
            return .web
        case "subagent":
            return .subagents
        case "ask_user", "question":
            return .questions
        case "todo_write", "update_plan", "plan":
            return .plan
        default:
            return toolName.hasPrefix("subagent_") ? .subagents : .tools
        }
    }
}

/// Summary data carried by a `.processHeader` row.
///
/// The header is a display-only row: the original process rows remain in
/// `ChatTimeline.items`, so search, paging, trimming and long-press continue to
/// see them. `startSeq...endSeq` covers the rows this header stands for and is
/// what the list host uses to keep its scroll anchor when a row becomes hidden.
/// 展开预折摘要（`+link/fold`）时取详情的进度。
/// 由 ChatModel 持有（一个轮次一份），视图只渲染，不自己计时、不自己重试。
public enum PrefetchStatus: Sendable, Equatable {
    case loading(loaded: Int)
    case failed

    /// 又收到一批明细；只有进行中的状态才推进。
    public func advanced(by count: Int) -> PrefetchStatus {
        guard case .loading(let loaded) = self else { return self }
        return .loading(loaded: loaded + count)
    }
}

public struct TimelineProcessHeader: Sendable, Equatable {
    public enum Scope: String, Sendable {
        /// One completed turn's whole process.
        case turn
        /// One contiguous process run between visible assistant replies.
        case group
    }

    public let id: String
    public let scope: Scope
    /// Zero when the page does not carry enough evidence to name the turn.
    public let turn: Int
    public let startSeq: Int
    public let endSeq: Int
    public let toolCount: Int
    public let reasoningCount: Int
    public let messageCount: Int
    public let subagentCount: Int
    public let activityCounts: [TimelineProcessActivity: Int]
    public let isExpanded: Bool
    public let isFoldable: Bool
    public let isRunning: Bool
    public let endReason: String?
    public let duration: TimeInterval?
    public let hasFailure: Bool
    /// The turn begins or ends outside the loaded window.
    public let isPartial: Bool
    /// 这一行是连接器折好下发的摘要（`+link/fold`），不是客户端从过程行推导出来的。
    /// 展开它要先按 `startSeq...endSeq` 取回详情，再走正常的折叠路径。
    public let isPrefetched: Bool
    /// 展开摘要时的取详情进度；普通轮次恒为 nil。
    public let prefetchStatus: PrefetchStatus?

    public init(
        id: String,
        scope: Scope,
        turn: Int,
        startSeq: Int,
        endSeq: Int,
        toolCount: Int,
        reasoningCount: Int,
        messageCount: Int,
        subagentCount: Int,
        activityCounts: [TimelineProcessActivity: Int],
        isExpanded: Bool,
        isFoldable: Bool,
        isRunning: Bool,
        endReason: String?,
        duration: TimeInterval?,
        hasFailure: Bool,
        isPartial: Bool,
        isPrefetched: Bool = false,
        prefetchStatus: PrefetchStatus? = nil
    ) {
        self.id = id
        self.scope = scope
        self.turn = turn
        self.startSeq = startSeq
        self.endSeq = endSeq
        self.toolCount = toolCount
        self.reasoningCount = reasoningCount
        self.messageCount = messageCount
        self.subagentCount = subagentCount
        self.activityCounts = activityCounts
        self.isExpanded = isExpanded
        self.isFoldable = isFoldable
        self.isRunning = isRunning
        self.endReason = endReason
        self.duration = duration
        self.hasFailure = hasFailure
        self.isPartial = isPartial
        self.isPrefetched = isPrefetched
        self.prefetchStatus = prefetchStatus
    }

    /// 只替换进度字段；用于折叠投影把模型侧的状态贴到表头上。
    public func with(prefetchStatus: PrefetchStatus?) -> TimelineProcessHeader {
        TimelineProcessHeader(
            id: id, scope: scope, turn: turn, startSeq: startSeq, endSeq: endSeq,
            toolCount: toolCount, reasoningCount: reasoningCount, messageCount: messageCount,
            subagentCount: subagentCount, activityCounts: activityCounts,
            isExpanded: isExpanded, isFoldable: isFoldable, isRunning: isRunning,
            endReason: endReason, duration: duration, hasFailure: hasFailure,
            isPartial: isPartial, isPrefetched: isPrefetched, prefetchStatus: prefetchStatus)
    }

    /// The row a display projection inserts for this header.
    public var item: TimelineItem {
        TimelineItem(id: id, kind: .processHeader(self), seq: startSeq)
    }
}

/// 末尾运行行：一轮还在跑时，流程末尾写「深度求索中，用时 12秒 ···」。
///
/// 为什么是**一行**而不是视图尾部的一块：默认 uikit 宿主只渲染 `rowsFor` 给出的行，
/// 任何"只画在 SwiftUI 尾部"的东西在那里都不存在（TC-112 失败的真因）。
/// 行身份固定（`running-line`），定时刷新由行视图自己的 `TimelineView` 做，
/// 模型只给开始时刻。它不参与缓存/裁剪/搜索。
public struct TimelineRunningLine: Sendable, Equatable {
    /// 唯一身份：一个会话同时只有一行运行状态。
    public static let identity = "running-line"
    /// 本轮开始的时刻；nil 时只写「深度求索中」。
    public let since: Date?

    public init(since: Date?) {
        self.since = since
    }

    public var id: String { Self.identity }

    /// 排序键取尾部（`Int.max - 2`）：永远排在所有数据行之后，
    /// 又不会与上行合成键（`Int.max - 1` 起）相撞。
    public var item: TimelineItem {
        TimelineItem(id: id, kind: .runningLine(self), seq: Int.max - 2)
    }
}

/// 一行**步骤元数据**（概要 v2 的 `groups[].steps[]`）。
///
/// 它只在概要模式下出现：过程正文（`tool/result` 与思考正文）根本没有下发，
/// 所以这一行只有名称、参数预览、状态与结果字节数，**没有正文**——不是伪造的
/// tool/result 行。读者点开单条时用 `detailRequest` 按 seq 取那一条正文
/// （M6 只留接口，不在投影里发起请求）。
public struct TimelineProcessStep: Sendable, Equatable {
    /// 行身份；重折同一份概要必须得到同一个 id（列表宿主按它做位移锚）。
    public let id: String
    /// 所属分组行的 id（与 `TimelineProcessHeader.id` 同一套键）。
    public let groupKey: String
    /// 所属轮次（0 表示这一页判断不出轮次号）。
    public let turn: Int
    /// 调用 / 思考事件自己的 seq。
    public let seq: Int
    public let kind: FoldSummaryV2.StepKind
    /// 工具名（`bash` / `read`…）；思考步骤固定 `thinking`。
    public let name: String
    public let preview: String
    public let status: FoldSummaryV2.StepStatus
    /// 结果事件所在 seq；结果还没回来时没有。
    public let resultSeq: Int?
    /// 结果正文（UTF-8）字节数；思考步骤是思考正文大小。
    public let bytes: Int?
    /// 按需取回来的正文状态。nil = 还没点开过（卡片只显示大小与入口）。
    public let body: ProcessStepBodyState?

    public init(id: String, groupKey: String, turn: Int, seq: Int,
                kind: FoldSummaryV2.StepKind, name: String, preview: String,
                status: FoldSummaryV2.StepStatus, resultSeq: Int? = nil,
                bytes: Int? = nil, body: ProcessStepBodyState? = nil) {
        self.id = id
        self.groupKey = groupKey
        self.turn = turn
        self.seq = seq
        self.kind = kind
        self.name = name
        self.preview = preview
        self.status = status
        self.resultSeq = resultSeq
        self.bytes = bytes
        self.body = body
    }

    /// 同一行的另一个正文状态（投影把模型侧的状态贴上来，行本身仍是不可变的）。
    public func with(body: ProcessStepBodyState?) -> TimelineProcessStep {
        TimelineProcessStep(
            id: id, groupKey: groupKey, turn: turn, seq: seq, kind: kind,
            name: name, preview: preview, status: status,
            resultSeq: resultSeq, bytes: bytes, body: body)
    }

    /// 这一条正文所在的 seq：工具步骤取结果，思考步骤取自己。
    public var bodySeq: Int { resultSeq ?? seq }

    public var isRunning: Bool { status == .running }

    /// 这一条算哪一类活动；思考没有类别（与 `FoldSummaryV2.Step.activity` 同口径）。
    public var activity: TimelineProcessActivity? {
        kind == .reasoning ? nil : TimelineProcessActivity.classify(name)
    }

    /// 单条正文一次能取多少字节。超过它的结果在手机上没有可读价值，
    /// 也没有分段展开的 UI，所以是终态（`ProcessStepBodyState.tooLarge`）。
    public static let detailMaxBytes = 2 * 1024 * 1024

    /// 按需取这一条正文的请求。
    ///
    /// 走现有 `_link/sessionWindow`（不带 fold），只取那一条记录：`before` 是
    /// 开区间上界，所以正好盖住 `bodySeq`。
    public func detailRequest(address: SessionAddress,
                              encoding: String? = nil) -> HistoryWindowRequest {
        HistoryWindowRequest(
            address: address,
            before: bodySeq + 1,
            through: nil,
            limit: 1,
            maxBytes: Self.detailMaxBytes,
            encoding: encoding,
            fold: nil)
    }

    /// The row a display projection inserts for this step.
    public var item: TimelineItem {
        TimelineItem(id: id, kind: .processStep(self), seq: seq)
    }
}

/// 单条步骤正文的状态（按需取：点击才请求，失败只影响这一张卡）。
public enum ProcessStepBodyState: Sendable, Equatable {
    case loading
    /// 取回来了；`bytes` 是正文 UTF-8 大小（与服务端下发的 `bytes` 对得上最好）。
    case loaded(text: String, bytes: Int)
    /// 请求失败（网络、宿主裁剪等）：卡片内可重试。
    case failed
    /// 超出单条能展开的上限：终态，不再提供重试（重试也只会得到同一个结果）。
    case tooLarge
}

extension ProcessStepBodyState {
    public var text: String? {
        if case .loaded(let text, _) = self { return text }
        return nil
    }
}
