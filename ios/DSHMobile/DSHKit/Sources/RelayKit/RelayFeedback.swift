import Foundation
import DSHKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What can go wrong on the feedback endpoints, as cases the UI can branch on.
///
/// Deliberately **not** a `LocalizedError`: this package has no business knowing
/// what a phone should say. The four failures a person can act on (no network,
/// too often, too long, gone) are distinct cases rather than one status code, so
/// the composer can keep the draft and phrase each one itself — that distinction
/// is exactly what `RelayDeviceAdmin` folds into a bare `httpStatus`.
public enum FeedbackClientError: Error, Sendable, Equatable {
    /// The request never produced an HTTP answer (offline, DNS, TLS, timeout).
    /// The associated value is diagnostic, not user-facing.
    case network(String)
    /// `429 feedback/rate-limited`: the relay refused to write, nothing was stored.
    case rateLimited
    /// `400 feedback/too-long` or `413 feedback/too-large`: the body was over the limit.
    case tooLong
    /// `404 feedback/not-found`: no such thread, or the ticket does not own it.
    case notFound
    /// Any other non-2xx the relay answered, with its error code when it named one.
    case server(status: Int, code: String?)
    /// The relay answered, but not with the envelope this client understands.
    case decoding(String)
}

/// 正文字段的取值（FR-034）：由消息自带标记区分两种格式。
///
/// - ``text``：Markdown（默认），交给 App 自己的渲染器画，字体、暗色与动态字号都跟 App 一致。
/// - ``html``：报告类消息，交给锁死的 HTML 容器（`HTMLMessageView`）。
///
/// 线上标记一律经 ``init(wire:)`` 归一：缺字段、`null`、大小写不一致与任何认不出的值都落到
/// ``text``。**退到 Markdown 是安全的，退到 HTML 不是**——HTML 容器要多锁一层才敢开，
/// 所以只有明确的 `html` 才配走那条路。服务端此刻还没有这个字段，客户端先按"读不出来就是
/// Markdown"跑起来。
public enum FeedbackBodyFormat: String, Sendable, Hashable, Codable {
    case text
    case html

    /// 归一线上标记；认不出来一律 ``text``。
    public init(wire: String?) {
        let normalized = wire?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self = normalized == Self.html.rawValue ? .html : .text
    }
}

/// One message inside a thread : what the user wrote, or what we answered.
public struct FeedbackMessage: Sendable, Hashable, Identifiable, Codable {
    /// Who wrote it. Unknown values decode as ``unknown`` rather than failing the
    /// whole inbox: a later server-side author must not blank the records page.
    public enum Author: String, Sendable, Hashable, Codable {
        case user
        case owner
        case unknown

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Author(rawValue: raw) ?? .unknown
        }
    }

    public let messageId: String
    public let author: Author
    public let body: String
    /// 正文格式（FR-034）：`text` 或 `html`。
    ///
    /// 声明成 `String?` 是为了对齐线上字段：解码走 `decodeIfPresent`，缺字段、`null` 与
    /// 认不出的值都归一成 `"text"`（见 ``FeedbackBodyFormat/init(wire:)``），所以解码之后
    /// 不会是 `nil`；只有成员逐一构造时才可能留空，那时也按 Markdown 渲染。
    public let format: String?
    public let createdAt: Date?

    public var id: String { messageId }

    /// 解析后的格式：判断走哪条渲染路径时用这个，不要在界面里比字符串。
    public var bodyFormat: FeedbackBodyFormat { FeedbackBodyFormat(wire: format) }

    public init(messageId: String, author: Author, body: String, format: String? = nil, createdAt: Date?) {
        self.messageId = messageId
        self.author = author
        self.body = body
        self.format = format.map { FeedbackBodyFormat(wire: $0).rawValue }
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case messageId, author, body, format, createdAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messageId = try container.decode(String.self, forKey: .messageId)
        author = (try? container.decode(Author.self, forKey: .author)) ?? .unknown
        body = (try? container.decode(String.self, forKey: .body)) ?? ""
        // 服务端还没有这个字段：缺字段/未知值一律当作 `text`。
        format = FeedbackBodyFormat(
            wire: try? container.decodeIfPresent(String.self, forKey: .format)
        ).rawValue
        // The relay reports milliseconds since the epoch, same as `RelayDevice`.
        createdAt = RelayDevice.date(fromMilliseconds: try? container.decodeIfPresent(Int.self, forKey: .createdAt))
    }
}

