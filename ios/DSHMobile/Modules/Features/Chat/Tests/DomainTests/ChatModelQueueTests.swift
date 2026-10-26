@testable import DSHChatDomain
import DSHConnectionAPI
import DSHCore
import DSHKit
import DSHTestingSupport
import XCTest

/// 排队输入：`session/control` 订阅、乐观入队/合并/提升、`session/updateQueue` 调用。
@MainActor
final class ChatModelQueueTests: XCTestCase {

    private var carrier: FakeCarrier!
    private var hub: HostEventHub!
    private var model: ChatModel!
    private var fake: FakeLinkService!

    override func setUp() async throws {
        try await super.setUp()
        carrier = FakeCarrier()
        hub = HostEventHub()
        model = ChatModel()
        fake = FakeLinkService(profiles: [TestFixtures.relayProfile()],
                               state: .connected(hostHome: "/Users/tester"))
        fake.activeProfile = try XCTUnwrap(fake.profiles.first)
        fake.clientOverride = HostClientFactory.make(carrier: carrier)
        carrier.registerLiveStream("session/follow")
        model.attach(store: fake, hub: hub)
    }

    override func tearDown() async throws {
        await model.close()
        hub.stop()
        model = nil
        fake = nil
        hub = nil
        carrier = nil
        try await super.tearDown()
    }

    private func open() async throws {
        await model.open(try ChatSeam.summary(id: "s-1", asOfSeq: 10))
        await carrier.waitForLiveStream("session/follow")
    }

