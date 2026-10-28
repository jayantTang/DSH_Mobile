import Foundation

// MARK: - Status

/// 宿主任务的生命周期状态（`specs/018-mobile-activity-visibility/contracts/host-job-surface.md` §4）。
///
/// 未知值降级为 ``unknown(_:)`` 而不是让解码失败：宿主新增状态时，名单里那一行仍然
/// 显示得出来，只是不参与"在跑"的判定——`isLive` 只认 `running` / `stopping`，
/// 不把不认识的状态猜成还在跑（`data-model.md` §2 的状态机是只读镜像，手机不驱动）。
public enum JobStatus: Sendable, Hashable {
    case running
    case stopping
    case completed
    case killed
    case failed
    case unknown(String)

    public var wireValue: String {
        switch self {
        case .running: return "running"
        case .stopping: return "stopping"
        case .completed: return "completed"
        case .killed: return "killed"
        case .failed: return "failed"
        case .unknown(let raw): return raw
        }
    }

    /// 还活着的两种（`link-job-roster.md` §2：`running` 只含这两种）。
    public var isLive: Bool {
        switch self {
        case .running, .stopping: return true
        default: return false
        }
    }

    /// 终态：`completed` / `killed` / `failed`，以及不认识的值（不猜它在跑）。
    public var isTerminal: Bool { !isLive }
}

extension JobStatus: Codable {
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "running": self = .running
        case "stopping": self = .stopping
        case "completed": self = .completed
        case "killed": self = .killed
        case "failed": self = .failed
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

// MARK: - Output

public enum JobChannel: Sendable, Hashable {
    case stdout
    case stderr
    case log
    case unknown(String)

    public var wireValue: String {
        switch self {
        case .stdout: return "stdout"
        case .stderr: return "stderr"
        case .log: return "log"
        case .unknown(let raw): return raw
        }
    }
}

extension JobChannel: Codable {
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "stdout": self = .stdout
        case "stderr": self = .stderr
        case "log": self = .log
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

/// 宿主 `JobView.output`。`earliest > 0` 表示最老的字节已经被 ring 丢掉。
public struct JobOutput: Sendable, Codable, Hashable {
    /// 已产出的字节数。`0` 且已结算 → 行不可展开（没有可看的内容）。
    public let total: Int
    /// 还保留着的最老字节偏移。
    public let earliest: Int
    let spillPaths: [String]?

    public init(total: Int, earliest: Int = 0, spillPaths: [String]? = nil) {
        self.total = total
        self.earliest = earliest
        self.spillPaths = spillPaths
    }

    /// 头部被丢过（输出页必须显式提示，`contracts/activity-ui.md` §3）。
    var headLost: Bool { earliest > 0 }

    private enum CodingKeys: String, CodingKey {
        case total, earliest, spillPaths
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = (try? container.decode(Int.self, forKey: .total)) ?? 0
        earliest = (try? container.decode(Int.self, forKey: .earliest)) ?? 0
        spillPaths = try? container.decodeIfPresent([String].self, forKey: .spillPaths)
    }
}

// MARK: - Job

/// 一个后台任务的手机侧镜像。
///
/// 同一个类型吃两种线形：宿主 `JobView`（`output` 是嵌套对象）与连接器的
/// `JobLite`（只有扁平 `outputTotal` / `outputLost`，见 `link-job-roster.md` §2）。
/// 合成一型是为了让 `ActivityStore` 的 `liveJobs` 只有一种元素类型，视图不必分两套。
public struct Job: Sendable, Hashable, Codable, Identifiable {
    /// `<kind>-N`。行标识、`job/follow` 与 `job/kill` 的 key。
    public let id: String
    public let kind: String
    /// 行标题（一行命令或描述）。
    public let label: String
    /// 归属会话；unowned 任务没有。
    public let owner: String?
    public let status: JobStatus
    public let progress: String?
    /// 终止原因（如 `signal: SIGTERM; cancelled by the user`）。
    public let detail: String?
    /// 毫秒，宿主给的起点；手机只负责 ticking，不重算。
    public let startedAt: Double
    public let finishedAt: Double?
    public let output: JobOutput
    /// 连接器把 `output.earliest > 0` 折成 `outputLost: true`，宿主 `JobView` 不给这个键。
    public let outputLost: Bool?

    public var isLive: Bool { status.isLive }

