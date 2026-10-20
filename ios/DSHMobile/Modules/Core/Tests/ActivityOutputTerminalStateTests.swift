import DSHCore
import DSHKit
import DSHTestingSupport
import XCTest

/// 「任务详情」（面板里的「查看输出 ›」）在**落不到终态**时会一直转圈：`JobOutputView`
/// 的最后一条分支是 `ProgressView`，它的条件是
/// `chunks 为空 && error == nil && isFinished == false && hasOpened == false`。
/// 也就是说：链接没有 client、或订阅建不起来时，页面永远停在"加载中"，
/// 读者看到的既不是输出也不是错误——这也是"详情显示的不是有效内容"的一种。
///
/// 用例把这条界面判据搬成断言：展开输出之后，`OutputFeed` 必须已经落到
/// 四个可见结局之一（有内容 / 已开流 / 已结束 / 错误）。现在不满足（会红）。
@MainActor
final class ActivityOutputTerminalStateTests: XCTestCase {

    private func job(id: String = "bash-1") throws -> Job {
        let json = """
        {"id":"\(id)","kind":"bash","label":"npm test","status":"running","startedAt":1,
         "outputTotal":0,"owner":"session-1"}
        """
        return try JSONDecoder().decode(Job.self, from: Data(json.utf8))
    }

    /// `JobOutputView.content(for:)` 的最后一条分支条件（与视图一一对应）。
    private func showsLoadingSpinner(_ feed: ActivityModel.OutputFeed?) -> Bool {
        guard let feed else { return true }
        return feed.chunks.isEmpty
            && feed.error == nil
            && feed.isFinished == false
            && feed.hasOpened == false
    }

    /// 链接没给 client（断线、或连接器还没挂上）时展开输出：
    /// 页面必须给出可见结局，不能停在转圈。
    func testOpeningOutputWithoutClientDoesNotStayLoading() throws {
        let service = FakeLinkService(capabilities: [LinkHandshake.Capability.jobsRoster])
        service.clientOverride = nil
        let hub = HostEventHub()
        let model = ActivityModel()
        model.attach(service: service, hub: hub)
        defer { model.closeOutput(); hub.stop() }

        model.openOutput(sessionId: "session-1", job: try job())

        XCTAssertFalse(
            showsLoadingSpinner(model.outputFeed),
            "without a client the output page spins forever; it must reach an error or a terminal state instead"
        )
    }
}
