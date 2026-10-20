import DSHKit
import DSHTestingSupport
import DSHSettingsDomain
import XCTest

/// 027 — 两个状态变化挤在同一个窗口里时，`SettingsModel` 怎么收场。
///
/// 单动作的用例在隔壁（`SettingsSaveStateTests`、`SettingsDirtyMergeTests`、
/// `SettingsValueTextTests`）；这一份钉的是"写还没回来，第二个命名空间 / 第二次
/// 拒绝 / 还没结束的读就到了"——按命名空间分开的那套状态机正是为这种交错存在的。
@MainActor
final class SettingsCombinationTests: XCTestCase {

    /// 两个命名空间：一个能被拦住，另一个照常写。
    enum TwoNamespaces {
        static let first = "ns-a"
        static let second = "ns-b"

        static func document() -> JSONValue {
            .object([
                "writable": .bool(true),
                "hasDocument": .bool(true),
                "namespaces": .array([
                    namespace(first, value: .object(["preference": .string("system")])),
                    namespace(second, value: .object(["fontSize": .int(13)])),
                ]),
            ])
        }

        private static func namespace(_ ns: String, value: JSONValue) -> JSONValue {
            .object([
                "ns": .string(ns),
                "value": value,
                "applies": .string("live"),
                "revision": .int(3),
            ])
        }

        /// 每个 `settings/update` 带的是哪个命名空间、哪份 patch。
        static func writes(_ carrier: FakeCarrier) -> [(ns: String, patch: JSONValue?)] {
            carrier.calls(to: "settings/update").map { call in
                (call.args?["ns"]?.stringValue ?? "", call.args?["patch"])
            }
        }
    }

    /// 并发保存两个命名空间：一个停在 saving 时，另一个的保存照常走完——
    /// 两个命名空间的状态机互不排队。
    func test_a_write_held_in_one_namespace_does_not_hold_the_other_one() async {
        let gate = TestGate()
        let gated = GatedCarrier()
        let harness = SettingsHarness.make(carrier: gated)
        let carrier = gated.inner
        carrier.serveDocument(TwoNamespaces.document())
        carrier.acceptWrites()
        await harness.model.load()

        let first = TwoNamespaces.first
        let second = TwoNamespaces.second
        harness.model.setValue(namespace: first, path: ["preference"], value: .string("dark"))
        harness.model.setValue(namespace: second, path: ["fontSize"], value: .int(15))
        // 防抖不是这条用例的对象：先把排好的定时器撤掉，下面两次写就是仅有的两次。
        harness.model.stop()

        // 只有第一个到达的 update 被拦住，第二个直接过。
        let oneShot = OneShotFlag()
        gated.hold = { method in
            guard method == "settings/update" else { return }
            if oneShot.claim() { await gate.wait() }
        }

        let held = Task { await harness.model.save(namespace: first) }
        let parked = await eventually { harness.model.saveState(for: first) == .saving }
        XCTAssertTrue(parked, "the first write never reached the saving state")

        await harness.model.save(namespace: second)

        XCTAssertEqual(harness.model.saveState(for: second), .saved,
                       "the second namespace must not wait behind the first one")
        XCTAssertEqual(harness.model.saveState(for: first), .saving,
                       "the held write is still in flight")
        XCTAssertEqual(TwoNamespaces.writes(carrier).map(\.ns), [second],
                       "only the namespace that was not held may have gone out")

        await gate.open()
        await held.value

        XCTAssertEqual(harness.model.saveState(for: first), .saved)
        let writes = TwoNamespaces.writes(carrier)
        XCTAssertEqual(writes.count, 2, "one write per namespace, neither lost nor duplicated")
        XCTAssertEqual(Set(writes.map(\.ns)), Set([first, second]))
        var patches: [String: JSONValue] = [:]
        for write in writes {
            if let patch = write.patch { patches[write.ns] = patch }
        }
        XCTAssertEqual(patches[second]?["fontSize"], .int(15),
                       "each write carries its own namespace's edit")
        XCTAssertEqual(patches[first]?["preference"], .string("dark"))
        harness.model.stop()
    }

