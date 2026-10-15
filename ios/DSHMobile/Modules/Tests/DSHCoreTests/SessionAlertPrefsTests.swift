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
        SessionAlertPrefs.onChange = nil
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
        SessionAlertPrefs.onChange = { fired.fulfill() }

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
