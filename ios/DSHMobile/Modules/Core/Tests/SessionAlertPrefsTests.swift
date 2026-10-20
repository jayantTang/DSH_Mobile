import DSHCore
import DSHTestingSupport
import XCTest

/// 025 T016 — `SessionAlertPrefs`: the two switches, their storage, and the
/// hook the app wires to push registration.
///
/// Every case runs against a scratch defaults domain, never `.standard`: these
/// keys are the user's own notification choices on their device, and they also
/// have to keep their shipped names, because the type moved modules in 025 and
/// a renamed key would silently reset the choice on upgrade.
@MainActor
final class SessionAlertPrefsTests: XCTestCase {

    private var isolated: IsolatedDefaults!

    override func setUp() {
        super.setUp()
        isolated = IsolatedDefaults(label: "alerts")
    }

    override func tearDown() {
        isolated?.removeDomain()
        isolated = nil
        super.tearDown()
    }

    func test_both_switches_default_to_on_with_an_empty_domain() {
        // Someone installing a remote client for their agent installed it
        // precisely to be told when something needs them.
        let prefs = SessionAlertPrefs(defaults: isolated.defaults)

        XCTAssertTrue(prefs.notifyOnTurnEnd)
        XCTAssertTrue(prefs.notifyOnAttention)
        XCTAssertFalse(prefs.isAuthorized)
    }

    func test_a_write_is_read_back_by_a_new_instance() {
        let first = SessionAlertPrefs(defaults: isolated.defaults)
        first.notifyOnTurnEnd = false
        first.notifyOnAttention = false

        let second = SessionAlertPrefs(defaults: isolated.defaults)

        XCTAssertFalse(second.notifyOnTurnEnd)
        XCTAssertFalse(second.notifyOnAttention)
    }

    func test_each_switch_writes_only_its_own_value() {
        let prefs = SessionAlertPrefs(defaults: isolated.defaults)
        prefs.notifyOnTurnEnd = false

        XCTAssertFalse(SessionAlertPrefs(defaults: isolated.defaults).notifyOnTurnEnd)
        XCTAssertTrue(SessionAlertPrefs(defaults: isolated.defaults).notifyOnAttention)
    }

    func test_the_storage_keys_are_the_shipped_ones() {
        // The migration contract of 025: the type moved, the keys did not.
        isolated.defaults.set(false, forKey: "alerts.notifyOnTurnEnd")
        isolated.defaults.set(false, forKey: "alerts.notifyOnAttention")

        let prefs = SessionAlertPrefs(defaults: isolated.defaults)

        XCTAssertFalse(prefs.notifyOnTurnEnd)
        XCTAssertFalse(prefs.notifyOnAttention)
    }

    func test_every_write_notifies_the_sync_hook() async {
        let prefs = SessionAlertPrefs(defaults: isolated.defaults)
        let fired = expectation(description: "onChange fired per write")
        fired.expectedFulfillmentCount = 2
        prefs.onChange = { fired.fulfill() }

        prefs.notifyOnTurnEnd = false
        prefs.notifyOnAttention = false

        await fulfillment(of: [fired], timeout: 2)
    }

    func test_authorization_state_is_not_persisted() {
        // It mirrors the system's answer, which the app re-reads on launch.
        // Storing it would let a stale "granted" outlive a revocation.
        let prefs = SessionAlertPrefs(defaults: isolated.defaults)
        prefs.isAuthorized = true

        XCTAssertFalse(SessionAlertPrefs(defaults: isolated.defaults).isAuthorized)
    }
}

// MARK: - 032：账户级开关

extension SessionAlertPrefsTests {
    /// 用户在本机改一次，两个钩子都要动：`onChange` 重新登记设备级推送，`onLocalChange` 推账户级。
    func test_a_local_change_fires_both_hooks() async {
        let prefs = SessionAlertPrefs(defaults: isolated.defaults)
        var onChange = 0
        var onLocal = 0
        prefs.onChange = { onChange += 1 }
        prefs.onLocalChange = { onLocal += 1 }

        prefs.notifyOnTurnEnd = false
        await settle()

        XCTAssertEqual(onChange, 1)
        XCTAssertEqual(onLocal, 1)
    }

    /// 远端并进来的值只走 `onChange`（本机要重新登记推送），**不**回推账户级——
    /// 否则两台设备会来回推同一份状态。
    func test_a_remote_change_does_not_echo_back_to_the_account() async {
        let prefs = SessionAlertPrefs(defaults: isolated.defaults)
        var onChange = 0
        var onLocal = 0
        prefs.onChange = { onChange += 1 }
        prefs.onLocalChange = { onLocal += 1 }

        prefs.applyRemote(turnEnd: false, attention: true)
        await settle()

        XCTAssertFalse(prefs.notifyOnTurnEnd)
        XCTAssertTrue(prefs.notifyOnAttention)
        XCTAssertEqual(onChange, 1, "a remote change still re-registers the device push")
        XCTAssertEqual(onLocal, 0, "a merged value must not be pushed back")
    }

    /// 远端值与本地一致时不产生任何副作用（免得每次拉取都触发一次登记）。
    func test_an_identical_remote_value_is_a_no_op() async {
        let prefs = SessionAlertPrefs(defaults: isolated.defaults)
        var onChange = 0
        prefs.onChange = { onChange += 1 }

        prefs.applyRemote(turnEnd: true, attention: true)
        await settle()

        XCTAssertEqual(onChange, 0)
    }

    /// 远端值也要落盘：下一次冷启动读到的是账户口径。
    func test_a_remote_value_persists() async {
        let prefs = SessionAlertPrefs(defaults: isolated.defaults)
        prefs.applyRemote(turnEnd: false, attention: false)
        await settle()

        let reloaded = SessionAlertPrefs(defaults: isolated.defaults)
        XCTAssertFalse(reloaded.notifyOnTurnEnd)
        XCTAssertFalse(reloaded.notifyOnAttention)
    }

    /// 钩子是 `Task` 里跑的，给它一拍再断言。
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(20))
    }
}