    /// 输出头部被丢过：连接器明说过就照它，否则看 `output.earliest`。
    public var headOutputLost: Bool { outputLost ?? output.headLost }

    /// 有没有可展开的输出。
    public var hasOutput: Bool { output.total > 0 }

    public init(
        id: String,
        kind: String,
        label: String,
        owner: String? = nil,
        status: JobStatus,
        progress: String? = nil,
        detail: String? = nil,
        startedAt: Double,
        finishedAt: Double? = nil,
        output: JobOutput = JobOutput(total: 0),
        outputLost: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.owner = owner
        self.status = status
        self.progress = progress
        self.detail = detail
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.output = output
        self.outputLost = outputLost
    }

    /// 已跑时长（毫秒，`data-model.md` §2 "时长口径"）：活着的用 `now - startedAt`，
    /// 结束的用 `finishedAt - startedAt`，此后固定不变。
    public func elapsedMilliseconds(now: Double) -> Double {
        let end = finishedAt ?? (isLive ? now : startedAt)
        return max(0, end - startedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, label, owner, status, progress, detail, startedAt, finishedAt
        case output, outputTotal, outputLost
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `id` 是唯一硬要求：没有它这一行无法渲染、无法 kill、无法展开输出。
        id = try container.decode(String.self, forKey: .id)
        kind = (try? container.decode(String.self, forKey: .kind)) ?? "unknown"
        label = (try? container.decode(String.self, forKey: .label)) ?? ""
        owner = try? container.decodeIfPresent(String.self, forKey: .owner)
        status = (try? container.decode(JobStatus.self, forKey: .status)) ?? .unknown("")
        progress = try? container.decodeIfPresent(String.self, forKey: .progress)
        detail = try? container.decodeIfPresent(String.self, forKey: .detail)
        startedAt = (try? container.decode(Double.self, forKey: .startedAt)) ?? 0
        finishedAt = try? container.decodeIfPresent(Double.self, forKey: .finishedAt)
        outputLost = try? container.decodeIfPresent(Bool.self, forKey: .outputLost)

        if let nested = try? container.decodeIfPresent(JobOutput.self, forKey: .output) {
            output = nested
        } else if let total = try? container.decodeIfPresent(Int.self, forKey: .outputTotal) {
            // JobLite：扁平 `outputTotal`，头部是否被丢另由 `outputLost` 说。
            output = JobOutput(total: total)
        } else {
            output = JobOutput(total: 0)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(label, forKey: .label)
        try container.encodeIfPresent(owner, forKey: .owner)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(progress, forKey: .progress)
        try container.encodeIfPresent(detail, forKey: .detail)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(finishedAt, forKey: .finishedAt)
        try container.encode(output, forKey: .output)
        try container.encodeIfPresent(outputLost, forKey: .outputLost)
    }
}

// MARK: - Frames

/// `job/list` 的一帧：整份替换，无自然结束（`host-job-surface.md` §1）。
public struct JobListFrame: Sendable, Hashable {
    public let type: String
    public let jobs: [Job]

    public init(type: String = "rows", jobs: [Job]) {
        self.type = type
        self.jobs = jobs
    }

    /// 单行坏数据被丢掉，其余照常（`tasks.md` T012）。
    public var liveJobs: [Job] { jobs.filter(\.isLive) }
}

extension JobListFrame: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, jobs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? container.decode(String.self, forKey: .type)) ?? "rows"
        jobs = FailableDecodable<Job>.values(in: container, forKey: .jobs)
    }
}

/// `job/follow` 的一帧（`host-job-surface.md` §2）。
///
/// 解不出的帧在 ``DSHClient/jobFollow(sessionId:jobId:from:)`` 里降级成
/// ``unknown(type:raw:)`` 而**不结束流**：输出还在后面，结束流等于让用户以为任务没了。
public enum JobFollowFrame: Sendable, Hashable {
    /// 首帧：任务快照 + 起始字节偏移。
    case opened(job: Job, from: Int)
    case output(chunks: [JobChunk], next: Int, lossy: Bool)
    /// 结算且 ring 抽干后的最后一帧，随后流正常关闭。
    case status(job: Job)
    case unknown(type: String, raw: JSONValue)

