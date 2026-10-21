@testable import DSHChatDomain
import DSHCore
@testable import DSHKit
import DSHTestingSupport
import XCTest

/// 「只看我的提问」列表里印出来的「第 N 条」必须是会话里的位置。
///
/// 2026-10-19 现象：列表最近一两条显示成「第 9223372036854775806 条」。
/// `TranscriptSearchSheet.row` 把 `TranscriptSearchHit.seq` 直接当序号印出来，而
/// `ChatModel.localUserInputHits` 的 seq 来自 `MessageStore`：未确认的上行消息在库里
/// 带的是 `MessagePipeline` 的合成排序键（`Int.max` 起递减），于是本地排序键冒充了
/// 会话位置。搜索面板的关键词查法走同一条读侧（`searchUserInputRecords`），一起钉住。
///
/// 这份用例钉的是**用户看到的结果**，不是修法：无论最终选择"读侧排除未确认消息"
/// 还是"面板不给未入历史的行编号"，这两条都必须绿。
@MainActor
final class ChatModelUserInputIndexTests: XCTestCase {

    private var carrier: FakeCarrier!
    private var hub: HostEventHub!
    private var model: ChatModel!
    private var layer: MessageLayer!
    private var directory: URL!

    /// 会话里真实存在的两个位置（面板应当印出的最大序号就是它）。
    private static let newestConfirmedSeq = 3
    /// `MessagePipeline` 给未确认消息分配的合成键。
    private static let syntheticSeq = Int.max - 1

    override func setUp() async throws {
        try await super.setUp()
        carrier = FakeCarrier()
        hub = HostEventHub()
        model = ChatModel()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-user-input-index-tests-\(UUID().uuidString)")
        layer = MessageLayer()
        let client = HostClientFactory.make(carrier: carrier)
        layer.attach(client: { client },
                     storePath: directory.appendingPathComponent("messages.sqlite3"))
        guard layer.store != nil else {
            throw XCTSkip("MessageLayer could not open its message store in this environment")
        }
        model.attach(messageLayer: layer)
    }

    override func tearDown() async throws {
        await model.close()
        hub.stop()
        model = nil
        layer = nil
        hub = nil
        carrier = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    // MARK: - 浏览态（「只看我的提问」，本地全量库）

    func testTheBrowsingListNeverPrintsALocalSortKeyAsTheIndex() async throws {
        try await openSession()
        try await seedHistory()

        let hits = await model.localUserInputHits(query: "")

        XCTAssertFalse(hits.isEmpty, "the fixture has confirmed prompts; the list must show them")
        for hit in hits {
            XCTAssertLessThanOrEqual(
                hit.seq, Self.newestConfirmedSeq,
                "the sheet prints hit.seq as 「第 N 条」: a message the session has not numbered "
                + "must not show up with a synthetic key (got \(hit.seq))")
        }
    }

    // MARK: - 关键词查法（同一条读侧，FTS/LIKE 两条分支）

    func testKeywordHitsNeverPrintALocalSortKeyAsTheIndex() async throws {
        try await openSession()
        try await seedHistory()

        for query in ["还没确认", "刚发"] {
            let hits = await model.localUserInputHits(query: query)
            XCTAssertTrue(hits.isEmpty,
                          "an unsaved prompt has no position in the session (query: \(query), "
                          + "seqs: \(hits.map(\.seq)))")
        }
    }

    // MARK: - 夹具

    private func openSession() async throws {
        carrier.streamScripts["session/follow"] = [.hang]
        let profile = TestFixtures.relayProfile()
        let fake = FakeLinkService(
            profiles: [profile],
            state: .connected(hostHome: "/Users/tester")
        )
        fake.activeProfile = profile
        fake.capabilities = ["history-role-filter"]
        fake.clientOverride = HostClientFactory.make(carrier: carrier)
        model.attach(store: fake, hub: hub)
        await model.open(try ChatSeam.summary(id: "s-user-inputs", asOfSeq: 3))
        XCTAssertNotNil(model.sessionScope, "the fixture needs a scope to write the store")
    }

    /// 两条已确认的用户输入（会话位置 2、3）＋ 一条未确认（合成键）。
    ///
    /// 未确认那条从 `MessagePipeline` 的同一落库入口写进去——`upsertPending`，
    /// 与真机"刚发出去还没等到确认"时库里那一行长完全一样。
    private func seedHistory() async throws {
        let scope = try XCTUnwrap(model.sessionScope)
        let sessionId = try XCTUnwrap(model.session?.sessionId)
        let store = try XCTUnwrap(layer.store)
        try await store.applyWrites([
            .upsertRecords(scope: scope, sessionId: sessionId, records: [
                userMessage(2, text: "上一轮问过的问题"),
                userMessage(Self.newestConfirmedSeq, text: "这一轮问过的问题"),
            ]),
            .upsertPending(scope: scope, sessionId: sessionId, clientId: "c-live",
                           record: userMessage(Self.syntheticSeq, text: "刚发出还没确认")),
        ])
    }

    /// 与真实上行记录同形：正文在 `data.text`，来源是用户本人，rpcId 即 clientId。
    private func userMessage(_ seq: Int, text: String) -> SessionRecord {
        let json = #"""
        {"type":"user/message","seq":\#(seq),"time":1789276358732,"data":{"text":"\#(text)","source":{"kind":"user","rpcId":"r-\#(seq)"}}}
        """#
        let event = try! JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
        return SessionRecord(event: event)
    }
}
