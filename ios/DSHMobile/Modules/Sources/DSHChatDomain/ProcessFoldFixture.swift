#if DEBUG
import DSHKit
import Foundation

/// DEBUG-only deterministic transcript for the process-fold UI cases.
///
/// The UI cases must not depend on the agent choosing to call a tool, so the
/// `-DSHProbeProcessFoldFixture` launch argument swaps a real session's
/// transcript for these records before any live stream starts. Production
/// builds do not contain this type.
enum ProcessFoldFixture {

    static var records: [SessionRecord] { fixture.map(Self.record) }

    private static var fixture: [[String: JSONValue]] {
        var events: [[String: JSONValue]] = []
        var seq = 1
        func append(_ type: String, _ data: [String: JSONValue]) {
            events.append(["type": .string(type), "seq": .int(seq),
                           "data": .object(data)])
            seq += 1
        }

        append("turn/start", ["turn": .int(1)])
        append("user/message", [
            "id": .string("fixture-user-1"),
            "source": .object(["kind": .string("user")]),
            "content": .array([.object(["type": .string("text"),
                                       "text": .string("Inspect the build and run two commands")])]),
        ])
        append("tool/call", toolData(turn: 1, step: 1, callId: "fixture-read",
                                     name: "read", arguments: "{\"path\":\"Package.swift\"}"))
        append("tool/result", resultData(turn: 1, step: 1, callId: "fixture-read",
                                         text: "FIXTURE-TOOL-OUTPUT"))
        append("assistant/message", assistantData(turn: 1, step: 2,
                                                  reasoning: "Check the package first, then run commands"))
        append("tool/call", toolData(turn: 1, step: 2, callId: "fixture-bash-1",
                                     name: "bash", arguments: "{\"command\":\"swift build\"}"))
        append("tool/result", resultData(turn: 1, step: 2, callId: "fixture-bash-1",
                                         text: "Build complete"))
        append("assistant/message", assistantData(turn: 1, step: 3,
                                                  text: "Read the first result, then run the second command"))
        append("tool/call", toolData(turn: 1, step: 3, callId: "fixture-bash-2",
                                     name: "bash", arguments: "{\"command\":\"swift test\"}"))
        append("tool/result", resultData(turn: 1, step: 3, callId: "fixture-bash-2",
                                         text: "All tests passed"))
        append("assistant/message", assistantData(turn: 1, step: 4,
                                                  text: "FIXTURE-ANSWER done"))
        append("turn/end", ["turn": .int(1),
                            "reason": .object(["kind": .string("completed")])])

        append("turn/start", ["turn": .int(2)])
        append("user/message", [
            "id": .string("fixture-user-2"),
            "source": .object(["kind": .string("user")]),
            "content": .array([.object(["type": .string("text"),
                                       "text": .string("Confirm once more")])]),
        ])
        append("tool/call", toolData(turn: 2, step: 1, callId: "fixture-grep",
                                     name: "grep", arguments: "{\"pattern\":\"FIXTURE\"}"))
        append("tool/result", resultData(turn: 2, step: 1, callId: "fixture-grep",
                                         text: "FIXTURE-TOOL-OUTPUT"))
        append("assistant/message", assistantData(turn: 2, step: 2,
                                                  text: "FIXTURE-ANSWER 2"))
        append("turn/end", ["turn": .int(2),
                            "reason": .object(["kind": .string("completed")])])
        return events
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
                                   text: String) -> [String: JSONValue] {
        ["turn": .int(turn), "step": .int(step),
         "message": .object([
            "source": .object(["callId": .string(callId)]),
            "content": .array([
                .object([
                    "type": .string("tool-result"),
                    "toolCallId": .string(callId),
                    "isError": .bool(false),
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
