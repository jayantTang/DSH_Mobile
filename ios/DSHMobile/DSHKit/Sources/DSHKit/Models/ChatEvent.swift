import Foundation

// MARK: - Content blocks

/// One block of message content.
///
/// DSH extends this union as new capabilities land, so unknown block types are
/// preserved verbatim rather than dropped — a phone must never silently lose a
/// part of the conversation it does not yet understand.
public enum ContentBlock: Sendable {
    case text(String)
    case reasoning(String)
    case toolCall(id: String, name: String, arguments: String)
    case toolResult(toolCallId: String, content: [ContentBlock], isError: Bool)
    case image(ImageAttachment)
    case file(FileAttachment)
    case unknown(type: String, raw: JSONValue)

    public struct ImageAttachment: Sendable, Hashable {
        public let attachmentId: String
        public let mediaType: String
        public let bytes: Int?
        public let width: Int?
        public let height: Int?
        public let name: String?

        /// What the wire tells us about this picture's *content*, for caches that
        /// must not serve an old picture under a reused id.
        public var cacheVariant: String {
            "\(bytes ?? 0)-\(mediaType)"
        }
    }

    public struct FileAttachment: Sendable, Hashable {
        public let attachmentId: String
        public let name: String
        public let bytes: Int?
    }

    /// Plain text of this block, when it has one.
    public var text: String? {
        switch self {
        case .text(let value): return value
        case .reasoning(let value): return value
        case .unknown(_, let raw): return raw["text"]?.stringValue
        default: return nil
        }
    }
}

extension ContentBlock: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, text, id, name, arguments, toolCallId, content, isError, attachment, mediaType, bytes, width, height
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = (try? container.decode(String.self, forKey: .type)) ?? "unknown"

        switch type {
        case "text":
            self = .text((try? container.decode(String.self, forKey: .text)) ?? "")
        case "reasoning":
            self = .reasoning((try? container.decode(String.self, forKey: .text)) ?? "")
        case "tool-call":
            self = .toolCall(
                id: (try? container.decode(String.self, forKey: .id)) ?? "",
                name: (try? container.decode(String.self, forKey: .name)) ?? "",
                arguments: (try? container.decode(String.self, forKey: .arguments)) ?? "{}"
            )
        case "tool-result":
            self = .toolResult(
                toolCallId: (try? container.decode(String.self, forKey: .toolCallId)) ?? "",
                content: (try? container.decode([ContentBlock].self, forKey: .content)) ?? [],
                isError: (try? container.decode(Bool.self, forKey: .isError)) ?? false
            )
        case "image":
            let attachment = try? container.decode(AttachmentPayload.self, forKey: .attachment)
            self = .image(
                ImageAttachment(
                    attachmentId: attachment?.attachmentId ?? "",
                    mediaType: attachment?.mediaType ?? "image/png",
                    bytes: attachment?.bytes,
                    width: attachment?.width,
                    height: attachment?.height,
                    name: attachment?.name
                )
            )
        case "file":
            let attachment = try? container.decode(AttachmentPayload.self, forKey: .attachment)
            self = .file(
                FileAttachment(
                    attachmentId: attachment?.attachmentId ?? "",
                    name: attachment?.name ?? "file",
                    bytes: attachment?.bytes
                )
            )
        default:
            self = .unknown(type: type, raw: (try? JSONValue(from: decoder)) ?? .null)
        }
    }

    private struct AttachmentPayload: Decodable {
        let attachmentId: String
        let mediaType: String?
        let bytes: Int?
        let width: Int?
        let height: Int?
        let name: String?
    }
}

// MARK: - Chat events

/// A session event projected onto the shapes a chat transcript renders.
public enum ChatEvent: Sendable {
    case userMessage(UserMessage)
    case assistantMessage(AssistantMessage)
    case toolCall(ToolCall)
    case toolResult(ToolResult)
    case turnStart(turn: Int)
    case turnEnd(turn: Int, reason: String)
    case stepStart(turn: Int, step: Int)
    case stepEnd(turn: Int, step: Int)
    case inboxSpliced(InboxSpliced)
    case titleChanged(String)
    case other(type: String, seq: Int, time: Date?, data: JSONValue)

    public struct UserMessage: Sendable {
        public let id: String
        public let content: [ContentBlock]
        public let rpcId: String?
        public let isSteering: Bool
        /// Who authored this message.
        ///
        /// Only `user` is conversation. The host also journals messages from
        /// plugins and from its own runtime-context injection, which share the
        /// `user/message` event type but must never be rendered as something
        /// the human typed.
        public let sourceKind: String

        public var isFromHuman: Bool { sourceKind == "user" }
    }

    public struct AssistantMessage: Sendable {
        public let turn: Int
        public let step: Int
        public let content: [ContentBlock]
        public let stream: JSONValue?
    }

    public struct ToolCall: Sendable {
        public let turn: Int
        public let step: Int
        public let callId: String
        public let name: String
        /// The raw JSON argument string exactly as the model produced it.
        public let arguments: String

        /// Parsed arguments, when they are valid JSON.
        public var parsedArguments: JSONValue? {
            guard let data = arguments.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(JSONValue.self, from: data)
        }
    }

    public struct ToolResult: Sendable {
        public let turn: Int
        public let step: Int
        public let callId: String
        public let content: [ContentBlock]
        public let isError: Bool
    }

