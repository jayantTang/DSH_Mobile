@testable import DSHChatDomain
import DSHConnectionAPI
import DSHCore
import DSHKit
import DSHTestingSupport
import XCTest

/// 「扫描式搜索要能说出已扫多少片」的用例（2026-10-17 owner：条数与进度要一开始就看得见）。
///
/// 判据是 `ChatModel.SearchPage.progress`：连接器在一页里回报"共几片、还剩几片"（片 = 2000
/// 个 seq 一段的扫描单位），模型换算成"已扫 k/N 片"。界面只有在 `hasMore == false` 时才敢写
/// 「已搜全部历史」——这条用例钉的正是这个前提，以及"老连接器不发字段时不假装知道进度"。
@MainActor
final class ChatModelSearchProgressTests: XCTestCase {

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

    func test_a_scanned_page_reports_the_chunks_it_covered() async throws {
        try await openSession()
        carrier.unaryResponses["_link/sessionFind"] = .success(
            Self.find(totalChunks: 4, remainingChunks: 3, hasMore: true))

        let returned = await model.searchPage(query: "needle", onlyMine: false)
        let page = try XCTUnwrap(returned)

        XCTAssertEqual(page.scope, "connector")
        XCTAssertEqual(page.progress, .init(scannedChunks: 1, totalChunks: 4),
                       "4 chunks with 3 left means 1 scanned")
        XCTAssertTrue(page.hasMore, "an unfinished scan must not claim the whole history")
    }

    func test_the_page_that_reached_the_oldest_chunk_marks_the_scan_finished() async throws {
        try await openSession()
        carrier.unaryResponses["_link/sessionFind"] = .success(
            Self.find(totalChunks: 4, remainingChunks: 0, hasMore: false))

        let returned = await model.searchPage(query: "needle", onlyMine: false)
        let page = try XCTUnwrap(returned)

        XCTAssertEqual(page.progress, .init(scannedChunks: 4, totalChunks: 4))
        XCTAssertFalse(page.hasMore, "only a finished scan may claim the whole history")
    }

    func test_a_connector_without_the_progress_fields_leaves_progress_unknown() async throws {
        try await openSession()
        carrier.unaryResponses["_link/sessionFind"] = .success(Self.find(hasMore: true))

        let returned = await model.searchPage(query: "needle", onlyMine: false)
        let page = try XCTUnwrap(returned)

        XCTAssertNil(page.progress, "a connector that reports no chunks leaves progress unknown, not zero")
        XCTAssertTrue(page.hasMore)
    }

    func testHalfAProgressReportIsTreatedAsUnknown() async throws {
        // 只给 totalChunks、不给 remainingChunks（半个报告）不许当成"已扫 0 片"。
        try await openSession()
        carrier.unaryResponses["_link/sessionFind"] = .success(
            .object(["hits": .array([]), "hasMore": .bool(true), "source": .string("scan"),
                     "totalChunks": .int(7)]))

        let returned = await model.searchPage(query: "needle", onlyMine: false)
        let page = try XCTUnwrap(returned)

        XCTAssertNil(page.progress, "half a progress report must stay unknown")
        XCTAssertTrue(page.hasMore)
    }

    // MARK: - 夹具

    /// 一页 `_link/sessionFind` 的应答。留空 `totalChunks`/`remainingChunks` 就是老连接器的形状。
    private static func find(totalChunks: Int? = nil, remainingChunks: Int? = nil,
                            hasMore: Bool) -> JSONValue {
        var object: [String: JSONValue] = [
            "hits": .array([]),
            "hasMore": .bool(hasMore),
            "source": .string("scan"),
        ]
        if let totalChunks { object["totalChunks"] = .int(totalChunks) }
        if let remainingChunks { object["remainingChunks"] = .int(remainingChunks) }
        return .object(object)
    }

    private func openSession() async throws {
        // 活流挂住不结束：免得 EventStreamRetry 每 0.5 秒重订阅，把跟踪刷满。
        carrier.streamScripts["session/follow"] = [.hang]
        let profile = TestFixtures.relayProfile()
        let fake = FakeLinkService(
            profiles: [profile],
            state: .connected(hostHome: "/Users/tester")
        )
        fake.activeProfile = profile
        fake.capabilities = ["session-search", "search-progress"]
        fake.clientOverride = HostClientFactory.make(carrier: carrier)
        model.attach(store: fake, hub: hub)
        await model.open(try ChatSeam.summary(id: "s-search", asOfSeq: 1))
    }
}
