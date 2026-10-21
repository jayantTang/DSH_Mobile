@testable import DSHChatDomain
import DSHConnectionAPI
import DSHCore
import DSHKit
import DSHTestingSupport
import XCTest

/// 「换会话时可见状态必须自洽」的用例（2026-10-16 owner 报的"新建会话先闪一下旧会话"）。
///
/// 断言对象是**渲染入口** `ChatModel.rowsFor(screen:)`：它回答"这一屏该画哪些行"，
/// 界面（`ChatView`）与量具（`StaleRenderWatch`）读的都是它。配合"这一刻发布的是哪个会话"，
/// 判据有三条：
///
/// 1. 没有会话时，任何一屏都拿不到行；
/// 2. 发布了 A 时，A 那一屏拿到 A 的行，别的屏拿到空；
/// 3. 换会话的过渡帧（已开始切、还没发布）里，**新那一屏拿到空**，而旧那一屏仍拿得到自己的行
///    ——第 3 条正是缺陷曾经出现的位置，用 `beforeVisibleSwap` 把这一刻挂住再断言。
///
/// 这些断言为什么放在单元层：判据是"模型交给渲染器的行属于谁"，与真实中转、真机界面无关。
/// 换会话的两次磁盘等待在单测环境里常常不成立（没有 messageLayer 时读尾部立即返回），
/// 所以用 `beforeVisibleSwap` 这个 DEBUG-only 挂起点把过渡帧钉住；生产构建里它恒为 nil。
@MainActor
final class ChatModelSwitchVisibilityTests: XCTestCase {

    private var carrier: FakeCarrier!
    private var hub: HostEventHub!
    private var model: ChatModel!

    override func setUp() {
        super.setUp()
        carrier = FakeCarrier()
        hub = HostEventHub()
        model = ChatModel()
    }

    override func tearDown() async throws {
        await model.close()
        hub.stop()
        model = nil
        hub = nil
        carrier = nil
        try await super.tearDown()
    }

    // MARK: - 渲染入口的归属规则

    func test_the_renderer_only_ever_gets_rows_of_its_own_session() async throws {
        XCTAssertTrue(model.rowsFor(screen: "s-a").isEmpty,
                      "no screen may be handed rows before a session is open")

        let aRowIds = try await openSessionA()

        XCTAssertEqual(model.rowsFor(screen: "s-a").map(\.id), aRowIds,
                       "screen A should be handed A's own rows")
        XCTAssertTrue(model.rowsFor(screen: "s-other").isEmpty,
                      "screen s-other must not be handed A's rows: \(model.rowsFor(screen: "s-other").map(\.id))")
        XCTAssertTrue(model.rowsFor(screen: "s-b").isEmpty,
                      "screen B must not be handed A's rows before B is opened")
    }

    // MARK: - 过渡帧（缺陷现场）

    func test_during_the_switch_the_new_screen_gets_nothing_and_the_old_one_keeps_its_rows() async throws {
        let aRowIds = try await openSessionA()

        // 把 open(B) 挂在"发布点之前"的那一刻。
        let gate = SwapGate()
        model.beforeVisibleSwap = {
            gate.reached = true
            while !gate.released { try? await Task.sleep(for: .milliseconds(2)) }
        }
        let bSummary = try ChatSeam.summary(id: "s-b", asOfSeq: 3)
        let opening = Task { await self.model.open(bSummary) }
        let parked = await eventually { gate.reached }
        XCTAssertTrue(parked, "open(B) never reached the swap point (the debug hook was not called)")

        // ① 这就是用户看到的那一闪：B 那一屏被交出了 A 的行。修复后必须是空。
        XCTAssertTrue(model.rowsFor(screen: "s-b").isEmpty,
                      "screen B was handed A's rows during the switch: \(model.rowsFor(screen: "s-b").map(\.id))")
        // ② 旧那一屏（A）在过渡期间仍拿得到自己的行，不该被判成"没有内容"。
        XCTAssertEqual(model.rowsFor(screen: "s-a").map(\.id), aRowIds,
                       "screen A lost its rows during the switch (the outgoing screen would flash blank)")
        // ③ 此刻发布的仍是 A：B 还没有被发布，界面不可能画到 B 的头像/标题。
        XCTAssertEqual(model.visible?.summary.sessionId, "s-a")

        gate.released = true
        await opening.value

        // ④ 发布 B 之后：旧那一屏再也拿不到行，B 那一屏拿到 B 自己的行。
        let resubscribed = await eventually { self.carrier.calls(to: "session/follow").count == 2 }
        XCTAssertTrue(resubscribed, "open(B) did not subscribe to B's stream")
        XCTAssertEqual(model.visible?.summary.sessionId, "s-b")
        XCTAssertTrue(model.rowsFor(screen: "s-a").isEmpty,
                      "screen A is still handed rows after the switch: \(model.rowsFor(screen: "s-a").map(\.id))")

        carrier.liveStreams["session/follow"]?.yield(ChatSeam.snapshot(cursor: 3, records: [
            ChatSeam.userMessage(seq: 2, text: "in B"),
        ]))
        let gotB = await eventually { !self.model.rowsFor(screen: "s-b").isEmpty }
        XCTAssertTrue(gotB, "B's snapshot never landed on screen B")
        XCTAssertEqual(model.rowsFor(screen: "s-b").map(\.id), ["user-message-2"])
        XCTAssertFalse(model.rowsFor(screen: "s-b").map(\.id).contains(where: aRowIds.contains),
                       "screen B's rows contain rows that belong to A")
    }

