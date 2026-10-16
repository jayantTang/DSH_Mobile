import Foundation
import XCTest
@testable import DSHFoundation

/// `SessionViewLog`：这台手机上次打开每个会话是什么时候。
///
/// 它只可能坏在两件事上：**容量**（开过几千个会话的手机不该把 plist 越写越长）和
/// **作用域**（两台电脑可以有同名 session id，"读过了"不能跟着串台）。
/// 上限语义读自源码：`limit = 400`，只有 `markViewed` 会触发 `trim()`，判据是
/// `count > limit`，被丢的是 stamp 最小的那几条（先到先出）。
///
/// 每个用例用同一个固定名字的 defaults 域（cfprefsd 会给每个域留一个 plist，
/// 随机名字只会留下一堆空文件），进出都清空。
///
/// 断言消息一律 ASCII：check:i18n 扫整棵 Modules 树。
@MainActor
final class SessionViewLogTests: XCTestCase {

    /// `SessionViewLog.limit` 的读数（源码里是 private，用例把 400 钉在这里）。
    private static let cap = 400
    private static let suiteName = "dsh.tests.session-view-log"

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: Self.suiteName)
        defaults?.synchronize()
        defaults = nil
        super.tearDown()
    }

    private func makeLog() -> SessionViewLog { SessionViewLog(defaults: defaults) }

    // MARK: - 基本读写

    func test_a_fresh_store_is_empty() {
        let log = makeLog()

        XCTAssertTrue(log.viewedAt.isEmpty, "nothing has been opened yet")
        XCTAssertNil(log.lastViewed("s1"))
    }

    func test_a_mark_survives_a_new_instance() {
        let first = makeLog()
        first.markViewed("s1", at: 100)

        let second = makeLog()

        XCTAssertEqual(second.lastViewed("s1"), 100, "the mark is in the defaults domain, not in memory")
    }

    func test_a_backwards_stamp_does_not_move_a_mark() {
        let log = makeLog()
        log.markViewed("s1", at: 200)

        log.markViewed("s1", at: 100)

        XCTAssertEqual(log.lastViewed("s1"), 200, "a clock that steps backwards must not move the mark")
        log.markViewed("s1", at: 300)
        XCTAssertEqual(log.lastViewed("s1"), 300, "a newer stamp still wins")
    }

    // MARK: - 上限

    func test_the_cap_is_inclusive_at_four_hundred() {
        let log = makeLog()

        for index in 0..<Self.cap { log.markViewed("s\(index)", at: Double(index)) }

        XCTAssertEqual(log.viewedAt.count, Self.cap, "exactly at the cap nothing is dropped")
        XCTAssertNotNil(log.lastViewed("s0"), "the oldest entry survives while the store is not over the cap")
    }

    func test_the_first_mark_over_the_cap_evicts_the_oldest() {
        let log = makeLog()
        for index in 0..<Self.cap { log.markViewed("s\(index)", at: Double(index)) }

        log.markViewed("s\(Self.cap)", at: Double(Self.cap))

        XCTAssertEqual(log.viewedAt.count, Self.cap, "the store never grows past the cap")
        XCTAssertNil(log.lastViewed("s0"), "the oldest stamps go first")
        XCTAssertEqual(log.lastViewed("s1"), 1, "the second oldest is still there")
        XCTAssertEqual(log.lastViewed("s\(Self.cap)"), Double(Self.cap))
    }

    func test_four_hundred_and_fifty_marks_keep_the_newest_four_hundred() {
        let log = makeLog()
        for index in 0..<450 { log.markViewed("s\(index)", at: Double(index)) }

        XCTAssertEqual(log.viewedAt.count, Self.cap)
        XCTAssertNil(log.lastViewed("s49"), "the fifty oldest marks are gone")
        XCTAssertEqual(log.lastViewed("s50"), 50, "the surviving window starts here")
        XCTAssertEqual(log.lastViewed("s449"), 449)

        let reloaded = makeLog()
        XCTAssertEqual(reloaded.viewedAt.count, Self.cap, "the trimmed map is what gets persisted")
        XCTAssertEqual(reloaded.lastViewed("s50"), 50)
    }

    func test_the_cap_counts_every_scope_together() {
        let log = makeLog()
        log.useScope("A")
        for index in 0..<Self.cap { log.markViewed("s\(index)", at: Double(index)) }

        log.useScope("B")
        log.markViewed("only", at: 9_999)

        XCTAssertEqual(log.viewedAt.count, Self.cap, "the cap is on the stored map, not per computer")
        XCTAssertEqual(log.lastViewed("only"), 9_999, "the newest mark is the one that stays")
        log.useScope("A")
        XCTAssertNil(log.lastViewed("s0"), "the eviction took the oldest stamp, whichever computer it came from")
        XCTAssertEqual(log.lastViewed("s1"), 1)
    }

    // MARK: - 作用域与清理

    func test_marks_are_kept_apart_per_computer() {
        let log = makeLog()
        log.useScope("A")
        log.markViewed("s1", at: 100)

        log.useScope("B")
        XCTAssertNil(log.lastViewed("s1"), "session ids are unique per computer, not across them")

        log.useScope(nil)
        XCTAssertNil(log.lastViewed("s1"), "with no computer pointed at, no mark matches")

        log.useScope("A")
        XCTAssertEqual(log.lastViewed("s1"), 100, "the mark is still there for the computer it belongs to")
    }

    func test_prune_forgets_sessions_the_list_no_longer_shows() {
        let log = makeLog()
        log.useScope("A")
        log.markViewed("s1", at: 1)
        log.markViewed("s2", at: 2)

        log.prune(keeping: ["s1"])

        XCTAssertEqual(log.lastViewed("s1"), 1, "a session that is still listed keeps its mark")
        XCTAssertNil(log.lastViewed("s2"), "a session that is gone takes its mark with it")

        let reloaded = makeLog()
        reloaded.useScope("A")
        XCTAssertNil(reloaded.lastViewed("s2"), "the prune is persisted, not memory only")
    }
}
