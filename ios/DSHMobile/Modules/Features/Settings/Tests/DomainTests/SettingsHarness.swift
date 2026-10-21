import DSHKit
import DSHTestingSupport
import DSHSettingsDomain
import Foundation

/// The fixture `SettingsModel` is driven through in this suite.
///
/// A case keeps its own reference to the carrier (a `FakeCarrier` for what went
/// out on the wire, a `GatedCarrier` when it also needs to look at a state that
/// exists only while a call is in flight); the harness only wires the pieces.
@MainActor
struct SettingsHarness {
    let store: FakeLinkService
    let model: SettingsModel

    /// Builds a harness: one saved profile (relay or direct) plus a fake client.
    ///
    /// The profile decides what the screen is *allowed* to do — the device
    /// section needs a relay transport — while the carrier decides what actually
    /// answers. Keeping them apart is what lets a case cover "a relay profile
    /// whose client has no relay identity".
    static func make(carrier: any DSHCarrier, relay: Bool = true) -> SettingsHarness {
        let profile = relay ? TestFixtures.relayProfile() : TestFixtures.directProfile()
        let store = FakeLinkService(profiles: [profile])
        store.activeProfile = profile
        store.clientOverride = HostClientFactory.make(carrier: carrier)
        let model = SettingsModel()
        model.attach(to: store)
        return SettingsHarness(store: store, model: model)
    }
}

/// The `settings/describe` answer `SettingsModel` reads.
enum SettingsFixture {
    static let namespace = "ui-theme"

    static func document(
        writable: Bool = true,
        value: JSONValue = .object(["preference": .string("system")])
    ) -> JSONValue {
        .object([
            "writable": .bool(writable),
            "hasDocument": .bool(true),
            "namespaces": .array([
                .object([
                    "ns": .string(namespace),
                    "value": value,
                    "applies": .string("live"),
                    "revision": .int(3),
                ]),
            ]),
        ])
    }
}

extension FakeCarrier {
    /// Answers `settings/describe` with `document`.
    func serveDocument(_ document: JSONValue) {
        unaryResponses["settings/describe"] = .success(document)
    }

    /// Both write endpoints succeed (an empty ack, as the host sends).
    func acceptWrites() {
        unaryResponses["settings/update"] = .success(.object([:]))
        unaryResponses["settings/replace"] = .success(.object([:]))
    }

    /// The write endpoints this fake host was asked to perform, in call order.
    ///
    /// Recorded as method names rather than a count: "one write" and "one write
    /// of the right shape" are different claims, and a merge and a whole-section
    /// replace are the two shapes `SettingsModel` chooses between.
    var writeMethods: [String] {
        calls.map(\.method).filter { $0 == "settings/update" || $0 == "settings/replace" }
    }
}

/// Runs on the main actor until `condition` holds, or gives up after `deadline`.
///
/// Needed wherever a case asserts on state set by a task it started: polling is
/// the only way to observe it without depending on how many times the scheduler
/// happens to switch.
@MainActor
func eventually(deadline: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(deadline)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
