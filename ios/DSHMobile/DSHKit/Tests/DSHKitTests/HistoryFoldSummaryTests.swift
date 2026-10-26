import Foundation
import XCTest

@testable import DSHKit

/// 折叠感知下发（能力 `history-fold-summary`）的协议层：
/// 回包带 `folds`、事件流里用一条 `+link/fold` 替代已折的过程行；
/// 时间线把它插成 `processHeader`（`isPrefetched`），不是普通数据行。
final class HistoryFoldSummaryTests: XCTestCase {

    private static let wire = """
    {"records":[
      {"event":{"type":"turn/start","seq":1,"time":1000,"data":{"turn":1}}},
      {"event":{"type":"user/message","seq":2,"time":1001,"data":{"content":[{"type":"text","text":"问"}]}}},
      {"event":{"type":"+link/fold","seq":3,"time":1002,"data":{"turn":1,"startSeq":3,"endSeq":4,"finalSeq":5,"dividerSeq":6,"toolCount":2,"reasoningCount":1,"messageCount":1,"subagentCount":0,"endReason":"done","durationMs":1200,"foldedCount":2}}},
      {"event":{"type":"assistant/message","seq":5,"time":1005,"data":{"turn":1,"content":[{"type":"text","text":"答"}]}}},
      {"event":{"type":"turn/end","seq":6,"time":1006,"data":{"turn":1,"reason":"done"}}}
    ],"startSeq":1,"endSeq":6,"hasMore":true,
    "folds":[{"turn":1,"startSeq":3,"endSeq":4,"finalSeq":5,"dividerSeq":6,"toolCount":2,"reasoningCount":1,"messageCount":1,"subagentCount":0,"endReason":"done","durationMs":1200,"foldedCount":2}]}
    """

    func testWindowDecodesFolds() throws {
        let value = try JSONDecoder().decode(HistoryWindowValue.self, from: Data(Self.wire.utf8))
        XCTAssertEqual(value.folds?.count, 1)
        let fold = try XCTUnwrap(value.folds?.first)
        XCTAssertEqual(fold.startSeq, 3)
        XCTAssertEqual(fold.endSeq, 4)
        XCTAssertEqual(fold.toolCount, 2)
        XCTAssertEqual(fold.dividerSeq, 6)
        XCTAssertEqual(fold.durationMs, 1200)
    }

    func testTimelineInsertsAPrefetchedHeader() throws {
        let value = try JSONDecoder().decode(HistoryWindowValue.self, from: Data(Self.wire.utf8))
        var timeline = ChatTimeline()
        timeline.reset(with: value.records)

        let headers = timeline.items.compactMap { item -> TimelineProcessHeader? in
            if case .processHeader(let header) = item.kind { return header }
            return nil
        }
        XCTAssertEqual(headers.count, 1, "一条摘要只插一行，不再由过程行推导第二行")
        let header = try XCTUnwrap(headers.first)
        XCTAssertTrue(header.isPrefetched)
        XCTAssertEqual(header.turn, 1)
        XCTAssertEqual(header.startSeq, 3)
        XCTAssertEqual(header.endSeq, 4)
        XCTAssertEqual(header.toolCount, 2)
        XCTAssertEqual(header.reasoningCount, 1)
        XCTAssertEqual(header.messageCount, 1)
        XCTAssertEqual(header.endReason, "done")
        XCTAssertEqual(header.duration ?? 0, 1.2, accuracy: 0.001)
        XCTAssertTrue(header.isFoldable, "摘要行可点开；展开要由上层回取详情")
    }

    func testPlainWindowStillHasNoFolds() throws {
        let json = #"{"records":[],"startSeq":1,"endSeq":1,"hasMore":false}"#
        let value = try JSONDecoder().decode(HistoryWindowValue.self, from: Data(json.utf8))
        XCTAssertNil(value.folds)
    }

    func testRequestEncodesFoldOnlyWhenAsked() throws {
        func encode(_ fold: HistoryWindowFold?) throws -> String {
            let request = HistoryWindowRequest(address: .session(sessionId: "s"), before: 10, fold: fold)
            return String(data: try JSONEncoder().encode(request), encoding: .utf8) ?? ""
        }
        XCTAssertFalse(try encode(nil).contains("\"fold\""))
        XCTAssertTrue(try encode(true).contains("\"fold\":true"))
    }

    func testDetailRequestCoversExactlyTheFoldedRangeWithoutFold() throws {
        let summary = try JSONDecoder().decode(HistoryFoldSummary.self, from: Data(
            #"{"turn":1,"startSeq":3,"endSeq":4,"finalSeq":5,"dividerSeq":6,"toolCount":2,"reasoningCount":1,"messageCount":1,"subagentCount":0,"endReason":"done","durationMs":1200,"foldedCount":2}"#.utf8))
        let request = summary.detailRequest(address: .session(sessionId: "s"), encoding: "deflate-raw")
        XCTAssertEqual(request.before, 5, "before 是开区间上界，必须正好盖住 endSeq")
        XCTAssertEqual(request.limit, 2)
        XCTAssertEqual(request.maxBytes, 512 * 1024)
        XCTAssertNil(request.fold, "展开要的是原事件，不能再次折叠")
        XCTAssertEqual(request.encoding, "deflate-raw")
    }

}
