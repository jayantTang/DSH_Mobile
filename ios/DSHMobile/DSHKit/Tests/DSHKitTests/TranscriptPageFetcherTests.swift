import DSHKit
import XCTest

/// 通道选择与两路归一（spec 007 T027 的协议层部分）：
/// 能力在就走精确窗口；不在就退回 `session/page` + 已发布的差值补偿，并把这类页标成
/// `clamped`（它本来就无法承诺"接得上"），让 pager 接受缺口而不是永远失败。
final class TranscriptPageFetcherTests: XCTestCase {

    private final class Recorder: DSHCarrier, @unchecked Sendable {
        var calls: [(method: String, args: String)] = []
        var windowValue: HistoryWindowValue?
        var pageValues: [SessionPage] = []
        var error: Error?

        func unary<Args: Encodable & Sendable, Value: Decodable & Sendable>(
            method: String, args: Args, as valueType: Value.Type
        ) async throws -> Value {
            calls.append((method, String(describing: args)))
            if let error { throw error }
            if let windowValue {
                // `DSHClient.historyWindow` 先按未类型化的 JSON 取回（要兼容压缩信封），
                // 所以桩在 `Value == JSONValue` 时也要能给出同一份值的 JSON 形态。
                if valueType == JSONValue.self {
                    let data = try JSONEncoder().encode(windowValue)
                    return try JSONDecoder().decode(JSONValue.self, from: data) as! Value
                }
                if let value = windowValue as? Value { return value }
            }
            if !pageValues.isEmpty {
                let next = pageValues.removeFirst()
                if let value = next as? Value { return value }
            }
            throw TranscriptPageFetcher.Failure.emptyPage
        }

        func stream<Args: Encodable & Sendable>(
            endpoint: String, args: Args
        ) async -> AsyncThrowingStream<JSONValue, any Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func eventResult(_ result: JSONValue) async throws {}
        func close() async {}
    }

    private func record(_ seq: Int) -> SessionRecord {
        let json = #"{"type":"user/message","seq":\#(seq),"time":1789276358732,"data":{"content":[]}}"#
        let event = try! JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
        return SessionRecord(event: event)
    }

    /// `SessionPage` 没有公开的逐成员构造器（它是线上模型），所以按线上 JSON 造。
    private func makeSessionPage(_ range: ClosedRange<Int>, hasMore: Bool) -> SessionPage {
        let records = range.map { seq in
            #"{"event":{"type":"user/message","seq":\#(seq),"time":1789276358732,"data":{"content":[]}}}"#
        }
        let json = #"{"records":[\#(records.joined(separator: ","))],"hasMore":\#(hasMore)}"#
        return try! JSONDecoder().decode(SessionPage.self, from: Data(json.utf8))
    }

    /// 空页：`range` 表达不了空区间，单独造一个。
    private func emptySessionPage() -> SessionPage {
        let json = #"{"records":[],"hasMore":false}"#
        return try! JSONDecoder().decode(SessionPage.self, from: Data(json.utf8))
    }

    private func fetcher(_ carrier: Recorder, capabilities: Set<String>) -> TranscriptPageFetcher {
        TranscriptPageFetcher(
            client: HostClientFactory.make(carrier: carrier),
            address: .session(sessionId: "s1"),
            throughSeq: 1000,
            capabilities: capabilities
        )
    }

    func testCapabilitySelectsTheExactChannel() {
        XCTAssertEqual(TranscriptPageFetcher.channel(capabilities: ["history-window", "git"]), .exactWindow)
        XCTAssertEqual(TranscriptPageFetcher.channel(capabilities: ["git"]), .legacyPage)
        XCTAssertEqual(TranscriptPageFetcher.channel(capabilities: []), .legacyPage)
    }

    func testExactChannelCallsTheConnectorMethodAndKeepsAbutment() async throws {
        let carrier = Recorder()
        carrier.windowValue = HistoryWindowValue(
            records: (440...499).map(record), startSeq: 440, endSeq: 499,
            hasMore: true, truncatedBy: nil, clamped: false
        )
        let page = try await fetcher(carrier, capabilities: ["history-window"]).page(before: 500)
        XCTAssertEqual(carrier.calls.map(\.method), ["_link/sessionWindow"])
        XCTAssertEqual(page.startSeq, 440)
        XCTAssertEqual(page.endSeq, 499)
        XCTAssertFalse(page.clamped, "精确窗口没被裁剪就是没被裁剪")
        XCTAssertTrue(page.hasMore)
    }

    func testExactChannelPropagatesUnsupportedSoTheCallerCanFallBack() async {
        struct Unsupported: Error {}
        let carrier = Recorder()
        carrier.error = Unsupported()
        do {
            _ = try await fetcher(carrier, capabilities: ["history-window"]).page(before: 500)
            XCTFail("应该把连接器的错误抛出去，而不是自己悄悄换通道")
        } catch {
            XCTAssertTrue(error is Unsupported)
        }
    }

    func testLegacyChannelCorrectsTheShortfallOnce() async throws {
        let carrier = Recorder()
        // 第一次少了 5 条（endSeq 494，而窗口底是 500-1=499），校正后接上。
        carrier.pageValues = [
            makeSessionPage(440...494, hasMore: true),
            makeSessionPage(445...499, hasMore: true),
        ]
        let page = try await fetcher(carrier, capabilities: ["git"]).page(before: 500)
        XCTAssertEqual(carrier.calls.map(\.method), ["session/page", "session/page"], "短页要重问一次")
        XCTAssertEqual(page.endSeq, 499)
        XCTAssertEqual(page.startSeq, 445)
        XCTAssertTrue(page.clamped, "旧通道无法承诺接得上，必须如实标出")
    }

    func testLegacyChannelGivesUpAfterMaxAttemptsAndMarksTheGap() async throws {
        let carrier = Recorder()
        // 每次都短一截：三次尝试后按原样返回（与已发布行为一致），由 clamped 交代缺口。
        carrier.pageValues = (0..<TranscriptPageBoundary.maxAttempts).map { step in
            makeSessionPage((400 + step)...(490 + step), hasMore: true)
        }
        let page = try await fetcher(carrier, capabilities: ["git"]).page(before: 500)
        XCTAssertEqual(carrier.calls.count, TranscriptPageBoundary.maxAttempts)
        XCTAssertTrue(page.clamped)
        XCTAssertLessThan(page.endSeq, 499, "缺口如实存在，不假装接上")
    }

    func testLegacyEmptyPageIsAnErrorNotAnEnd() async {
        let carrier = Recorder()
        carrier.pageValues = [emptySessionPage()]
        do {
            _ = try await fetcher(carrier, capabilities: ["git"]).page(before: 500)
            XCTFail("空页必须报错，交由 pager 判失败")
        } catch {
            XCTAssertTrue(error is TranscriptPageFetcher.Failure)
        }
    }
}
