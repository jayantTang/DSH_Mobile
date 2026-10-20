import DSHKit
import DSHTestingSupport
import DSHSettingsDomain
import XCTest

/// `SettingsModel.loadDevices`: the ways the paired-device section comes up
/// empty, and the one way it comes up failed.
///
/// The section only exists on a relay link (`SettingsModel.canManageDevices`),
/// and the list itself is an HTTPS call to the relay, not a DSH method — so
/// these cases cover the transport verdict and the failure the relay call
/// reports. The success path is not here: `RelayDeviceAdmin` is a concrete type
/// the model builds itself, with no seam to hand it a canned `GET /devices`
/// answer, and standing up a listening relay is the simulator lane's job rather
/// than a unit case's.
@MainActor
final class SettingsDevicesTests: XCTestCase {

    /// Nothing to manage: a direct (DEBUG) link has nowhere to send the request,
    /// and a relay link whose carrier exposes no relay identity ends the same
    /// way — withdrawn, not left spinning.
    func test_a_section_with_nothing_to_manage_is_withdrawn() async {
        // Direct: the section is never offered.
        let direct = SettingsHarness.make(carrier: FakeCarrier(), relay: false)
        await direct.model.loadDevices(retries: 1, interval: .milliseconds(1))
        XCTAssertFalse(direct.model.devicesAvailable,
                       "a direct link cannot manage devices; there is no relay to ask")
        XCTAssertTrue(direct.model.devices.isEmpty)
        XCTAssertEqual(direct.model.devicesPhase, .idle,
                       "the section must not be left with a spinner on it")

        // Relay, but the client is not a relay carrier: the section is offered
        // while the wait runs, then withdrawn.
        let relay = SettingsHarness.make(carrier: FakeCarrier(), relay: true)
        let listing = Task { await relay.model.loadDevices(retries: 5, interval: .milliseconds(50)) }
        let offered = await eventually { relay.model.devicesAvailable }
        XCTAssertTrue(offered, "a relay link should offer the section while it waits for its carrier")
        XCTAssertEqual(relay.model.devicesPhase, .loading)
        await listing.value

        XCTAssertFalse(relay.model.devicesAvailable)
        XCTAssertEqual(relay.model.devicesPhase, .idle)
        XCTAssertTrue(relay.model.devices.isEmpty)
    }

    /// A relay that cannot be reached: the list fails with words on it, and the
    /// section stays offered so a later refresh can fill it.
    ///
    /// No external network is touched. The relay origin points at a closed
    /// loopback port, so the GET is refused immediately — the same shape an
    /// offline relay produces, without a timeout to wait out. The URL comes from
    /// the carrier, not from the saved profile, which is the point: the profile
    /// says "relay", the carrier says where.
    func test_a_relay_that_cannot_be_reached_reports_the_failure() async {
        let relayURL = URL(string: "http://127.0.0.1:1/dsh-link")!
        let link = LinkCarrier(configuration: LinkConfiguration(
            relayURL: relayURL, agentId: "agt_test", deviceToken: "dts_test"
        ))
        let harness = SettingsHarness.make(carrier: link)

        await harness.model.loadDevices(retries: 1, interval: .milliseconds(1))

        XCTAssertTrue(harness.model.devicesAvailable,
                      "a failed list keeps the section, so a refresh can retry it")
        XCTAssertTrue(harness.model.devices.isEmpty)

        guard case .failed(let message) = harness.model.devicesPhase else {
            XCTFail("an unreachable relay must leave the section failed, not \(harness.model.devicesPhase)")
            return
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(harness.model.devicesError, message,
                       "the row's error line and the phase carry the same wording")
    }
}