    public var job: Job? {
        switch self {
        case .opened(let job, _), .status(let job): return job
        default: return nil
        }
    }
}

extension JobFollowFrame: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, job, from, chunks, next, lossy
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "opened":
            self = .opened(
                job: try container.decode(Job.self, forKey: .job),
                from: (try? container.decode(Int.self, forKey: .from)) ?? 0
            )
        case "output":
            self = .output(
                chunks: FailableDecodable<JobChunk>.values(in: container, forKey: .chunks),
                next: (try? container.decode(Int.self, forKey: .next)) ?? 0,
                lossy: (try? container.decode(Bool.self, forKey: .lossy)) ?? false
            )
        case "status":
            self = .status(job: try container.decode(Job.self, forKey: .job))
        default:
            self = .unknown(type: type, raw: (try? JSONValue(from: decoder)) ?? .null)
        }
    }
}

/// `job/follow` 的一段输出（按字节偏移定位）。
public struct JobChunk: Sendable, Codable, Hashable {
    /// 这段文本在整份输出里的起始字节偏移。
    public let at: Int
    public let text: String
    public let channel: JobChannel?
    /// 与上一段之间丢过一段（输出页必须显式提示）。
    public let gapBefore: Bool?

    public init(at: Int = 0, text: String, channel: JobChannel? = nil, gapBefore: Bool? = nil) {
        self.at = at
        self.text = text
        self.channel = channel
        self.gapBefore = gapBefore
    }

    private enum CodingKeys: String, CodingKey {
        case at, text, channel, gapBefore
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        at = (try? container.decode(Int.self, forKey: .at)) ?? 0
        text = (try? container.decode(String.self, forKey: .text)) ?? ""
        channel = try? container.decodeIfPresent(JobChannel.self, forKey: .channel)
        gapBefore = try? container.decodeIfPresent(Bool.self, forKey: .gapBefore)
    }
}

/// `job/kill` 的回执（`host-job-surface.md` §3）。
///
/// `requested` 只表示"已受理"：行要等名单回流才变，手机不得乐观改状态。
/// `already-finished` 不是错误，是"已经结束了"。
public struct JobKillValue: Sendable, Hashable, Decodable {
    public enum Outcome: Sendable, Hashable {
        case requested
        case alreadyFinished
        case unknown(String)
    }

    public let outcome: Outcome

    public init(outcome: Outcome) {
        self.outcome = outcome
    }

    private enum CodingKeys: String, CodingKey {
        case outcome
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? container.decode(String.self, forKey: .outcome)) ?? ""
        switch raw {
        case "requested": outcome = .requested
        case "already-finished": outcome = .alreadyFinished
        default: outcome = .unknown(raw)
        }
    }
}

/// `subagents/interruptByParent` 的回执（`host-job-surface.md` §5）。
public struct SubagentInterruptValue: Sendable, Hashable, Decodable {
    public let accepted: Bool

    public init(accepted: Bool) {
        self.accepted = accepted
    }

    private enum CodingKeys: String, CodingKey {
        case accepted
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accepted = (try? container.decode(Bool.self, forKey: .accepted)) ?? false
    }
}

// MARK: - Roster

/// `_link/jobRoster` 的一次回答，也是 `link/jobs` 推帧里那"一格"的母型
/// （`contracts/link-job-roster.md` §2 / §3，`data-model.md` §4）。
public struct ActivityRoster: Sendable, Hashable {
    /// 服务端采样时间（毫秒）。乱序保护就用它。
    public let at: Double
    /// 只含**有活的**会话；没活的会话不占位（手机把缺席理解为"没有活"）。
    public let sessions: [String: SessionCell]

    public struct SessionCell: Sendable, Hashable {
        /// 只含 `running` / `stopping`；已结算的不下发。
        public let running: [Job]
        /// 已结算任务计数（面板「已结束 N 个」用）。
        public let settled: Int

        public init(running: [Job], settled: Int) {
            self.running = running
            self.settled = settled
        }

        /// 终态永远不进"在跑"（`data-model.md` §6 不变式 2）。
        public var liveJobs: [Job] { running.filter(\.isLive) }
    }

    public init(at: Double, sessions: [String: SessionCell]) {
        self.at = at
        self.sessions = sessions
    }

    public func cell(_ sessionId: String) -> SessionCell? { sessions[sessionId] }

    public func running(_ sessionId: String) -> [Job] { sessions[sessionId]?.liveJobs ?? [] }

    public static let empty = ActivityRoster(at: 0, sessions: [:])
}

extension ActivityRoster: Decodable {
    private enum CodingKeys: String, CodingKey {
        case at, sessions
    }