    private func item(_ id: String, rpcId: String?, placement: String = "queued",
                      text: String) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id),
            "placement": .string(placement),
            "message": .object([
                "id": .string(id),
                "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            ]),
        ]
        if let rpcId { object["rpcId"] = .string(rpcId) }
        return .object(object)
    }

    private func queueFrame(_ items: [JSONValue], session: String = "s-1") -> JSONValue {
        .object(["type": .string("queue"), "sessionId": .string(session),
                 "items": .array(items)])
    }

    private func yieldControl(_ frame: JSONValue) {
        carrier.liveStreams["session/control"]?.yield(frame)
    }

    // MARK: - 控制帧

    func test_baseline_and_queue_frames_are_filtered_by_session_and_deduplicated() async throws {
        carrier.registerLiveStream("session/control")
        try await open()
        yieldControl(.object([
            "type": .string("baseline"),
            "value": .object(["queues": .object([
                "s-1": .array([item("m-1", rpcId: "r-1", text: "第一条")]),
                "s-2": .array([item("other", rpcId: nil, text: "别的会话")]),
            ])]),
        ]))
        yieldControl(queueFrame([
            item("m-1", rpcId: "r-1", text: "第一条"),
            item("m-2", rpcId: "r-2", placement: "steering", text: "第二条"),
        ]))

        let applied = await eventually { model.queuedInputs.count == 2 }
        XCTAssertTrue(applied, "queue: \(model.queuedInputs.map(\.id))")
        XCTAssertEqual(model.queuedInputs.map(\.id), ["m-1", "m-2"])
        XCTAssertFalse(model.queuedInputs.contains { $0.text == "别的会话" })
        XCTAssertEqual(model.queuedInputs.last?.placement, .steering)
    }

    // MARK: - 乐观入队 / 合并 / 提升

    func test_a_queued_send_is_optimistic_then_merged_by_rpc_id_and_promoted() async throws {
        carrier.registerLiveStream("session/control")
        carrier.unaryResponses["session/prompt"] = .success(.object([:]))
        try await open()
        yieldControl(queueFrame([]))

        model.draft = "排队的话"
        await model.send()

        let local = await eventually { model.queuedInputs.count == 1 }
        XCTAssertTrue(local, "queue: \(model.queuedInputs.map(\.id))")
        let optimistic = try XCTUnwrap(model.queuedInputs.first)
        XCTAssertTrue(optimistic.isLocal)
        XCTAssertEqual(optimistic.text, "排队的话")
        XCTAssertNotNil(optimistic.rpcId)
        // 排队输入不进转写：等待中的用户行被隐藏。
        XCTAssertFalse(model.rowsFor(screen: "s-1").contains { item in
            guard case .userMessage(_, _, _, let isPending, _) = item.kind else { return false }
            return isPending
        })

        let rpcId = try XCTUnwrap(optimistic.rpcId)
        yieldControl(queueFrame([item("m-9", rpcId: rpcId, text: "排队的话")]))
        let merged = await eventually {
            model.queuedInputs.count == 1 && model.queuedInputs.first?.id == "m-9"
        }
        XCTAssertTrue(merged, "queue: \(model.queuedInputs.map(\.id))")
        XCTAssertEqual(model.queuedInputs.first?.isLocal, false, "控制帧到达后以宿主项为准")

        // 宿主提升：转写里出现正常用户消息；队列帧随之变空。
        carrier.liveStreams["session/follow"]?.yield(ChatSeam.snapshot(
            cursor: 2, records: [ChatSeam.userMessage(seq: 1, text: "排队的话", rpcId: rpcId)]))
        yieldControl(queueFrame([]))
        let promoted = await eventually {
            model.queuedInputs.isEmpty
                && model.rowsFor(screen: "s-1").contains { $0.id == "user-\(rpcId)" }
        }
        XCTAssertTrue(promoted, "rows: \(model.rowsFor(screen: "s-1").map(\.id))")
    }

    // MARK: - updateQueue

    func test_steer_and_remove_call_updateQueue_with_the_host_item_id() async throws {
        carrier.registerLiveStream("session/control")
        carrier.unaryResponses["session/updateQueue"] = .success(.object([:]))
        try await open()
        yieldControl(queueFrame([
            item("m-1", rpcId: "r-1", text: "第一条"),
            item("m-2", rpcId: "r-2", text: "第二条"),
        ]))
        _ = await eventually { model.queuedInputs.count == 2 }

        let first = try XCTUnwrap(model.queuedInputs.first)
        await model.steerQueuedInput(first)
        let steerCall = try XCTUnwrap(carrier.calls(to: "session/updateQueue").last)
        let steerArgs = try XCTUnwrap(steerCall.args?["request"])
        XCTAssertEqual(steerArgs["sessionId"]?.stringValue, "s-1")
        XCTAssertEqual(steerArgs["itemId"]?.stringValue, "m-1")
        XCTAssertEqual(steerArgs["action"]?["kind"]?.stringValue, "steer")
        XCTAssertEqual(model.queuedInputs.map(\.id), ["m-2"])

        let second = try XCTUnwrap(model.queuedInputs.first)
        await model.removeQueuedInput(second)
        let removeCall = try XCTUnwrap(carrier.calls(to: "session/updateQueue").last)
        let removeArgs = try XCTUnwrap(removeCall.args?["request"])
        XCTAssertEqual(removeArgs["itemId"]?.stringValue, "m-2")
        XCTAssertEqual(removeArgs["action"]?["kind"]?.stringValue, "remove")
        XCTAssertTrue(model.queuedInputs.isEmpty)
    }

    // MARK: - 无控制能力

    func test_without_control_frames_only_the_local_optimistic_item_is_shown() async throws {
        carrier.streamScripts["session/control"] = [
            .failure(DSHRPCFailure(code: "link/unsupported", message: "no control stream")),
        ]
        carrier.unaryResponses["session/prompt"] = .success(.object([:]))
        try await open()
        let unavailable = await eventually { !model.queueControlAvailable }
        XCTAssertTrue(unavailable)

        model.draft = "本地乐观"
        await model.send()
        let shown = await eventually { model.queuedInputs.count == 1 }
        XCTAssertTrue(shown)
        XCTAssertTrue(model.queuedInputs.first?.isLocal == true)

        // 动作退化为本地撤回，不发 updateQueue。
        let item = try XCTUnwrap(model.queuedInputs.first)
        await model.steerQueuedInput(item)
        XCTAssertTrue(model.queuedInputs.isEmpty)
        XCTAssertTrue(carrier.calls(to: "session/updateQueue").isEmpty)
    }

    private func eventually(deadline: TimeInterval = 3,
                            _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}
