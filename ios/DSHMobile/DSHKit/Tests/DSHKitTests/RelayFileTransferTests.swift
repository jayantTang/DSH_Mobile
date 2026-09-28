import Foundation
import Testing

@testable import DSHKit
import RelayKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The background upload path (R-1 C-18), driven by an injected session.
///
/// **No real background session is opened here on purpose.** `URLSessionConfiguration
/// .background` only exists on iOS and only behaves that way there — on macOS (where
/// this suite runs) a background session is an ordinary one, so a test that used one
/// would prove nothing about being woken up after suspension. What *is* testable
/// here, and is where the bugs actually were, is the request that goes out, the
/// path-selection policy, and the fallback.
///
/// Serialised because the stub keeps its canned answers in static storage.
@Suite("Background file transfer", .serialized)
struct RelayFileTransferTests {

    /// A URLProtocol that records requests and replays canned answers.
    final class Stub: URLProtocol, @unchecked Sendable {
        struct Exchange: Sendable {
            let status: Int
            let body: Data
        }

        nonisolated(unsafe) static var exchanges: [Exchange] = []
        nonisolated(unsafe) static var requests: [URLRequest] = []

        static func reset(_ list: [Exchange]) {
            exchanges = list
            requests = []
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requests.append(request)
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

    private func transfer(relay: String = "https://relay.test/dsh-link") -> RelayFileTransfer {
        RelayFileTransfer(
            relayURL: URL(string: relay)!,
            deviceToken: "dt_phone",
            session: Stub.session()
        )
    }

    /// A file of the given size in a temporary directory.
    private func makeFile(bytes: Int, name: String = "big.bin") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-file-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x5a, count: bytes).write(to: url)
        return url
    }

    // MARK: - the request

