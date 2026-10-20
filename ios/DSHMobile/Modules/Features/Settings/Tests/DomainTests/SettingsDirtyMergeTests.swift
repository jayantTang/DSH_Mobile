import DSHKit
import DSHTestingSupport
import DSHSettingsDomain
import XCTest

/// `SettingsModel`'s dirty-key bookkeeping: how many keystrokes turn into how
/// many RPCs, and what shape that RPC has.
///
/// Two shapes exist and the merge is the whole point of the type: a partial
/// `settings/update` carrying just the keys a namespace touched, and a
/// whole-section `settings/replace` when an override is being *dropped* (a merge
/// cannot delete a key). Every case here pins which shape a given sequence of
/// edits produces, and that it is produced once.
@MainActor
final class SettingsDirtyMergeTests: XCTestCase {

    /// Three edits — two of them to the same key — in one namespace are one
    /// patch, and the patch carries the value the user left behind.
    func test_edits_in_one_namespace_merge_into_a_single_patch() async throws {
        let carrier = FakeCarrier()
        let harness = SettingsHarness.make(carrier: carrier)
        let ns = SettingsFixture.namespace
        carrier.serveDocument(SettingsFixture.document(
            value: .object(["preference": .string("system"), "fontSize": .int(13)])
        ))
        carrier.acceptWrites()
        await harness.model.load()

        harness.model.setValue(namespace: ns, path: ["preference"], value: .string("dark"))
        harness.model.setValue(namespace: ns, path: ["preference"], value: .string("light"))
        harness.model.setValue(namespace: ns, path: ["fontSize"], value: .int(15))
        await harness.model.flushPendingSaves()

        XCTAssertEqual(carrier.writeMethods, ["settings/update"],
                       "edits merge into one write per namespace, not one per keystroke")
        let call = try XCTUnwrap(carrier.calls(to: "settings/update").first)
        XCTAssertEqual(call.args?["ns"]?.stringValue, ns)
        let patch = try XCTUnwrap(call.args?["patch"]?.objectValue)
        XCTAssertEqual(patch.keys.sorted(), ["fontSize", "preference"],
                       "the patch names each touched key exactly once")
        XCTAssertEqual(patch["preference"], .string("light"),
                       "the last edit to a key is the one that goes out")
        XCTAssertEqual(patch["fontSize"], .int(15))

        // The dirty set is cleared by the write, so saving again is silent.
        await harness.model.flushPendingSaves()
        XCTAssertEqual(carrier.writeMethods, ["settings/update"])
        XCTAssertEqual(harness.model.saveState(for: ns), .saved)
    }

    /// An edit followed by a reset of the same key: the two intents cancel out
    /// into one whole-section write that no longer carries the key.
    func test_a_reset_after_an_edit_replaces_the_section_once() async throws {
        let carrier = FakeCarrier()
        let harness = SettingsHarness.make(carrier: carrier)
        let ns = SettingsFixture.namespace
        carrier.serveDocument(SettingsFixture.document(value: .object(["preference": .string("system")])))
        carrier.acceptWrites()
        await harness.model.load()

        harness.model.setValue(namespace: ns, path: ["preference"], value: .string("dark"))
        harness.model.resetField(namespace: ns, path: ["preference"])
        await harness.model.flushPendingSaves()

        XCTAssertEqual(carrier.writeMethods, ["settings/replace"],
                       "dropping an override is not expressible as a merge")
        let call = try XCTUnwrap(carrier.calls(to: "settings/replace").first)
        XCTAssertEqual(call.args?["ns"]?.stringValue, ns)
        let section = try XCTUnwrap(call.args?["section"])
        XCTAssertNil(section["preference"],
                     "the reset must survive the edit that came before it")

        // Both sets were cleared by the write, so the same save again is silent.
        await harness.model.flushPendingSaves()
        XCTAssertEqual(carrier.writeMethods, ["settings/replace"])
        XCTAssertEqual(harness.model.saveState(for: ns), .saved)
    }

    /// The other order: an edit after a reset. The recorded reset is not
    /// cancelled by the later edit, so the write is still one whole-section
    /// replace — and it carries the value the user left behind.
    func test_an_edit_after_a_reset_still_replaces_the_section_once() async throws {
        let carrier = FakeCarrier()
        let harness = SettingsHarness.make(carrier: carrier)
        let ns = SettingsFixture.namespace
        carrier.serveDocument(SettingsFixture.document(value: .object(["preference": .string("system")])))
        carrier.acceptWrites()
        await harness.model.load()

        harness.model.resetField(namespace: ns, path: ["preference"])
        harness.model.setValue(namespace: ns, path: ["preference"], value: .string("dark"))
        await harness.model.flushPendingSaves()

        XCTAssertEqual(carrier.writeMethods, ["settings/replace"],
                       "reset and edit net out to one section write, not two writes")
        let section = try XCTUnwrap(carrier.calls(to: "settings/replace").first?.args?["section"])
        XCTAssertEqual(section["preference"], .string("dark"),
                       "the section carries the value the user left behind")

        await harness.model.flushPendingSaves()
        XCTAssertEqual(carrier.writeMethods, ["settings/replace"])
    }
}
