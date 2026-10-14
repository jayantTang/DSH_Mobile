import XCTest

@testable import DSHKit

/// 反馈取件凭据列表的用例（spec 023 边界收敛：判定从 App 的 `FeedbackLocalStore` 抽进 DSHKit）。
///
/// 这些凭据是"重装之后还能取回那条回信"的唯一凭据，所以每条规则都要钉住：同线程覆盖、
/// 时间倒序、封顶丢最旧、坏数据当空。
final class FeedbackTicketListTests: XCTestCase {

    private struct Ticket: FeedbackTicketLike, Equatable {
        let threadId: String
        let createdAt: Date?
        var ticketKey: String = "k"
    }

    private func ticket(_ id: String, _ seconds: TimeInterval?) -> Ticket {
        Ticket(threadId: id, createdAt: seconds.map { Date(timeIntervalSince1970: $0) })
    }

    // MARK: - 排序与封顶

    func testNewestFirst() {
        let list = FeedbackTicketList.normalized([ticket("a", 100), ticket("b", 300), ticket("c", 200)])
        XCTAssertEqual(list.map(\.threadId), ["b", "c", "a"])
    }

    func testMissingDateSortsLast() {
        // 缺时间戳的当"最旧"（原来就是 `.distantPast`），不能让它在列表顶上冒充最新。
        let list = FeedbackTicketList.normalized([ticket("none", nil), ticket("old", 1)])
        XCTAssertEqual(list.map(\.threadId), ["old", "none"])
    }

    func testCapDropsTheOldest() {
        let many = (1...5).map { ticket("t\($0)", TimeInterval($0)) }
        let capped = FeedbackTicketList.normalized(many, cap: 3)
        XCTAssertEqual(capped.map(\.threadId), ["t5", "t4", "t3"], "留下的必须是最新的三条")
    }

    func testCapZeroMeansNoLimit() {
        let many = (1...5).map { ticket("t\($0)", TimeInterval($0)) }
        XCTAssertEqual(FeedbackTicketList.normalized(many, cap: 0).count, 5)
    }

    func testDefaultCapIsTheDocumentedTwoHundred() {
        XCTAssertEqual(FeedbackTicketList.cap, 200)
        let many = (1...205).map { ticket("t\($0)", TimeInterval($0)) }
        XCTAssertEqual(FeedbackTicketList.normalized(many).count, 200)
    }

    // MARK: - 记一条

    func testSavingTheSameThreadReplacesTheOldOne() {
        let merged = FeedbackTicketList.saving(ticket("a", 200), into: [ticket("a", 100), ticket("b", 50)])
        XCTAssertEqual(merged.map(\.threadId), ["a", "b"])
        XCTAssertEqual(merged.first?.createdAt, Date(timeIntervalSince1970: 200), "留下的是新的那条")
    }

    func testSavingKeepsTheListCapped() {
        let existing = (1...200).map { ticket("t\($0)", TimeInterval($0)) }
        let merged = FeedbackTicketList.saving(ticket("new", 999), into: existing)
        XCTAssertEqual(merged.count, 200)
        XCTAssertEqual(merged.first?.threadId, "new")
        XCTAssertFalse(merged.contains { $0.threadId == "t1" }, "最旧的那条被挤出去了")
    }

    // MARK: - 往返与坏数据

    func testRoundTripThroughAString() throws {
        let list = [ticket("a", 100), ticket("b", 200)]
        let encoded = try FeedbackTicketList.encode(list)
        let decoded: [Ticket] = FeedbackTicketList.decode(encoded)
        XCTAssertEqual(decoded.map(\.threadId), ["b", "a"])
        XCTAssertEqual(decoded.first?.createdAt, Date(timeIntervalSince1970: 200), "日期要能往返")
    }

    func testBadDataReadsAsEmpty() {
        // 一条坏凭据不该让整页打不开。
        XCTAssertEqual((FeedbackTicketList.decode("not json") as [Ticket]).count, 0)
        XCTAssertEqual((FeedbackTicketList.decode("") as [Ticket]).count, 0)
        XCTAssertEqual((FeedbackTicketList.decode(nil) as [Ticket]).count, 0)
        XCTAssertEqual((FeedbackTicketList.decode("[{\"threadId\":\"a\"}]") as [Ticket]).count, 0, "缺字段也算坏数据")
    }

    func testEncodeNormalizesBeforeWriting() throws {
        let encoded = try FeedbackTicketList.encode([ticket("a", 1), ticket("b", 2)])
        let decoded: [Ticket] = FeedbackTicketList.decode(encoded)
        XCTAssertEqual(decoded.map(\.threadId), ["b", "a"], "落盘顺序就是展示顺序，读回来不该再依赖排序")
    }
}
