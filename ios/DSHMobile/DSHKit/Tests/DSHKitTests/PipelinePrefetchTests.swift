@testable import DSHKit
import XCTest

/// 取页调度（017）：一次多页时的并发上界、方向顺序、同页合并、失败隔离、预取封顶。
///
/// 这些是"翻页不再一屏一等"的机械判据：读者触发要排在预取前面、同时在飞的页数有上界、
/// 同一页不许因为预取变成两次请求。端到端手感由仿真器用例取证（见
/// `specs/017-turn-prefetch/quickstart.md`）。
final class PipelinePrefetchTests: XCTestCase {

    // MARK: - 假件

    private actor FetchStub {
        private var script: [Int: SessionPipeline.FetchPage] = [:]
        private var failures: Set<Int> = []
        private(set) var requests: [ClosedRange<Int>] = []
        private(set) var priorities: [Int: Int] = [:]
        private(set) var peakInFlight = 0
        private var inFlight = 0
        /// 每次取页的人为延迟（毫秒）：用来观察并发与顺序。
        var delayMs: UInt64 = 20

        func set(_ range: ClosedRange<Int>, hasMore: Bool = true) {
            script[range.lowerBound] = SessionPipeline.FetchPage(
                records: range.map { Self.record($0) },
                hasMore: hasMore)
        }

        func fail(_ range: ClosedRange<Int>) { failures.insert(range.lowerBound) }

        func setDelay(_ ms: UInt64) { delayMs = ms }

        func fetch(_ range: ClosedRange<Int>, _ priority: SessionPipeline.FetchPriority) async throws -> SessionPipeline.FetchPage {
            requests.append(range)
            priorities[range.lowerBound] = priority.rawValue
            inFlight += 1
            peakInFlight = max(peakInFlight, inFlight)
            defer { inFlight -= 1 }
            if delayMs > 0 { try? await Task.sleep(nanoseconds: delayMs * 1_000_000) }
            if failures.contains(range.lowerBound) { throw StubError.failed(range.lowerBound) }
            if let page = script[range.lowerBound] { return page }
            return SessionPipeline.FetchPage(records: [], hasMore: true)
        }

        func observed() -> (requests: [ClosedRange<Int>], priorities: [Int: Int], peak: Int) {
            (requests, priorities, peakInFlight)
        }

        static func record(_ seq: Int) -> SessionRecord {
            let json = #"{"type":"assistant/message","seq":\#(seq),"time":1789276358732,"data":{"text":"m\#(seq)"}}"#
            let event = try! JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
            return SessionRecord(event: event)
        }
    }

    private enum StubError: Error, Equatable { case failed(Int) }

    private func makePipeline(_ stub: FetchStub) -> SessionPipeline {
        SessionPipeline(
            scope: "mac", sessionId: "s1", store: nil,
            fetch: { range, priority in try await stub.fetch(range, priority) },
            frameTick: {}, now: { 1000 }, pageSize: 50, hotLimit: 500)
    }

    /// 让挂起的预取任务跑完（预取是 fire-and-forget 的 Task）。
    private func settle(_ ms: UInt64 = 300) async {
        try? await Task.sleep(nanoseconds: ms * 1_000_000)
    }

