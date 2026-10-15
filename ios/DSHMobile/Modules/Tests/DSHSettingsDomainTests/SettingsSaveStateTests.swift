import DSHKit
import DSHTestingSupport
import DSHSettingsDomain
import XCTest

/// The save state machine of `SettingsModel`: what the badge beside a namespace
/// title says, and what a refused write leaves behind.
///
/// The writes are driven through `flushPendingSaves()` rather than by waiting out
/// the 650 ms debounce: `flushPendingSaves` is what the screen calls on dismissal,
/// it cancels the pending timer first, and cancelling it here is what makes "one
/// write" mean one write. The debounce itself is not covered by these cases.
@MainActor
final class SettingsSaveStateTests: XCTestCase {

    /// A namespace the screen has opened but never written reports idle, and an
    /// edit alone is not a write in flight.
    func test_a_namespace_that_was_never_written_reports_idle() async {
        let carrier = FakeCarrier()
        let harness = SettingsHarness.make(carrier: carrier)
        let ns = SettingsFixture.namespace
        carrier.serveDocument(SettingsFixture.document())
        await harness.model.load()

        XCTAssertEqual(harness.model.saveState(for: ns), .idle)
        XCTAssertEqual(harness.model.saveState(for: "no-such-namespace"), .idle,
                       "a namespace the fake host never sent must not read as a failure")

        harness.model.setValue(namespace: ns, path: ["preference"], value: .string("dark"))
        XCTAssertEqual(harness.model.saveState(for: ns), .idle,
                       "the badge describes a write, not an edit")
        harness.model.stop()

        // The badge copy: idle shows nothing, and each write state shows exactly
        // one word of its own.
        XCTAssertNil(SettingsModel.SaveState.idle.label)
        let labels = [
            SettingsModel.SaveState.saving.label,
            SettingsModel.SaveState.saved.label,
            SettingsModel.SaveState.failed("x").label,
        ].compactMap { $0 }
        XCTAssertEqual(labels.count, 3, "every non-idle state needs a badge")
        XCTAssertEqual(Set(labels).count, 3, "the badges must be told apart")
    }

    /// idle -> saving -> saved, with the write held open so the middle state can
    /// actually be looked at.
    func test_a_write_walks_idle_saving_saved() async {
        let gate = TestGate()
        let gated = GatedCarrier()
        let harness = SettingsHarness.make(carrier: gated)
        let carrier = gated.inner
        let ns = SettingsFixture.namespace
        carrier.serveDocument(SettingsFixture.document())
        carrier.acceptWrites()
        await harness.model.load()

        harness.model.setValue(namespace: ns, path: ["preference"], value: .string("dark"))
        XCTAssertEqual(harness.model.saveState(for: ns), .idle)

        gated.hold = { method in
            if method == "settings/update" { await gate.wait() }
        }
        let write = Task { await harness.model.flushPendingSaves() }

        let parked = await eventually { harness.model.saveState(for: ns) == .saving }
        XCTAssertTrue(parked, "the write never reached the saving state")
        await gate.open()
        await write.value

        XCTAssertEqual(harness.model.saveState(for: ns), .saved)
        XCTAssertEqual(carrier.writeMethods, ["settings/update"])
    }

    /// A write the host refuses lands in failed, and the edit survives it.
    func test_a_write_the_host_refuses_lands_in_failed_and_keeps_the_edit() async {
        let carrier = FakeCarrier()
        let harness = SettingsHarness.make(carrier: carrier)
        let ns = SettingsFixture.namespace
        carrier.serveDocument(SettingsFixture.document())
        await harness.model.load()

        let raw = "conflict from the host"
        carrier.unaryResponses["settings/update"] = .failure(
            DSHRPCFailure(code: "settings-conflict", message: raw)
        )

        harness.model.setValue(namespace: ns, path: ["preference"], value: .string("dark"))
        await harness.model.flushPendingSaves()

        guard case .failed(let message) = harness.model.saveState(for: ns) else {
            XCTFail("a refused write must land in failed, not \(harness.model.saveState(for: ns))")
            return
        }
        XCTAssertFalse(message.isEmpty)
        // Pinned as it is, not as it should be: `save` reports through
        // `LinkErrors.describe`, which passes a code it does not know straight
        // through, so the badge shows the host's own sentence. The
        // settings-specific copy for `settings-conflict` lives in
        // `SettingsModel.describe` and nothing on this path calls it.
        XCTAssertEqual(message, raw)
        XCTAssertEqual(harness.model.value(namespace: ns, path: ["preference"]), .string("dark"),
                       "a refused write must not eat the edit")

        // Still queued, so the next attempt sends it again instead of dropping it.
        await harness.model.flushPendingSaves()
        XCTAssertEqual(carrier.calls(to: "settings/update").count, 2)
    }

    /// A deployment that refuses writes is not even asked: the save path stops at
    /// the guard instead of putting a doomed RPC on the wire.
    func test_a_read_only_deployment_refuses_the_write_without_a_call() async {
        let carrier = FakeCarrier()
        let harness = SettingsHarness.make(carrier: carrier)
        let ns = SettingsFixture.namespace
        carrier.serveDocument(SettingsFixture.document(writable: false))
        carrier.acceptWrites()
        await harness.model.load()

        XCTAssertTrue(harness.model.isReadOnly)

        harness.model.setValue(namespace: ns, path: ["preference"], value: .string("dark"))
        await harness.model.flushPendingSaves()

        guard case .failed(let message) = harness.model.saveState(for: ns) else {
            XCTFail("a read-only deployment must report a failed save, not \(harness.model.saveState(for: ns))")
            return
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(carrier.writeMethods.isEmpty,
                      "a read-only deployment must not be asked to write at all")
        XCTAssertEqual(harness.model.value(namespace: ns, path: ["preference"]), .string("dark"))
    }
}