    // MARK: - 发布序列

    func test_the_published_sequence_never_pairs_the_new_session_with_the_old_rows() async throws {
        let aRowIds = try await openSessionA()

        let recorder = PublishRecorder()
        recorder.watch(model)

        await model.open(try ChatSeam.summary(id: "s-b", asOfSeq: 3))
        let resubscribed = await eventually { self.carrier.calls(to: "session/follow").count == 2 }
        XCTAssertTrue(resubscribed, "open(B) did not subscribe to B's stream")
        carrier.liveStreams["session/follow"]?.yield(ChatSeam.snapshot(cursor: 3, records: [
            ChatSeam.userMessage(seq: 2, text: "in B"),
        ]))
        _ = await eventually { !self.model.rowsFor(screen: "s-b").isEmpty }
        try? await Task.sleep(for: .milliseconds(50))

        // 序列里必须真的出现过这两个自洽的发布，否则这条用例什么也没验到。
        XCTAssertTrue(recorder.states.contains { $0.sessionId == "s-a" && $0.rowIds == aRowIds },
                      "the published sequence never shows A's rows under A: \(recorder.states)")
        XCTAssertTrue(recorder.states.contains { $0.sessionId == "s-b" && !$0.rowIds.isEmpty },
                      "the published sequence never shows B's rows under B: \(recorder.states)")
        // 反例：**任何**一次发布都不允许出现"开的是 B、行还是 A"。
        XCTAssertFalse(recorder.states.contains { $0.sessionId == "s-b" && $0.rowIds == aRowIds },
                       "the published sequence paired screen B with A's rows: \(recorder.states)")
    }

    // MARK: - 夹具

    /// 打开 A，并让它有两条行；返回这两行的 id。
    private func openSessionA() async throws -> [String] {
        carrier.registerLiveStream("session/follow")
        attachFakeLink(carrier: carrier)
        await model.open(try ChatSeam.summary(id: "s-a", asOfSeq: 1))
        await carrier.waitForLiveStream("session/follow")
        carrier.liveStreams["session/follow"]?.yield(ChatSeam.snapshot(cursor: 1, records: [
            ChatSeam.userMessage(seq: 1, text: "in A"),
            ChatSeam.assistantMessage(seq: 2, text: "ok"),
        ]))
        let folded = await eventually { self.model.rowsFor(screen: "s-a").count == 2 }
        XCTAssertTrue(folded, "A's snapshot did not fold into two rows: \(model.rowsFor(screen: "s-a").map(\.id))")
        return model.rowsFor(screen: "s-a").map(\.id)
    }

    private func attachFakeLink(carrier anyCarrier: any DSHCarrier) {
        let profile = TestFixtures.relayProfile()
        let fake = FakeLinkService(
            profiles: [profile],
            state: .connected(hostHome: "/Users/tester")
        )
        fake.activeProfile = profile
        fake.clientOverride = HostClientFactory.make(carrier: anyCarrier)
        model.attach(store: fake, hub: hub)
    }

    /// Runs the main actor until `condition` holds, or returns false on timeout.
    private func eventually(deadline: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    /// `beforeVisibleSwap` 的开关。
    ///
    /// 用类而不是捕获局部 `var`：挂起点的闭包是要存进模型的逃逸闭包，
    /// 捕获可变局部变量在并发检查下不成立。
    @MainActor
    private final class SwapGate {
        var reached = false
        var released = false
    }

    /// 记录 `visible` 的每一次发布（会话 id + 那一刻的行的 id）。
    ///
    /// `withObservationTracking` 的回调发生在**变更之前**，所以在回调里让出一次主线程
    /// 再读，记到的才是"发布之后"的状态。
    @MainActor
    private final class PublishRecorder {
        struct State: CustomStringConvertible {
            let sessionId: String?
            let rowIds: [String]

            var description: String { "\(sessionId ?? "-"):\(rowIds)" }
        }

        private(set) var states: [State] = []
        private weak var model: ChatModel?

        func watch(_ model: ChatModel) {
            self.model = model
            capture()
            observe()
        }

        private func capture() {
            guard let model else { return }
            states.append(State(sessionId: model.visible?.summary.sessionId,
                                rowIds: model.visible?.timeline.items.map(\.id) ?? []))
        }

        private func observe() {
            guard let model else { return }
            withObservationTracking {
                _ = model.visible?.summary.sessionId
                _ = model.visible?.timeline.items.count
            } onChange: { [weak self] in
                Task { @MainActor in
                    self?.capture()
                    self?.observe()
                }
            }
        }
    }
}
