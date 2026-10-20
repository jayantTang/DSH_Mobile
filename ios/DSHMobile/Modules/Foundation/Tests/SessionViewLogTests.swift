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

// MARK: - 032：账户级已读水位

extension SessionViewLogTests {
    /// 本文件用的都是同一个 defaults 域（在 setUp 里清空）；scope 用参数区分"哪台电脑"。
    private func scoped(_ scope: String? = "agt_1") -> SessionViewLog {
        let log = SessionViewLog(defaults: defaults)
        log.useScope(scope)
        return log
    }

    /// 远端更大的水位被采纳；远端更小的不会把本地已读抹掉（取 max）。
    func test_remote_watermarks_merge_by_maximum() {
        let log = scoped()
        log.markViewed("sess_a", at: 1_000)
        log.markViewed("sess_b", at: 5_000)

        let changed = log.mergeRemote(viewedAt: ["sess_a": 9_000, "sess_b": 2_000])

        XCTAssertTrue(changed)
        XCTAssertEqual(log.lastViewed("sess_a"), 9_000, "the newer remote watermark wins")
        XCTAssertEqual(log.lastViewed("sess_b"), 5_000, "an older remote value must not erase it")
    }

    /// 远端多出来的会话要并进来（另一台设备读过、这台还没见过）。
    func test_remote_sessions_are_added() {
        let log = scoped()
        XCTAssertTrue(log.mergeRemote(viewedAt: ["sess_new": 1_234]))
        XCTAssertEqual(log.lastViewed("sess_new"), 1_234)
        // 再来一次同样的水位：没有变化，调用方据此省掉一次刷新。
        XCTAssertFalse(log.mergeRemote(viewedAt: ["sess_new": 1_234]))
    }

    /// 合并后要落盘：另开一个日志读同一份 defaults 能看到。
    func test_merged_watermarks_persist() {
        scoped().mergeRemote(viewedAt: ["sess_a": 42])
        XCTAssertEqual(scoped().lastViewed("sess_a"), 42)
    }

    /// 换一台电脑：并进来的水位只属于那台电脑的 scope，不串到另一台。
    func test_merging_is_scoped_to_one_host() {
        let first = scoped("agt_1")
        first.mergeRemote(viewedAt: ["sess_a": 42])
        let second = scoped("agt_2")
        XCTAssertNil(second.lastViewed("sess_a"), "another host must not see it")
        XCTAssertEqual(second.mergeRemote(viewedAt: ["sess_a": 7]), true)
    }

    /// 快照只含本机的会话，键去掉 scope 前缀（上传用的形状）。
    func test_the_snapshot_drops_the_scope_prefix() {
        let first = scoped("agt_1")
        first.markViewed("sess_a", at: 100)
        scoped("agt_2").markViewed("sess_a", at: 200)

        XCTAssertEqual(first.accountSnapshot(), ["sess_a": 100])
        // 没绑 scope 时没有可上传的东西（不该把别人的会话传上去）。
        let unscoped = SessionViewLog(defaults: defaults)
        XCTAssertTrue(unscoped.accountSnapshot().isEmpty)
    }
}