    private struct RawCell: Decodable {
        let running: [Job]
        let settled: Int

        private enum CodingKeys: String, CodingKey {
            case running, settled
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            running = FailableDecodable<Job>.values(in: container, forKey: .running)
            settled = (try? container.decode(Int.self, forKey: .settled)) ?? 0
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        at = (try? container.decode(Double.self, forKey: .at)) ?? 0
        // `sessions` 是**必填**：缺了它与"空名单"不是一回事。解成 `[:]` 会让手机把
        // "这次读不出名单"显示成"没有活"，正是 `link-job-roster.md` §4 不变式 3 禁止的
        // 那种降级。解不出就抛，由调用方整块隐藏（`ActivityModel.refresh`）。
        let raw = try container.decode([String: RawCell].self, forKey: .sessions)
        sessions = raw.mapValues { SessionCell(running: $0.running, settled: $0.settled) }
    }
}

// MARK: - Push frame

/// `link/jobs` 推帧的 `value`（只描述**一个会话**那一格，语义是整份替换）。
///
/// 它走在现有 per-device `$events` 流上，App 侧的 `HostEventHub` 会把整条帧
/// 记为 `.unknown(type: "link/jobs", raw: …)`；把 `raw["value"]` 交给
/// `JSONDecoder`/`JSONValue.decoded(as:)` 就是这一型。
public struct LinkJobsFrame: Sendable, Hashable {
    public let at: Double
    public let sessionId: String
    public let running: [Job]
    public let settled: Int

    public init(at: Double, sessionId: String, running: [Job], settled: Int) {
        self.at = at
        self.sessionId = sessionId
        self.running = running
        self.settled = settled
    }

    /// 线上帧的类型名（`contracts/link-job-roster.md` §3）。
    public static let frameType = "link/jobs"

    /// 这一格里"在跑"的任务（终态过滤）。
    public var liveJobs: [Job] { running.filter(\.isLive) }
}

extension LinkJobsFrame: Decodable {
    private enum CodingKeys: String, CodingKey {
        case at, sessionId, running, settled
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        at = (try? container.decode(Double.self, forKey: .at)) ?? 0
        sessionId = try container.decode(String.self, forKey: .sessionId)
        running = FailableDecodable<Job>.values(in: container, forKey: .running)
        settled = (try? container.decode(Int.self, forKey: .settled)) ?? 0
    }
}

// MARK: - Request bodies

/// `job/list` 的 `request`（`host-job-surface.md` §1）。
struct JobListRequest: Encodable, Sendable {
    let sessionId: String
}

/// `job/follow` 的 `request`（`host-job-surface.md` §2）。
///
/// `sessionId` 对 unowned 任务可以省；`from` 省略表示"从宿主保留的最老字节开始"。
struct JobFollowRequest: Encodable, Sendable {
    let sessionId: String?
    let jobId: String
    let from: Int?

    init(sessionId: String? = nil, jobId: String, from: Int? = nil) {
        self.sessionId = sessionId
        self.jobId = jobId
        self.from = from
    }
}

/// `job/kill` 的 `request`（`host-job-surface.md` §3）。
struct JobKillRequest: Encodable, Sendable {
    let sessionId: String
    let jobId: String
}

/// `subagents/interruptByParent` 的**扁平**参数（没有 `request` 信封）。
///
/// `mode` 在宿主 schema 里是字面量 `continuable`（`dsh-api-remotes`），一次性
/// 子智能体用不了这个端点，所以手机侧不开放 `mode` 参数。
struct SubagentInterruptRequest: Encodable, Sendable, Hashable {
    let childSessionId: String
    let parentSessionId: String
    let mode: String

    init(childSessionId: String, parentSessionId: String) {
        self.childSessionId = childSessionId
        self.parentSessionId = parentSessionId
        self.mode = "continuable"
    }
}

// MARK: - Lossy element decoding

/// 逐个元素"能解就留、解不出就丢"的 Decodable 包装。
///
/// 名单里一行坏数据不该让整份名单消失（`tasks.md` T012："Decoder 容忍未知字段与
/// '单行坏数据'"）；这也让连接器与宿主各版本上新加的字段天然被忽略。
struct FailableDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }

    static func values<Key: CodingKey>(
        in container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) -> [Value] {
        let wrappers = (try? container.decode([FailableDecodable<Value>].self, forKey: key)) ?? []
        return wrappers.compactMap(\.value)
    }
}
