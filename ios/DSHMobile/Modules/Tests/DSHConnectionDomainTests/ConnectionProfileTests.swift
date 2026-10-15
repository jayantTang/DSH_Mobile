import DSHConnectionAPI
import DSHConnectionDomain
import DSHTestingSupport
import XCTest

/// 025 T019 — the pairing state machine's pure half.
///
/// Nothing here needs a network, a host or an install: the profile shape that
/// goes to disk, the two transports, the state flags the UI branches on, and
/// the `LinkService` surface every other domain layer is handed. The dialling
/// loop itself (`ConnectionStore.performConnect`) stays out of reach — it wants
/// a real carrier — and is covered by the simulator lanes instead.
@MainActor
final class ConnectionProfileTests: XCTestCase {

    // MARK: - Codable

    func test_a_relay_profile_survives_a_codable_round_trip() throws {
        var profile = TestFixtures.relayProfile()
        profile.hostHome = "/Users/tester"
        profile.relayName = "Tester Mac"
        profile.lastConnectedAt = Date(timeIntervalSince1970: 1_700_000_000)
        profile.outdatedNoticeDismissedFor = "1.2.3"

        let data = try JSONEncoder().encode([profile])
        let decoded = try JSONDecoder().decode([ConnectionProfile].self, from: data)

        XCTAssertEqual(decoded, [profile])
        XCTAssertEqual(decoded.first?.transport, profile.transport)
        XCTAssertEqual(decoded.first?.secretAccount, profile.secretAccount)
    }

    func test_a_direct_profile_survives_a_codable_round_trip() throws {
        var profile = TestFixtures.directProfile()
        profile.hostHome = "/Users/tester"

        let data = try JSONEncoder().encode([profile])
        let decoded = try JSONDecoder().decode([ConnectionProfile].self, from: data)

        XCTAssertEqual(decoded, [profile])
        XCTAssertTrue(decoded[0].isDirect)
    }

    func test_profiles_written_before_the_optional_fields_existed_still_decode() throws {
        // Every optional field was added after profiles were already on disk.
        // A mandatory field here would fail the whole array and lose the saved
        // connections, so the missing-key case is part of the contract.
        let legacy: [[String: Any]] = [
            [
                "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
                "name": "Old Mac",
                "transport": [
                    "relay": [
                        "relayURL": "https://relay.example.com/dsh-link",
                        "agentId": "agt_old",
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)

        let decoded = try JSONDecoder().decode([ConnectionProfile].self, from: data)

        XCTAssertEqual(decoded.count, 1)
        let profile = try XCTUnwrap(decoded.first)
        XCTAssertEqual(profile.name, "Old Mac")
        XCTAssertEqual(
            profile.transport,
            .relay(relayURL: URL(string: "https://relay.example.com/dsh-link")!, agentId: "agt_old")
        )
        XCTAssertNil(profile.hostHome)
        XCTAssertNil(profile.relayName)
        XCTAssertNil(profile.lastConnectedAt)
        XCTAssertNil(profile.outdatedNoticeDismissedFor)
    }

    // MARK: - Identity and transport

    func test_the_keychain_account_is_derived_from_the_profile_id() {
        let id = UUID()
        let profile = ConnectionProfile(
            id: id,
            name: "Mac",
            transport: .relay(relayURL: URL(string: "https://relay.example.com/dsh-link")!, agentId: "agt")
        )

        XCTAssertEqual(profile.secretAccount, "profile-\(id.uuidString)")
        XCTAssertNotEqual(
            TestFixtures.relayProfile().secretAccount,
            TestFixtures.directProfile().secretAccount
        )
    }

    func test_only_the_direct_transport_avoids_the_relay() {
        XCTAssertTrue(TestFixtures.directProfile().isDirect)
        XCTAssertFalse(TestFixtures.relayProfile().isDirect)
    }

    func test_profiles_are_matched_by_transport_identity_not_by_name() {
        // Scanning the same computer twice must update the saved entry instead
        // of piling up copies; the identity used for that is the transport.
        let first = TestFixtures.relayProfile(name: "A")
        let sameHost = TestFixtures.relayProfile(name: "B")
        let otherHost = ConnectionProfile(
            name: "A",
            transport: .relay(relayURL: URL(string: "https://relay.example.com/dsh-link")!, agentId: "agt_other")
        )

        XCTAssertEqual(first.transport, sameHost.transport)
        XCTAssertNotEqual(first.transport, otherHost.transport)
        XCTAssertNotEqual(first.id, sameHost.id)
    }

    func test_the_subtitle_names_the_host_each_transport_reaches() {
        XCTAssertEqual(TestFixtures.directProfile().subtitle, "http://127.0.0.1:19387")

        let relay = TestFixtures.relayProfile().subtitle
        XCTAssertTrue(relay.hasPrefix("relay.example.com"), "unexpected relay subtitle: \(relay)")
        XCTAssertTrue(relay.contains("·"), "unexpected relay subtitle: \(relay)")
    }

    // MARK: - ConnectionState

    func test_the_state_flags_are_mutually_exclusive() {
        let cases: [(ConnectionState, Bool, Bool)] = [
            (.disconnected, false, false),
            (.connecting("dialing"), false, true),
            (.connected(hostHome: "/Users/tester"), true, false),
            (.connected(hostHome: nil), true, false),
            (.failed("nope"), false, false),
        ]

        for (state, connected, connecting) in cases {
            XCTAssertEqual(state.isConnected, connected, "isConnected for \(state)")
            XCTAssertEqual(state.isConnecting, connecting, "isConnecting for \(state)")
        }
    }

    // MARK: - LinkService, through the fake every domain test injects

    func test_the_protocol_reports_the_state_it_was_given() {
        let fake = FakeLinkService(state: .connecting("dialing"))
        let service: any LinkService = fake

        XCTAssertTrue(service.isConnecting)
        XCTAssertFalse(service.isConnected)

        fake.state = .connected(hostHome: "/Users/tester")
        XCTAssertTrue(service.isConnected)
        XCTAssertFalse(service.isConnecting)
        XCTAssertEqual(service.state, .connected(hostHome: "/Users/tester"))

        fake.state = .failed("nope")
        XCTAssertFalse(service.isConnected)
        XCTAssertFalse(service.isConnecting)
    }

    func test_capability_probing_answers_from_the_declared_set() {
        let service: any LinkService = FakeLinkService(capabilities: ["relay.file-transfer"])

        XCTAssertTrue(service.supports("relay.file-transfer"))
        XCTAssertFalse(service.supports("session-search"))
        XCTAssertFalse(FakeLinkService().supports("relay.file-transfer"))
    }

    func test_the_protocol_exposes_the_saved_profiles_and_the_last_error() {
        let relay = TestFixtures.relayProfile()
        let fake = FakeLinkService(profiles: [relay], state: .connected(hostHome: relay.hostHome))
        fake.activeProfile = relay
        fake.lastError = "last failure"
        fake.connectorVersion = "0.9.0"
        let service: any LinkService = fake

        XCTAssertEqual(service.profiles, [relay])
        XCTAssertEqual(service.activeProfile, relay)
        XCTAssertEqual(service.lastError, "last failure")
        XCTAssertEqual(service.connectorVersion, "0.9.0")
    }

    func test_a_fake_started_empty_has_no_profile_and_no_capability() {
        let service: any LinkService = FakeLinkService()

        XCTAssertTrue(service.profiles.isEmpty)
        XCTAssertNil(service.activeProfile)
        XCTAssertEqual(service.state, .disconnected)
        XCTAssertNil(service.lastError)
        XCTAssertTrue(service.capabilities.isEmpty)
    }
}