    /// 等预取稳定：直到"更早方向的请求数"连续两次读数相同，或超时。
    /// 预取是后台 Task，固定 sleep 会让用例随调度抖动，所以用收敛判据。
    private func waitForPrefetch(_ stub: FetchStub, timeoutMs: UInt64 = 2000) async -> [ClosedRange<Int>] {
        var last: [ClosedRange<Int>] = []
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 40_000_000)
            let current = await stub.observed().requests
            if !current.isEmpty, current.count == last.count { return current }
            last = current
        }
        return last
    }

    // MARK: - 一次多页：并发有上界、页都落地

    func testMultiPageFetchRunsConcurrentlyUnderTheCap() async throws {
        let stub = FetchStub()
        // 读者一次要 3 页（1...150 → 对齐页 1/51/101）。
        for start in [1, 51, 101] { await stub.set(start...(start + 49), hasMore: true) }
        let pipeline = makePipeline(stub)

        _ = try await pipeline.records(in: 1...150, priority: .userVisible)
        let observed = await stub.observed()
        let dataPages = observed.requests.filter { $0.lowerBound <= 101 }
        XCTAssertEqual(Set(dataPages.map(\.lowerBound)), [1, 51, 101], "三页都要取到")
        XCTAssertLessThanOrEqual(observed.peak, SessionPipeline.fetchConcurrency,
                                 "同时在飞的页数不得超过上限")
        XCTAssertGreaterThan(observed.peak, 1, "三页不该是逐页串行")
    }

    // MARK: - 方向：往回翻先发离窗口最近的那页

    /// 往回读三页：先发离已加载窗口最近（页码最大）的那页，再向外扩。
    ///
    /// 先读一段建立窗口（那一次的预取是背景噪音），再往回读目标区间——只断言这一次的
    /// 前三页顺序。
    func testOlderDirectionSendsTheNearestPageFirst() async throws {
        let stub = FetchStub()
        for start in [151, 201, 251, 301, 401] { await stub.set(start...(start + 49), hasMore: true) }
        let pipeline = makePipeline(stub)

        _ = try await pipeline.records(in: 401...450, priority: .userVisible)
        _ = await waitForPrefetch(stub)
        _ = try await pipeline.records(in: 151...300, priority: .userVisible)
        let mine = await stub.observed().requests.filter { (151...300).contains($0.lowerBound) }
        XCTAssertEqual(mine.prefix(3).map(\.lowerBound), [251, 201, 151],
                       "往回翻时先发紧挨窗口那一页，再按页码递减向外")
    }

    /// 预取按方向从读者位置往外备，且总量被 `prefetchDepth` 封住。
    ///
    /// 分两步：先建立窗口（要最新的两页），再往回读一页——这时读者位置变成窗口下沿，
    /// 预取应当只覆盖它下面 `prefetchDepth` 页，不得一路扫到底。
    func testPrefetchStaysWithinDepthOfTheReader() async throws {
        let stub = FetchStub()
        for start in stride(from: 1, through: 901, by: 50) { await stub.set(start...(start + 49)) }
        let pipeline = makePipeline(stub)

        _ = try await pipeline.records(in: 801...900, priority: .userVisible)
        _ = await waitForPrefetch(stub)
        _ = try await pipeline.records(in: 751...800, priority: .userVisible)
        let all = await waitForPrefetch(stub)
        let prefetched = all.filter { $0.lowerBound < 751 }
        XCTAssertFalse(prefetched.isEmpty, "往回读时应当预取，否则读者又会撞等待")
        XCTAssertGreaterThanOrEqual(prefetched.map(\.lowerBound).max() ?? 0, 701,
                                    "先备紧挨读者位置的那一页")
        XCTAssertGreaterThanOrEqual(prefetched.map(\.lowerBound).min() ?? 0, 651,
                                    "预取不得超出读者位置往下 prefetchDepth 页")
    }

    // MARK: - 同页合并：预取与读者不会发两次

    func testReaderAndPrefetchForTheSamePageIssueOneRequest() async throws {
        let stub = FetchStub()
        await stub.setDelay(120)
        await stub.set(351...400, hasMore: true)
        await stub.set(301...350, hasMore: true)
        let pipeline = makePipeline(stub)

        // 先发一次取页，紧接着再要同一段（模拟预取与读者撞在同一页）。
        async let first: [SessionRecord] = pipeline.records(in: 301...350, priority: .prefetch)
        async let second: [SessionRecord] = pipeline.records(in: 301...350, priority: .userVisible)
        _ = try await (first, second)
        await settle()

        let hits = await stub.observed().requests.filter { $0.lowerBound == 301 }
        XCTAssertEqual(hits.count, 1, "同一页只能发一次网络请求")
    }

    // MARK: - 失败隔离：一页失败不拖垮其它页

    func testOneFailedPageDoesNotBlockTheOthers() async throws {
        let stub = FetchStub()
        for start in [1, 51, 101] { await stub.set(start...(start + 49), hasMore: true) }
        await stub.fail(51...100)
        let pipeline = makePipeline(stub)

        do {
            _ = try await pipeline.records(in: 1...150, priority: .userVisible)
            XCTFail("有页失败时应当抛出（读者要能看见失败）")
        } catch {
            // 预期：失败向上抛，其它页照常落地。
        }
        let first = await pipeline.record(at: 1)
        let last = await pipeline.record(at: 101)
        XCTAssertTrue(first != nil && last != nil, "同一批里没失败的页仍要落地")
    }

    // MARK: - 预取封顶：沿方向最多提前 prefetchDepth 页

    func testPrefetchDepthIsBounded() async throws {
        let stub = FetchStub()
        for start in stride(from: 1001, through: 1450, by: 50) { await stub.set(start...(start + 49)) }
        let pipeline = makePipeline(stub)

        _ = try await pipeline.records(in: 1401...1450, priority: .userVisible)
        let prefetches = await waitForPrefetch(stub)
        let older = prefetches.filter { $0.lowerBound < 1401 }
        XCTAssertLessThanOrEqual(older.count, SessionPipeline.prefetchDepth,
                                 "预取最多提前 prefetchDepth 页")
        XCTAssertFalse(older.isEmpty, "往回读时应当触发预取（否则读者又会撞等待）")
    }

    // MARK: - 已到最老不再预取

    func testNoPrefetchOlderOnceTheLogIsExhausted() async throws {
        let stub = FetchStub()
        await stub.set(1...50, hasMore: false)
        let pipeline = makePipeline(stub)

        _ = try await pipeline.records(in: 1...50, priority: .userVisible)
        await settle()
        let older = await stub.observed().requests.filter { $0.upperBound < 1 }
        XCTAssertTrue(older.isEmpty, "日志最老之后不许再向更早方向预取")
    }
}
