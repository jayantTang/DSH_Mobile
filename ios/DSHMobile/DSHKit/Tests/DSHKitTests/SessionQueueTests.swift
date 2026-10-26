import Foundation
import XCTest

@testable import DSHKit

/// 排队输入：`session/control` 的帧解码与 `session/updateQueue` 的请求编码。
final class SessionQueueTests: XCTestCase {

    private func value(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    private static let item = #"""
    {"id":"m-1","placement":"queued","rpcId":"r-1",
     "message":{"id":"m-1","content":[
       {"type":"text","text":"第二条：排队测试"},
       {"type":"image","attachment":{"attachmentId":"att-1","mediaType":"image/png"}}]}}
    """#

    func test_a_queue_frame_decodes_items_and_content() throws {
        let frame = SessionControlFrame.decode(try value("""
        {"type":"queue","sessionId":"s-1","items":[\(Self.item)]}
        """))
        guard case .queue(let sessionId, let items) = try XCTUnwrap(frame) else {
            return XCTFail("expected a queue frame")
        }
        XCTAssertEqual(sessionId, "s-1")
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.id, "m-1")
        XCTAssertEqual(item.placement, .queued)
        XCTAssertEqual(item.rpcId, "r-1")
        XCTAssertEqual(item.text, "第二条：排队测试")
        XCTAssertEqual(item.images.first?.attachmentId, "att-1")
    }

    func test_a_baseline_carries_one_queue_per_session() throws {
        let frame = SessionControlFrame.decode(try value("""
        {"type":"baseline","value":{"queues":{
          "s-1":[\(Self.item)],
          "s-2":[{"id":"m-2","placement":"steering","message":{"content":[
            {"type":"text","text":"插一句"}]}}]}}}
        """))
        guard case .baseline(let queues, _, _) = try XCTUnwrap(frame) else {
            return XCTFail("expected a baseline")
        }
        XCTAssertEqual(queues["s-1"]?.count, 1)
        XCTAssertEqual(queues["s-2"]?.first?.placement, .steering)
        XCTAssertEqual(queues["s-2"]?.first?.text, "插一句")
    }

    func test_the_inbox_projection_is_the_queue_source_the_host_sends() throws {
        let frame = SessionControlFrame.decode(try value("""
        {"type":"projection","sessionId":"s-1","key":"inbox","seq":24,
         "value":{"next-turn":[{"id":"m-9","content":[{"type":"text","text":"队列样本"}],
           "source":{"kind":"user","rpcId":"r-9"}}],"next-step":[]}}
        """))
        guard case .projection(let sessionId, let key, let payload) = try XCTUnwrap(frame) else {
            return XCTFail("expected a projection")
        }
        XCTAssertEqual(sessionId, "s-1")
        XCTAssertEqual(key, "inbox")
        let items = SessionControlFrame.inboxItems(payload)
        XCTAssertEqual(items.map(\.id), ["m-9"])
        XCTAssertEqual(items.first?.rpcId, "r-9")
        XCTAssertEqual(items.first?.text, "队列样本")
    }

    func test_a_baseline_parses_inboxes_from_projections() throws {
        let frame = SessionControlFrame.decode(try value("""
        {"type":"baseline","value":{"projections":{
          "s-1":{"asOfSeq":24,"values":{"inbox":{"next-turn":[
            {"id":"m-9","content":[{"type":"text","text":"基线队列"}],
             "source":{"kind":"user","rpcId":"r-9"}}]}}}}}}
        """))
        guard case .baseline(_, let inboxes, _) = try XCTUnwrap(frame) else {
            return XCTFail("expected a baseline")
        }
        XCTAssertEqual(inboxes["s-1"]?.first?.text, "基线队列")
    }

    func test_other_control_frames_are_ignored() throws {
        let frame = SessionControlFrame.decode(try value(#"{"type":"jobs","sessionId":"s-1","jobs":[]}"#))
        guard case .other(let type) = try XCTUnwrap(frame) else {
            return XCTFail("expected an ignored frame")
        }
        XCTAssertEqual(type, "jobs")
    }

    func test_projection_merge_only_changes_the_named_key() throws {
        let merged = SessionProjectionValues.empty
            .merging(key: "title", value: .string("新标题"))
            .merging(key: "tokenUsage", value: try value(#"{"uncachedInputTokens":10,"outputTokens":5}"#))
        XCTAssertEqual(merged.title, "新标题")
        XCTAssertEqual(merged.tokenUsage?.totalTokens, 15)
        XCTAssertNil(merged.contextPressure)
    }

    func test_a_baseline_decodes_projection_values() throws {
        let frame = SessionControlFrame.decode(try value("""
        {"type":"baseline","value":{"projections":{
          "s-1":{"asOfSeq":7,"values":{"title":"标题","tokenUsage":{"uncachedInputTokens":3,"outputTokens":4}}}}}}
        """))
        guard case .baseline(_, _, let projections) = try XCTUnwrap(frame) else {
            return XCTFail("expected a baseline")
        }
        XCTAssertEqual(projections["s-1"]?.title, "标题")
        XCTAssertEqual(projections["s-1"]?.tokenUsage?.totalTokens, 7)
    }

    private func encoded(_ action: QueueAction) throws -> [String: JSONValue] {
        let data = try JSONEncoder().encode(action)
        let object = try JSONDecoder().decode(JSONValue.self, from: data).objectValue
        return try XCTUnwrap(object)
    }

    func test_queue_actions_encode_the_wire_shape() throws {
        XCTAssertEqual(try encoded(.remove)["kind"]?.stringValue, "remove")
        XCTAssertEqual(try encoded(.steer)["kind"]?.stringValue, "steer")
        let edit = try encoded(.edit(text: "改过的正文"))
        XCTAssertEqual(edit["kind"]?.stringValue, "edit")
        let content = try XCTUnwrap(edit["content"]?.arrayValue)
        XCTAssertEqual(content.first?["type"]?.stringValue, "text")
        XCTAssertEqual(content.first?["text"]?.stringValue, "改过的正文")
    }

    func test_the_update_queue_request_contains_session_item_and_action() throws {
        let request = SessionUpdateQueueRequest(sessionId: "s-1", itemId: "m-1",
                                                action: .steer)
        let data = try JSONEncoder().encode(request)
        let object = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(object["sessionId"]?.stringValue, "s-1")
        XCTAssertEqual(object["itemId"]?.stringValue, "m-1")
        XCTAssertEqual(object["action"]?["kind"]?.stringValue, "steer")
    }
}
