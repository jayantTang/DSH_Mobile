import Foundation

/// 概要 v2：连接器在 `fold: "summary"` 模式下折出来的一轮**过程元数据**。
///
/// 与 v1（`HistoryFoldSummary`，`foldedCount` 那套）的分工：v1 只是把过程段
/// 换成一条摘要记录，原始事件照样下发；v2 整段过程一个字节都不发，只给
/// 分组与步骤的标题（`name` / `preview` / `status` / `bytes` / `resultSeq`）。
/// 所以它**不是一个可见行**：解码成独立模型，由 `TranscriptProcessFold` 的投影
/// 生成轮次行、分组行与步骤元数据行；正文按需单条取（`TimelineProcessStep`）。
///
/// 线上形状（连接器 `lib/history/fold-summary.js`）：
///
///     +link/fold { v:2, turn, startSeq, endSeq, durationMs, endReason,
///                  activities:{commands:n,...},
///                  groups:[ { startSeq, endSeq, activities, toolCount,
///                             steps:[ { seq, kind:"tools"|"reasoning",
///                                       name, preview, status,
///                                       resultSeq?, bytes? } ] } ] }
///
/// 一页里同一轮可能有多条（中间讲话把过程切成多段），按 `startSeq` 各自成组。
public struct FoldSummaryV2: Sendable, Equatable {
    /// 线类型。以 `+` 开头，不会与宿主事件类型相撞（与 DSHKit `Timeline` 同一常量值）。
    static let recordType = "+link/fold"
    /// 本客户端认识的版本。没有 `v` 的记录是 v1，仍走老路径。
    public static let version = 2

    public enum StepKind: String, Sendable, Equatable {
        case tools
        case reasoning
    }

    public enum StepStatus: String, Sendable, Equatable {
        case ok
        case error
        case running
    }

    /// 一条步骤的元数据（没有正文）。
    public struct Step: Sendable, Equatable {
        public let seq: Int
        public let kind: StepKind
        /// 工具名（`bash` / `read`…）；思考步骤固定 `thinking`。
        public let name: String
        /// 参数预览（连接器折叠空白后截断）。思考步骤为空。
        public let preview: String
        public let status: StepStatus
        /// 结果事件所在 seq；结果还没回来时没有。
        public let resultSeq: Int?
        /// 结果正文（UTF-8）字节数；思考步骤是思考正文大小。
        public let bytes: Int?

        public init(seq: Int, kind: StepKind, name: String, preview: String,
                    status: StepStatus, resultSeq: Int? = nil, bytes: Int? = nil) {
            self.seq = seq
            self.kind = kind
            self.name = name
            self.preview = preview
            self.status = status
            self.resultSeq = resultSeq
            self.bytes = bytes
        }

        /// 这条步骤算哪一类活动。思考不是「已完成的活动」（桌面口径），没有类别。
        public var activity: TimelineProcessActivity? {
            // 连接器把少数工具（如 job_output）也放进 reasoning 段，名字不是
            // `thinking` 时仍按工具分类，不能一律当思考。
            if kind == .reasoning, name == "thinking" || name.isEmpty { return nil }
            return TimelineProcessActivity.classify(name)
        }

        public var isRunning: Bool { status == .running }
    }

    /// 一段连续过程（中间讲话切开的段）。桌面的一段通常只有一组。
    public struct Group: Sendable, Equatable {
        public let startSeq: Int
        public let endSeq: Int
        public let activities: [TimelineProcessActivity: Int]
        /// 工具步骤数（连接器只数 `kind == "tools"`）。
        public let toolCount: Int
        public let steps: [Step]

        public init(startSeq: Int, endSeq: Int,
                    activities: [TimelineProcessActivity: Int],
                    toolCount: Int, steps: [Step]) {
            self.startSeq = startSeq
            self.endSeq = endSeq
            self.activities = activities
            self.toolCount = toolCount
            self.steps = steps
        }

        public var reasoningCount: Int { steps.filter { $0.kind == .reasoning }.count }
        public var subagentCount: Int { steps.filter { $0.activity == .subagents }.count }
        public var isRunning: Bool { steps.contains(where: \.isRunning) }
    }

    /// 轮次号；连接器在缺边界时给 `null`，这里按 0（未知）处理，改用 `startSeq` 认领。
    public let turn: Int
    public let startSeq: Int
    public let endSeq: Int
    /// 这一轮**开始**的宿主时间（epoch ms）。运行中没有 `durationMs`，计时起点用它；
    /// 窗口裁到轮次中间时本地没有 `turn/start`，这是唯一的真实起点。
    public let startedAt: Double?
    public let durationMs: Double?
    public let endReason: String?
    /// 这一段的整体活动计数（只数工具步骤）。
    public let activities: [TimelineProcessActivity: Int]
    public let groups: [Group]

    public init(turn: Int, startSeq: Int, endSeq: Int, startedAt: Double? = nil,
                durationMs: Double?, endReason: String?,
                activities: [TimelineProcessActivity: Int], groups: [Group]) {
        self.turn = turn
        self.startSeq = startSeq
        self.endSeq = endSeq
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.endReason = endReason
        self.activities = activities
        self.groups = groups
    }

    public var duration: TimeInterval? {
        durationMs.map { $0 / 1000 }
    }

