import DSHConnectionAPI
import DSHConnectionDomain
import DSHKit
import DSHTestingSupport
import RelayKit
import XCTest

/// 025 T019 — what `ConnectionStore` can answer without a link.
///
/// Two things live here: the profile list's persistence (the shape on disk and
/// the reader that has to keep decoding it) and `describe(_:)`, the one place a
/// transport failure becomes words a person can act on.
///
/// Why the persistence cases do not drive `addProfile`/`removeProfile`: those
/// write through `UserDefaults.standard`, which `ConnectionStore` hard-wires
/// and nothing can inject, so a test that exercised them would either leak into
/// the runner's own domain or rewrite a real device's saved pairings. They also
/// need a keychain entry. What is testable is the contract on both sides of it
/// — the encoding the store writes, and the reader the store uses — so that is
/// what these cases pin, plus the read-only agreement between them.
@MainActor
final class ConnectionDomainStoreTests: XCTestCase {

    /// The key `ConnectionStore` persists the profile array under.
    private static let profilesKey = "dsh.connection.profiles"

    // MARK: - Persistence

    func test_saved_profiles_round_trip_through_a_defaults_domain() throws {
        let isolated = IsolatedDefaults(label: "profiles")
        defer { isolated.removeDomain() }

        let saved = [TestFixtures.relayProfile(), TestFixtures.directProfile()]
        isolated.defaults.set(try JSONEncoder().encode(saved), forKey: Self.profilesKey)

        let raw = try XCTUnwrap(isolated.defaults.data(forKey: Self.profilesKey))
        XCTAssertEqual(try JSONDecoder().decode([ConnectionProfile].self, from: raw), saved)
    }

    func test_a_missing_key_is_no_saved_connections_rather_than_a_failure() throws {
        // A fresh install has no value under the key at all, and the reader has
        // to answer "nothing saved" instead of refusing to start.
        let isolated = IsolatedDefaults(label: "empty-profiles")
        defer { isolated.removeDomain() }

        XCTAssertNil(isolated.defaults.data(forKey: Self.profilesKey))
        XCTAssertEqual(try expectedProfiles(in: isolated.defaults), [])
    }

    func test_the_static_reader_agrees_with_what_is_on_disk() throws {
        // Read-only on the shared domain on purpose (see the note above): the
        // claim is that `persistedProfiles()` is exactly the decode of the data
        // the store itself would write, whatever that domain happens to hold.
        let expected = try expectedProfiles(in: .standard)
        XCTAssertEqual(ConnectionStore.persistedProfiles(), expected)
    }

    /// The decode `ConnectionStore.loadProfiles()` performs, spelled out.
    private func expectedProfiles(in defaults: UserDefaults) throws -> [ConnectionProfile] {
        guard let data = defaults.data(forKey: Self.profilesKey) else { return [] }
        return try JSONDecoder().decode([ConnectionProfile].self, from: data)
    }

    // MARK: - A store before it is dialled

    func test_a_new_store_has_no_link_and_nothing_active() {
        let store = ConnectionStore()

        XCTAssertEqual(store.profiles, ConnectionStore.persistedProfiles())
        XCTAssertEqual(store.state, .disconnected)
        XCTAssertNil(store.activeProfile)
        XCTAssertNil(store.diagnosticsCarrier)
        XCTAssertFalse(store.isConnecting)
        XCTAssertFalse(store.isReconnecting)
        XCTAssertTrue(store.capabilities.isEmpty)
        XCTAssertFalse(store.supportsFileTransfer)
        XCTAssertNil(store.activeBaseURL)
        XCTAssertNil(store.scopeId)
        XCTAssertFalse(store.showsOutdatedConnectorNotice)
    }

    func test_a_link_service_view_of_the_store_starts_disconnected() {
        let service: any LinkService = ConnectionStore()

        XCTAssertFalse(service.isConnected)
        XCTAssertFalse(service.isConnecting)
        XCTAssertEqual(service.state, .disconnected)
    }

    func test_file_transfer_without_a_relay_profile_is_refused() {
        // `.direct` is the DEBUG-only channel and cannot carry file bytes; the
        // refusal is what keeps the product path unambiguous — a second route
        // that quietly took over is what the R-1 incident was made of.
        let store = ConnectionStore()

        do {
            _ = try store.fileTransferTarget()
            XCTFail("a store with no relay profile must refuse a file transfer")
        } catch let error as RelayFileTransfer.Unavailable {
            guard case .noRelay = error else {
                return XCTFail("unexpected unavailable case: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - describe(_:): a failure in words

    private struct StubError: LocalizedError {
        var errorDescription: String? { "stub description" }
    }

    func test_a_localized_error_keeps_its_own_wording() {
        XCTAssertEqual(LinkErrors.describe(StubError()), "stub description")
    }

    func test_each_pairing_failure_gets_its_own_wording() {
        // The defect this pins: every pairing failure used to read "the code is
        // invalid, used or expired", so a user holding a stale code could not
        // tell which of the three it was — or what to do next.
        let used = LinkErrors.describe(DSHRPCFailure(code: "pair/used-code", message: "used"))
        let expired = LinkErrors.describe(DSHRPCFailure(code: "pair/expired-code", message: "expired"))
        let invalid = LinkErrors.describe(DSHRPCFailure(code: "pair/invalid-code", message: "bad"))

        for message in [used, expired, invalid] {
            XCTAssertFalse(message.isEmpty)
        }
        XCTAssertEqual(Set([used, expired, invalid]).count, 3)
    }

    func test_a_connector_failure_is_told_apart_from_a_credential_failure() {
        let offline = LinkErrors.describe(DSHRPCFailure(code: "host/offline", message: "offline"))
        let stale = LinkErrors.describe(DSHRPCFailure(code: "auth/invalid-token", message: "stale"))
        let oldConnector = LinkErrors.describe(DSHRPCFailure(code: "file/unsupported", message: "old"))

        XCTAssertFalse(offline.isEmpty)
        XCTAssertEqual(Set([offline, stale, oldConnector]).count, 3)
    }

    func test_a_timeout_and_a_dead_network_are_worded_differently() {
        let timeout = LinkErrors.describe(URLError(.timedOut))
        let offline = LinkErrors.describe(URLError(.notConnectedToInternet))

        XCTAssertFalse(timeout.isEmpty)
        XCTAssertFalse(offline.isEmpty)
        XCTAssertNotEqual(timeout, offline)
    }

    func test_an_unknown_failure_keeps_the_error_itself() {
        // The last branch deliberately does not flatten an unrecognised failure
        // into a generic sentence: an accurate unknown beats a wrong summary.
        let unknown = DSHRPCFailure(code: "something/else", message: "something else")

        XCTAssertEqual(LinkErrors.describe(unknown), unknown.localizedDescription)
    }
}
