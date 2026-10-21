@testable import DSHConnectionDomain
import DSHConnectionAPI
import DSHKit
import DSHTestingSupport
import XCTest

/// 连接状态机：用可注入 carrier 覆盖首次连接、失败、断线清理。
@MainActor
final class ConnectionStoreConnectTests: XCTestCase {

    private func makeStore() -> (ConnectionStore, IsolatedDefaults) {
        let defaults = IsolatedDefaults(label: "connection-connect")
        let store = ConnectionStore(defaults: defaults.defaults)
        return (store, defaults)
    }

    private func stubSessionList(_ carrier: FakeCarrier, success: Bool) {
        carrier.unaryResponses["session/list"] = success
            ? .success(.object(["items": .array([])]))
            : .failure(NSError(domain: "test", code: 1))
    }

    func test_a_relay_connect_installs_the_client_and_marks_connected() async {
        let (store, defaults) = makeStore()
        defer { defaults.removeDomain() }
        let carrier = FakeCarrier()
        stubSessionList(carrier, success: true)
        carrier.unaryResponses["_link/hello"] = .success(.object([:]))
        store.makeCarrier = { _, _ in carrier }

        let profile = TestFixtures.relayProfile()
        await store.connect(profile: profile, secret: "device-token")

        XCTAssertTrue(store.state.isConnected)
        XCTAssertEqual(store.activeProfile?.id, profile.id)
        XCTAssertNotNil(store.chatHost)
        XCTAssertEqual(store.diagnosticsCarrier != nil, true)
        await store.disconnect()
        XCTAssertEqual(store.state, .disconnected)
        XCTAssertNil(store.chatHost)
    }

    func test_a_failed_connect_reports_failed_without_installing_a_link() async {
        let (store, defaults) = makeStore()
        defer { defaults.removeDomain() }
        let carrier = FakeCarrier()
        stubSessionList(carrier, success: false)
        store.makeCarrier = { _, _ in carrier }

        await store.connect(profile: TestFixtures.relayProfile(), secret: "device-token")

        guard case .failed = store.state else {
            return XCTFail("expected failed, got \(store.state)")
        }
        XCTAssertNil(store.chatHost)
        XCTAssertNotNil(store.lastError)
    }

    func test_disconnect_cancels_the_watcher_and_clears_the_profile() async {
        let (store, defaults) = makeStore()
        defer { defaults.removeDomain() }
        let carrier = FakeCarrier()
        stubSessionList(carrier, success: true)
        carrier.unaryResponses["_link/hello"] = .success(.object([:]))
        store.makeCarrier = { _, _ in carrier }

        await store.connect(to: TestFixtures.relayProfile())
        await store.disconnect()

        XCTAssertEqual(store.state, .disconnected)
        XCTAssertNil(store.activeProfile)
        XCTAssertNil(store.hostHome)
        XCTAssertTrue(store.capabilities.isEmpty)
    }
}
