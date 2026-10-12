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
    public let createdAt: Date?

    public var id: String { messageId }

    public init(messageId: String, author: Author, body: String, createdAt: Date?) {
        self.messageId = messageId
        self.author = author
        self.body = body
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case messageId, author, body, createdAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messageId = try container.decode(String.self, forKey: .messageId)
        author = (try? container.decode(Author.self, forKey: .author)) ?? .unknown
        body = (try? container.decode(String.self, forKey: .body)) ?? ""
        // The relay reports milliseconds since the epoch, same as `RelayDevice`.
        createdAt = RelayDevice.date(fromMilliseconds: try? container.decodeIfPresent(Int.self, forKey: .createdAt))
    }
}

/// One feedback thread, as the relay returns it in an inbox answer.
public struct FeedbackThread: Sendable, Hashable, Identifiable, Codable {
    public let threadId: String
    /// `open` (待回复) or `replied` (已回复); kept as the server's raw string.
    public let status: String
    public let createdAt: Date?
    public let lastMessageAt: Date?
    /// The relay's own count of owner messages newer than `userReadAt`.
    public let unread: Int
    public let messages: [FeedbackMessage]

    public var id: String { threadId }

    /// Whether we have answered at least once.
    public var isReplied: Bool { status == "replied" }

    public init(
        threadId: String,
        status: String,
        createdAt: Date?,
        lastMessageAt: Date?,
        unread: Int,
        messages: [FeedbackMessage]
    ) {
        self.threadId = threadId
        self.status = status
        self.createdAt = createdAt
        self.lastMessageAt = lastMessageAt
        self.unread = unread
        self.messages = messages
    }

    private enum CodingKeys: String, CodingKey {
        case threadId, status, createdAt, lastMessageAt, unread, messages
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        threadId = try container.decode(String.self, forKey: .threadId)
        status = (try? container.decode(String.self, forKey: .status)) ?? "open"
        createdAt = RelayDevice.date(fromMilliseconds: try? container.decodeIfPresent(Int.self, forKey: .createdAt))
        lastMessageAt = RelayDevice.date(fromMilliseconds: try? container.decodeIfPresent(Int.self, forKey: .lastMessageAt))
        unread = (try? container.decode(Int.self, forKey: .unread)) ?? 0
        messages = (try? container.decode([FeedbackMessage].self, forKey: .messages)) ?? []
    }
}

/// One notice we broadcast to paired devices; independent of any thread.
public struct FeedbackNotice: Sendable, Hashable, Identifiable, Codable {
    public let noticeId: String
    public let subject: String?
    public let body: String
    public let createdAt: Date?
    /// The relay's read state for *this device*.
    public let read: Bool

    public var id: String { noticeId }

    public init(noticeId: String, subject: String?, body: String, createdAt: Date?, read: Bool) {
        self.noticeId = noticeId
        self.subject = subject
        self.body = body
        self.createdAt = createdAt
        self.read = read
    }

    private enum CodingKeys: String, CodingKey {
        case noticeId, subject, body, createdAt, read
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        noticeId = try container.decode(String.self, forKey: .noticeId)
        subject = try? container.decodeIfPresent(String.self, forKey: .subject)
        body = (try? container.decode(String.self, forKey: .body)) ?? ""
        createdAt = RelayDevice.date(fromMilliseconds: try? container.decodeIfPresent(Int.self, forKey: .createdAt))
        read = (try? container.decodeIfPresent(Bool.self, forKey: .read)) ?? false
    }
}

/// One inbox answer: threads we own, notices for this device, and the relay's
/// unread total. Pulling it **never** changes read state.
public struct FeedbackInbox: Sendable, Hashable {
    public let threads: [FeedbackThread]
    public let notices: [FeedbackNotice]
    public let unreadCount: Int

    public init(threads: [FeedbackThread], notices: [FeedbackNotice], unreadCount: Int) {
        self.threads = threads.sorted {
            ($0.lastMessageAt ?? $0.createdAt ?? .distantPast)
                > ($1.lastMessageAt ?? $1.createdAt ?? .distantPast)
        }
        self.notices = notices.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        self.unreadCount = unreadCount
    }
}

/// The pickup credential for one thread. The relay stores only its hash; losing
/// it on this phone means that thread can never be read here again.
///
/// `Codable` on purpose: the app keeps the array of these in the Keychain, and
/// `createdAt` travels as the relay's epoch milliseconds so the stored JSON and
/// the wire body read the same way.
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
    public func submit(
        text: String,
        appVersion: String? = nil,
        deviceModel: String? = nil,
        systemVersion: String? = nil,
        clientRef: String = UUID().uuidString
    ) async throws -> FeedbackTicket {
        struct Request: Encodable {
            let text: String
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
        let data = try await post("/feedback/submit", Request(
            text: text, appVersion: appVersion, deviceModel: deviceModel,
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
    /// valid device token — threads bound to this device, plus its notices.
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
            unreadCount: answer.unreadCount ?? 0
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