    /// 连环冲突：第一次保存被拒，重试又被拒——停在 failed，两次各发一次请求，
    /// 之后不再自己重发（拒绝不是重试循环的起点）。
    func test_a_write_refused_twice_stays_failed_and_never_resends_on_its_own() async {
        let carrier = FakeCarrier()
        let harness = SettingsHarness.make(carrier: carrier)
        let ns = SettingsFixture.namespace
        carrier.serveDocument(SettingsFixture.document(value: .object(["preference": .string("system")])))
        await harness.model.load()

        carrier.unaryResponses["settings/update"] = .failure(
            DSHRPCFailure(code: "settings-conflict", message: "conflict from the host")
        )

        harness.model.setValue(namespace: ns, path: ["preference"], value: .string("dark"))
        await harness.model.flushPendingSaves()

        guard case .failed(let firstFailure) = harness.model.saveState(for: ns) else {
            XCTFail("a refused write must land in failed, not \(harness.model.saveState(for: ns))")
            return
        }

        // The retry: the host refuses it again, for the same reason.
        await harness.model.flushPendingSaves()

        guard case .failed(let secondFailure) = harness.model.saveState(for: ns) else {
            XCTFail("a refused retry must land in failed, not \(harness.model.saveState(for: ns))")
            return
        }
        XCTAssertEqual(secondFailure, firstFailure, "the same refusal must read the same both times")
        XCTAssertEqual(
            secondFailure,
            "\u{8BBE}\u{7F6E}\u{5DF2}\u{5728}\u{5176}\u{4ED6}\u{4F4D}\u{7F6E}\u{66F4}\u{65B0}\u{3002}\u{8BF7}\u{5237}\u{65B0}\u{540E}\u{91CD}\u{8BD5}\u{3002}",
            "a conflict must reach the user as the conflict wording, not as a transport error"
        )
        XCTAssertEqual(carrier.calls(to: "settings/update").count, 2, "one write per attempt")
        XCTAssertEqual(harness.model.value(namespace: ns, path: ["preference"]), .string("dark"),
                       "two refusals must not eat the edit")

        // 静置一段时间：拒绝之后没有任何自动重发。
        try? await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(carrier.calls(to: "settings/update").count, 2,
                       "a failed save must not put itself back on the wire")
        XCTAssertEqual(harness.model.saveState(for: ns), .failed(secondFailure))
        harness.model.stop()
    }

    /// 加载中编辑：`load()` 还没回来时用户已经敲了一格——晚到的读不许把它盖掉。
    /// 读本身仍然落地（document 里是宿主那份），只是草稿与待写状态归用户。
    func test_an_edit_made_while_the_load_is_in_flight_survives_the_late_read() async {
        let gate = TestGate()
        let gated = GatedCarrier()
        let harness = SettingsHarness.make(carrier: gated)
        let carrier = gated.inner
        let ns = SettingsFixture.namespace
        carrier.serveDocument(SettingsFixture.document(value: .object(["preference": .string("system")])))
        carrier.acceptWrites()

        gated.hold = { method in
            if method == "settings/describe" { await gate.wait() }
        }

        let load = Task { await harness.model.load() }
        let reading = await eventually { harness.model.phase == .loading }
        XCTAssertTrue(reading, "the read never started, so nothing was in flight")

        // The user types while the screen is still loading.
        harness.model.setValue(namespace: ns, path: ["preference"], value: .string("dark"))
        XCTAssertEqual(harness.model.value(namespace: ns, path: ["preference"]), .string("dark"))
        // 防抖不是这条用例的对象：撤掉它，让"读回来那一帧"成为唯一可能覆盖草稿的动作。
        harness.model.stop()

        await gate.open()
        await load.value

        XCTAssertEqual(harness.model.phase, .loaded)
        XCTAssertEqual(carrier.calls(to: "settings/describe").count, 1, "one read")
        XCTAssertEqual(harness.model.document?.namespace(ns)?.value["preference"], .string("system"),
                       "the read did land and carries the host's value")
        XCTAssertEqual(harness.model.value(namespace: ns, path: ["preference"]), .string("dark"),
                       "the late read must not overwrite an edit made while it was in flight")

        // 待写的那一格也还是用户的：下一次保存发出去的是 "dark"，不是宿主的 "system"。
        await harness.model.save(namespace: ns)
        let writes = carrier.calls(to: "settings/update")
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.args?["patch"]?["preference"], .string("dark"))
        harness.model.stop()
    }
}

/// Hands the hold to the first caller only, so a case can park one write without
/// parking the next one. A synchronous claim on purpose: the second write must
/// lose the race by arriving later, not by winning a hop to an actor.
private final class OneShotFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}