/// 来信人标识（团队收件箱扩展，2026-10-15 服务端二期）。
///
/// 每个叶子字段都可缺省：匿名提交只有 `kind == .anonymous`；团队账号自己的提交
/// 服务端不会绑给团队，`teamBound` 用来区分"这条线程要不要进团队收件箱"。
public struct FeedbackThreadSource: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable {
        case device
        case anonymous
    }

    public let kind: Kind?
    public let deviceModel: String?
    public let appVersion: String?
    public let systemVersion: String?
    /// 账号短 id（如 `acc_8627cd67`），用于界面上认人；不是完整 id。
    public let accountHint: String?
    /// 这条线程是否绑了团队（属性，不是视角——两侧都看得到）。
    public let teamBound: Bool?

    public init(kind: Kind? = nil, deviceModel: String? = nil, appVersion: String? = nil,
                systemVersion: String? = nil, accountHint: String? = nil, teamBound: Bool? = nil) {
        self.kind = kind
        self.deviceModel = deviceModel
        self.appVersion = appVersion
        self.systemVersion = systemVersion
        self.accountHint = accountHint
        self.teamBound = teamBound
    }

    /// 列表/详情的首行文案：机型 + 账号短 id；信息不足或匿名时给确定文案。
    public var displayLine: String {
        if kind == .anonymous { return String(localized: "匿名来信") }
        let parts = [deviceModel, accountHint].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? String(localized: "匿名来信") : parts.joined(separator: " · ")
    }
}

/// One feedback thread, as the relay returns it in an inbox answer.
public struct FeedbackThread: Sendable, Hashable, Identifiable, Codable {
    public let threadId: String
    /// The one-line title the sender wrote, when they wrote one.
    ///
    /// Optional on purpose: the relay learned this field after the first phones
    /// shipped, so an answer from a relay that does not have it yet must decode
    /// rather than fail. Empty is treated as absent by the UI, which falls back
    /// to the first sentence of the body.
    public let subject: String?
    /// `open` (待回复) or `replied` (已回复); kept as the server's raw string.
    public let status: String
    public let createdAt: Date?
    public let lastMessageAt: Date?
    /// The relay's own count of owner messages newer than `userReadAt`.
    public let unread: Int
    /// 团队侧口径：这条线程里团队没读的用户来信条数（团队收件箱扩展，缺省 0）。
    public let teamUnread: Int
    /// 发件人标识（团队收件箱扩展）；全部字段可缺省，老服务端不下发时为 nil。
    public let source: FeedbackThreadSource?
    public let messages: [FeedbackMessage]

    public var id: String { threadId }

    /// Whether we have answered at least once.
    public var isReplied: Bool { status == "replied" }

    public init(
        threadId: String,
        subject: String? = nil,
        status: String,
        createdAt: Date?,
        lastMessageAt: Date?,
        unread: Int,
        teamUnread: Int = 0,
        source: FeedbackThreadSource? = nil,
        messages: [FeedbackMessage]
    ) {
        self.threadId = threadId
        self.subject = subject
        self.status = status
        self.createdAt = createdAt
        self.lastMessageAt = lastMessageAt
        self.unread = unread
        self.teamUnread = teamUnread
        self.source = source
        self.messages = messages
    }

    private enum CodingKeys: String, CodingKey {
        case threadId, subject, status, createdAt, lastMessageAt, unread, teamUnread, source, messages
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        threadId = try container.decode(String.self, forKey: .threadId)
        // Missing, null and wrong-typed all mean "no subject" — never a failure.
        subject = try? container.decodeIfPresent(String.self, forKey: .subject)
        status = (try? container.decode(String.self, forKey: .status)) ?? "open"
        createdAt = RelayDevice.date(fromMilliseconds: try? container.decodeIfPresent(Int.self, forKey: .createdAt))
        lastMessageAt = RelayDevice.date(fromMilliseconds: try? container.decodeIfPresent(Int.self, forKey: .lastMessageAt))
        unread = (try? container.decode(Int.self, forKey: .unread)) ?? 0
        // 团队收件箱扩展：缺字段/类型不对一律退默认，老服务端照常能解。
        teamUnread = (try? container.decode(Int.self, forKey: .teamUnread)) ?? 0
        source = try? container.decodeIfPresent(FeedbackThreadSource.self, forKey: .source)
        messages = (try? container.decode([FeedbackMessage].self, forKey: .messages)) ?? []
    }
}