    @Test("the upload goes to the relay under its mount prefix with every query field")
    func requestShape() async throws {
        Stub.reset([.init(status: 200, body: Data(#"{"path":"/home/u/.dsh/inbox/s1/big.bin","bytes":12}"#.utf8))])
        let file = try makeFile(bytes: 12)
        _ = try await transfer().upload(fileURL: file, name: "big.bin",
                                        sessionId: "s-1", bid: "bid-1")

        let request = try #require(Stub.requests.first)
        let url = try #require(request.url)
        #expect(url.path == "/dsh-link/files/up")
        #expect(request.httpMethod == "PUT")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer dt_phone")

        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let fields = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value) })
        #expect(fields["sessionId"] == "s-1")
        #expect(fields["name"] == "big.bin")
        #expect(fields["bytes"] == "12")
        #expect(fields["bid"] == "bid-1")
    }

    @Test("the staged answer reads as the same shape the WSS path returns")
    func stagedShape() async throws {
        Stub.reset([.init(status: 200, body: Data(#"{"path":"/home/u/.dsh/inbox/s1/notes.txt","bytes":7}"#.utf8))])
        let file = try makeFile(bytes: 7, name: "notes.txt")
        let staged = try await transfer().upload(fileURL: file, name: "notes.txt",
                                                 sessionId: "s-1", bid: "b")
        #expect(staged.path == "/home/u/.dsh/inbox/s1/notes.txt")
        #expect(staged.bytes == 7)
        // 调用方不该需要知道文件是走哪条路送到的。
        #expect(staged.asStaged.path == staged.path)
        #expect(staged.asStaged.bytes == staged.bytes)
    }

    @Test("a stable bid is reused when the same attempt is retried")
    func stableBid() async throws {
        // 连接器按 bid 覆盖写，所以同一次尝试的重试必须复用同一个 id——
        // 否则重试会在电脑上留下第二份文件。
        Stub.reset([
            .init(status: 503, body: Data(#"{"ok":false,"error":{"code":"host/offline","message":"no"}}"#.utf8)),
            .init(status: 200, body: Data(#"{"path":"/p","bytes":3}"#.utf8)),
        ])
        let file = try makeFile(bytes: 3)
        let subject = transfer()
        _ = try? await subject.upload(fileURL: file, name: "a.bin", sessionId: "s", bid: "same-bid")
        _ = try await subject.upload(fileURL: file, name: "a.bin", sessionId: "s", bid: "same-bid")

        let bids = Stub.requests.compactMap { request -> String? in
            guard let url = request.url,
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            else { return nil }
            return items.first { $0.name == "bid" }?.value
        }
        #expect(bids == ["same-bid", "same-bid"])
    }

    // MARK: - failures and the fallback

    @Test("a relay error is surfaced with the relay's own code")
    func relayError() async throws {
        Stub.reset([.init(status: 409, body: Data(#"{"ok":false,"error":{"code":"file/rejected","message":"no space"}}"#.utf8))])
        let file = try makeFile(bytes: 4)
        await #expect(throws: DSHRPCFailure.self) {
            _ = try await transfer().upload(fileURL: file, name: "a", sessionId: "s", bid: "b")
        }
    }

    @Test("the statuses that mean \"use the other path\" are recognised")
    func fallbackStatuses() {
        // 老连接器不认这一族帧 → 501；中转拒绝体积 → 413；没有这条路由 → 404/405。
        #expect(RelayFileTransfer.shouldFallBack(status: 501))
        #expect(RelayFileTransfer.shouldFallBack(status: 413))
        #expect(RelayFileTransfer.shouldFallBack(status: 404))
        #expect(RelayFileTransfer.shouldFallBack(status: 405))
        // 这些是"这次没成"，不该被悄悄换成另一条路再传一遍整个文件。
        #expect(!RelayFileTransfer.shouldFallBack(status: 500))
        #expect(!RelayFileTransfer.shouldFallBack(status: 401))
        #expect(!RelayFileTransfer.shouldFallBack(status: 409))
    }

    @Test("the capability gate is feature detection, not a version comparison")
    func capabilityGate() {
        #expect(RelayFileTransfer.supportsBackgroundTransfer(
            capabilities: ["file-transfer", "background-transfer"]))
        // 老连接器不列这个词：不启用新路，退回 WSS。
        #expect(!RelayFileTransfer.supportsBackgroundTransfer(capabilities: ["file-transfer", "events"]))
        #expect(!RelayFileTransfer.supportsBackgroundTransfer(capabilities: []))
        #expect(RelayFileTransfer.capability == "background-transfer")
    }

    // MARK: - the threshold

    @Test("the threshold defaults to 8 MB and a large value is the kill switch")
    func threshold() {
        #expect(RelayFileTransfer.thresholdBytes(value: nil) == 8 * 1024 * 1024)
        #expect(RelayFileTransfer.thresholdBytes(value: "") == 8 * 1024 * 1024)
        #expect(RelayFileTransfer.thresholdBytes(value: "8") == 8 * 1024 * 1024)
        #expect(RelayFileTransfer.thresholdBytes(value: "1") == 1024 * 1024)
        #expect(RelayFileTransfer.thresholdBytes(value: "0") == 0)
        // 设成很大的值 = 回到"只有 WSS"的今天（回落手段）：100000 MB 是 100 GB，
        // 比任何真实文件都大得多。
        let huge = RelayFileTransfer.thresholdBytes(value: "100000")
        #expect(huge == 100_000 * 1024 * 1024)
        #expect(huge > 32 * 1024 * 1024 * 1024)
        // 解析不了就用默认值，而不是变成一个奇怪的门槛。
        #expect(RelayFileTransfer.thresholdBytes(value: "abc") == 8 * 1024 * 1024)
    }

    @Test("a file's size comes from the filesystem, not from the caller")
    func fileSize() throws {
        let file = try makeFile(bytes: 12345)
        #expect(RelayFileTransfer.fileSize(file) == 12345)
        // 不存在的文件读作 0：那会让它落在阈值下面 → 走已经验过的 WSS 路。
        #expect(RelayFileTransfer.fileSize(file.deletingLastPathComponent()
            .appendingPathComponent("nope")) == 0)
    }

    @Test("the macOS build has no background configuration, and says so")
    func noBackgroundOnMacOS() {
        // 这条不是"跳过测试"：它钉住的是 `backgroundConfiguration()` 在非 iOS 上
        // 明确返回 nil（而不是悄悄给一个普通配置，让调用方以为拿到了后台语义）。
        #if os(iOS)
        #expect(RelayFileTransfer.backgroundConfiguration() != nil)
        #else
        #expect(RelayFileTransfer.backgroundConfiguration() == nil)
        #endif
    }
}
