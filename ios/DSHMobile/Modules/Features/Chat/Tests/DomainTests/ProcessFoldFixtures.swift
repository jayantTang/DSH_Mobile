import DSHKit
import Foundation

/// JSON fixtures that go through the real decoder, so the fold is exercised on
/// the same event shapes the host sends.
enum ProcessFoldFixtures {
    static func record(_ object: [String: JSONValue]) throws -> SessionRecord {
        let data = try JSONEncoder().encode(JSONValue.object(object))
        return SessionRecord(event: try JSONDecoder().decode(SessionEvent.self, from: data))
    }

    static func timeline(_ events: [[String: JSONValue]]) throws -> ChatTimeline {
        var timeline = ChatTimeline()
        for event in events {
            _ = timeline.apply(try record(event).event)
        }
        return timeline
    }

    static func turnStart(seq: Int, turn: Int) -> [String: JSONValue] {
        ["type": .string("turn/start"), "seq": .int(seq),
         "data": .object(["turn": .int(turn)])]
    }

    static func user(seq: Int, text: String, turn: Int = 1,
                     isSteering: Bool = false, sourceKind: String = "user") -> [String: JSONValue] {
        var data: [String: JSONValue] = [
            "id": .string("message-\(seq)"),
            "source": .object(["kind": .string(sourceKind)]),
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
        ]
        if isSteering { data["steering"] = .bool(true) }
        return ["type": .string("user/message"), "seq": .int(seq), "data": .object(data)]
    }


    static func steering(seq: Int, text: String) -> [String: JSONValue] {
        ["type": .string("agent/inbox/spliced"), "seq": .int(seq),
         "data": .object([
            "target": .string("next-step"),
            "inserted": .array([
                .object([
                    "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                    "source": .object(["kind": .string("user"), "rpcId": .string("steer-\(seq)")]),
                ]),
            ]),
         ])]
    }

    static func assistant(seq: Int, text: String? = nil, reasoning: String? = nil,
                          turn: Int = 1, step: Int = 1) -> [String: JSONValue] {
        var blocks: [JSONValue] = []
        if let reasoning {
            blocks.append(.object(["type": .string("reasoning"), "text": .string(reasoning)]))
        }
        if let text {
            blocks.append(.object(["type": .string("text"), "text": .string(text)]))
        }
        return ["type": .string("assistant/message"), "seq": .int(seq),
                "data": .object([
                    "turn": .int(turn), "step": .int(step),
                    "message": .object(["content": .array(blocks)]),
                ])]
    }

    static func toolCall(seq: Int, callId: String, name: String,
                         turn: Int = 1, step: Int = 1,
                         arguments: String = "{}") -> [String: JSONValue] {
        ["type": .string("tool/call"), "seq": .int(seq),
         "data": .object([
            "turn": .int(turn), "step": .int(step),
            "callId": .string(callId), "name": .string(name), "arguments": .string(arguments),
         ])]
    }

    static func toolResult(seq: Int, callId: String, text: String = "ok",
                           isError: Bool = false, turn: Int = 1,
                           step: Int = 1) -> [String: JSONValue] {
        ["type": .string("tool/result"), "seq": .int(seq),
         "data": .object([
            "turn": .int(turn), "step": .int(step),
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
            ]),
         ])]
    }

    static func notice(seq: Int, text: String, isError: Bool = false) -> [String: JSONValue] {
        ["type": .string(isError ? "agent/error" : "compaction/end"),
         "seq": .int(seq),
         "data": .object(isError ? ["message": .string(text)] : [:])]
    }

    static func turnEnd(seq: Int, turn: Int = 1, reason: String = "completed") -> [String: JSONValue] {
        ["type": .string("turn/end"), "seq": .int(seq),
         "data": .object(["turn": .int(turn), "reason": .object(["kind": .string(reason)])])]
    }

    /// A completed turn with `tools` calls and `reasoning` thinking blocks.
    static func completedTurn(turn: Int, startSeq: Int, tools: Int,
                              reasoning: Int = 1,
                              intermediate: Bool = false) -> [[String: JSONValue]] {
        var events: [[String: JSONValue]] = [
            turnStart(seq: startSeq, turn: turn),
            user(seq: startSeq + 1, text: "question \(turn)", turn: turn),
        ]
        var seq = startSeq + 2
        for index in 0..<tools {
            if reasoning > 0, index < reasoning {
                events.append(assistant(seq: seq, reasoning: "think \(index)", turn: turn, step: index + 1))
                seq += 1
            }
            let callId = "call-\(turn)-\(index)"
            events.append(toolCall(seq: seq, callId: callId, name: index.isMultiple(of: 2) ? "read" : "bash",
                                   turn: turn, step: index + 1))
            seq += 1
            events.append(toolResult(seq: seq, callId: callId, turn: turn, step: index + 1))
            seq += 1
            if intermediate, index == tools / 2 {
                events.append(assistant(seq: seq, text: "still working \(turn)", turn: turn, step: index + 1))
                seq += 1
            }
        }
        events.append(assistant(seq: seq, text: "answer \(turn)", turn: turn, step: tools + 1))
        seq += 1
        events.append(turnEnd(seq: seq, turn: turn))
        return events
    }
}
