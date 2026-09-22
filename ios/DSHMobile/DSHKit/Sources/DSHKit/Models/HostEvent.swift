import Foundation

/// A notification delivered on the forwarded host event stream.
///
/// DSH distinguishes two forms. `emit` is fire-and-forget. `waterfall` is a
/// pending invocation: the host is blocked until *some* client answers it, so a
/// waterfall left unanswered visibly stalls the desktop session. Answering it
/// from the phone is the single most valuable thing a mobile client does.
public enum HostEvent: Sendable {
    case ready(clientId: String, home: String)
    case emit(event: String, args: [JSONValue])
    case waterfall(Waterfall)
    case cancelled(eventId: String)
    case unknown(type: String, raw: JSONValue)

    public struct Waterfall: Sendable {
        public let event: String
        public let eventId: String
        public let agentId: String
        public let request: JSONValue
    }
}

extension HostEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, clientId, host, home, event, args, eventId, agentId, request
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = (try? container.decode(String.self, forKey: .type)) ?? "unknown"
        switch type {
        case "ready":
            self = .ready(
                clientId: (try? container.decode(String.self, forKey: .clientId)) ?? "",
                home: (try? container.decode(Home.self, forKey: .host))?.home ?? ""
            )
        case "emit":
            self = .emit(
                event: (try? container.decode(String.self, forKey: .event)) ?? "",
                args: (try? container.decode([JSONValue].self, forKey: .args)) ?? []
            )
        case "waterfall":
            self = .waterfall(
                Waterfall(
                    event: (try? container.decode(String.self, forKey: .event)) ?? "",
                    eventId: (try? container.decode(String.self, forKey: .eventId)) ?? "",
                    agentId: (try? container.decode(String.self, forKey: .agentId)) ?? "",
                    request: (try? container.decode(JSONValue.self, forKey: .request)) ?? .null
                )
            )
        case "cancel":
            self = .cancelled(eventId: (try? container.decode(String.self, forKey: .eventId)) ?? "")
        default:
            self = .unknown(type: type, raw: (try? JSONValue(from: decoder)) ?? .null)
        }
    }

    private struct Home: Decodable { let home: String }
}

/// The answer sent back for a pending waterfall.
public struct EventAnswer: Encodable, Sendable {
    public enum Outcome: Sendable {
        /// The client declined to handle it; the host continues to the next listener.
        case next
        /// A successful result.
        case result(JSONValue)
        /// The listener failed; the host surfaces this rejection.
        case rejected(code: String, message: String)

        var wire: WireOutcome {
            switch self {
            case .next:
                return WireOutcome(kind: "next", value: nil, error: nil)
            case .result(let value):
                return WireOutcome(kind: "result", value: value, error: nil)
            case .rejected(let code, let message):
                return WireOutcome(kind: "rejected", value: nil, error: WireError(name: "Error", message: message, code: code))
            }
        }
    }

    public let clientId: String
    public let eventId: String
    public let outcome: WireOutcome

    public init(clientId: String, eventId: String, outcome: Outcome) {
        self.clientId = clientId
        self.eventId = eventId
        self.outcome = outcome.wire
    }

    public struct WireOutcome: Encodable, Sendable {
        let kind: String
        let value: JSONValue?
        let error: WireError?
    }

    public struct WireError: Encodable, Sendable {
        let name: String
        let message: String
        let code: String
    }
}

// MARK: - Known interactive payloads

/// The payload of a `user-questions/request` waterfall.
///
/// This is the host asking the human to choose; the phone renders it as a
/// native question sheet and answers with the selected option labels plus, when
/// the user typed one, a free-text answer of their own.
public struct UserQuestionsRequest: Sendable, Codable {
    public let questions: [Question]

    public struct Question: Sendable, Codable, Identifiable {
        public let id: String
        public let question: String
        /// Supporting detail the host sends alongside the question, kept out of
        /// the option labels on purpose.
        public let detail: String?
        public let header: String?
        public let options: [Option]?
        public let multiSelect: Bool?

        public var allowsMultiple: Bool { multiSelect ?? false }
    }

    public struct Option: Sendable, Codable, Identifiable, Hashable {
        public let label: String
        public let description: String?

        public var id: String { label }
    }
}

/// One answer to one question.
public struct UserQuestionAnswer: Encodable, Sendable {
    public let id: String
    public let selected: [String]
    public let custom: String?

    public init(id: String, selected: [String], custom: String? = nil) {
        self.id = id
        self.selected = selected
        self.custom = custom
    }
}

/// One question as the user left it on screen: what is ticked, and what they typed.
///
/// The two are separate because the wire format keeps them separate; see
/// `UserQuestionsAnswer.init(drafts:)` for how they combine.
public struct UserQuestionDraft: Sendable {
    public let id: String
    public let selected: [String]
    public let custom: String
    public let allowsMultiple: Bool

    public init(id: String, selected: [String], custom: String, allowsMultiple: Bool) {
        self.id = id
        self.selected = selected
        self.custom = custom
        self.allowsMultiple = allowsMultiple
    }
}

/// The value returned for a `user-questions/request` waterfall.
public struct UserQuestionsAnswer: Encodable, Sendable {
    public let answers: [UserQuestionAnswer]

    public init(answers: [UserQuestionAnswer]) {
        self.answers = answers
    }

    /// Builds the wire answer from what a question sheet collected.
    ///
    /// Free text travels in its own `custom` field — never appended to
    /// `selected` as if it were an option label. The host's answer item defines
    /// it that way, and the two shapes are not interchangeable: an option label
    /// the user never saw is worse than useless to whoever reads the answer.
    ///
    /// For a single-select question the typed answer *is* the choice, so
    /// `selected` goes out empty; a multi-select may carry both. That is exactly
    /// what the desktop composer sends.
    public init(drafts: [UserQuestionDraft]) {
        self.init(answers: drafts.map { draft in
            let custom = draft.custom.trimmingCharacters(in: .whitespacesAndNewlines)
            return UserQuestionAnswer(
                id: draft.id,
                selected: custom.isEmpty || draft.allowsMultiple ? draft.selected : [],
                custom: custom.isEmpty ? nil : custom
            )
        })
    }
}

extension HostEvent.Waterfall {
    /// Decodes this waterfall's request as a multiple-choice prompt, if it is one.
    public var userQuestions: UserQuestionsRequest? {
        guard event == "user-questions/request" else { return nil }
        let data = try? JSONEncoder().encode(request)
        guard let data else { return nil }
        return try? JSONDecoder().decode(UserQuestionsRequest.self, from: data)
    }
}
