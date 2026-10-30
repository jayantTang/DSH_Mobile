import Foundation
import Testing

@testable import DSHKit
import RelayKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The feedback channel is a *relay* HTTP call, so these tests drive a stubbed
/// `URLSession` instead of a carrier: what matters is the request that goes out
/// (anonymous or not, under which mount prefix) and how the relay's answers are
/// told apart.
// Serialised: the stub keeps its canned answers in static storage, so
// concurrent tests would consume each other's responses.
@Suite("Relay feedback client", .serialized)
struct RelayFeedbackTests {

    /// A URLProtocol that records requests and replays canned answers.
    final class Stub: URLProtocol, @unchecked Sendable {
        struct Exchange: Sendable {
            let status: Int
            let body: Data
        }

        nonisolated(unsafe) static var exchanges: [Exchange] = []
        nonisolated(unsafe) static var requests: [URLRequest] = []
        nonisolated(unsafe) static var bodies: [Data] = []
        /// When set, the request fails before any HTTP answer exists.
        nonisolated(unsafe) static var transportError: Error?

        static func reset(_ list: [Exchange], failingWith error: Error? = nil) {
            exchanges = list
            requests = []
            bodies = []
            transportError = error
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requests.append(request)
            // A body set via `httpBody` arrives on the stream; URLProtocol sees
            // it as `httpBodyStream`, so read it back for assertions.
            var body = Data()
            if let stream = request.httpBodyStream {
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    if read <= 0 { break }
                    body.append(contentsOf: buffer[0 ..< read])
                }
                stream.close()
            } else if let direct = request.httpBody {
                body = direct
            }
            Self.bodies.append(body)

            if let error = Self.transportError {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
            let exchange = Self.exchanges.isEmpty
                ? Exchange(status: 500, body: Data("{}".utf8))
                : Self.exchanges.removeFirst()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: exchange.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: exchange.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        static func session() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [Stub.self]
            return URLSession(configuration: configuration)
        }
    }

    private func client(relay: String = "https://relay.test/dsh-link",
                        token: String? = "dt_phone") -> RelayFeedbackClient {
        RelayFeedbackClient(relayURL: URL(string: relay)!, deviceToken: token, session: Stub.session())
    }

    private func ticket(_ threadId: String = "th_1") -> FeedbackTicket {
        FeedbackTicket(threadId: threadId, ticketKey: "fk_\(threadId)", createdAt: Date(timeIntervalSince1970: 1))
    }

    /// Runs one call and returns the `FeedbackClientError` it threw, if any.
    private func failure(_ operation: () async throws -> Void) async -> FeedbackClientError? {
        do {
            try await operation()
            return nil
        } catch let error as FeedbackClientError {
            return error
        } catch {
            Issue.record("expected FeedbackClientError, got \(error)")
            return nil
        }
    }

