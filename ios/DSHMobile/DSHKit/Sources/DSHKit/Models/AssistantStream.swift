import Foundation

/// One frame of the host's process-local assistant stream.
///
/// These frames are what make live token-by-token output visible before the
/// assistant message is committed to the durable journal. They are opt-in per
/// follow stream (`assistantStream: true`) and are advisory: the committed
/// `assistant/message` event always supersedes them.
public enum AssistantStreamFrame: Sendable {
    case start(attemptId: String, revision: Int, turn: Int, step: Int, startedAfterSeq: Int)
    case chunk(attemptId: String, revision: Int, index: Int, time: Date?, chunk: AssistantChunk)
    case end(attemptId: String, revision: Int, index: Int, committedSeq: Int?)
    case unknown(type: String, raw: JSONValue)
}

/// One decoded streaming delta.
public enum AssistantChunk: Sendable {
    case textDelta(String)
    case reasoningDelta(String)
    case toolCallDelta(id: String, name: String?, index: Int, argumentsDelta: String)
    case other(type: String, raw: JSONValue)

    /// The text this chunk contributes, when it contributes any.
    public var text: String? {
        switch self {
        case .textDelta(let text), .reasoningDelta(let text): return text
        case .toolCallDelta(_, _, _, let delta): return delta.isEmpty ? nil : delta
        case .other: return nil
        }
    }
}

extension AssistantStreamFrame: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, attemptId, revision, turn, step, startedAfterSeq, index, time, chunk, outcome
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = (try? container.decode(String.self, forKey: .type)) ?? "unknown"
        let attemptId = (try? container.decode(String.self, forKey: .attemptId)) ?? ""
        let revision = (try? container.decode(Int.self, forKey: .revision)) ?? 0

        switch type {
        case "start":
            self = .start(
                attemptId: attemptId,
                revision: revision,
                turn: (try? container.decode(Int.self, forKey: .turn)) ?? 0,
                step: (try? container.decode(Int.self, forKey: .step)) ?? 0,
                startedAfterSeq: (try? container.decode(Int.self, forKey: .startedAfterSeq)) ?? -1
            )
        case "chunk":
            let millis = (try? container.decode(Double.self, forKey: .time)) ?? 0
            let raw = (try? container.decode(JSONValue.self, forKey: .chunk)) ?? .null
            self = .chunk(
                attemptId: attemptId,
                revision: revision,
                index: (try? container.decode(Int.self, forKey: .index)) ?? 0,
                time: millis > 0 ? Date(timeIntervalSince1970: millis / 1000) : nil,
                chunk: AssistantChunk.decode(raw)
            )
        case "end":
            var committed: Int?
            if let outcome = try? container.decode(Outcome.self, forKey: .outcome),
               outcome.kind == "committed" {
                committed = outcome.seq
            }
            self = .end(
                attemptId: attemptId,
                revision: revision,
                index: (try? container.decode(Int.self, forKey: .index)) ?? 0,
                committedSeq: committed
            )
        default:
            self = .unknown(type: type, raw: (try? JSONValue(from: decoder)) ?? .null)
        }
    }

    private struct Outcome: Decodable {
        let kind: String
        let seq: Int?
    }
}

extension AssistantChunk {
    /// Decodes one streaming delta from its opaque wire value.
    static func decode(_ value: JSONValue) -> AssistantChunk {
        let type = value["type"]?.stringValue ?? "unknown"
        switch type {
        case "text-delta":
            return .textDelta(value["text"]?.stringValue ?? "")
        case "reasoning-delta":
            return .reasoningDelta(value["text"]?.stringValue ?? "")
        case "tool-call-delta":
            return .toolCallDelta(
                id: value["id"]?.stringValue ?? "",
                name: value["name"]?.stringValue,
                index: value["index"]?.intValue ?? 0,
                argumentsDelta: value["argumentsDelta"]?.stringValue ?? ""
            )
        default:
            return .other(type: type, raw: value)
        }
    }
}
