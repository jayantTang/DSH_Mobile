#if DEBUG
import DSHKit
import Foundation

/// DEBUG-only deterministic transcript for the process-fold UI cases.
///
/// The UI cases must not depend on the agent choosing to call a tool, so the
/// `-DSHProbeProcessFoldFixture` launch argument swaps a real session's
/// transcript for these records before any live stream starts. Production
/// builds do not contain this type.
///
/// 变体由第二个启动参数选：`-DSHProbeProcessFoldVariant failure` 造「失败 + 中断」
/// 两轮（设计 `20261025-过程折叠-对齐桌面` §M5），不带参数是两条已完成轮次。
/// 每条事件都带 `time`（宿主口径：epoch 毫秒），轮次行才有真实的「已完成，用时 N秒」。
enum ProcessFoldFixture {

    enum Variant: String {
        /// 两条已完成、带时长的轮次：收起态与两级展开用。
        case completed
        /// 一条已完成 + 一条失败（error）+ 一条被中断（interrupted）：失败/停止用。
        case failure
        /// 一轮开着、bash 正在跑（没有 turn/end、没有结果）：运行中分组行用。
        case running
        /// 一轮被取消：概要里那条 bash 还标着 running，turn/end 写 aborted。
        /// 用来核对「没回来的工具归 error、分组行文案静态」。
        case cancelled
        /// 一轮以 max-steps 结束、带时长：按正常完成处理。
        case maxSteps = "max-steps"
    }

    static var variant: Variant {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DSHProbeProcessFoldVariant"),
              index + 1 < arguments.count,
              let value = Variant(rawValue: arguments[index + 1])
        else { return .completed }
        return value
    }

    static var records: [SessionRecord] { events(for: variant).map(Self.record) }

    // MARK: - 变体

    private static func events(for variant: Variant) -> [[String: JSONValue]] {
        switch variant {
        case .completed: return completedEvents()
        case .failure: return failureEvents()
        case .running: return runningEvents()
        case .cancelled: return cancelledEvents()
        case .maxSteps: return maxStepsEvents()
        }
    }

    /// 被取消的一轮：概要里 bash 仍是 `running`，轮次以 aborted 收尾。
    ///
    /// 期望的显示：轮次行「已停止」常开、无箭头；分组行写静态的「执行了命令」，
    /// 不再出现「正在分析请求」；组展开后那张 bash 卡片是 error（没回来的工具）。
    private static func cancelledEvents() -> [[String: JSONValue]] {
        var builder = Builder(start: 1_760_000_000_000)
        let base = builder.start


        builder.append("turn/start", ["turn": .int(1)], at: base)
        builder.append("user/message", userData(id: "fixture-user-cancelled",
                                               text: "Run the long command"),
                       at: base + 400)
        builder.append("+link/fold", [
            "v": .int(2), "turn": .int(1), "startSeq": .int(2), "endSeq": .int(2),
            "durationMs": .null, "endReason": .string("aborted"),
            "activities": .object(["commands": .int(1)]),
            "groups": .array([
                .object([
                    "startSeq": .int(2), "endSeq": .int(2),
                    "activities": .object(["commands": .int(1)]),
                    "steps": .array([
                        .object(["seq": .int(2), "kind": .string("tools"), "name": .string("bash"),
                                 "preview": .string("sleep 300"), "status": .string("running")]),
                    ]),
                ]),
            ]),
        ], at: base + 2_000)
        builder.append("turn/end", ["turn": .int(1),
                                    "reason": .object(["kind": .string("aborted")])],
                       at: base + 30_000)
        return builder.events
    }

    /// max-steps 收尾：按正常完成处理，有 12 秒用时。
    private static func maxStepsEvents() -> [[String: JSONValue]] {
        var builder = Builder(start: 1_760_000_000_000)
        let base = builder.start


        builder.append("turn/start", ["turn": .int(1)], at: base)
        builder.append("user/message", userData(id: "fixture-user-max",
                                               text: "Keep going until the limit"),
                       at: base + 400)
        builder.append("tool/call", toolData(turn: 1, step: 1, callId: "fixture-max",
                                             name: "bash",
                                             arguments: "{\"command\":\"swift test\"}"),
                       at: base + 1_200)
        builder.append("tool/result", resultData(turn: 1, step: 1, callId: "fixture-max",
                                                 text: "All tests passed"),
                       at: base + 2_000)
        builder.append("assistant/message", assistantData(turn: 1, step: 2,
                                                          text: "FIXTURE-MAX-ANSWER"),
                       at: base + 3_000)
        builder.append("turn/end", ["turn": .int(1),
                                    "reason": .object(["kind": .string("max-steps")])],
                       at: base + 12_000)
        return builder.events
    }