/// One notice we broadcast to an account; independent of any thread.
public struct FeedbackNotice: Sendable, Hashable, Identifiable, Codable {
    public let noticeId: String
    public let subject: String?
    public let body: String
    /// 正文格式（FR-034），口径与 ``FeedbackMessage/format`` 完全一致：缺字段与未知值
    /// 一律 `text`，只有明确的 `html` 才走锁死的 HTML 容器。
    public let format: String?
    public let createdAt: Date?
    /// The relay's read state for *this account* (019): the same notice is read or unread
    /// for every device under the account, so one phone opening it clears the other's badge.
    public let read: Bool

    public var id: String { noticeId }

    /// 解析后的格式：判断走哪条渲染路径时用这个。
    public var bodyFormat: FeedbackBodyFormat { FeedbackBodyFormat(wire: format) }

    public init(noticeId: String, subject: String?, body: String, format: String? = nil,
                createdAt: Date?, read: Bool) {
        self.noticeId = noticeId
        self.subject = subject
        self.body = body
        self.format = format.map { FeedbackBodyFormat(wire: $0).rawValue }
        self.createdAt = createdAt
        self.read = read
    }

    private enum CodingKeys: String, CodingKey {
        case noticeId, subject, body, format, createdAt, read
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        noticeId = try container.decode(String.self, forKey: .noticeId)
        subject = try? container.decodeIfPresent(String.self, forKey: .subject)
        body = (try? container.decode(String.self, forKey: .body)) ?? ""
        // 与 `FeedbackMessage` 同一个归一：读不出来就是 Markdown。
        format = FeedbackBodyFormat(
            wire: try? container.decodeIfPresent(String.self, forKey: .format)
        ).rawValue
        createdAt = RelayDevice.date(fromMilliseconds: try? container.decodeIfPresent(Int.self, forKey: .createdAt))
        read = (try? container.decodeIfPresent(Bool.self, forKey: .read)) ?? false
    }
}

/// One inbox answer: threads we own, the notices delivered to this account, and the
/// relay's unread total. Pulling it **never** changes read state.
public struct FeedbackInbox: Sendable, Hashable {
    public let threads: [FeedbackThread]
    public let notices: [FeedbackNotice]
    public let unreadCount: Int
    /// 调用方是不是团队账号（服务端判定）：true 时两栏方向对调——
    /// 收件箱是用户来信、已发送是团队回信。缺省 false（用户侧逐像素不变）。
    public let teamPerspective: Bool

    public init(threads: [FeedbackThread], notices: [FeedbackNotice], unreadCount: Int,
                teamPerspective: Bool = false) {
        self.threads = threads.sorted {
            ($0.lastMessageAt ?? $0.createdAt ?? .distantPast)
                > ($1.lastMessageAt ?? $1.createdAt ?? .distantPast)
        }
        self.notices = notices.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        self.unreadCount = unreadCount
        self.teamPerspective = teamPerspective
    }
}

/// The pickup credential for one thread. The relay stores only its hash; losing
/// it on this phone means that thread can never be read here again.
///
/// `Codable` on purpose: the app keeps the array of these in the Keychain, and
/// `createdAt` travels as the relay's epoch milliseconds so the stored JSON and
/// the wire body read the same way.
/// 本机凭据列表的判定在 DSHKit（`FeedbackTicketList`）；这里补一句 conformance，
/// 让那份判定不必认识 RelayKit 的类型。
extension FeedbackTicket: FeedbackTicketLike {}

public struct FeedbackTicket: Sendable, Hashable, Codable {
    public let threadId: String
    public let ticketKey: String
    public let createdAt: Date?

    public init(threadId: String, ticketKey: String, createdAt: Date? = nil) {
        self.threadId = threadId
        self.ticketKey = ticketKey
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case threadId, ticketKey, createdAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        threadId = try container.decode(String.self, forKey: .threadId)
        ticketKey = try container.decode(String.self, forKey: .ticketKey)
        createdAt = RelayDevice.date(fromMilliseconds: try? container.decodeIfPresent(Int.self, forKey: .createdAt))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(threadId, forKey: .threadId)
        try container.encode(ticketKey, forKey: .ticketKey)
        if let createdAt {
            try container.encode(Int(createdAt.timeIntervalSince1970 * 1000), forKey: .createdAt)
        }
    }
}

/// One answer to `POST /feedback/append`.
public struct FeedbackAppendResult: Sendable, Hashable {
    public let threadId: String
    public let messageId: String
    public let createdAt: Date?

    public init(threadId: String, messageId: String, createdAt: Date?) {
        self.threadId = threadId
        self.messageId = messageId
        self.createdAt = createdAt
    }
}