    public struct InboxSpliced: Sendable {
        public let target: String
        public let inserted: [ContentBlock]
        /// The request id the inserted message was submitted under.
        ///
        /// This is the same id the durable `user/message` carries once the
        /// queue promotes it, which is what lets the two collapse into one row
        /// instead of showing the message twice.
        public let rpcId: String?
        /// True for the splice that withdraws a queued item.
        public let isRemoval: Bool
        /// Who authored the spliced content.
        ///
        /// The host injects its own notifications through the same channel —
        /// approval-policy changes, background-job completions — with
        /// `kind: "plugin"`. Rendering those as user bubbles is what put a
        /// second, unexplained message under every prompt.
        public let sourceKind: String

        public var isFromHuman: Bool { sourceKind == "user" }
    }
}

extension ChatEvent {
    /// The sequence number this event occupies in the session journal.
    public var seq: Int {
        switch self {
        case .other(_, let seq, _, _): return seq
        default: return 0
        }
    }
}

/// Projects a raw journal event into a renderable chat event.
public enum ChatEventDecoder {
    /// Decodes one durable session event, tolerating unknown event types.
    public static func decode(_ event: SessionEvent) -> ChatEvent {
        let data = event.data
        let time = event.date

        switch event.type {
        case "user/message":
            return .userMessage(
                ChatEvent.UserMessage(
                    id: data["id"]?.stringValue ?? UUID().uuidString,
                    content: decodeBlocks(data["content"]),
                    rpcId: data["source"]?["rpcId"]?.stringValue,
                    isSteering: false,
                    sourceKind: data["source"]?["kind"]?.stringValue ?? "user"
                )
            )

        case "assistant/message":
            let message = data["message"]
            return .assistantMessage(
                ChatEvent.AssistantMessage(
                    turn: data["turn"]?.intValue ?? 0,
                    step: data["step"]?.intValue ?? 0,
                    content: decodeBlocks(message?["content"]),
                    stream: data["stream"]
                )
            )

        case "tool/call":
            return .toolCall(
                ChatEvent.ToolCall(
                    turn: data["turn"]?.intValue ?? 0,
                    step: data["step"]?.intValue ?? 0,
                    callId: data["callId"]?.stringValue ?? "",
                    name: data["name"]?.stringValue ?? "tool",
                    arguments: data["arguments"]?.stringValue ?? "{}"
                )
            )

        case "tool/result":
            let message = data["message"]
            let blocks = decodeBlocks(message?["content"])
            // The result envelope nests the tool's own blocks one level down.
            let flattened = blocks.flatMap { block -> [ContentBlock] in
                if case .toolResult(_, let inner, _) = block, !inner.isEmpty { return inner }
                return [block]
            }
            let isError = blocks.contains { block in
                if case .toolResult(_, _, let flag) = block { return flag }
                return false
            }
            return .toolResult(
                ChatEvent.ToolResult(
                    turn: data["turn"]?.intValue ?? 0,
                    step: data["step"]?.intValue ?? 0,
                    callId: message?["source"]?["callId"]?.stringValue ?? "",
                    content: flattened,
                    isError: isError
                )
            )

        case "turn/start":
            return .turnStart(turn: data["turn"]?.intValue ?? 0)

        case "turn/end":
            return .turnEnd(
                turn: data["turn"]?.intValue ?? 0,
                reason: data["reason"]?["kind"]?.stringValue ?? "unknown"
            )

        case "step/start":
            return .stepStart(turn: data["turn"]?.intValue ?? 0, step: data["step"]?.intValue ?? 0)

        case "step/end":
            return .stepEnd(turn: data["turn"]?.intValue ?? 0, step: data["step"]?.intValue ?? 0)

        case "agent/inbox/spliced":
            let first = data["inserted"]?.arrayValue?.first
            return .inboxSpliced(
                ChatEvent.InboxSpliced(
                    target: data["target"]?.stringValue ?? "next-turn",
                    inserted: decodeBlocks(first?["content"]),
                    rpcId: first?["source"]?["rpcId"]?.stringValue,
                    isRemoval: (data["inserted"]?.arrayValue?.isEmpty ?? true),
                    sourceKind: first?["source"]?["kind"]?.stringValue ?? "user"
                )
            )

        case "session/title":
            return .titleChanged(data["title"]?.stringValue ?? "")

        default:
            return .other(type: event.type, seq: event.seq, time: time, data: data)
        }
    }

    static func decodeBlocks(_ value: JSONValue?) -> [ContentBlock] {
        guard let array = value?.arrayValue else { return [] }
        return array.compactMap { element in
            guard let data = try? JSONEncoder().encode(element) else { return nil }
            return try? JSONDecoder().decode(ContentBlock.self, from: data)
        }
    }
}

// MARK: - Tool rendering helpers

extension ChatEvent.ToolCall {
    /// A short, human-readable summary of the call, mirroring the desktop UI.
    ///
    /// Falls back to the raw argument string when the shape is unfamiliar, so
    /// new tools remain readable without a client update.
    public var summary: String {
        guard let args = parsedArguments else { return arguments }
        switch name {
        case "bash", "shell":
            return args["command"]?.stringValue ?? arguments
        case "read", "read_file":
            return args["path"]?.stringValue ?? args["file_path"]?.stringValue ?? ""
        case "edit", "str_replace", "write", "create":
            return args["path"]?.stringValue ?? args["file_path"]?.stringValue ?? ""
        case "glob", "grep", "search":
            return args["pattern"]?.stringValue ?? args["query"]?.stringValue ?? ""
        case "web_search":
            return args["query"]?.stringValue ?? ""
        case "web_fetch":
            return args["url"]?.stringValue ?? ""
        case "present":
            return args["path"]?.stringValue ?? ""
        default:
            return args["description"]?.stringValue ?? args["prompt"]?.stringValue ?? ""
        }
    }
}