    /// 运行中：一轮开着、bash 已发出但没有结果，也没有 turn/end。
    ///
    /// 这条夹具只造「运行中」这一屏（不需要真的等模型跑工具）。注意
    /// `Timeline.reset` 会把"快照里的工具调用"一律判成已结束（历史不是实时流），
    /// 所以当前动作只能从概要 v2 的 `status: "running"` 步骤来——这里补一条
    /// `+link/fold` v2 记录，视图据此写「正在运行命令 · <命令>」。
    private static func runningEvents() -> [[String: JSONValue]] {
        var builder = Builder(start: 1_760_000_000_000)
        let base = builder.start


        builder.append("turn/start", ["turn": .int(1)], at: base)
        builder.append("user/message", userData(id: "fixture-user-running",
                                               text: "Use bash to sleep twice and then answer"),
                       at: base + 400)
        builder.append("+link/fold", [
            "v": .int(2),
            "turn": .int(1),
            "startSeq": .int(2),
            "endSeq": .int(2),
            "durationMs": .null,
            "endReason": .null,
            "activities": .object(["commands": .int(1)]),
            "groups": .array([
                .object([
                    "startSeq": .int(2),
                    "endSeq": .int(2),
                    "activities": .object(["commands": .int(1)]),
                    "steps": .array([
                        .object([
                            "seq": .int(2),
                            "kind": .string("tools"),
                            "name": .string("bash"),
                            "preview": .string("sleep 30 && sleep 30"),
                            "status": .string("running"),
                        ]),
                    ]),
                ]),
            ]),
        ], at: base + 1_400)
        return builder.events
    }

    /// 已完成：第一轮 18 秒（read → bash → bash），第二轮 42 秒（grep）。
    private static func completedEvents() -> [[String: JSONValue]] {
        var builder = Builder(start: 1_760_000_000_000)
        let base = builder.start


        builder.append("turn/start", ["turn": .int(1)], at: base)
        builder.append("user/message", userData(id: "fixture-user-1",
                                               text: "Inspect the build and run two commands"),
                       at: base + 400)
        builder.append("tool/call", toolData(turn: 1, step: 1, callId: "fixture-read",
                                             name: "read",
                                             arguments: "{\"path\":\"Package.swift\"}"),
                       at: base + 1_200)
        builder.append("tool/result", resultData(turn: 1, step: 1, callId: "fixture-read",
                                                 text: "FIXTURE-TOOL-OUTPUT"),
                       at: base + 2_000)
        builder.append("assistant/message",
                       assistantData(turn: 1, step: 2,
                                     reasoning: "Check the package first, then run commands"),
                       at: base + 3_000)
        builder.append("tool/call", toolData(turn: 1, step: 2, callId: "fixture-bash-1",
                                             name: "bash",
                                             arguments: "{\"command\":\"swift build\"}"),
                       at: base + 5_000)
        builder.append("tool/result", resultData(turn: 1, step: 2, callId: "fixture-bash-1",
                                                 text: "Build complete"),
                       at: base + 6_400)
        builder.append("assistant/message",
                       assistantData(turn: 1, step: 3,
                                     text: "Read the first result, then run the second command"),
                       at: base + 7_200)
        builder.append("tool/call", toolData(turn: 1, step: 3, callId: "fixture-bash-2",
                                             name: "bash",
                                             arguments: "{\"command\":\"swift test\"}"),
                       at: base + 9_000)
        builder.append("tool/result", resultData(turn: 1, step: 3, callId: "fixture-bash-2",
                                                 text: "All tests passed"),
                       at: base + 10_800)
        builder.append("assistant/message", assistantData(turn: 1, step: 4,
                                                          text: "FIXTURE-ANSWER done"),
                       at: base + 12_000)
        builder.append("turn/end", ["turn": .int(1),
                                    "reason": .object(["kind": .string("completed")])],
                       at: base + 18_000)

        builder.append("turn/start", ["turn": .int(2)], at: base + 20_000)
        builder.append("user/message", userData(id: "fixture-user-2", text: "Confirm once more"),
                       at: base + 20_400)
        builder.append("tool/call", toolData(turn: 2, step: 1, callId: "fixture-grep",
                                             name: "grep",
                                             arguments: "{\"pattern\":\"FIXTURE\"}"),
                       at: base + 22_000)
        builder.append("tool/result", resultData(turn: 2, step: 1, callId: "fixture-grep",
                                                 text: "FIXTURE-TOOL-OUTPUT"),
                       at: base + 24_000)
        builder.append("assistant/message", assistantData(turn: 2, step: 2,
                                                          text: "FIXTURE-ANSWER 2"),
                       at: base + 25_000)
        builder.append("turn/end", ["turn": .int(2),
                                    "reason": .object(["kind": .string("completed")])],
                       at: base + 62_000)
        return builder.events
    }

