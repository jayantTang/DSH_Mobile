import Foundation

/// DEBUG 夹具：一份**确定性的**活动名单，供单测与将来的 UI 用例共用
/// （`specs/018-mobile-activity-visibility/contracts/activity-ui.md` §8）。
///
/// 它只是纯数据：不解析启动参数、不碰网络、不影响产品路径。App 侧的
/// `-DSHActivityFixture canned` 钩子决定要不要用它，DSHKit 不认任何参数。
///
/// 内容（与 §8 逐项对应）：
/// - 父会话 `session-fixture-parent`：1 个在跑任务 `bash-fixture-1`、`settled: 3`、
///   两个在跑的子会话 `sub-fixture-continuable` / `sub-fixture-oneshot`；
/// - 另一个未打开的会话 `session-fixture-other`：1 个在跑任务 `bash-fixture-2`。
///
/// id 是契约的一部分，用例直接按字符串断言；改 id 等于改用例。
public enum ActivityFixture {

    public static let parentSessionId = "session-fixture-parent"
    public static let otherSessionId = "session-fixture-other"
    public static let jobId = "bash-fixture-1"
    public static let otherJobId = "bash-fixture-2"
    public static let continuableChildId = "sub-fixture-continuable"
    public static let oneShotChildId = "sub-fixture-oneshot"
    public static let jobLabel = "npm run lane:l1 -- run --scenario smoke"
    public static let settledCount = 3

    /// 夹具的一份完整输入：能力位 + 名单 + 会话行。
    public struct Content: Sendable {
        public let capabilities: Set<String>
        public let roster: ActivityRoster
        public let sessions: [SessionSummary]
        /// 展开「查看输出」时给的那三段（第二段带一次 `gapBefore`，用于断言"丢了一段"提示）。
        public let output: [JobChunk]

        /// 按顺序喂给状态机的三组输入。
        public var inputs: [ActivityStore.Input] {
            [.capabilities(capabilities), .roster(roster), .sessions(sessions)]
        }

        /// 已吃下这份夹具的状态机（用例与 UI 的便捷入口）。
        public func applied() -> ActivityStore {
            var store = ActivityStore()
            store.apply(inputs)
            return store
        }
    }

    /// 夹具的默认起跑时刻（毫秒）：3 分钟前。
    ///
    /// 曾经取"进程启动时刻"，在开机很久的机器上会算出几百小时（模拟器核对时出现 249:45:38），
    /// 看起来像数据坏了。3 分钟既能让"已跑时长"跳，又落在合理区间。
    static var processStartedAt: Double {
        Date().timeIntervalSince1970 * 1000 - 180_000
    }

    /// 取夹具。
    ///
    /// - Parameters:
    ///   - startedAt: 任务的起跑时刻，默认取进程启动时刻。
    ///   - at: 名单采样时刻，默认取当前时刻。两者都显式给时整份夹具完全确定。
    /// - Parameter parentSessionId: 把夹具挂到哪个会话上。默认是夹具自己的固定 id；
    ///   UI 用例要开一个**真实存在**的（临时）会话时，把它传进来，面板才有内容可点。
    public static func canned(
        startedAt: Double = Date().timeIntervalSince1970 * 1000 - 180_000,  // = `processStartedAt`
        at: Double = Date().timeIntervalSince1970 * 1000,
        parentSessionId: String = ActivityFixture.parentSessionId
    ) -> Content {
        // 不直接用 `Int(Double)`：NaN / 无穷 / 溢出会 trap（`npm run check:traps` 会拦）。
        let start = milliseconds(startedAt)
        let sampled = milliseconds(at)

        let rosterJSON = """
        {"at": \(sampled),
         "sessions": {
           "\(parentSessionId)": {
             "running": [
               {"id": "\(jobId)", "kind": "bash", "label": "\(jobLabel)",
                "status": "running", "startedAt": \(start), "outputTotal": 0,
                "owner": "\(parentSessionId)"}
             ],
             "settled": \(settledCount)
           },
           "\(otherSessionId)": {
             "running": [
               {"id": "\(otherJobId)", "kind": "bash", "label": "tail -f logs/dev.log",
                "status": "running", "startedAt": \(start), "outputTotal": 0,
                "owner": "\(otherSessionId)"}
             ],
             "settled": 0
           }
         }}
        """

        let sessionsJSON = """
        {"items": [
          {"sessionId": "\(parentSessionId)", "updatedAt": \(sampled), "running": false,
           "blank": false, "agentAvailable": true,
           "projections": {"asOfSeq": 1, "values": {}}},
          {"sessionId": "\(continuableChildId)", "updatedAt": \(sampled), "running": true,
           "blank": false, "parentSessionId": "\(parentSessionId)", "origin": "subagent",
           "agentAvailable": true,
           "projections": {"asOfSeq": 1, "values": {
             "subagent": {"mode": "continuable", "label": "审查 018 的界面契约", "seq": 1},
             "subagentTiming": {"active": {"since": \(start)}}}}},
          {"sessionId": "\(oneShotChildId)", "updatedAt": \(sampled), "running": true,
           "blank": false, "parentSessionId": "\(parentSessionId)", "origin": "subagent",
           "agentAvailable": true,
           "projections": {"asOfSeq": 1, "values": {
             "subagent": {"mode": "one-shot", "label": "跑一遍 swift test", "seq": 2},
             "subagentTiming": {"active": {"since": \(start)}}}}}
        ]}
        """

        let roster = decode(ActivityRoster.self, rosterJSON, what: "roster") ?? .empty
        let sessions = decode(SessionListValue.self, sessionsJSON, what: "sessions")?.items ?? []

        return Content(
            capabilities: [LinkHandshake.Capability.events, LinkHandshake.Capability.jobsRoster],
            roster: roster,
            sessions: sessions,
            output: [
                JobChunk(at: 0, text: "lane l1 · 第 1 段\n", channel: .stdout),
                JobChunk(at: 16, text: "（中间丢了一段）\n", channel: .stderr, gapBefore: true),
                JobChunk(at: 32, text: "pass 2 · fail 0\n", channel: .stdout),
            ]
        )
    }

    /// 夹具是常量数据：解不出来就是写错了。这里**不 trap**（`npm run check:traps` 禁止
    /// `assertionFailure`）：解不出就返回 nil，用它的用例会在自己的断言里立刻暴露，
    /// Release 里退化成空数据而不是崩溃——这条路径不参与产品行为。
    private static func decode<T: Decodable>(_ type: T.Type, _ json: String, what: String) -> T? {
        _ = what
        return try? JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    /// 毫秒取整：非有限值、负数或超出 `Int` 范围时退回 0。
    ///
    /// 用 `Int(exactly:)` 而不是 `Int(_:)`：越界与 NaN 都返回 nil，不 trap
    /// （`npm run check:traps` 的 R5 就是拦 `Int(Double)`）。
    private static func milliseconds(_ value: Double) -> Int {
        guard value.isFinite, value >= 0 else { return 0 }
        return Int(exactly: value.rounded()) ?? 0
    }
}