/// The feedback channel's HTTP client (`/feedback/submit|inbox|append|read`).
///
/// A plain HTTPS call, not a DLP method: feedback lives on the relay, which the
/// phone reaches without any computer being awake — the whole point of entry
/// points no longer sending people to GitHub. The device token is **optional**:
/// without one every call is anonymous and still succeeds, which is what a phone
/// that never paired (or whose pairing was revoked) needs.
public struct RelayFeedbackClient: Sendable {
    /// Relay origin in HTTP form, including any mount prefix.
    public let relayURL: URL
    /// This phone's device credential, when it has one.
    public let deviceToken: String?
    private let session: URLSession
    private let timeout: TimeInterval

    public init(
        relayURL: URL,
        deviceToken: String? = nil,
        session: URLSession? = nil,
        timeout: TimeInterval = 20
    ) {
        self.relayURL = relayURL
        self.deviceToken = deviceToken
        self.timeout = timeout
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: - Requests

    /// Creates a thread and returns its pickup credential, which the caller must
    /// keep — the server stores only the hash, so this is the one time it exists.
    ///
    /// `clientRef` is the idempotency key: retrying the same reference returns the
    /// thread that already exists instead of a second one.
    ///
    /// `subject` is the optional one-line title. Whitespace-only is the same as
    /// absent (the contract says so), and an absent subject is **omitted** from
    /// the body rather than sent as null — a relay that predates the field must
    /// see exactly the request it used to see.
    public func submit(
        text: String,
        subject: String? = nil,
        appVersion: String? = nil,
        deviceModel: String? = nil,
        systemVersion: String? = nil,
        clientRef: String = UUID().uuidString
    ) async throws -> FeedbackTicket {
        struct Request: Encodable {
            let text: String
            let subject: String?
            let appVersion: String?
            let deviceModel: String?
            let systemVersion: String?
            let clientRef: String
        }
        struct Answer: Decodable {
            let ok: Bool?
            let threadId: String?
            let ticketKey: String?
            let createdAt: Int?
            let error: DSHRPCFailure?
        }
        let title = subject?.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = try await post("/feedback/submit", Request(
            text: text,
            subject: (title?.isEmpty ?? true) ? nil : title,
            appVersion: appVersion, deviceModel: deviceModel,
            systemVersion: systemVersion, clientRef: clientRef
        ))
        let answer = try decode(Answer.self, from: data)
        guard answer.ok == true, let threadId = answer.threadId, let ticketKey = answer.ticketKey else {
            throw Self.failure(answer.error, status: 200)
        }
        let createdAt = RelayDevice.date(fromMilliseconds: answer.createdAt)
        return FeedbackTicket(threadId: threadId, ticketKey: ticketKey, createdAt: createdAt)
    }

    /// Everything this phone may read: threads its tickets own, plus — with a
    /// valid device token — threads bound to this device, plus the notices
    /// delivered to this device's **account** (019: one inbox per account, shared
    /// by every device under it).
    ///
    /// Read-only by contract: the relay does not move `userReadAt` here, so a
    /// refresh on its own can never clear the unread badge.
    public func inbox(
        tickets: [FeedbackTicket],
        messagesPerThread: Int = 50,
        notices: Bool = true
    ) async throws -> FeedbackInbox {
        struct WireTicket: Encodable {
            let threadId: String
            let ticketKey: String
        }
        struct Request: Encodable {
            let tickets: [WireTicket]
            let messagesPerThread: Int
            let notices: Bool
        }
        struct Answer: Decodable {
            let ok: Bool?
            let threads: [FeedbackThread]?
            let notices: [FeedbackNotice]?
            let unreadCount: Int?
            let teamPerspective: Bool?
            let error: DSHRPCFailure?
        }
        let wire = tickets.map { WireTicket(threadId: $0.threadId, ticketKey: $0.ticketKey) }
        let data = try await post("/feedback/inbox", Request(
            tickets: wire, messagesPerThread: messagesPerThread, notices: notices
        ))
        let answer = try decode(Answer.self, from: data)
        guard answer.ok == true else { throw Self.failure(answer.error, status: 200) }
        return FeedbackInbox(
            threads: answer.threads ?? [],
            notices: answer.notices ?? [],
            unreadCount: answer.unreadCount ?? 0,
            teamPerspective: answer.teamPerspective ?? false
        )
    }

    /// Adds one message to an existing thread; the thread goes back to `open` so
    /// the owner sees it again. A wrong ticket and a missing thread are the same
    /// failure — the relay does not disclose which.
    public func append(
        threadId: String,
        ticketKey: String?,
        text: String,
        clientRef: String = UUID().uuidString
    ) async throws -> FeedbackAppendResult {
        struct Request: Encodable {
            let threadId: String
            let ticketKey: String?
            let text: String
            let clientRef: String
        }
        struct Answer: Decodable {
            let ok: Bool?
            let threadId: String?
            let messageId: String?
            let createdAt: Int?
            let error: DSHRPCFailure?
        }
        let data = try await post("/feedback/append", Request(
            threadId: threadId, ticketKey: ticketKey, text: text, clientRef: clientRef
        ))
        let answer = try decode(Answer.self, from: data)
        guard answer.ok == true, let messageId = answer.messageId else {
            throw Self.failure(answer.error, status: 200)
        }
        return FeedbackAppendResult(
            threadId: answer.threadId ?? threadId,
            messageId: messageId,
            createdAt: RelayDevice.date(fromMilliseconds: answer.createdAt)
        )
    }

    /// Marks threads and notices as read, and answers with what is still unread.
    ///
    /// Anonymous threads are marked through their tickets, so `tickets` travels
    /// with the ids; notices are per device and are ignored without a token.
    /// Idempotent on the relay, so calling it twice costs nothing.
    @discardableResult
    public func markRead(
        threadIds: [String],
        noticeIds: [String] = [],
        tickets: [FeedbackTicket] = []
    ) async throws -> Int {
        struct WireTicket: Encodable {
            let threadId: String
            let ticketKey: String
        }
        struct Request: Encodable {
            let threadIds: [String]
            let noticeIds: [String]
            let tickets: [WireTicket]
        }
        struct Answer: Decodable {
            let ok: Bool?
            let unreadCount: Int?
            let error: DSHRPCFailure?
        }
        let wire = tickets.map { WireTicket(threadId: $0.threadId, ticketKey: $0.ticketKey) }
        let data = try await post("/feedback/read", Request(
            threadIds: threadIds, noticeIds: noticeIds, tickets: wire
        ))
        let answer = try decode(Answer.self, from: data)
        guard answer.ok == true else { throw Self.failure(answer.error, status: 200) }
        return answer.unreadCount ?? 0
    }

    // MARK: - Transport

    private func post<Body: Encodable>(_ path: String, _ body: Body) async throws -> Data {
        var components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false)
        // The relay may be mounted under a path prefix so it shares an existing
        // domain and certificate; the prefix is appended to, never replaced.
        components?.path = LinkConfiguration.appending(path: path, to: relayURL)
        components?.query = nil
        guard let url = components?.url else {
            throw FeedbackClientError.network("invalid-relay-url")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let deviceToken, !deviceToken.isEmpty {
            request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        }
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw FeedbackClientError.decoding("request-encode-failed: \(error)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FeedbackClientError.network(String(describing: error))
        }
        // Status first, decode second: a relay that answered 500 with an HTML
        // page must read as a server failure, never as a malformed ticket.
        guard let http = response as? HTTPURLResponse else {
            throw FeedbackClientError.network("invalid-relay-response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.failure(Self.errorCode(in: data), status: http.statusCode)
        }
        return data
    }

    /// Decodes a success body, keeping "the relay answered something else" a
    /// distinct failure from "the relay said no".
    private func decode<Payload: Decodable>(_ type: Payload.Type, from data: Data) throws -> Payload {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw FeedbackClientError.decoding(String(describing: error))
        }
    }

    private static func errorCode(in data: Data) -> String? {
        struct Envelope: Decodable {
            let error: DSHRPCFailure?
        }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.error?.code
    }

    /// Maps an error code (and, when there is none, the status) onto the cases
    /// the UI branches on. `413 feedback/too-large` is a length problem too: the
    /// draft is what has to shrink, and telling the user "too long" is right.
    private static func failure(_ error: DSHRPCFailure?, status: Int) -> FeedbackClientError {
        failure(error?.code, status: status)
    }

    private static func failure(_ code: String?, status: Int) -> FeedbackClientError {
        switch code {
        case "feedback/rate-limited":
            return .rateLimited
        case "feedback/too-long", "feedback/too-large":
            return .tooLong
        case "feedback/not-found":
            return .notFound
        default:
            break
        }
        switch status {
        case 404:
            return .notFound
        case 413:
            return .tooLong
        case 429:
            return .rateLimited
        default:
            return .server(status: status, code: code)
        }
    }
}
