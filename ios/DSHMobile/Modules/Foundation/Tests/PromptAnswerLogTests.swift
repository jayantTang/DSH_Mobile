import Foundation
import XCTest
@testable import DSHFoundation

/// `PromptAnswerLog`：本机答过的待回应提示台账（032 的 `answeredPrompts`）。
///
/// 它坏在三件事上：**覆盖**（PUT 是整体替换，推之前必须带上旧条目，否则别的设备的作答被抹掉）、
/// **串台**（两台电脑的 promptId 不能混）和**容量**（答过几千条的设备不该把 plist 越写越大）。
/// 断言消息一律 ASCII：check:i18n 扫整棵 Modules 树。
@MainActor
final class PromptAnswerLogTests: XCTestCase {

    private static let suiteName = "dsh.tests.prompt-answer-log"
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

    private func scoped(_ scope: String? = "agt_1") -> PromptAnswerLog {
        let log = PromptAnswerLog(defaults: defaults)
        log.useScope(scope)
        return log
    }

    func test_an_answer_is_recorded_and_read_back() {
        let log = scoped()
        XCTAssertFalse(log.isAnswered("p1"))
        log.markAnswered("p1", at: 100)
        XCTAssertTrue(log.isAnswered("p1"))
        XCTAssertEqual(scoped().isAnswered("p1"), true, "it must survive a reload")
    }

    func test_the_snapshot_carries_every_known_answer() {
        // 关键：推上去的是**全量**（PUT 整体替换），只推最新一条会把别的作答弄丢。
        let log = scoped()
        log.markAnswered("p1", at: 100)
        log.markAnswered("p2", at: 200)
        XCTAssertEqual(log.accountSnapshot(), ["p1": 100, "p2": 200])
    }

    func test_remote_answers_merge_and_keep_the_newest() {
        let log = scoped()
        log.markAnswered("p1", at: 500)
        XCTAssertTrue(log.mergeRemote(answeredAt: ["p1": 100, "p2": 700]))
        XCTAssertEqual(log.accountSnapshot()["p1"], 500, "older remote must not win")
        XCTAssertEqual(log.accountSnapshot()["p2"], 700)
        XCTAssertFalse(log.mergeRemote(answeredAt: ["p1": 100, "p2": 700]), "no change -> false")
    }

    func test_merging_is_scoped_to_one_host() {
        scoped("agt_1").markAnswered("p1", at: 100)
        XCTAssertFalse(scoped("agt_2").isAnswered("p1"), "another host must not see it")
    }

    func test_the_snapshot_drops_the_scope_prefix() {
        scoped("agt_1").markAnswered("p1", at: 100)
        scoped("agt_2").markAnswered("p1", at: 200)
        XCTAssertEqual(scoped("agt_1").accountSnapshot(), ["p1": 100])
        XCTAssertTrue(PromptAnswerLog(defaults: defaults).accountSnapshot().isEmpty)
    }

    func test_the_log_stays_bounded() {
        let log = scoped()
        for index in 0..<80 { log.markAnswered("p\(index)", at: Double(index)) }
        XCTAssertEqual(log.accountSnapshot().count, 64, "oldest answers are dropped first")
        XCTAssertFalse(log.isAnswered("p0"))
        XCTAssertTrue(log.isAnswered("p79"))
    }
}
