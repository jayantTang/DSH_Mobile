import Foundation
import Testing

@testable import DSHKit
import RelayKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 信件附件的 wire 契约（2026-11-12）：`preview` / `compressed` / `limits.roles`
/// 的解码，`beginAttachment(role:)` 的请求，以及 `fetchAttachment` 的**流式**取字节
/// 与进度回调（旧的非流式实现已被替换，不保留第二条通路）。
@Suite("Relay feedback attachment wire", .serialized)
struct RelayFeedbackAttachmentWireTests {

    /// 一条能声明 `Content-Length` 并分块投递的桩：流式取字节要能看到进度。
    final class ChunkedStub: URLProtocol, @unchecked Sendable {
        struct Answer: Sendable {
            let status: Int
            let headers: [String: String]
            let chunks: [Data]
        }

        nonisolated(unsafe) static var answer = Answer(status: 500, headers: [:], chunks: [])
        nonisolated(unsafe) static var requests: [URLRequest] = []

        static func reset(_ answer: Answer) {
            Self.answer = answer
            requests = []
        }

        static func session() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ChunkedStub.self]
            return URLSession(configuration: configuration)
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requests.append(request)
            let answer = Self.answer
            let response = HTTPURLResponse(url: request.url!, statusCode: answer.status,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: answer.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in answer.chunks {
                client?.urlProtocol(self, didLoad: chunk)
            }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func client() -> RelayFeedbackClient {
        RelayFeedbackClient(relayURL: URL(string: "https://relay.test/dsh-link")!,
                            deviceToken: "dt_phone",
                            session: ChunkedStub.session())
    }

    private func beginBody() throws -> [String: Any] {
        let body = try #require(ChunkedStub.requests.first?.httpBody
                                ?? ChunkedStub.requests.first?.httpBodyStream.flatMap(Self.read))
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0 ..< count])
        }
        return data
    }

    // MARK: - 解码

    @Test("a paired attachment decodes the original plus its preview")
    func pairedAttachmentDecodes() throws {
        let json = Data("""
        {"attachmentId":"fa_original","name":"IMG_1234.jpg","contentType":"image/jpeg",
         "byteSize":7340032,"sha256":"aaaa","width":3544,"height":7680,
         "createdAt":1791825010506,"compressed":false,
         "preview":{"attachmentId":"fa_preview","contentType":"image/jpeg",
                    "byteSize":471859,"sha256":"bbbb","width":1181,"height":2560}}
        """.utf8)
        let attachment = try JSONDecoder().decode(FeedbackAttachment.self, from: json)
        #expect(attachment.attachmentId == "fa_original")
        #expect(attachment.compressed == false)
        let preview = try #require(attachment.preview)
        #expect(preview.attachmentId == "fa_preview")
        #expect(preview.contentType == "image/jpeg")
        #expect(preview.byteSize == 471_859)
        #expect(preview.sha256 == "bbbb")
        #expect(preview.width == 1181)
        #expect(preview.height == 2560)
    }

    @Test("a preview-only attachment decodes as compressed without a preview object")
    func compressedAttachmentDecodes() throws {
        let json = Data("""
        {"attachmentId":"fa_preview","name":"截屏.jpg","contentType":"image/jpeg",
         "byteSize":471859,"sha256":"cccc","createdAt":1791825010506,"compressed":true}
        """.utf8)
        let attachment = try JSONDecoder().decode(FeedbackAttachment.self, from: json)
        #expect(attachment.compressed == true)
        #expect(attachment.preview == nil)
    }

    @Test("an old attachment decodes with no preview and not compressed")
    func legacyAttachmentDecodes() throws {
        let json = Data("""
        {"attachmentId":"fa_old","name":"旧.png","contentType":"image/png",
         "byteSize":12,"sha256":"dddd","width":null,"height":null,"createdAt":1791825010506}
        """.utf8)
        let attachment = try JSONDecoder().decode(FeedbackAttachment.self, from: json)
        #expect(attachment.preview == nil)
        #expect(attachment.compressed == false)
    }

    @Test("limits decode the roles capability and default it to none")
    func limitsDecodeRoles() throws {
        let paired = try JSONDecoder().decode(FeedbackAttachmentLimits.self, from: Data("""
        {"maxPerMessage":8,"maxFileBytes":8388608,"maxTotalBytes":25165824,
         "types":["jpeg"],"roles":["original","preview"]}
        """.utf8))
        #expect(paired.roles == ["original", "preview"])

        let legacy = try JSONDecoder().decode(FeedbackAttachmentLimits.self, from: Data("""
        {"maxPerMessage":8,"maxFileBytes":8388608,"maxTotalBytes":25165824,"types":["jpeg"]}
        """.utf8))
        #expect(legacy.roles == [], "缺 roles = 这个服务端只会落单文件")
    }

    // MARK: - 请求

    @Test("begin carries the role, and omits it when the caller does not pick one")
    func beginCarriesRole() async throws {
        ChunkedStub.reset(.init(status: 200, headers: [:], chunks: [Data("""
        {"ok":true,"attachmentId":"fa_1","slot":0,"role":"preview","state":"pending",
         "byteSize":12,"sha256":"eeee","createdAt":1791825010506}
        """.utf8)]))
        _ = try await client().beginAttachment(
            clientRef: "ref-1", slot: 0, name: "截屏.jpg", contentType: "image/jpeg",
            byteSize: 12, sha256: "eeee", role: "preview")
        #expect(try beginBody()["role"] as? String == "preview")

        ChunkedStub.reset(.init(status: 200, headers: [:], chunks: [Data("""
        {"ok":true,"attachmentId":"fa_2","state":"pending","byteSize":12,"sha256":"eeee"}
        """.utf8)]))
        _ = try await client().beginAttachment(
            clientRef: "ref-1", slot: 0, name: "旧.png", contentType: "image/png",
            byteSize: 12, sha256: "eeee")
        #expect(try beginBody()["role"] == nil, "旧服务端看不懂这个键，旧请求形状不变")
    }

    // MARK: - 流式取字节

    @Test("fetch streams the bytes and reports progress against Content-Length")
    func fetchStreamsWithProgress() async throws {
        let chunks = [Data(repeating: 0x41, count: 4),
                      Data(repeating: 0x42, count: 4),
                      Data(repeating: 0x43, count: 4)]
        ChunkedStub.reset(.init(status: 200,
                                headers: ["Content-Type": "image/jpeg",
                                          "Content-Length": "12"],
                                chunks: chunks))
        let recorder = ProgressRecorder()
        let bytes = try await client().fetchAttachment(
            attachmentId: "fa_original", ticketKey: "fk_1",
            onProgress: { received, total in recorder.record(received, total) })

        #expect(bytes == chunks.reduce(Data(), +), "流式读完的字节必须与分块一致")
        let progress = recorder.values
        #expect(progress.first?.total == 12, "总长来自 Content-Length")
        #expect(progress.last?.received == 12, "最后一次进度等于总长")
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $0.received <= $1.received },
                "进度单调不减")

        let request = try #require(ChunkedStub.requests.first)
        #expect(request.url?.absoluteString == "https://relay.test/dsh-link/feedback/attachment/fetch")
        #expect(request.value(forHTTPHeaderField: "X-Feedback-Ticket") == "fk_1")
    }

    @Test("fetch maps a non-2xx answer without waiting for a body shape")
    func fetchMapsFailure() async throws {
        ChunkedStub.reset(.init(status: 404,
                                headers: ["Content-Type": "application/json"],
                                chunks: [Data(#"{"ok":false,"error":{"code":"feedback/not-found"}}"#.utf8)]))
        do {
            _ = try await client().fetchAttachment(attachmentId: "fa_missing")
            Issue.record("a 404 must throw")
        } catch let error as FeedbackClientError {
            guard case .notFound = error else {
                Issue.record("expected .notFound, got \(error)")
                return
            }
        }
    }

    /// 进度回调来自别的线程；测试只需要一个有序序列。
    final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(received: Int, total: Int?)] = []

        func record(_ received: Int, _ total: Int?) {
            lock.lock()
            storage.append((received, total))
            lock.unlock()
        }

        var values: [(received: Int, total: Int?)] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }
}
