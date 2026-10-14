import XCTest

@testable import DSHKit

/// 转写窗口策略的用例（spec 023 / S1，T023–T024）。
///
/// 这些用例钉的是**照搬过来的口径**，不是新口径：搬迁不许顺手改语义。边界值（等于预算、
/// 保留带上下限、keepLast 覆盖）各一条——它们是 2026-10-08 / 10-11 那几次实测踩出来的。
final class TranscriptWindowPlannerTests: XCTestCase {

    private let budget = TranscriptPayloadBudget(limitBytes: 1000)

    func testNothingToDropWhenUnderBudget() {
        XCTAssertEqual(TranscriptWindowPlanner.rowsToDrop(payloadBytes: [100, 100], under: budget), 0)
    }

    func testExactlyAtBudgetDoesNotDrop() {
        // 判据是"超过"而不是"达到"：等于预算时不该丢，否则每轮滚动都会白丢一行。
        XCTAssertEqual(TranscriptWindowPlanner.rowsToDrop(payloadBytes: [500, 500], under: budget), 0)
    }

    func testDropsFromTheOldestEndUntilBackUnderBudget() {
        // 24 行窗口 → 保留带 20 行（24/4=6 → 抬到 20），最多丢 4 行。
        // 总量 1620、预算 1000：超 620，最老那行 700 字节，丢 1 行就回到预算内。
        var sizes = Array(repeating: 10, count: 22)
        sizes.insert(700, at: 0)
        sizes.insert(700, at: 0)
        XCTAssertEqual(sizes.count, 24)
        XCTAssertEqual(TranscriptWindowPlanner.rowsToDrop(payloadBytes: sizes, under: budget), 1)
    }

    func testKeepBandFloorOfTwentyRows() {
        // 窗口很小（30 行）时也必须留住 20 行：写死 120 会让丢弃整条路走不通。
        let sizes = Array(repeating: 100, count: 30)   // 3000 字节
        let dropped = TranscriptWindowPlanner.rowsToDrop(payloadBytes: sizes, under: budget)
        XCTAssertEqual(dropped, 10, "30 行窗口 + 1000 预算：最多丢到剩 20 行")
    }

    func testKeepBandIsAQuarterOfTheWindowCappedAt120() {
        let band = TranscriptWindowPlanner.KeepBand.default
        XCTAssertEqual(band.rows(forRowCount: 30), 20, "30/4=7 → 抬到下限 20")
        XCTAssertEqual(band.rows(forRowCount: 200), 50, "200/4=50 → 在上下限之间")
        XCTAssertEqual(band.rows(forRowCount: 1000), 120, "1000/4=250 → 压到上限 120")
    }

    func testExplicitKeepLastWins() {
        let sizes = Array(repeating: 100, count: 100)
        // 保留 90 行 → 最多丢 10 行，即使预算允许丢更多。
        XCTAssertEqual(TranscriptWindowPlanner.rowsToDrop(payloadBytes: sizes, under: budget, keepLast: 90), 10)
    }

    func testNeverDropsIntoTheKeepBand() {
        // 预算小到"全都不够"时，也只能丢到保留带为止（不许把窗口丢空）。
        let sizes = Array(repeating: 1_000_000, count: 40)
        let tiny = TranscriptPayloadBudget(limitBytes: 1)
        XCTAssertEqual(TranscriptWindowPlanner.rowsToDrop(payloadBytes: sizes, under: tiny), 20,
                       "40 行窗口的保留带是 20 行")
    }

    func testEmptyWindowDropsNothing() {
        XCTAssertEqual(TranscriptWindowPlanner.rowsToDrop(payloadBytes: [], under: budget), 0)
    }

    func testPureFunctionSameInputSameOutput() {
        let sizes = Array(repeating: 400, count: 24)   // 9600 字节、预算 1000、保留带 20 行
        let first = TranscriptWindowPlanner.rowsToDrop(payloadBytes: sizes, under: budget)
        let second = TranscriptWindowPlanner.rowsToDrop(payloadBytes: sizes, under: budget)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, 4, "最多丢到保留带（24 - 20 = 4）")
    }

    /// **照搬过来的已知怪相**：窗口行数少于保留带下限（20）时，预算裁剪整条路走不通——
    /// `dropped < count - keep` 恒为假，于是永远返回 0。搬迁前的 `ChatModel.rowsToDropForBudget`
    /// 就是这个行为（`keep` 先被抬到 20，再被 `min(count, keep)` 收成 count，判定式就成了 `0 < 0`）。
    ///
    /// 这里**不修语义**（搬迁不许改行为）；要修另开任务，判据是"小窗口能不能靠裁剪回到预算内"。
    func testWindowsSmallerThanTheKeepBandNeverDrop() {
        let sizes = Array(repeating: 1_000_000, count: 5)
        XCTAssertEqual(TranscriptWindowPlanner.rowsToDrop(payloadBytes: sizes, under: budget), 0)
    }

    // MARK: - 行数上限那条旋钮（DEBUG 探针走的路）

    func testRowLimitDropsDownToTheLimit() {
        XCTAssertEqual(TranscriptWindowPlanner.rowsToDrop(rowCount: 500, limit: 120), 380)
        XCTAssertEqual(TranscriptWindowPlanner.rowsToDrop(rowCount: 120, limit: 120), 0, "刚好等于上限不丢")
        XCTAssertEqual(TranscriptWindowPlanner.rowsToDrop(rowCount: 10, limit: 120), 0)
    }

    func testRowLimitDisabledWhenLimitIsNotPositive() {
        XCTAssertEqual(TranscriptWindowPlanner.rowsToDrop(rowCount: 500, limit: 0), 0)
        XCTAssertEqual(TranscriptWindowPlanner.rowsToDrop(rowCount: 500, limit: -1), 0)
    }
}