    /// 失败与中断：与正常完成同一套折叠的是 error；interrupted 常开、无箭头。
    private static func failureEvents() -> [[String: JSONValue]] {
        var builder = Builder(start: 1_760_000_000_000)
        let base = builder.start


        builder.append("turn/start", ["turn": .int(1)], at: base)
        builder.append("user/message", userData(id: "fixture-user-1", text: "Build it"),
                       at: base + 400)
        builder.append("tool/call", toolData(turn: 1, step: 1, callId: "fixture-bash",
                                             name: "bash",
                                             arguments: "{\"command\":\"swift build\"}"),
                       at: base + 1_200)
        builder.append("tool/result", resultData(turn: 1, step: 1, callId: "fixture-bash",
                                                 text: "Build complete"),
                       at: base + 2_000)
        builder.append("assistant/message", assistantData(turn: 1, step: 2,
                                                          text: "FIXTURE-ANSWER 1"),
                       at: base + 3_000)
        builder.append("turn/end", ["turn": .int(1),
                                    "reason": .object(["kind": .string("completed")])],
                       at: base + 9_000)

        builder.append("turn/start", ["turn": .int(2)], at: base + 20_000)
        builder.append("user/message", userData(id: "fixture-user-2",
                                               text: "Run the check that fails"),
                       at: base + 20_400)
        builder.append("tool/call", toolData(turn: 2, step: 1, callId: "fixture-fail",
                                             name: "bash",
                                             arguments: "{\"command\":\"npm test\"}"),
                       at: base + 21_000)
        builder.append("tool/result", resultData(turn: 2, step: 1, callId: "fixture-fail",
                                                 text: "Command failed with exit code 1",
                                                 isError: true),
                       at: base + 22_000)
        builder.append("turn/end", ["turn": .int(2),
                                    "reason": .object(["kind": .string("error")])],
                       at: base + 25_000)

        builder.append("turn/start", ["turn": .int(3)], at: base + 40_000)
        builder.append("user/message", userData(id: "fixture-user-3", text: "Stop this one"),
                       at: base + 40_400)
        builder.append("tool/call", toolData(turn: 3, step: 1, callId: "fixture-read-3",
                                             name: "read",
                                             arguments: "{\"path\":\"Package.swift\"}"),
                       at: base + 41_000)
        builder.append("tool/result", resultData(turn: 3, step: 1, callId: "fixture-read-3",
                                                 text: "FIXTURE-TOOL-OUTPUT"),
                       at: base + 42_000)
        builder.append("assistant/message", assistantData(turn: 3, step: 2,
                                                          text: "FIXTURE-ANSWER 3"),
                       at: base + 43_000)
        builder.append("turn/end", ["turn": .int(3),
                                    "reason": .object(["kind": .string("interrupted")])],
                       at: base + 50_000)
        return builder.events
    }

    // MARK: - 构造

    private struct Builder {
        let start: Double
        private(set) var events: [[String: JSONValue]] = []
        /// 从 0 开始：第一条 **内容行** 的 seq 必须是 1，才不会让「向上翻页」的游标
        /// 判成"还有更早"（`cursor > 1` 才发请求）。以前从 1 起、turn/start 占掉 1，
        /// 第一条内容行就成了 2 → 夹具会话被问一页更早的记录 → 空页 → 顶上多一条
        /// 「读取更早的记录失败，点按重试」胶囊（与夹具无关）。
        private var seq = 0

        init(start: Double) { self.start = start }

        mutating func append(_ type: String, _ data: [String: JSONValue], at time: Double) {
            events.append(["type": .string(type), "seq": .int(seq), "time": .double(time),
                           "data": .object(data)])
            seq += 1
        }
    }

    private static func userData(id: String, text: String) -> [String: JSONValue] {
        ["id": .string(id),
         "source": .object(["kind": .string("user")]),
         "content": .array([.object(["type": .string("text"), "text": .string(text)])])]
    }

    private static func record(_ object: [String: JSONValue]) -> SessionRecord {
        let data = try! JSONEncoder().encode(JSONValue.object(object))
        let event = try! JSONDecoder().decode(SessionEvent.self, from: data)
        return SessionRecord(event: event)
    }

    private static func toolData(turn: Int, step: Int, callId: String,
                                 name: String, arguments: String) -> [String: JSONValue] {
        ["turn": .int(turn), "step": .int(step), "callId": .string(callId),
         "name": .string(name), "arguments": .string(arguments)]
    }

    private static func resultData(turn: Int, step: Int, callId: String,
                                   text: String, isError: Bool = false) -> [String: JSONValue] {
        ["turn": .int(turn), "step": .int(step),
         "message": .object([
            "source": .object(["callId": .string(callId)]),
            "content": .array([
                .object([
                    "type": .string("tool-result"),
                    "toolCallId": .string(callId),
                    "isError": .bool(isError),
                    "content": .array([
                        .object(["type": .string("text"), "text": .string(text)]),
                    ]),
                ]),
            ]),
         ])]
    }

    private static func assistantData(turn: Int, step: Int,
                                      text: String? = nil,
                                      reasoning: String? = nil) -> [String: JSONValue] {
        var blocks: [JSONValue] = []
        if let reasoning {
            blocks.append(.object(["type": .string("reasoning"), "text": .string(reasoning)]))
        }
        if let text {
            blocks.append(.object(["type": .string("text"), "text": .string(text)]))
        }
        return ["turn": .int(turn), "step": .int(step),
                "message": .object(["content": .array(blocks)])]
    }
}
#endif
