import DSHKit
import XCTest

/// P2 的线格式与"命中落在哪一行"（spec 007 T036）。
final class HistorySearchTests: XCTestCase {

    private func userMessage(seq: Int, text: String = "hi") -> SessionRecord {
        let json = """
        {"type":"user/message","seq":\(seq),"time":1789276358732,
         "data":{"content":[{"type":"text","text":"\(text)"}],
                 "source":{"kind":"user","rpcId":"r\(seq)"},"role":"user","id":"m\(seq)"}}
        """
        let event = try! JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
        return SessionRecord(event: event)
    }

    func testRequestEncodesFlatArgsAndOmitsWhatIsNotSet() throws {
        let request = HistorySearchRequest(address: .session(sessionId: "s1"), query: "needle")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["address", "query"], "没给的可选字段不该出现")
        XCTAssertNil(object["request"], "连接器本地方法不吃 {request: …} 信封")
    }

    func testResponseDecodesHitsWithHighlightOffsets() throws {
        let json = """
        {"hits":[{"seq":1685,"role":"me","snippet":"…关于渐变背景图的提问…","highlightStart":4,"highlightLength":5}],
         "cursor":"1600","hasMore":true,"source":"scan"}
        """
        let value = try JSONDecoder().decode(HistorySearchValue.self, from: Data(json.utf8))
        XCTAssertEqual(value.hits.first?.seq, 1685)
        XCTAssertEqual(value.hits.first?.role, "me")
        XCTAssertEqual(value.cursor, "1600")
        XCTAssertTrue(value.hasMore)
        XCTAssertEqual(value.source, "scan")
    }

    func testAResponseCarriesScanProgressAndAnOlderOneDoesNot() throws {
        // 扫描应答带片数（界面据此说「已扫 k/N 片」）；老连接器不发这两个字段时是**缺失**，
        // 不是 0——界面按"进度未知"处理。
        let scannedJSON = #"{"hits":[],"cursor":"1200","hasMore":true,"source":"scan","totalChunks":7,"remainingChunks":5}"#
        let scanned = try JSONDecoder().decode(HistorySearchValue.self, from: Data(scannedJSON.utf8))
        XCTAssertEqual(scanned.totalChunks, 7)
        XCTAssertEqual(scanned.remainingChunks, 5)

        let indexedJSON = #"{"hits":[],"cursor":null,"hasMore":false,"source":"index"}"#
        let indexed = try JSONDecoder().decode(HistorySearchValue.self, from: Data(indexedJSON.utf8))
        XCTAssertNil(indexed.totalChunks, "the indexed path has no chunk concept")
        XCTAssertNil(indexed.remainingChunks)

        let partialJSON = #"{"hits":[],"hasMore":true,"source":"scan","totalChunks":7}"#
        let partial = try JSONDecoder().decode(HistorySearchValue.self, from: Data(partialJSON.utf8))
        XCTAssertEqual(partial.totalChunks, 7)
        XCTAssertNil(partial.remainingChunks, "half a progress report is not a progress report")
    }

    func testASingleCharacterQueryIsSentAsIs() throws {
        // 下限由连接器掌握（2026-10-17 起 1 个字符）；客户端不偷偷改写查询。
        let request = HistorySearchRequest(address: .session(sessionId: "s1"), query: "我", limit: 50)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(object["query"] as? String, "我")
        XCTAssertEqual(Set(object.keys), ["address", "query", "limit"])
    }

    func testAHitLandsOnTheRowThatOwnsItsSeq() {
        let items = ChatTimeline()
        var timeline = items
        timeline.reset(with: [userMessage(seq: 100), userMessage(seq: 200), userMessage(seq: 300)])
        let rows = timeline.items
        XCTAssertEqual(TranscriptHitLocator.row(forSeq: 250, in: rows)?.seq, 200, "落在 200 那一行")
        XCTAssertEqual(TranscriptHitLocator.row(forSeq: 200, in: rows)?.seq, 200, "正好等于行自己的 seq")
        XCTAssertEqual(TranscriptHitLocator.row(forSeq: 999, in: rows)?.seq, 300, "比最后一行还新：最后一行")
        XCTAssertEqual(TranscriptHitLocator.row(forSeq: 1, in: rows)?.seq, 100, "比第一行还旧：第一行")
        XCTAssertNil(TranscriptHitLocator.row(forSeq: 1, in: []))
    }

    /// 009 场景⑥回归：换窗口拉取的"本地命中"判定必须是精确归属。
    /// `row(forSeq:)` 会把窗口外命中钳到窗口第一行——拿它当归属判定时，
    /// 任何比窗口旧的 seq 都是假命中，跳转拉取整段被跳过（空操作）。
    func testExactMembershipRejectsHitsOutsideTheWindow() {
        var timeline = ChatTimeline()
        timeline.reset(with: [userMessage(seq: 100), userMessage(seq: 200), userMessage(seq: 300)])
        let rows = timeline.items
        XCTAssertEqual(TranscriptHitLocator.row(exactlyForSeq: 250, in: rows)?.seq, 200, "窗口内：归 200 那行")
        XCTAssertEqual(TranscriptHitLocator.row(exactlyForSeq: 100, in: rows)?.seq, 100, "正好第一行")
        XCTAssertEqual(TranscriptHitLocator.row(exactlyForSeq: 300, in: rows)?.seq, 300, "正好最后一行")
        XCTAssertNil(TranscriptHitLocator.row(exactlyForSeq: 99, in: rows), "比窗口旧：不算命中（钳制版会给 100）")
        XCTAssertNil(TranscriptHitLocator.row(exactlyForSeq: 301, in: rows), "比窗口新：不算命中（钳制版会给 300）")
        XCTAssertNil(TranscriptHitLocator.row(exactlyForSeq: 200, in: []))
    }

    /// 边界只认数据行：009 的缺口行（含顶部合成行 `gap:0-0`，seq=0）不是内容。
    /// 拿缺口行当窗口下界，"比窗口旧"的判定会永远成立（假命中复发）。
    func testExactMembershipIgnoresGapRowsAtTheEdges() {
        var timeline = ChatTimeline()
        timeline.reset(with: [userMessage(seq: 100), userMessage(seq: 200)])
        var rows = timeline.items
        rows.insert(ChatTimeline.gapItem(start: 0, end: 0, status: .loading), at: 0)
        rows.append(ChatTimeline.gapItem(start: 201, end: 250, status: .loading))
        XCTAssertNil(TranscriptHitLocator.row(exactlyForSeq: 50, in: rows),
                     "第一行是 gap:0-0 也不能把 seq=50 判成窗口内")
        XCTAssertEqual(TranscriptHitLocator.row(exactlyForSeq: 150, in: rows)?.seq, 100)
    }

    /// 缺口行永远不是"落地"判定（007 用例 49 链路回归）：命中落在缺口里
    ///（数据还没到）返回 nil，梯子/rebase waiter 继续等真行出现；
    /// 旧实现会解析到缺口占位行本身，先把视口滚到加载占位条上。
    func testExactMembershipNeverLandsOnGapRows() {
        var timeline = ChatTimeline()
        timeline.reset(with: [userMessage(seq: 100), userMessage(seq: 200)])
        var rows = timeline.items
        rows.insert(ChatTimeline.gapItem(start: 150, end: 160, status: .loading), at: 1)
        XCTAssertNil(TranscriptHitLocator.row(exactlyForSeq: 155, in: rows),
                     "落在缺口里：数据还没到，不算命中（旧实现给缺口行）")
        XCTAssertNil(TranscriptHitLocator.row(exactlyForSeq: 150, in: rows),
                     "缺口行自己的 seq（gap.start）也不算命中")
        XCTAssertEqual(TranscriptHitLocator.row(exactlyForSeq: 200, in: rows)?.seq, 200,
                       "缺口之外的真行照常解析")
    }

    /// 同一 seq 同时存在缺口行与数据行（撞键）：解析到数据行，不是缺口占位行。
    func testExactMembershipPrefersDataRowOverGapRowAtSameSeq() {
        var timeline = ChatTimeline()
        timeline.reset(with: [userMessage(seq: 100), userMessage(seq: 200)])
        var rows = timeline.items
        rows.append(ChatTimeline.gapItem(start: 200, end: 250, status: .loading)) // seq=200 撞键
        let landed = TranscriptHitLocator.row(exactlyForSeq: 200, in: rows)
        XCTAssertEqual(landed?.seq, 200)
        XCTAssertEqual(landed?.kind.isContentRow, true, "同 seq 撞键归数据行")
    }

    /// 只有缺口行（数据完全没到）：返回 nil。
    func testExactMembershipReturnsNilWhenOnlyGapRowsExist() {
        let rows = [ChatTimeline.gapItem(start: 150, end: 160, status: .loading)]
        XCTAssertNil(TranscriptHitLocator.row(exactlyForSeq: 155, in: rows))
    }

    /// 命中落在缺口里：不填缺口占位行的 id，退到合成身份（点它按 seq 换窗口再跳）。
    func testAttachFallsBackToSyntheticIdWhenHitLandsInAGap() {
        var timeline = ChatTimeline()
        timeline.reset(with: [userMessage(seq: 100), userMessage(seq: 200)])
        var rows = timeline.items
        rows.insert(ChatTimeline.gapItem(start: 150, end: 160, status: .loading), at: 1)
        let hits = [
            HistorySearchHit(seq: 155, role: "me", snippet: "needle", highlightStart: 0, highlightLength: 6),
        ]
        let mapped = TranscriptHitLocator.attach(hits: hits, to: rows)
        XCTAssertEqual(mapped.map(\.id), ["seq-155"])
    }

    func testAttachFillsRowIDsAndDropsHitsWithNoRow() {
        var timeline = ChatTimeline()
        timeline.reset(with: [userMessage(seq: 100), userMessage(seq: 200)])
        let hits = [
            HistorySearchHit(seq: 200, role: "me", snippet: "a needle", highlightStart: 2, highlightLength: 6),
            HistorySearchHit(seq: 150, role: "agent", snippet: "b needle", highlightStart: 2, highlightLength: 6),
        ]
        let mapped = TranscriptHitLocator.attach(hits: hits, to: timeline.items)
        XCTAssertEqual(mapped.count, 2)
        XCTAssertEqual(mapped[0].role, .me)
        XCTAssertEqual(mapped[1].role, .agent)
        XCTAssertEqual(mapped[0].id, timeline.items.last?.id, "200 那一行")
        XCTAssertEqual(mapped[1].seq, 150, "命中自己的 seq 保留（跳转与高亮都用它）")
    }
}
