import DSHCore
import DSHKit
import DSHTestingSupport
import XCTest

/// 列表状态订阅归模型，不归视图：列表面板关闭/离屏期间收到的
/// `api-session/status(false)` 必须仍然生效，回到列表不需要开关一次会话。
@MainActor
final class SessionListLiveStateTests: SessionsDomainTestCase {

    func test_status_false_reaches_the_model_without_any_view() async throws {
        carrier.registerLiveStream("$events")
        let client = HostClientFactory.make(carrier: carrier)
        // 先起事件源，再 attach：`HostEventHub.start` 会清空已有观察者，
        // 顺序反了模型就收不到帧（这正是“视图订阅”类 bug 的测试盲区）。
        hub.start(link: LinkGateway(clientProvider: { client }))
        await carrier.waitForLiveStream("$events")
        model.attach(to: fake, hub: hub)

        stubSessions([Wire.session("s1", updatedAt: 1_000, running: true)])
        await model.refresh()
        XCTAssertTrue(try XCTUnwrap(model.allSessions.first).running)

        let continuation = try XCTUnwrap(carrier.liveStreams["$events"])
        let frame = """
        {"type":"emit","event":"api-session/status","args":["s1",false]}
        """
        switch continuation.yield(try JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))) {
        case .enqueued: break
        case .dropped: XCTFail("events stream not reading")
        case .terminated: XCTFail("events stream ended")
        @unknown default: XCTFail("unexpected yield")
        }

        await eventually("status(false) applies with no view present") {
            self.model.allSessions.first?.running == false
        }
    }

    private func eventually(_ description: String, deadline: TimeInterval = 2,
                            _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("timed out: \(description)")
    }
}
