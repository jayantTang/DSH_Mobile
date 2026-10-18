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
