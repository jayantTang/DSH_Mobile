import Foundation

/// 宿主排队输入（`session/control` 的 `SessionQueuedItem`）。
///
/// 排队项的**唯一所有者是宿主**：本地只做乐观回显与控制帧合并，不把队列写进
/// 转写（设计 `20261026-排队输入-设计.md` §3）。
public struct SessionQueuedItem: Sendable, Identifiable {
    public enum Placement: String, Sendable, Codable, Equatable {
        case queued
        case steering
        case context
    }

    public let id: String
    public let placement: Placement
    /// Prompt-RPC 身份：本地乐观回显与这条队列项靠它合并。
    public let rpcId: String?
    /// 文本与图片（图片只有 attachment 元数据）。
    public let content: [ContentBlock]

    public init(id: String, placement: Placement, rpcId: String?,
                content: [ContentBlock]) {
        self.id = id
        self.placement = placement
        self.rpcId = rpcId
        self.content = content
    }

    /// 拼接的正文（队列条单行显示）。
    public var text: String {
        content.compactMap { block -> String? in
            switch block {
            case .text(let text): return text
            case .unknown(_, let raw): return raw["text"]?.stringValue
            default: return nil
            }
        }.joined()
    }

    public var images: [ContentBlock.ImageAttachment] {
        content.compactMap { block -> ContentBlock.ImageAttachment? in
            if case .image(let attachment) = block { return attachment }
            return nil
        }
    }

    public static func decode(_ value: JSONValue) -> SessionQueuedItem? {
        guard let id = value["id"]?.stringValue else { return nil }
        let placement = Placement(rawValue: value["placement"]?.stringValue ?? "queued") ?? .queued
        let message = value["message"]
        let contentValue = message?["content"] ?? value["content"]
        return SessionQueuedItem(
            id: id,
            placement: placement,
            rpcId: value["rpcId"]?.stringValue,
            content: decodeBlocks(contentValue))
    }

    static func decodeBlocks(_ value: JSONValue?) -> [ContentBlock] {
        guard let array = value?.arrayValue else { return [] }
        return array.compactMap { element in
            guard let data = try? JSONEncoder().encode(element) else { return nil }
            return try? JSONDecoder().decode(ContentBlock.self, from: data)
        }
    }
}

/// `session/control` 的帧；本客户端只消费队列，其余原样忽略。
public enum SessionControlFrame: Sendable {
    /// 每个会话的队列快照（一上来必有一帧）。
    case baseline(queues: [String: [SessionQueuedItem]],
                  inboxes: [String: [SessionQueuedItem]],
                  projections: [String: SessionProjectionValues])
    /// 某个会话的整份队列被替换。
    case queue(sessionId: String, items: [SessionQueuedItem])
    /// 会话投影更新；排队输入从 `inbox` 投影的 `next-turn` 读（宿主实际下发的是这条）。
    case projection(sessionId: String, key: String, value: JSONValue)
    /// jobs 等不参与排队输入。
    case other(type: String)

    public static func decode(_ value: JSONValue) -> SessionControlFrame? {
        guard let type = value["type"]?.stringValue else { return nil }
        switch type {
        case "baseline":
            let queues = value["value"]?["queues"]?.objectValue ?? [:]
            var parsed: [String: [SessionQueuedItem]] = [:]
            for (sessionId, items) in queues {
                parsed[sessionId] = decodeItems(items)
            }
            let projections = value["value"]?["projections"]?.objectValue ?? [:]
            var inboxes: [String: [SessionQueuedItem]] = [:]
            var values: [String: SessionProjectionValues] = [:]
            for (sessionId, projection) in projections {
                if let inbox = projection["values"]?["inbox"] {
                    inboxes[sessionId] = inboxItems(inbox)
                }
                if let raw = projection["values"],
                   let data = try? JSONEncoder().encode(raw),
                   let decoded = try? JSONDecoder().decode(SessionProjectionValues.self, from: data) {
                    values[sessionId] = decoded
                }
            }
            return .baseline(queues: parsed, inboxes: inboxes, projections: values)
        case "queue":
            guard let sessionId = value["sessionId"]?.stringValue else { return nil }
            return .queue(sessionId: sessionId, items: decodeItems(value["items"]))
        case "projection":
            guard let sessionId = value["sessionId"]?.stringValue,
                  let key = value["key"]?.stringValue else { return nil }
            return .projection(sessionId: sessionId, key: key,
                               value: value["value"] ?? .null)
        default:
            return .other(type: type)
        }
    }

    static func decodeItems(_ value: JSONValue?) -> [SessionQueuedItem] {
        (value?.arrayValue ?? []).compactMap(SessionQueuedItem.decode)
    }

    /// `inbox` 投影 → 排队项。宿主实际下发的是这份（`session/control` 的
    /// `projection` 帧 / baseline 里的 `projections[session].values.inbox`）；
    /// 行形状是 `{id, content, source:{kind:"user",rpcId}}`，没有 placement 字段。
    public static func inboxItems(_ inbox: JSONValue) -> [SessionQueuedItem] {
        let rows = inbox["next-turn"]?.arrayValue ?? []
        return rows.compactMap { row in
            guard let id = row["id"]?.stringValue else { return nil }
            return SessionQueuedItem(
                id: id,
                placement: .queued,
                rpcId: row["source"]?["rpcId"]?.stringValue,
                content: SessionQueuedItem.decodeBlocks(row["content"]))
        }
    }
}
