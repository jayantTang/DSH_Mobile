import DSHConnectionAPI
import DSHCore
import DSHKit
import DSHSessionsDomain
import DSHTestingSupport
import XCTest

/// 027 — 冷启动预取瀑布：给哪几个会话排预取。
///
/// 预取是纯后台、纯缓存的行为：用户看不到它，它错了也只会以"打开会话要等"或
/// "后台悄悄拉了几百个会话"的形式出现（后者真的发生过，见 `MessageLayer` 的
/// 注记）。所以"挑哪些目标"必须钉住，而它只能从取页请求上看出来。
///
/// 存储走临时目录：`MessageLayer.attach(client:storePath:)` 的缝（028 加的）在这里够得着
/// ——瀑布就住在这个 layer 上，用例自己装配它，所以直接把库指到本用例的临时目录，
/// 不再往 `~/Library/Caches/message-store/` 建空库。
@MainActor
final class SessionListColdStartPrefetchTests: SessionsDomainTestCase {

    /// 取页请求的方法名（连接器本地方法，参数是扁平的 `HistoryWindowRequest`）。
    private static let fetchMethod = "_link/sessionWindow"

    func testColdStartPrefetchTakesTheTopTenAndSkipsSessionsWithoutACursor() async throws {
        // 12 条会话，活跃度 s1 > s2 > … > s12；s3 没有游标（asOfSeq = 0）。
        // 游标取 50 的整数倍：每条会话的缺口正好落在一个对齐页里，一次请求一条。
        let ids = (1...12).map { "s\($0)" }
        stubSessions(ids.enumerated().map { offset, id in
            let index = offset + 1
            return Wire.session(id,
                                updatedAt: Double(13 - index) * 1_000,
                                cwd: "/Users/me/proj",
                                asOfSeq: index == 3 ? 0 : 1_050 - index * 50)
        })
        stubWorkspaces([Wire.workspace("w1", path: "/Users/me/proj", title: "proj", sessions: ids)])

        // 消息层挂上之后才有瀑布。库文件指到本用例的临时目录：真实 Caches 那份一个字都不碰。
        let client = DSHClient(carrier: carrier)
        let storeURL = temp.url.appendingPathComponent("messages.sqlite3")
        let layer = MessageLayer()
        layer.attach(client: { client }, storePath: storeURL)
        guard layer.isReady else {
            throw XCTSkip("MessageLayer could not open its message store in this environment")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path),
                      "the layer must have opened the store at the injected path")
        model.attach(to: fake, hub: hub, messageLayer: layer)

        await model.refresh()
        let calls = await settledPrefetchCalls()

        // 上限 10：活跃度排第 11、12 的两条不预取。
        // 游标为 0 的跳过：s3 排在 prefix 里，但没有 cursor → 目标只有 9 个。
        let requested = Dictionary(grouping: calls) {
            $0.args?["address"]?["sessionId"]?.stringValue ?? "<missing>"
        }
        XCTAssertEqual(Set(requested.keys), ["s1", "s2", "s4", "s5", "s6", "s7", "s8", "s9", "s10"],
                       "targets are the ten most active sessions minus the ones with no cursor")
        XCTAssertEqual(calls.count, 9, "one page per target")
        XCTAssertNil(requested["s11"], "the activity cap must cut the list at ten")
        XCTAssertNil(requested["s12"])
        XCTAssertNil(requested["s3"], "a session with no cursor has nothing to prefetch")

        // 每条目标用的是自己的游标（对齐页上界 + 1）。
        let first = try XCTUnwrap(requested["s1"]?.first)
        XCTAssertEqual(first.args?["before"]?.intValue, 1_001)
        XCTAssertEqual(first.args?["address"]?["kind"]?.stringValue, "session")
        let tenth = try XCTUnwrap(requested["s10"]?.first)
        XCTAssertEqual(tenth.args?["before"]?.intValue, 551)
        XCTAssertEqual(notes("prefetch.coldstart").last?.fields["sessions"], "9")

        // 一台电脑一轮启动只排一次：再刷新一次不会重排。
        XCTAssertEqual(model.lastPrefetchScope, scope)
        await model.refresh()
        let again = await settledPrefetchCalls()
        XCTAssertEqual(again.count, 9, "the waterfall is scheduled once per computer, not once per refresh")
        XCTAssertEqual(notes("prefetch.coldstart").count, 1)
    }

    /// 瀑布是 `Task(priority: .utility)`，没有句柄：等取页请求安静下来再断言。
    private func settledPrefetchCalls(
        quietFor: TimeInterval = 0.3, deadline: TimeInterval = 5
    ) async -> [FakeCarrier.RecordedCall] {
        var lastCount = -1
        var quietSince = Date()
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            let count = carrier.calls(to: Self.fetchMethod).count
            if count != lastCount {
                lastCount = count
                quietSince = Date()
            } else if count > 0, Date().timeIntervalSince(quietSince) >= quietFor {
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return carrier.calls(to: Self.fetchMethod)
    }
}
