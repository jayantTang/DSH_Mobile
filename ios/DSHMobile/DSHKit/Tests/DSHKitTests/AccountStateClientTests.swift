import Foundation
import Testing

@testable import DSHKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 账户级状态客户端：请求长什么样、回答怎么解读、合并规则怎么定。
// Serialised：stub 的罐头回答放在静态存储里，并发会互相吃掉。
@Suite("Account state client", .serialized)
struct AccountStateClientTests {

    final class Stub: URLProtocol, @unchecked Sendable {
        struct Exchange: Sendable {
            let status: Int
            let body: Data
        }

        nonisolated(unsafe) static var exchanges: [Exchange] = []
        nonisolated(unsafe) static var requests: [URLRequest] = []
        nonisolated(unsafe) static var bodies: [Data] = []

        static func reset(_ list: [Exchange]) {
            exchanges = list
            requests = []
            bodies = []
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requests.append(request)
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

            let exchange = Self.exchanges.isEmpty
                ? Exchange(status: 500, body: Data("{}".utf8))
                : Self.exchanges.removeFirst()
            let response = HTTPURLResponse(url: request.url!, statusCode: exchange.status,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: exchange.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeClient(mount: String = "") -> AccountStateClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        let base = mount.isEmpty ? "https://relay.test" : "https://relay.test/\(mount)"
        return AccountStateClient(relayURL: URL(string: base)!,
                                  deviceToken: "dt_test",
                                  session: URLSession(configuration: configuration))
    }

    @Test("拉取带上 Bearer 令牌与 keys 查询，回答解析成条目")
    func fetchCarriesTheTokenAndParsesEntries() async throws {
        Stub.reset([.init(status: 200, body: Data(#"""
        {"ok":true,"accountId":"acc_1","entries":{
          "alertPrefs":{"value":{"turnEnd":false},"updatedAt":1790000000000,"updatedByDeviceId":"dev_a"},
          "badgeWatermark":{"value":{"at":5},"updatedAt":1790000000001}}}
        """#.utf8))])
        let client = makeClient()

        let entries = try await client.fetch(keys: ["alertPrefs", "badgeWatermark"])

        #expect(entries.count == 2)
        #expect(entries["alertPrefs"]?.value == .object(["turnEnd": .bool(false)]))
        #expect(entries["alertPrefs"]?.updatedAt == 1_790_000_000_000)
        let request = try #require(Stub.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer dt_test")
        #expect(request.url?.path == "/account/state")
        #expect(request.url?.query == "keys=alertPrefs,badgeWatermark")
    }

    @Test("中转挂在路径前缀下时，请求也跟着走前缀")
    func fetchKeepsTheMountPrefix() async throws {
        Stub.reset([.init(status: 200, body: Data(#"{"ok":true,"entries":{}}"#.utf8))])
        _ = try await makeClient(mount: "dsh-link").fetch()
        #expect(Stub.requests.first?.url?.path == "/dsh-link/account/state")
    }

    @Test("写入把条目编码成 JSON，并回读 applied")
    func putSendsEntriesAndReadsApplied() async throws {
        Stub.reset([.init(status: 200, body: Data(#"""
        {"ok":true,"applied":["sessionRead.agt_1"],"entries":{
          "sessionRead.agt_1":{"value":{"sess_a":42},"updatedAt":1790000000000}}}
        """#.utf8))])
        let client = makeClient()

        let result = try await client.put([
            .init(key: "sessionRead.agt_1", value: .object(["sess_a": .int(42)]),
                  updatedAt: 1_790_000_000_000),
        ])

        #expect(result.applied == ["sessionRead.agt_1"])
        #expect(result.entries["sessionRead.agt_1"]?.value == .object(["sess_a": .int(42)]))
        let request = try #require(Stub.requests.first)
        #expect(request.httpMethod == "PUT")
        let body = try #require(Stub.bodies.first)
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let entries = try #require(decoded?["entries"] as? [[String: Any]])
        #expect(entries.first?["key"] as? String == "sessionRead.agt_1")
        #expect(entries.first?["updatedAt"] as? Int == 1_790_000_000_000)
    }

    @Test("空写入不发请求（省一次往返）")
    func putWithNoEntriesSkipsTheNetwork() async throws {
        Stub.reset([])
        let result = try await makeClient().put([])
        #expect(result.applied.isEmpty)
        #expect(Stub.requests.isEmpty)
    }

    @Test("非 200 带上中转给的错误文案")
    func aRefusalCarriesTheRelayMessage() async throws {
        Stub.reset([.init(status: 413,
                          body: Data(#"{"ok":false,"error":{"code":"account-state/too-large","message":"too big"}}"#.utf8))])
        await #expect(throws: AccountStateClient.Failure.http(status: 413, body: "too big")) {
            _ = try await makeClient().put([
                .init(key: "k", value: .string("v"), updatedAt: 1),
            ])
        }
    }

    @Test("看不懂的回答按 malformed 报错，不静默当空")
    func aMalformedAnswerIsReported() async throws {
        Stub.reset([.init(status: 200, body: Data("not json".utf8))])
        do {
            _ = try await makeClient().fetch()
            Issue.record("应该抛 malformed")
        } catch let failure as AccountStateClient.Failure {
            guard case .malformed = failure else {
                Issue.record("期望 malformed，实际 \(failure)")
                return
            }
        }
    }

    // MARK: - 合并规则

    @Test("水位类取最大值：远程更大的留下，本地更大的不被抹掉")
    func watermarkMergesByMaximum() {
        let local = JSONValue.object(["sess_a": .int(10), "sess_b": .int(3)])
        let remote = JSONValue.object(["sess_a": .int(7), "sess_b": .int(9)])
        let merged = AccountStateMerger.maxWatermark(local, remote)
        #expect(merged == .object(["sess_a": .int(10), "sess_b": .int(9)]))

        // 远端多出来的会话要并进来。
        let withNew = AccountStateMerger.maxWatermark(local, .object(["sess_c": .int(1)]))
        #expect(withNew == .object(["sess_a": .int(10), "sess_b": .int(3), "sess_c": .int(1)]))
    }

    @Test("水位类：缺一边时用另一边（不是清空）")
    func watermarkHandlesMissingSides() {
        let local = JSONValue.object(["sess_a": .int(1)])
        #expect(AccountStateMerger.maxWatermark(local, nil) == local)
        #expect(AccountStateMerger.maxWatermark(nil, local) == local)
        #expect(AccountStateMerger.maxWatermark(nil, nil) == .object([:]))
    }

    @Test("开关类取更新的那次写；时间戳相等时以远端为准（幂等重试不算冲突）")
    func togglesTakeTheLatestWrite() {
        let local = AccountStateClient.Entry(key: "alertPrefs", value: .bool(true), updatedAt: 100)
        let older = AccountStateClient.Entry(key: "alertPrefs", value: .bool(false), updatedAt: 50)
        let newer = AccountStateClient.Entry(key: "alertPrefs", value: .bool(false), updatedAt: 200)
        let same = AccountStateClient.Entry(key: "alertPrefs", value: .bool(false), updatedAt: 100)

        #expect(AccountStateMerger.latest(local, older) == local)
        #expect(AccountStateMerger.latest(local, newer) == newer)
        #expect(AccountStateMerger.latest(local, same) == same)
        #expect(AccountStateMerger.latest(local, nil) == local)
        #expect(AccountStateMerger.latest(nil, newer) == newer)
        #expect(AccountStateMerger.latest(nil, nil) == nil)
    }
}