    private func jsonBody() throws -> [String: Any] {
        let body = try #require(Stub.bodies.first)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    // MARK: - Requests

    @Test("submit posts the draft and the technical facts under the mount prefix")
    func submitRequest() async throws {
        Stub.reset([.init(status: 200, body: Data("""
        {"ok":true,"threadId":"th_9Kd","ticketKey":"fk_3nQ","createdAt":1760000000000}
        """.utf8))])

        let ticket = try await client().submit(
            text: "点了新建会话之后一直转圈",
            subject: "新建会话一直转圈",
            appVersion: "1.2 (345)",
            deviceModel: "iPhone15,4",
            systemVersion: "18.2",
            clientRef: "6F2B0B3E-1111-2222-3333-444455556666"
        )

        let request = try #require(Stub.requests.first)
        #expect(request.url?.absoluteString == "https://relay.test/dsh-link/feedback/submit")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer dt_phone")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try jsonBody()
        #expect(body["text"] as? String == "点了新建会话之后一直转圈")
        #expect(body["subject"] as? String == "新建会话一直转圈")
        #expect(body["appVersion"] as? String == "1.2 (345)")
        #expect(body["deviceModel"] as? String == "iPhone15,4")
        #expect(body["systemVersion"] as? String == "18.2")
        #expect(body["clientRef"] as? String == "6F2B0B3E-1111-2222-3333-444455556666")

        // `ticketKey` exists exactly once; the phone is the only place it lives.
        #expect(ticket.threadId == "th_9Kd")
        #expect(ticket.ticketKey == "fk_3nQ")
        // Milliseconds since the epoch, converted the way `RelayDevice` does it.
        #expect(ticket.createdAt == Date(timeIntervalSince1970: 1_760_000_000))
    }

    @Test("an omitted or blank subject never reaches the body")
    func subjectIsOmittedWhenBlank() async throws {
        Stub.reset([.init(status: 200, body: Data(
            #"{"ok":true,"threadId":"th_s","ticketKey":"fk_s","createdAt":1760000000000}"#.utf8
        ))])
        _ = try await client().submit(text: "先看看", subject: "   ")
        let blank = try jsonBody()
        // `nil` in the JSON body: a relay that predates `subject` sees the old request.
        #expect(blank.keys.contains("subject") == false || blank["subject"] is NSNull)

        Stub.reset([.init(status: 200, body: Data(
            #"{"ok":true,"threadId":"th_s","ticketKey":"fk_s","createdAt":1760000000000}"#.utf8
        ))])
        _ = try await client().submit(text: "先看看")
        #expect(try jsonBody().keys.contains("subject") == false || jsonBody()["subject"] is NSNull)
    }

    @Test("a relay without the subject field still decodes a thread")
    func threadSubjectIsOptional() async throws {
        // The answer a relay that has not learned `subject` yet sends: no such
        // key anywhere. It must decode, and the subject must read as absent.
        Stub.reset([.init(status: 200, body: Data("""
        {"ok":true,"unreadCount":0,
         "threads":[{"threadId":"th_1","status":"open","createdAt":1750000000000,
          "lastMessageAt":1750000000000,"unread":0,
          "messages":[{"messageId":"fm_1","author":"user","body":"没有主题","createdAt":1750000000000}]}],
         "notices":[]}
        """.utf8))])

        let inbox = try await client().inbox(tickets: [ticket()])
        #expect(inbox.threads.first?.subject == nil)
        #expect(inbox.threads.first?.messages.first?.body == "没有主题")

        // And when the relay does send one, it comes through.
        Stub.reset([.init(status: 200, body: Data("""
        {"ok":true,"unreadCount":0,
         "threads":[{"threadId":"th_1","subject":"新建会话一直转圈","status":"open",
          "createdAt":1750000000000,"lastMessageAt":1750000000000,"unread":0,
          "messages":[]}],
         "notices":[]}
        """.utf8))])
        let titled = try await client().inbox(tickets: [ticket()])
        #expect(titled.threads.first?.subject == "新建会话一直转圈")
    }

    @Test("a subject in the answer round-trips through a thread's own coding")
    func threadSubjectRoundTrip() throws {
        let thread = FeedbackThread(
            threadId: "th_1", subject: "主题", status: "replied",
            createdAt: Date(timeIntervalSince1970: 1), lastMessageAt: nil,
            unread: 0, messages: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(thread)
        let decoded = try JSONDecoder().decode(FeedbackThread.self, from: data)
        #expect(decoded.subject == "主题")
        #expect(decoded == thread)
    }

    @Test("an unpaired phone submits without an Authorization header")
    func anonymousSubmit() async throws {
        Stub.reset([.init(status: 200, body: Data(
            #"{"ok":true,"threadId":"th_a","ticketKey":"fk_a","createdAt":1760000000000}"#.utf8
        ))])

        let ticket = try await client(token: nil).submit(text: "连不上自己的电脑")
        #expect(ticket.threadId == "th_a")
        let request = try #require(Stub.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("inbox sends the tickets, not their timestamps, and decodes the answer")
    func inboxRequest() async throws {
        Stub.reset([.init(status: 200, body: Data("""
        {"ok":true,"unreadCount":2,
         "threads":[
           {"threadId":"th_old","status":"open","createdAt":1750000000000,"lastMessageAt":1750000000000,
            "unread":0,"messages":[{"messageId":"fm_1","author":"user","body":"第一条","createdAt":1750000000000}]},
           {"threadId":"th_new","status":"replied","createdAt":1760000000000,"lastMessageAt":1760000500000,
            "unread":1,"messages":[
              {"messageId":"fm_2","author":"user","body":"问题","createdAt":1760000000000},
              {"messageId":"fm_3","author":"owner","body":"回复","createdAt":1760000500000}]}],
         "notices":[{"noticeId":"nt_1","subject":"服务通知","body":"明天维护","createdAt":1760000600000,"read":false}]}
        """.utf8))])

        let inbox = try await client().inbox(tickets: [ticket()], messagesPerThread: 20)

        #expect(inbox.unreadCount == 2)
        // Newest thread first, so the records page needs no second sort.
        #expect(inbox.threads.map(\.threadId) == ["th_new", "th_old"])
        #expect(inbox.threads[0].isReplied)
        #expect(!inbox.threads[1].isReplied)
        #expect(inbox.threads[0].messages.map(\.author) == [.user, .owner])
        #expect(inbox.threads[0].messages[1].body == "回复")
        #expect(inbox.notices.first?.subject == "服务通知")
        #expect(inbox.notices.first?.read == false)

        let body = try jsonBody()
        #expect(body["messagesPerThread"] as? Int == 20)
        #expect(body["notices"] as? Bool == true)
        let sent = try #require(body["tickets"] as? [[String: Any]])
        #expect(sent.count == 1)
        #expect(sent[0]["threadId"] as? String == "th_1")
        #expect(sent[0]["ticketKey"] as? String == "fk_th_1")
        #expect(sent[0]["createdAt"] == nil, "时间戳不该混进取件凭据的请求体")
        // A relay with no mount prefix still resolves.
        Stub.reset([.init(status: 200, body: Data(#"{"ok":true,"threads":[],"notices":[],"unreadCount":0}"#.utf8))])
        _ = try await client(relay: "https://relay.test", token: nil).inbox(tickets: [])
        #expect(Stub.requests.first?.url?.absoluteString == "https://relay.test/feedback/inbox")
    }

    @Test("append carries the ticket and decodes the new message")
    func appendRequest() async throws {
        Stub.reset([.init(status: 200, body: Data(
            #"{"ok":true,"threadId":"th_1","messageId":"fm_9","createdAt":1760000900000}"#.utf8
        ))])

        let result = try await client().append(
            threadId: "th_1", ticketKey: "fk_th_1", text: "补充：只有 iOS 18 会这样",
            clientRef: "A1C3"
        )

        #expect(result.messageId == "fm_9")
        #expect(result.createdAt == Date(timeIntervalSince1970: 1_760_000_900))
        let request = try #require(Stub.requests.first)
        #expect(request.url?.absoluteString == "https://relay.test/dsh-link/feedback/append")
        let body = try jsonBody()
        #expect(body["threadId"] as? String == "th_1")
        #expect(body["ticketKey"] as? String == "fk_th_1")
        #expect(body["clientRef"] as? String == "A1C3")
    }

    @Test("markRead sends thread and notice ids and answers with what is left")
    func markReadRequest() async throws {
        Stub.reset([.init(status: 200, body: Data(#"{"ok":true,"unreadCount":0}"#.utf8))])

        let remaining = try await client().markRead(
            threadIds: ["th_1"], noticeIds: ["nt_1"], tickets: [ticket()]
        )

        #expect(remaining == 0)
        let request = try #require(Stub.requests.first)
        #expect(request.url?.absoluteString == "https://relay.test/dsh-link/feedback/read")
        let body = try jsonBody()
        #expect(body["threadIds"] as? [String] == ["th_1"])
        #expect(body["noticeIds"] as? [String] == ["nt_1"])
        let sent = try #require(body["tickets"] as? [[String: Any]])
        #expect(sent.first?["ticketKey"] as? String == "fk_th_1")
    }

    // MARK: - Failures

    @Test("a rate limit is its own failure, not a status code")
    func rateLimited() async throws {
        Stub.reset([.init(status: 429, body: Data(
            #"{"ok":false,"error":{"code":"feedback/rate-limited","message":"提交过于频繁"}}"#.utf8
        ))])
        let error = await failure { _ = try await client(token: nil).submit(text: "再试一次") }
        #expect(error == .rateLimited)
    }

    @Test("an over-long body is reported as a length problem")
    func tooLong() async throws {
        Stub.reset([.init(status: 400, body: Data(
            #"{"ok":false,"error":{"code":"feedback/too-long","message":"正文最多 4000 字"}}"#.utf8
        ))])
        let overLong = await failure {
            _ = try await client().submit(text: String(repeating: "x", count: 4001))
        }
        #expect(overLong == .tooLong)

        // The 16 KB request-body rejection is the same class of problem: the
        // draft is what has to shrink.
        Stub.reset([.init(status: 413, body: Data(
            #"{"ok":false,"error":{"code":"feedback/too-large","message":"请求体过大"}}"#.utf8
        ))])
        let tooLarge = await failure { _ = try await client().submit(text: "x") }
        #expect(tooLarge == .tooLong)
    }

    @Test("a missing thread and a wrong ticket are the same not-found")
    func notFound() async throws {
        Stub.reset([.init(status: 404, body: Data(
            #"{"ok":false,"error":{"code":"feedback/not-found","message":"not found"}}"#.utf8
        ))])
        let error = await failure {
            _ = try await client().append(threadId: "th_x", ticketKey: "fk_bad", text: "补充")
        }
        #expect(error == .notFound)

        // A relay that answers 404 without the envelope code still lands here.
        Stub.reset([.init(status: 404, body: Data("<html>404</html>".utf8))])
        let bare = await failure { _ = try await client().markRead(threadIds: ["th_x"]) }
        #expect(bare == .notFound)
    }

    @Test("other non-2xx answers keep the relay's own code")
    func serverFailure() async throws {
        Stub.reset([.init(status: 500, body: Data(
            #"{"ok":false,"error":{"code":"feedback/store-error","message":"落库失败"}}"#.utf8
        ))])
        let error = await failure { _ = try await client().submit(text: "一条反馈") }
        #expect(error == .server(status: 500, code: "feedback/store-error"))

        // No envelope at all: the status is all we have to report.
        Stub.reset([.init(status: 503, body: Data("upstream down".utf8))])
        let bare = await failure { _ = try await client(token: nil).submit(text: "一条反馈") }
        #expect(bare == .server(status: 503, code: nil))
    }

    @Test("a 200 that is not our envelope is a decode failure, not a 200")
    func decodingFailureIsNotASuccess() async throws {
        Stub.reset([.init(status: 200, body: Data("<html>nope</html>".utf8))])
        let error = await failure { _ = try await client().inbox(tickets: []) }
        guard case .decoding = error else {
            Issue.record("expected .decoding, got \(String(describing: error))")
            return
        }
    }

    @Test("a 200 without a ticket key is a decode failure, never a usable ticket")
    func successWithoutPayload() async throws {
        Stub.reset([.init(status: 200, body: Data(#"{"ok":true,"threadId":"th_1"}"#.utf8))])
        let error = await failure { _ = try await client().submit(text: "一条反馈") }
        #expect(error == .server(status: 200, code: nil))
    }

    @Test("a dead connection is a network failure with a diagnostic detail")
    func networkFailure() async throws {
        Stub.reset([], failingWith: URLError(.notConnectedToInternet))
        let error = await failure { _ = try await client().inbox(tickets: []) }
        guard case .network(let detail) = error else {
            Issue.record("expected .network, got \(String(describing: error))")
            return
        }
        #expect(!detail.isEmpty)
    }

    // MARK: - Models

    @Test("an unknown author or status does not fail the whole inbox")
    func unknownAuthorDegrades() throws {
        let data = Data("""
        {"threadId":"th_1","status":"archived","createdAt":null,"lastMessageAt":1760000000000,
         "unread":0,"messages":[{"messageId":"fm_1","author":"robot","body":"hi","createdAt":1760000000000}]}
        """.utf8)
        let thread = try JSONDecoder().decode(FeedbackThread.self, from: data)
        #expect(thread.messages.first?.author == .unknown)
        #expect(!thread.isReplied)
        #expect(thread.createdAt == nil)
        #expect(thread.lastMessageAt != nil)
    }

    @Test("a ticket round-trips through JSON with the relay's millisecond stamp")
    func ticketIsStorable() throws {
        let original = FeedbackTicket(
            threadId: "th_1", ticketKey: "fk_1", createdAt: Date(timeIntervalSince1970: 1_760_000_000)
        )
        let encoded = try JSONEncoder().encode([original])
        #expect(String(decoding: encoded, as: UTF8.self).contains("1760000000000"))
        let decoded = try JSONDecoder().decode([FeedbackTicket].self, from: encoded)
        #expect(decoded == [original])
    }

    // MARK: - 正文格式（FR-034）

    /// 三种解码都要能跑：服务端此刻还没有 `format` 字段，收到它的那条路还必须先能跑。
    @Test("an html body carries its format through both models")
    func htmlFormatDecodes() throws {
        let message = try JSONDecoder().decode(FeedbackMessage.self, from: Data("""
        {"messageId":"fm_1","author":"owner","body":"<h1>日报</h1>","format":"html","createdAt":1760000000000}
        """.utf8))
        #expect(message.format == "html")
        #expect(message.bodyFormat == .html)

        let notice = try JSONDecoder().decode(FeedbackNotice.self, from: Data("""
        {"noticeId":"nt_1","subject":"日报","body":"<h1>日报</h1>","format":"html",
         "createdAt":1760000000000,"read":false}
        """.utf8))
        #expect(notice.format == "html")
        #expect(notice.bodyFormat == .html)
    }

    @Test("a missing format reads as Markdown on both models")
    func missingFormatIsText() throws {
        // 老服务端（还没有这个字段）发来的那两种形状：整个键都没有，或显式 null。
        let absent = try JSONDecoder().decode(FeedbackMessage.self, from: Data("""
        {"messageId":"fm_1","author":"owner","body":"你好：","createdAt":1760000000000}
        """.utf8))
        #expect(absent.format == "text")
        #expect(absent.bodyFormat == .text)

        let null = try JSONDecoder().decode(FeedbackNotice.self, from: Data("""
        {"noticeId":"nt_1","subject":null,"body":"维护通知","format":null,"createdAt":1760000000000,"read":true}
        """.utf8))
        #expect(null.format == "text")
        #expect(null.bodyFormat == .text)
        #expect(null.read)
    }

    @Test("an unknown format degrades to Markdown, never to the HTML container")
    func unknownFormatIsText() throws {
        // 认不出的值（未来新增的格式、拼错的、大小写不一致的非 html）都不能开门进 HTML
        // 容器——那条路要多锁一层才敢开，只有明确的 `html` 才算。
        for raw in ["markdown", "rich", "hTmLx", "", "1"] {
            let message = try JSONDecoder().decode(FeedbackMessage.self, from: Data("""
            {"messageId":"fm_1","author":"owner","body":"正文","format":"\(raw)","createdAt":1}
            """.utf8))
            #expect(message.format == "text", "format=\(raw) 该按 text 处理")
            #expect(message.bodyFormat == .text)

            let notice = try JSONDecoder().decode(FeedbackNotice.self, from: Data("""
            {"noticeId":"nt_1","subject":null,"body":"正文","format":"\(raw)","createdAt":1,"read":false}
            """.utf8))
            #expect(notice.format == "text", "format=\(raw) 该按 text 处理")
            #expect(notice.bodyFormat == .text)
        }
        // 大小写不同的 `html` 写法照旧认：它不是认不出的值。
        let upper = try JSONDecoder().decode(FeedbackMessage.self, from: Data("""
        {"messageId":"fm_1","author":"owner","body":"<h1>x</h1>","format":"HTML","createdAt":1}
        """.utf8))
        #expect(upper.format == "html")
        #expect(upper.bodyFormat == .html)
    }

    @Test("an inbox answer carries the format of messages and notices alike")
    func inboxCarriesFormat() async throws {
        Stub.reset([.init(status: 200, body: Data("""
        {"ok":true,"unreadCount":1,
         "threads":[{"threadId":"th_1","status":"replied","createdAt":1,"lastMessageAt":2,"unread":1,
          "messages":[{"messageId":"fm_1","author":"owner","body":"# 回信","format":"text","createdAt":2}]}],
         "notices":[{"noticeId":"nt_1","subject":"日报","body":"<h1>日报</h1>","format":"html",
          "createdAt":3,"read":false}]}
        """.utf8))])

        let inbox = try await client().inbox(tickets: [ticket()])
        #expect(inbox.threads.first?.messages.first?.bodyFormat == .text)
        #expect(inbox.notices.first?.bodyFormat == .html)
        // 镜像要存得下这个字段：离线渲染的判据来自本机那份 JSON。
        let encoded = try JSONEncoder().encode(inbox.notices.first)
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"format\":\"html\""))
    }

    // MARK: - v2 契约形状（2026-10-27 信件整改）

    private var v2Answer: Data {
        Data("""
        {"ok":true,"inboxVersion":2,"teamPerspective":true,"unreadCount":3,
         "threads":[{"threadId":"th_1","subject":"s","status":"open","createdAt":1760000000000,
                     "lastMessageAt":1760000001000,"unread":0,"teamUnread":9,"mySide":"owner",
                     "messages":[{"messageId":"u_1","author":"user","body":"q","createdAt":1760000001000}]}],
         "threadsPage":{"more":true,"nextBefore":{"lastMessageAt":1760000001000,"threadId":"th_1"}},
         "notices":[{"noticeId":"nt_1","subject":"weekly","format":"text",
                     "createdAt":1760000002000,"read":false}],
         "noticesPage":{"more":true,"nextBefore":{"createdAt":1760000002000,"noticeId":"nt_1"}},
         "limits":{"textChars":4000,"textBytes":12000,"subjectChars":80,"maxTicketPairs":200}}
        """.utf8)
    }

    @Test("a v2 answer carries the per-thread side, both pages, limits and summaries without bodies")
    func v2InboxShape() async throws {
        Stub.reset([.init(status: 200, body: v2Answer)])

        let inbox = try await client().inbox(tickets: [ticket()])

        #expect(inbox.inboxVersion == 2)
        #expect(inbox.isVersion2)
        #expect(inbox.threads.first?.mySide == .owner)
        #expect(inbox.threads.first?.resolvedSide == .owner)
        #expect(inbox.notices.first?.body == nil, "v2 lists carry summaries only")
        #expect(inbox.threadsPage?.more == true)
        #expect(inbox.threadsPage?.nextBefore?.threadId == "th_1")
        #expect(inbox.threadsPage?.nextBefore?.lastMessageAt == Date(timeIntervalSince1970: 1_760_000_001))
        #expect(inbox.noticesPage?.more == true)
        #expect(inbox.noticesPage?.nextBefore?.noticeId == "nt_1")
        #expect(inbox.limits?.textChars == 4000)
        #expect(inbox.limits?.textBytes == 12000)

        let body = try jsonBody()
        #expect(body["inboxVersion"] as? Int == 2, "v2 is switched on by the request, not sniffed")
        #expect(body["messagesPerThread"] == nil, "omitted = the server's own default")
        #expect(body["threadsPage"] == nil)
        #expect(body["noticePage"] == nil)
    }

    @Test("a v1 answer without mySide derives the side from the account perspective")
    func v1InboxDerivesMySide() async throws {
        Stub.reset([.init(status: 200, body: Data("""
        {"ok":true,"teamPerspective":true,"unreadCount":0,
         "threads":[{"threadId":"th_1","status":"open","unread":0,"teamUnread":0,
                     "messages":[{"messageId":"u_1","author":"user","body":"q","createdAt":1}]}],
         "notices":[]}
        """.utf8))])
        let team = try await client().inbox(tickets: [ticket()])
        #expect(team.inboxVersion == nil)
        #expect(!team.isVersion2)
        #expect(team.threads.first?.mySide == .owner)
        #expect(team.threadsPage == nil, "an old relay has no pages")
        #expect(team.limits == nil)

        Stub.reset([.init(status: 200, body: Data("""
        {"ok":true,"unreadCount":0,
         "threads":[{"threadId":"th_1","status":"reply","unread":0,
                     "messages":[{"messageId":"o_1","author":"owner","body":"a","createdAt":1}]}],
         "notices":[]}
        """.utf8))])
        let user = try await client().inbox(tickets: [ticket()])
        #expect(user.threads.first?.mySide == .user)
    }

    @Test("mySide stays optional: missing or unknown values never fail the inbox")
    func mySideIsOptional() throws {
        let owner = try JSONDecoder().decode(FeedbackThread.self, from: Data(
            #"{"threadId":"th_1","mySide":"owner","messages":[]}"#.utf8))
        #expect(owner.mySide == .owner)
        #expect(owner.resolvedSide == .owner)

        let missing = try JSONDecoder().decode(FeedbackThread.self, from: Data(
            #"{"threadId":"th_1","messages":[]}"#.utf8))
        #expect(missing.mySide == nil)
        #expect(missing.resolvedSide == .user, "the only nil fallback is the user side")

        let unknown = try JSONDecoder().decode(FeedbackThread.self, from: Data(
            #"{"threadId":"th_1","mySide":"robot","messages":[]}"#.utf8))
        #expect(unknown.mySide == nil)
    }

    @Test("a paging request carries only the cursor of the path being advanced")
    func pagingRequestCarriesTheCursor() async throws {
        Stub.reset([.init(status: 200, body: Data(
            #"{"ok":true,"inboxVersion":2,"threads":[],"notices":[],"unreadCount":0}"#.utf8))])

        _ = try await client().inbox(
            tickets: [],
            threadsPage: FeedbackPageRequest(
                limit: 30,
                before: FeedbackPageCursor(lastMessageAt: Date(timeIntervalSince1970: 1_760_000_000),
                                           threadId: "th_1"))
        )

        let body = try jsonBody()
        #expect(body["noticePage"] == nil)
        let page = try #require(body["threadsPage"] as? [String: Any])
        #expect(page["limit"] as? Int == 30)
        let before = try #require(page["before"] as? [String: Any])
        #expect(before["lastMessageAt"] as? Int == 1_760_000_000_000, "the relay reads milliseconds")
        #expect(before["threadId"] as? String == "th_1")
        #expect(before["createdAt"] == nil)
    }

    @Test("notice fetches one body by id and maps both failures like a thread")
    func noticeRequest() async throws {
        Stub.reset([.init(status: 200, body: Data("""
        {"ok":true,"notice":{"noticeId":"nt_1","subject":"daily","body":"<h1>daily</h1>",
                             "format":"html","createdAt":5000,"read":false}}
        """.utf8))])

        let notice = try await client().notice(noticeId: "nt_1")

        #expect(notice.body == "<h1>daily</h1>")
        #expect(notice.bodyFormat == .html)
        #expect(Stub.requests.first?.url?.absoluteString == "https://relay.test/dsh-link/feedback/notice")
        #expect(try jsonBody()["noticeId"] as? String == "nt_1")

        Stub.reset([.init(status: 404, body: Data(
            #"{"ok":false,"error":{"code":"feedback/not-found","message":"gone"}}"#.utf8))])
        let gone = await failure { _ = try await client().notice(noticeId: "nt_x") }
        #expect(gone == .notFound)

        Stub.reset([.init(status: 200, body: Data(#"{"ok":true}"#.utf8))])
        let empty = await failure { _ = try await client().notice(noticeId: "nt_x") }
        #expect(empty == .server(status: 200, code: nil))
    }

    @Test("a v2 notice summary decodes without a body and keeps html format")
    func noticeSummaryWithoutBody() throws {
        let summary = try JSONDecoder().decode(FeedbackNotice.self, from: Data(
            #"{"noticeId":"nt_1","subject":"s","format":"html","createdAt":1,"read":false}"#.utf8))
        #expect(summary.body == nil)
        #expect(!summary.hasBody)
        #expect(summary.bodyFormat == .html, "the list still knows how to render it once fetched")

        let inline = try JSONDecoder().decode(FeedbackNotice.self, from: Data(
            #"{"noticeId":"nt_1","body":"inline","createdAt":1,"read":true}"#.utf8))
        #expect(inline.body == "inline")
        #expect(inline.hasBody)
    }

    // MARK: - E3 真实服务端响应夹具

    /// 真 `mail` 服务（整改后的代码）对**生产库副本**跑出来的一份 v2 响应原文。
    ///
    /// 抓取：2026-10-27 23:44（Asia/Shanghai），库 `/tmp/mailcopy.db` 的副本，
    /// `POST /dsh-link/feedback/inbox {"inboxVersion":2}`，调用方是团队账号
    /// （团队账号，已脱敏）的设备令牌；服务端即 `mail/create_app` + 真 SQLite。
    /// 内容：6 条线程（每线程 2 条留言，`mySide=owner`）、40 条通知摘要（无 `body`）、
    /// `limits`（4000/12000/80）、两路 `nextBefore`（线程到头、通知还有更多）。
    ///
    /// 这份夹具存在的意义：客户端解码路径吃的是**服务端真实响应**，不是开发手写的桩；
    /// 桩与服务端一旦键名漂移，这条会红。
    private func realMailV2Answer() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/feedback-inbox-v2.json")
        return try Data(contentsOf: url)
    }

    @Test("a real v2 answer from the mail service decodes with mySide, both pages and limits")
    func realServerAnswerDecodes() async throws {
        Stub.reset([.init(status: 200, body: try realMailV2Answer())])

        let inbox = try await client().inbox(tickets: [])

        #expect(inbox.inboxVersion == 2)
        #expect(inbox.isVersion2)
        #expect(inbox.teamPerspective)
        #expect(inbox.threads.count == 6)
        #expect(inbox.notices.count == 40)
        // 每条线程都带服务端判定的 mySide（这份响应的 6 条都是团队侧看的用户来信）。
        #expect(inbox.threads.allSatisfy { $0.mySide == .owner })
        #expect(inbox.threads.allSatisfy { !$0.messages.isEmpty })
        // v2 列表只给摘要：正文按需取，列表里一条 body 都没有。
        #expect(inbox.notices.allSatisfy { $0.body == nil })
        #expect(inbox.notices.allSatisfy { ($0.subject?.isEmpty == false) })
        // 分页与 limits 都是服务端下发的真实值（不是客户端补的默认）。
        #expect(inbox.threadsPage?.more == false)
        #expect(inbox.threadsPage?.nextBefore?.threadId != nil)
        #expect(inbox.noticesPage?.more == true)
        #expect(inbox.noticesPage?.nextBefore?.noticeId != nil)
        #expect(inbox.limits == FeedbackLimits(textChars: 4000, textBytes: 12000, subjectChars: 80))
        // 真响应里的请求体没有被夹具夹带：这次请求仍然只声明 v2。
        #expect(try jsonBody()["inboxVersion"] as? Int == 2)
    }
}
