@testable import DSHChatDomain
import XCTest

/// 列表差集：按 id 对齐，只有"同 id 签名变了"才 reload。
///
/// 回归：uikit 宿主原来按同 index 的 id 比较，取消时分组行上方插入「已停止」，
/// 后面的行整体右移，分组行的运行态变化进不了 changedIds（TC-116）。
final class TranscriptRowDiffTests: XCTestCase {

    private func rows(_ pairs: [(String, String)]) -> [TranscriptRowDiff.Row] {
        pairs.map { TranscriptRowDiff.Row(id: $0.0, signature: $0.1) }
    }

    func test_inserting_a_row_above_does_not_reload_the_rows_below() {
        let changed = TranscriptRowDiff.changedRowIDs(
            previous: rows([("b", "s1"), ("c", "s1")]),
            current: rows([("a", "s1"), ("b", "s1"), ("c", "s1")]))
        XCTAssertTrue(changed.isEmpty, "新增行交给 diffable 插入，不必 reload：\(changed)")
    }

    func test_deleting_a_row_above_does_not_reload_the_rows_below() {
        let changed = TranscriptRowDiff.changedRowIDs(
            previous: rows([("a", "s1"), ("b", "s1"), ("c", "s1")]),
            current: rows([("b", "s1"), ("c", "s1")]))
        XCTAssertTrue(changed.isEmpty)
    }

    func test_reordering_alone_changes_nothing() {
        let changed = TranscriptRowDiff.changedRowIDs(
            previous: rows([("a", "s1"), ("b", "s2"), ("c", "s3")]),
            current: rows([("c", "s3"), ("a", "s1"), ("b", "s2")]))
        XCTAssertTrue(changed.isEmpty, "顺序变了但内容没变：交给 diffable 移动")
    }

    func test_a_content_change_is_reported_for_the_same_id() {
        let changed = TranscriptRowDiff.changedRowIDs(
            previous: rows([("a", "s1"), ("b", "s1"), ("c", "s1")]),
            current: rows([("a", "s1"), ("b", "running:false"), ("c", "s1")]))
        XCTAssertEqual(changed, ["b"])
    }

    func test_brand_new_ids_are_not_reported_as_changed() {
        XCTAssertTrue(TranscriptRowDiff.changedRowIDs(previous: [], current: rows([("a", "s1")])).isEmpty)
        let changed = TranscriptRowDiff.changedRowIDs(
            previous: rows([("a", "s1")]),
            current: rows([("a", "s1"), ("new", "s9")]))
        XCTAssertTrue(changed.isEmpty)
    }

    func test_tc116_top_insert_plus_a_running_flag_flip_still_reloads_the_group_row() {
        // 取消前后：分组行 id 不变、签名从 running 变 idle；上面还插了一行「已停止」。
        // 按 index 比较会拿 index0 的 notice 对 group、index1 的 group 对 step，全都对不上；
        // 按 id 对齐才能把 group 找出来。
        let previous = rows([
            ("process-group:1:3", "ph:running:true"),
            ("assistant-5-0", "text"),
        ])
        let current = rows([
            ("notice-stopped", "notice"),
            ("process-group:1:3", "ph:running:false"),
            ("assistant-5-0", "text"),
        ])
        XCTAssertEqual(TranscriptRowDiff.changedRowIDs(previous: previous, current: current),
                       ["process-group:1:3"])
    }

    func test_a_row_that_survives_a_delete_and_an_insert_is_still_compared() {
        let previous = rows([
            ("a", "s1"),
            ("group", "running:true"),
            ("c", "s3"),
        ])
        let current = rows([
            ("group", "running:false"),
            ("c", "s3"),
            ("d", "s4"),
        ])
        XCTAssertEqual(TranscriptRowDiff.changedRowIDs(previous: previous, current: current),
                       ["group"])
    }
}