    public var toolCount: Int { groups.reduce(0) { $0 + $1.toolCount } }
    public var reasoningCount: Int { groups.reduce(0) { $0 + $1.reasoningCount } }
    public var subagentCount: Int { groups.reduce(0) { $0 + $1.subagentCount } }

    /// 分组活动计数的合并值（轮次行的图标/标题用）；没有分组时退回整段计数。
    public var groupedActivities: [TimelineProcessActivity: Int] {
        var merged: [TimelineProcessActivity: Int] = [:]
        for group in groups {
            for (activity, count) in group.activities {
                merged[activity, default: 0] += count
            }
        }
        return merged.isEmpty ? activities : merged
    }

    // MARK: - 解码

    /// 一条 `+link/fold` 记录是不是 v2。v1（没有 `v`）返回 nil，调用方继续走老路径。
    public static func decode(_ event: SessionEvent) -> FoldSummaryV2? {
        guard event.type == recordType, event.data["v"]?.intValue == version else { return nil }
        return FoldSummaryV2(data: event.data, fallbackSeq: event.seq)
    }

    /// 从记录 `data` 解码。字段缺失时按能表达的最小值处理，不编造步骤。
    public init?(data: JSONValue, fallbackSeq: Int = 0) {
        guard data["v"]?.intValue == Self.version else { return nil }
        let groups = (data["groups"]?.arrayValue ?? []).compactMap(Group.decode)
        let startSeq = data["startSeq"]?.intValue ?? groups.first?.startSeq ?? fallbackSeq
        let endSeq = data["endSeq"]?.intValue ?? groups.last?.endSeq ?? startSeq
        self.init(
            turn: data["turn"]?.intValue ?? 0,
            startSeq: startSeq,
            endSeq: max(startSeq, endSeq),
            startedAt: data["startedAt"]?.doubleValue,
            durationMs: data["durationMs"]?.doubleValue,
            endReason: data["endReason"]?.stringValue,
            activities: Self.activityCounts(data["activities"], fallbackSteps: groups.flatMap(\.steps)),
            groups: groups)
    }

    /// 活动计数：先认线名；`activities` 缺失时按步骤现算（只数工具步骤，与连接器同口径）。
    static func activityCounts(_ value: JSONValue?,
                               fallbackSteps: [Step]) -> [TimelineProcessActivity: Int] {
        if case .object(let object)? = value, !object.isEmpty {
            var counts: [TimelineProcessActivity: Int] = [:]
            for (name, raw) in object {
                guard let count = raw.intValue, count > 0 else { continue }
                counts[TimelineProcessActivity.fromWireName(name), default: 0] += count
            }
            return counts
        }
        var counts: [TimelineProcessActivity: Int] = [:]
        for step in fallbackSteps where step.kind == .tools {
            counts[TimelineProcessActivity.classify(step.name), default: 0] += 1
        }
        return counts
    }
}

extension FoldSummaryV2.Group {
    static func decode(_ value: JSONValue) -> FoldSummaryV2.Group? {
        guard case .object = value else { return nil }
        let steps = (value["steps"]?.arrayValue ?? []).compactMap(FoldSummaryV2.Step.decode)
        guard !steps.isEmpty else { return nil }
        let startSeq = value["startSeq"]?.intValue ?? steps[0].seq
        let endSeq = value["endSeq"]?.intValue ?? steps[steps.count - 1].seq
        return FoldSummaryV2.Group(
            startSeq: startSeq,
            endSeq: max(startSeq, endSeq),
            activities: FoldSummaryV2.activityCounts(value["activities"], fallbackSteps: steps),
            toolCount: value["toolCount"]?.intValue ?? steps.filter { $0.kind == .tools }.count,
            steps: steps)
    }
}

extension FoldSummaryV2.Step {
    static func decode(_ value: JSONValue) -> FoldSummaryV2.Step? {
        // 没有 seq 的步骤没法按需取数，也放不进时间顺序：丢掉，不编一个位置。
        guard let seq = value["seq"]?.intValue else { return nil }
        return FoldSummaryV2.Step(
            seq: seq,
            kind: FoldSummaryV2.StepKind(rawValue: value["kind"]?.stringValue ?? "") ?? .tools,
            name: value["name"]?.stringValue ?? "tool",
            preview: value["preview"]?.stringValue ?? "",
            status: FoldSummaryV2.StepStatus(rawValue: value["status"]?.stringValue ?? "") ?? .ok,
            resultSeq: value["resultSeq"]?.intValue,
            bytes: value["bytes"]?.intValue)
    }
}

extension TimelineProcessActivity {
    /// 概要 v2 的活动线名 → 手机的活动类别。
    ///
    /// 连接器用的是桌面 `activity(name)` 那张表，比手机枚举细（`readImage`、
    /// `webSearch`、`webFetch`）。这里并回手机既有的三类，保证分组标题与 v1
    /// 由工具名分类出来的结果一致；不认识的线名按 `tools` 计（与 `classify` 同口径）。
    static func fromWireName(_ name: String) -> TimelineProcessActivity {
        switch name {
        case "read", "readImage": return .read
        case "write": return .write
        case "edit": return .edit
        case "search": return .search
        case "commands": return .commands
        case "code": return .code
        case "webSearch", "webFetch", "web": return .web
        case "subagents": return .subagents
        case "questions": return .questions
        case "plan": return .plan
        case "tools": return .tools
        default: return .tools
        }
    }
}
