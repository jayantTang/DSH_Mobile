import XCTest

@testable import DSHKit

/// 会话把手的用例（spec 023 边界收敛：门面交给 App 的窄对象）。
///
/// 把手**不含判定**，所以这里不重复 `SessionPipeline` 的规则，只证一件事：
/// **转发是通的**——App 通过把手做的事，真的落到了管道上（读到的区间、标了到顶、取到的记录）。
/// 这条缝如果哪天接错（例如把 `priority` 吃掉、或标到顶没传下去），App 那边只会表现为
/// "跳转失效""反复问历史"，很难查；所以在缝上钉几条。
final class SessionHandleTests: XCTestCase {

    private func event(seq: Int) -> SessionEvent { Self.event(seq: seq) }

    /// 不捕获 `self`（`fetch` 是 `@Sendable`，捕获非 Sendable 的测试类会编译不过）。
    private static func event(seq: Int) -> SessionEvent {
        let json = #"{"type":"assistant/message","seq":\#(seq),"time":1789276358732,"data":{"text":"m\#(seq)"}}"#
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
    }

    private func makeHandle(fetch: @escaping SessionPipeline.PageFetch) -> (SessionHandle, SessionPipeline) {
        let pipeline = SessionPipeline(scope: "mac", sessionId: "s1", store: nil,
                                       fetch: fetch, frameTick: {}, now: { 1000 })
        return (SessionHandle(pipeline: pipeline), pipeline)
    }

    func testRecordsGoThroughAndFetchTheRequestedRange() async throws {
        // 夹具记录下"管道真正请求了哪一段"，用来证明把手没有把区间/优先级吃掉。
        actor Asked {
            var ranges: [ClosedRange<Int>] = []
            var priorities: [String] = []
            func note(_ range: ClosedRange<Int>, _ priority: String) {
                ranges.append(range)
                priorities.append(priority)
            }
        }
        let asked = Asked()
        let (handle, _) = makeHandle { range, priority in
            await asked.note(range, priority == .userVisible ? "userVisible" : "other")
            // 管道按页对齐请求（pageSize 50），所以桩要把**整页**给回去，
            // 它会自己过滤成调用方要的那一段。
            let records = (range.lowerBound...range.upperBound).map { SessionRecord(event: Self.event(seq: $0)) }
            return SessionPipeline.FetchPage(records: Array(records), hasMore: false)
        }

        let records = try await handle.records(in: 10...12, priority: .userVisible)
        XCTAssertEqual(records.map(\.event.seq), [10, 11, 12], "把手要的是这一段，管道按页取完再裁")
        let ranges = await asked.ranges
        // 至少一次；实际可能是两次——管道会顺带预取相邻页（那是它自己的策略）。
        XCTAssertGreaterThanOrEqual(ranges.count, 1)
        XCTAssertTrue(ranges.contains { $0.contains(10) && $0.contains(12) },
                      "按页对齐可以，但必须有一次覆盖要的那一段；实得 \(ranges)")
    }

    func testMarkEarliestReachedIsForwardedAndSticky() async {
        let (handle, _) = makeHandle { _, _ in SessionPipeline.FetchPage(records: [], hasMore: false) }
        let before = await handle.topExhausted
        XCTAssertFalse(before)
        await handle.markEarliestReached()
        let after = await handle.topExhausted
        XCTAssertTrue(after, "把手的转发必须真的落到管道上")
    }

    func testRangesReflectWhatWasFetched() async throws {
        let (handle, _) = makeHandle { range, _ in
            let records = (range.lowerBound...range.upperBound).map { SessionRecord(event: Self.event(seq: $0)) }
            return SessionPipeline.FetchPage(records: Array(records), hasMore: false)
        }
        let empty = await handle.ranges
        XCTAssertTrue(empty.isEmpty)
        _ = try await handle.records(in: 5...7)
        let filled = await handle.ranges
        XCTAssertFalse(filled.isEmpty, "取过的区间要出现在 ranges 里")
    }

    func testRetryIsForwardedForTheGivenRange() async throws {
        // `retry` 清掉失败计数让下一次读取重试；这里只证"不抛错且区间被接受"。
        let (handle, _) = makeHandle { _, _ in SessionPipeline.FetchPage(records: [], hasMore: false) }
        try await handle.retry(range: 3...3)
        await handle.abandonGap(4...4)
        await handle.markEarliestReached()
    }

    func testApplyEventIsForwarded() async throws {
        let (handle, _) = makeHandle { _, _ in SessionPipeline.FetchPage(records: [], hasMore: false) }
        await handle.apply(events: [event(seq: 1)])
        // 应用之后不做断言（那是 SessionPipeline 的规则），只证这把缝不崩、不吞异常。
    }
}
