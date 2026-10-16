import DSHKit
@testable import DSHTestingSupport
import XCTest

/// `FakeCarrier.waitForLiveStream` 的**原子性**（2026-10-17 两次挂死的根因）。
///
/// 原来是"先查 `liveStreams[endpoint]`、再进锁登记"两步。两步之间恰好来一次订阅时，
/// `stream()` 会把当时的等待者列表一次取走（空表），随后登记的等待者永远没人唤醒——
/// 整套用例无声挂死（`sample` 显示卡在 `XCTWaiter` 里等一个再也不会来的续体）。
///
/// 这里钉住那条不变式：**流已注册就绝不再登记等待者**（调用方立刻继续），
/// 流未注册就登记、并且一定在订阅到来的那一刻被唤醒。
///
/// 注意两个容易写错的地方：
///   * `AsyncThrowingStream` 的建流闭包在**第一次迭代**时才跑，所以"订阅已发生"要以
///     真的有人在 `for await` 它为准，不能只看 `stream()` 返回；
///   * 等待一律有界（到点判失败），否则用例自己会挂死而不是报错——这正是本文件第一版
///     踩的坑。
final class FakeCarrierStreamWaiterTests: XCTestCase {

    private struct Args: Encodable, Sendable { let request = 0 }

    private actor Flag {
        private var value = false
        func set() { value = true }
        func get() -> Bool { value }
    }

    private func eventually(_ seconds: Double = 2,
                            _ condition: @escaping () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    /// 让建流闭包真的跑起来（第一次迭代），并等到流被登记。
    @discardableResult
    private func subscribe(_ carrier: FakeCarrier, _ endpoint: String) async -> Task<Void, Never> {
        let stream = await carrier.stream(endpoint: endpoint, args: Args())
        let consumer = Task {
            do { for try await _ in stream {} } catch { /* 流结束或出错都不影响这条用例 */ }
        }
        _ = await eventually { await carrier.liveStreams[endpoint] != nil }
        return consumer
    }

    func testWaitingAfterTheStreamWasRegisteredReturnsImmediately() async {
        let carrier = FakeCarrier()
        carrier.registerLiveStream("session/follow")
        let consumer = await subscribe(carrier, "session/follow")
        defer { consumer.cancel() }

        let flag = Flag()
        let waited = Task { await carrier.waitForLiveStream("session/follow"); await flag.set() }
        defer { waited.cancel() }

        let returned = await eventually { await flag.get() }
        XCTAssertTrue(returned,
                      "waitForLiveStream must not park when the stream is already there")
    }

    func testAWaitingCallerIsWokenByTheSubscription() async {
        let carrier = FakeCarrier()
        carrier.registerLiveStream("session/follow")

        let flag = Flag()
        let waited = Task { await carrier.waitForLiveStream("session/follow"); await flag.set() }
        defer { waited.cancel() }
        // 先确认它真的挂上了，再让订阅到来——否则这个用例可能只是"没等到需要唤醒的时刻"。
        let parked = await eventually { await carrier.liveStreamWaiters["session/follow"]?.isEmpty == false }
        XCTAssertTrue(parked, "the waiter should be registered before the subscription arrives")

        let consumer = await subscribe(carrier, "session/follow")
        defer { consumer.cancel() }

        let woke = await eventually { await flag.get() }
        XCTAssertTrue(woke, "the registered waiter must be resumed when the endpoint is subscribed")
    }

    func testAStaleWaiterForADifferentEndpointIsNotWoken() async {
        let carrier = FakeCarrier()
        carrier.registerLiveStream("session/other")

        let flag = Flag()
        let waited = Task { await carrier.waitForLiveStream("session/follow"); await flag.set() }
        defer { waited.cancel() }
        let parked = await eventually { await carrier.liveStreamWaiters["session/follow"]?.isEmpty == false }
        XCTAssertTrue(parked, "waiting on an endpoint nobody subscribed to yet")

        let consumer = await subscribe(carrier, "session/other")
        defer { consumer.cancel() }

        let woke = await eventually(0.4) { await flag.get() }
        XCTAssertFalse(woke, "another endpoint's subscription must not wake this waiter")
    }

    func testClaimingAWaiterForAnAlreadySubscribedEndpointIsRefused() async {
        // 直接钉 seam：这一支就是竞态里"检查之后、登记之前来了订阅"的那一刻该走的路。
        // 无条件登记（老写法）会让调用方永远挂起，所以这里必须拒绝。
        let carrier = FakeCarrier()
        carrier.registerLiveStream("session/follow")
        let consumer = await subscribe(carrier, "session/follow")
        defer { consumer.cancel() }

        let box = Flag()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let claimed = carrier.claimWaiter("session/follow", c)
            if claimed { Task { await box.set() } }   // 不该发生；发生了就让断言看得见
            c.resume()
        }
        let claimed = await eventually(0.3) { await box.get() }
        XCTAssertFalse(claimed, "an already-subscribed endpoint must refuse a new waiter")
        let leftover = await carrier.liveStreamWaiters["session/follow"]?.isEmpty ?? true
        XCTAssertTrue(leftover, "no waiter may be left behind for an already-subscribed endpoint")
    }
}
