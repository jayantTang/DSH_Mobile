import DSHChatDomain
import DSHConnectionAPI
import DSHCore
import DSHKit
import DSHTestingSupport
import XCTest

/// 会话内搜索的**选路规则**与**拒绝留痕**（spec 007 FR-010 / FR-013 / FR-015 / FR-036）。
///
/// 选路原来埋在 SwiftUI 视图的 `performSearch` 里，单测碰不到——2026-10-17 的返工
/// （"一个字仍然走本地窗口"）就是这么漏过去的。抽成 `ChatModel.searchChannel` 之后，
/// 正常路径（有/无关键词 × 有/无能力）与异常路径（连接器拒绝）都能在这里钉住。
@MainActor
final class ChatModelSearchChannelTests: XCTestCase {

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

    // MARK: - 选路（纯函数，不碰网络）

    func testOnlyMineAlwaysReadsTheLocalStore() {
        for query in ["", "我", "迁移"] {
            XCTAssertEqual(ChatModel.searchChannel(onlyMine: true, query: query,
                                                   connectorSearchesWholeSession: true),
                           .localStore, "onlyMine must win over everything else (query: \(query))")
        }
    }

    func testAKeywordGoesToTheConnectorWhenTheCapabilityIsThere() {
        XCTAssertEqual(ChatModel.searchChannel(onlyMine: false, query: "我",
                                               connectorSearchesWholeSession: true),
                       .connector, "one character is enough since 2026-10-17")
        XCTAssertEqual(ChatModel.searchChannel(onlyMine: false, query: "迁移",
                                               connectorSearchesWholeSession: true),
                       .connector)
    }

    func testAnEmptyOrBlankKeywordStaysInTheLocalWindow() {
        for query in ["", "   ", "\n"] {
            XCTAssertEqual(ChatModel.searchChannel(onlyMine: false, query: query,
                                                   connectorSearchesWholeSession: true),
                           .localWindow,
                           "an empty query has no scope: the connector refuses it (query: \(query.debugDescription))")
        }
    }

    func testWithoutTheCapabilityEverythingFallsBackToTheLocalWindow() {
        for query in ["", "我", "迁移"] {
            XCTAssertEqual(ChatModel.searchChannel(onlyMine: false, query: query,
                                                   connectorSearchesWholeSession: false),
                           .localWindow, "an old connector can only search what is loaded")
        }
    }

    // MARK: - 翻页闸门（2026-10-17 真机：连接器扫完之后仍给"继续往下滑"，点一次重扫第一页）

    func testAConnectorPageIsOnlyRequestedWhileItHasMoreAndACursor() {
        XCTAssertTrue(ChatModel.canRequestSearchPage(source: .connector, cursor: "1200",
                                                     connectorHasMore: true, localCanExtend: false),
                      "hasMore + cursor: the next page is a real page")
        XCTAssertFalse(ChatModel.canRequestSearchPage(source: .connector, cursor: nil,
                                                      connectorHasMore: true, localCanExtend: true),
                       "no cursor means page one: re-requesting it rescans from the top")
        XCTAssertFalse(ChatModel.canRequestSearchPage(source: .connector, cursor: "1200",
                                                      connectorHasMore: false, localCanExtend: true),
                       "the scan reached the start: the local library's older history is a different source")
    }

    func testTheLocalWindowStillFollowsTheLocalLibrary() {
        XCTAssertTrue(ChatModel.canRequestSearchPage(source: .localWindow, cursor: nil,
                                                     connectorHasMore: false, localCanExtend: true))
        XCTAssertFalse(ChatModel.canRequestSearchPage(source: .localWindow, cursor: nil,
                                                      connectorHasMore: true, localCanExtend: false))
    }

    func testTheLocalStoreNeverPages() {
        XCTAssertFalse(ChatModel.canRequestSearchPage(source: .localStore, cursor: "x",
                                                      connectorHasMore: true, localCanExtend: true),
                       "the on-device store has no older page to fetch")
    }

    // MARK: - 异常路径：拒绝不等于"没有结果"（FR-013）

    func testAConnectorRefusalLeavesAReasonInsteadOfAnEmptyResult() async throws {
        try await openSession()
        carrier.unaryResponses["_link/sessionFind"] = .failure(
            NSError(domain: "FakeCarrier", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "session search is disabled"]))

        let page = await model.searchPage(query: "needle", onlyMine: false)

        XCTAssertNil(page, "a refused search has no page")
        let reason = try XCTUnwrap(model.searchRefusalReason,
                                   "a refusal must leave a reason: the reader would otherwise read it as zero hits")
        XCTAssertTrue(reason.contains("session search is disabled"), reason)
        XCTAssertNotNil(model.searchRefusalNotice, "the sheet shows this line")
    }

    func testASuccessfulSearchClearsTheRefusal() async throws {
        try await openSession()
        carrier.unaryResponses["_link/sessionFind"] = .failure(
            NSError(domain: "FakeCarrier", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "boom"]))
        _ = await model.searchPage(query: "needle", onlyMine: false)
        XCTAssertNotNil(model.searchRefusalReason)

        carrier.unaryResponses["_link/sessionFind"] = .success(Self.find(totalChunks: 2,
                                                                        remainingChunks: 1,
                                                                        hasMore: true))
        let page = await model.searchPage(query: "needle", onlyMine: false)

        XCTAssertNotNil(page)
        XCTAssertNil(model.searchRefusalReason, "a later success must not keep the old refusal")
        XCTAssertNil(model.searchRefusalNotice)
    }

    // MARK: - 夹具

    private static func find(totalChunks: Int?, remainingChunks: Int?, hasMore: Bool) -> JSONValue {
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
        carrier.streamScripts["session/follow"] = [.hang]
        let profile = TestFixtures.relayProfile()
        let fake = FakeLinkService(
            profiles: [profile],
            state: .connected(hostHome: "/Users/tester")
        )
        fake.activeProfile = profile
        fake.capabilities = ["session-search", "search-progress"]
        fake.clientOverride = DSHClient(carrier: carrier)
        model.attach(store: fake, hub: hub)
        await model.open(try ChatSeam.summary(id: "s-search", asOfSeq: 1))
    }
}
