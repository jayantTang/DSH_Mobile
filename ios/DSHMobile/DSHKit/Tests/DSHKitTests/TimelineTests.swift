import Foundation
import XCTest

@testable import DSHKit

/// Deterministic tests for the transcript fold.
///
/// Real traffic shaped this type, but these cases pin the behaviour that is
/// easy to break: matching a tool result to its call, superseding a streaming
/// bubble with the committed message, and never losing an unrecognized event.
final class TimelineTests: XCTestCase {

    // MARK: - Fixtures

    private func event(_ json: String) throws -> SessionEvent {
        try JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
    }

    private func userMessage(seq: Int, text: String, id: String = "m1") throws -> SessionEvent {
        try event("""
        {"type":"user/message","seq":\(seq),"time":1789276358732,
         "data":{"content":[{"type":"text","text":"\(text)"}],
                 "source":{"kind":"user","rpcId":"r1"},
                 "role":"user","id":"\(id)"}}
        """)
    }

    private func assistantMessage(seq: Int, turn: Int, step: Int, blocks: String) throws -> SessionEvent {
        try event("""
        {"type":"assistant/message","seq":\(seq),"time":1789276359000,
         "data":{"turn":\(turn),"step":\(step),
                 "message":{"role":"assistant","content":[\(blocks)]}}}
        """)
    }

    private func toolCall(seq: Int, turn: Int, step: Int, callId: String, name: String, arguments: String) throws -> SessionEvent {
        let escaped = arguments.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return try event("""
        {"type":"tool/call","seq":\(seq),"time":1789276359100,
         "data":{"turn":\(turn),"step":\(step),"callId":"\(callId)","name":"\(name)","arguments":"\(escaped)"}}
        """)
    }

    private func toolResult(seq: Int, turn: Int, step: Int, callId: String, text: String, isError: Bool = false) throws -> SessionEvent {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let errorField = isError ? ",\"isError\":true" : ""
        return try event("""
        {"type":"tool/result","seq":\(seq),"time":1789276359200,
         "data":{"turn":\(turn),"step":\(step),
                 "message":{"source":{"kind":"tool","callId":"\(callId)"},
                            "content":[{"type":"tool-result","toolCallId":"\(callId)",
                                        "content":[{"type":"text","text":"\(escaped)"}]\(errorField)}]}}}
        """)
    }

    // MARK: - Tests

    func testUserAndAssistantMessagesProjectIntoRows() throws {
        var timeline = ChatTimeline()
        XCTAssertEqual(timeline.apply(try userMessage(seq: 1, text: "你好")), .appended)
        _ = timeline.apply(try assistantMessage(seq: 2, turn: 1, step: 1, blocks: #"{"type":"text","text":"你好！有什么可以帮你？"}"#))

        XCTAssertEqual(timeline.items.count, 2)
        guard case .userMessage(let text, _, _, _, _) = timeline.items[0].kind else {
            return XCTFail("first row should be the user's message")
        }
        XCTAssertEqual(text, "你好")
        guard case .assistantText(let reply) = timeline.items[1].kind else {
            return XCTFail("second row should be assistant prose")
        }
        XCTAssertEqual(reply, "你好！有什么可以帮你？")
    }

    func testReasoningAndProseBecomeSeparateRows() throws {
        var timeline = ChatTimeline()
        _ = timeline.apply(try assistantMessage(
            seq: 1, turn: 1, step: 1,
            blocks: #"{"type":"reasoning","text":"先看目录结构"},{"type":"text","text":"我来看看。"}"#
        ))

        XCTAssertEqual(timeline.items.count, 2)
        guard case .reasoning(let reasoning) = timeline.items[0].kind else {
            return XCTFail("reasoning should be its own row")
        }
        XCTAssertEqual(reasoning, "先看目录结构")
        guard case .assistantText = timeline.items[1].kind else {
            return XCTFail("prose should follow reasoning")
        }
    }

    func testToolResultAttachesToItsCall() throws {
        var timeline = ChatTimeline()
        _ = timeline.apply(try toolCall(
            seq: 1, turn: 1, step: 1,
            callId: "call_a", name: "bash",
            arguments: #"{"command":"git status"}"#
        ))
        _ = timeline.apply(try toolResult(
            seq: 2, turn: 1, step: 1,
            callId: "call_a", text: "nothing to commit"
        ))

        XCTAssertEqual(timeline.items.count, 1, "the result must not create a second row")
        guard case .toolCall(let invocation) = timeline.items[0].kind else {
            return XCTFail("expected one tool row")
        }
        XCTAssertEqual(invocation.callId, "call_a")
        XCTAssertEqual(invocation.summary, "git status", "the command should be extracted as the summary")
        XCTAssertFalse(invocation.isRunning, "a settled call must not still read as running")
        XCTAssertEqual(invocation.resultText, "nothing to commit")
        XCTAssertFalse(invocation.isError)
    }

    func testToolCallBlockInsideAssistantMessageIsRecognized() throws {
        // The host can carry the call inside the assistant message rather than
        // as a standalone event; both paths must produce the same row.
        var timeline = ChatTimeline()
        _ = timeline.apply(try assistantMessage(
            seq: 1, turn: 1, step: 1,
            blocks: #"{"type":"tool-call","id":"call_b","name":"read","arguments":"{\"path\":\"/tmp/a.txt\"}"}"#
        ))
        _ = timeline.apply(try toolResult(seq: 2, turn: 1, step: 1, callId: "call_b", text: "contents"))

        XCTAssertEqual(timeline.items.count, 1)
        guard case .toolCall(let invocation) = timeline.items[0].kind else {
            return XCTFail("expected a tool row")
        }
        XCTAssertEqual(invocation.name, "read")
        XCTAssertEqual(invocation.summary, "/tmp/a.txt")
        XCTAssertEqual(invocation.resultText, "contents")
    }

    func testFailedToolResultKeepsItsErrorFlag() throws {
        var timeline = ChatTimeline()
        _ = timeline.apply(try toolCall(seq: 1, turn: 1, step: 1, callId: "c", name: "bash", arguments: #"{"command":"false"}"#))
        _ = timeline.apply(try toolResult(seq: 2, turn: 1, step: 1, callId: "c", text: "exit 1", isError: true))

        guard case .toolCall(let invocation) = timeline.items[0].kind else {
            return XCTFail("expected a tool row")
        }
        XCTAssertTrue(invocation.isError)
    }

    func testOrphanToolResultIsSurfacedRatherThanDropped() throws {
        // A trimmed history page can start after the call that produced a
        // result — or the host re-emits a pruned result during compaction — so
        // the output must still be visible. It used to become a `.notice`, which
        // has no cap and no fold: a 703-line file dump filled the phone screen
        // with no way to collapse it (2026-09-24). It is a collapsed tool card
        // now, like every other result.
        var timeline = ChatTimeline()
        _ = timeline.apply(try toolResult(seq: 9, turn: 3, step: 2, callId: "missing", text: "output from a trimmed call"))

        XCTAssertEqual(timeline.items.count, 1)
        guard case .toolCall(let invocation) = timeline.items[0].kind else {
            return XCTFail("an orphaned result should become a tool card, not a notice")
        }
        XCTAssertEqual(invocation.resultText, "output from a trimmed call")
        XCTAssertFalse(invocation.isError)
        XCTAssertFalse(invocation.isRunning, "a result that has arrived is not still running")
        XCTAssertEqual(invocation.name, "工具输出", "without metadata the card says only that this is tool output")
        XCTAssertEqual(timeline.items[0].id, "tool-missing", "keyed by call id so a late call merges instead of duplicating")
    }

    func testOrphanToolResultWithFileMetadataNamesTheFile() throws {
        // `read` results carry the path in `meta`; the wire has no tool name on a
        // result, so this is what the orphan card has to work with.
        var timeline = ChatTimeline()
        _ = timeline.apply(try event("""
        {"type":"tool/result","seq":4,"time":1789276359200,
         "data":{"turn":1,"step":2,
                 "meta":{"path":"/Users/someone/project/ios/Features/Sessions/SessionListView.swift","totalLines":703},
                 "message":{"source":{"kind":"tool","callId":"call_x"},
                            "content":[{"type":"tool-result","toolCallId":"call_x",
                                        "content":[{"type":"text","text":"1: import SwiftUI"}]}]}}}
        """))

        guard case .toolCall(let invocation) = timeline.items[0].kind else {
            return XCTFail("an orphaned file result should become a tool card")
        }
        XCTAssertEqual(invocation.name, "文件内容")
        XCTAssertEqual(invocation.summary, "…/Sessions/SessionListView.swift")
    }

    func testOrphanResultMergesIntoItsCallWhenTheCallArrivesLater() throws {
        // A page loaded after the fact can bring the call the result belonged
        // to; the two must collapse into one card rather than showing the output
        // twice.
        var timeline = ChatTimeline()
        _ = timeline.apply(try toolResult(seq: 9, turn: 3, step: 2, callId: "call_late", text: "the output"))
        _ = timeline.apply(try toolCall(seq: 10, turn: 3, step: 2, callId: "call_late", name: "read", arguments: "{}"))

        XCTAssertEqual(timeline.items.count, 1, "the call and its orphaned result are one row")
        guard case .toolCall(let invocation) = timeline.items[0].kind else {
            return XCTFail("row should still be the tool card")
        }
        XCTAssertEqual(invocation.name, "read")
        XCTAssertEqual(invocation.resultText, "the output", "the result the card already had must survive the merge")
    }

    func testStreamingBubbleIsSupersededByTheCommittedMessage() throws {
        var timeline = ChatTimeline()
        _ = timeline.apply(AssistantStreamFrame.start(attemptId: "a1", revision: 1, turn: 2, step: 3, startedAfterSeq: 10))
        _ = timeline.apply(AssistantStreamFrame.chunk(
            attemptId: "a1", revision: 1, index: 0, time: nil,
            chunk: .textDelta("正在")
        ))
        XCTAssertEqual(timeline.streaming?.text, "正在")

        _ = timeline.apply(AssistantStreamFrame.chunk(
            attemptId: "a1", revision: 1, index: 1, time: nil,
            chunk: .reasoningDelta("思考中")
        ))
        XCTAssertEqual(timeline.streaming?.reasoning, "思考中")

        _ = timeline.apply(AssistantStreamFrame.end(attemptId: "a1", revision: 1, index: 2, committedSeq: 11))
        XCTAssertNil(timeline.streaming, "a settled attempt must leave no provisional bubble")

        _ = timeline.apply(try assistantMessage(seq: 11, turn: 2, step: 3, blocks: #"{"type":"text","text":"正在处理"}"#))
        XCTAssertEqual(timeline.items.count, 1)
        guard case .assistantText(let text) = timeline.items[0].kind else {
            return XCTFail("expected the committed prose")
        }
        XCTAssertEqual(text, "正在处理", "the committed text must be the authoritative one")
    }

    func testResetMarksInterruptedToolsAsFinished() throws {
        var timeline = ChatTimeline()
        let records = [
            SessionRecord(event: try toolCall(seq: 1, turn: 1, step: 1, callId: "c", name: "bash", arguments: #"{"command":"sleep 100"}"#))
        ]
        _ = timeline.reset(with: records)

        guard case .toolCall(let invocation) = timeline.items[0].kind else {
            return XCTFail("expected a tool row")
        }
        XCTAssertFalse(
            invocation.isRunning,
            "history is authoritative: a call with no result was interrupted, not still running"
        )
    }

    func testUnknownEventTypeIsNotRenderedButDoesNotBreakTheFold() throws {
        var timeline = ChatTimeline()
        _ = timeline.apply(try userMessage(seq: 1, text: "hi"))
        _ = timeline.apply(try event(#"{"type":"web/deepseek-search-llm-request","seq":2,"time":3,"data":{"endpoint":"x"}}"#))
        _ = timeline.apply(try event(#"{"type":"assistant/message","seq":3,"time":4,"data":{"turn":1,"step":1,"message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}}"#))

        XCTAssertEqual(timeline.items.count, 2, "an unrecognized event must not become a row of its own")
        guard case .assistantText(let text) = timeline.items[1].kind else {
            return XCTFail("expected the assistant row")
        }
        XCTAssertEqual(text, "ok")
    }

    func testInterruptedTurnIsMarkedAsUnfinished() throws {
        // Abnormal endings get the same divider as normal ones, but it reads as
        // a warning so a cancelled run is never mistaken for a finished one.
        var timeline = ChatTimeline()
        _ = timeline.apply(try userMessage(seq: 1, text: "run it"))
        _ = timeline.apply(try event(#"{"type":"turn/start","seq":2,"time":3,"data":{"turn":1}}"#))
        _ = timeline.apply(try event(#"{"type":"turn/end","seq":3,"time":4,"data":{"turn":1,"reason":{"kind":"cancelled"}}}"#))

        guard case .turnDivider(let turn, let reason, _) = timeline.items.last?.kind else {
            return XCTFail("an interrupted turn should be visible")
        }
        XCTAssertEqual(turn, 1)
        XCTAssertEqual(reason, "cancelled")
        XCTAssertFalse(timeline.isTurnOpen)
    }

    func testCompletedTurnAlwaysLeavesAMarker() throws {
        // This used to assert the opposite. Leaving no trace of a normal
        // completion is what made a finished run indistinguishable from a
        // stalled one on the phone, so the marker is now deliberate.
        var timeline = ChatTimeline()
        _ = timeline.apply(try event(#"{"type":"turn/start","seq":1,"time":1789276358000,"data":{"turn":1}}"#))
        XCTAssertTrue(timeline.isTurnOpen)

        _ = timeline.apply(try event(#"{"type":"turn/end","seq":2,"time":1789276359000,"data":{"turn":1,"reason":{"kind":"completed"}}}"#))
        XCTAssertFalse(timeline.isTurnOpen)

        XCTAssertEqual(timeline.items.count, 1, "exactly one marker, not a row per step")
        guard case .turnDivider(let turn, let reason, _) = timeline.items[0].kind else {
            return XCTFail("expected a completion marker")
        }
        XCTAssertEqual(turn, 1)
        XCTAssertEqual(reason, "completed")
    }

    func testSummariesCoverTheCommonTools() {
        XCTAssertEqual(
            ChatTimeline.summarize(name: "bash", arguments: #"{"command":"ls -la"}"#),
            "ls -la"
        )
        XCTAssertEqual(
            ChatTimeline.summarize(name: "read", arguments: #"{"path":"/a/b.swift"}"#),
            "/a/b.swift"
        )
        XCTAssertEqual(
            ChatTimeline.summarize(name: "web_search", arguments: #"{"query":"swift concurrency"}"#),
            "swift concurrency"
        )
        // An unfamiliar tool must not produce a crash or a blank card.
        XCTAssertEqual(
            ChatTimeline.summarize(name: "brand_new_tool", arguments: #"{"whatever":1}"#),
            ""
        )
        XCTAssertEqual(ChatTimeline.summarize(name: "bash", arguments: "not json"), "")
    }

    func testOptimisticEchoIsReplacedByTheHostsConfirmation() throws {
        // Sending a message inserts a row immediately so the transcript is not
        // empty during the round trip. The host's durable event carries the
        // same requestId, and must replace that row rather than add a second.
        var timeline = ChatTimeline()
        _ = timeline.echoUserPrompt(requestId: "req-42", text: "跑一下测试")
        XCTAssertEqual(timeline.items.count, 1)

        _ = timeline.apply(try event("""
        {"type":"user/message","seq":10,"time":1789276358732,
         "data":{"content":[{"type":"text","text":"跑一下测试"}],
                 "source":{"kind":"user","rpcId":"req-42"},
                 "role":"user","id":"m-1"}}
        """))

        XCTAssertEqual(timeline.items.count, 1, "the confirmation duplicated the echo")
        guard case .userMessage(let text, _, _, _, _) = timeline.items[0].kind else {
            return XCTFail("expected the user row")
        }
        XCTAssertEqual(text, "跑一下测试")
        XCTAssertEqual(timeline.items[0].seq, 10, "the row should now carry the durable sequence")
    }

    func testInboxSpliceRendersAsAQueuedMessage() throws {
        var timeline = ChatTimeline()
        _ = timeline.apply(try event("""
        {"type":"agent/inbox/spliced","seq":5,"time":6,
         "data":{"target":"next-turn","start":0,
                 "inserted":[{"content":[{"type":"text","text":"另外补充一句"}],
                              "source":{"kind":"user","rpcId":"r2"},"role":"user","id":"m9"}]}}
        """))
        guard case .userMessage(let text, _, let isSteering, _, _) = timeline.items[0].kind else {
            return XCTFail("a spliced message should read as a user message")
        }
        XCTAssertEqual(text, "另外补充一句")
        XCTAssertFalse(isSteering, "a next-turn splice is queued, not steering")
    }

    // MARK: - Regressions from on-device use

    func testQueuedSpliceAndDurableMessageCollapseIntoOneRow() throws {
        // The host journals a queued prompt twice: once when it is spliced into
        // the inbox, once when the queue promotes it to a real message. Both
        // carry the same request id, and keying them differently is what made
        // every message sent from the phone appear twice.
        var timeline = ChatTimeline()

        _ = timeline.apply(try event("""
        {"type":"agent/inbox/spliced","seq":3,"time":1789276358000,
         "data":{"target":"next-turn","start":0,
                 "inserted":[{"content":[{"type":"text","text":"你好"}],
                              "source":{"kind":"user","rpcId":"req-77"},
                              "role":"user","id":"m-77"}]}}
        """))
        guard case .userMessage(_, _, _, let pendingFirst, _) = timeline.items[0].kind else {
            return XCTFail("the splice should show immediately as a pending row")
        }
        XCTAssertTrue(pendingFirst, "a spliced message is queued, not yet committed")

        _ = timeline.apply(try event("""
        {"type":"user/message","seq":8,"time":1789276358300,
         "data":{"content":[{"type":"text","text":"你好"}],
                 "source":{"kind":"user","rpcId":"req-77"},
                 "role":"user","id":"m-77"}}
        """))

        XCTAssertEqual(timeline.items.count, 1, "the durable message duplicated the splice")
        guard case .userMessage(let text, _, _, let pendingAfter, _) = timeline.items[0].kind else {
            return XCTFail("expected the user row")
        }
        XCTAssertEqual(text, "你好")
        XCTAssertFalse(pendingAfter, "once committed the row must stop reading as queued")
    }

    func testSpliceRemovalDoesNotRenderAnEmptyRow() throws {
        var timeline = ChatTimeline()
        _ = timeline.apply(try event("""
        {"type":"agent/inbox/spliced","seq":5,"time":1789276359000,
         "data":{"target":"next-turn","start":0,"removedCount":1,"inserted":[]}}
        """))
        XCTAssertTrue(timeline.items.isEmpty, "withdrawing a queued item is not a message")
    }

    func testPluginInjectedContextIsNotRenderedAsAUserMessage() throws {
        // The host journals its own runtime-context injection under the same
        // event type as a human message. Rendering it put a wall of internal
        // text in the transcript as though the user had typed it.
        var timeline = ChatTimeline()
        _ = timeline.apply(try event("""
        {"type":"user/message","seq":9,"time":1789276360000,
         "data":{"content":[{"type":"text","text":"Current runtime context..."}],
                 "source":{"kind":"plugin","plugin":"core","form":"context"},
                 "role":"user","id":"ctx-1"}}
        """))
        XCTAssertTrue(timeline.items.isEmpty, "injected context must never be a chat bubble")

        _ = timeline.apply(try userMessage(seq: 10, text: "真正的问题"))
        XCTAssertEqual(timeline.items.count, 1)
    }

    func testEveryTurnEndProducesAVisibleMarkerWithDuration() throws {
        var timeline = ChatTimeline()
        _ = timeline.apply(try event(#"{"type":"turn/start","seq":1,"time":1789276358000,"data":{"turn":4}}"#))
        XCTAssertTrue(timeline.isTurnOpen)

        // Four seconds later.
        _ = timeline.apply(try event(#"{"type":"turn/end","seq":2,"time":1789276362000,"data":{"turn":4,"reason":{"kind":"completed"}}}"#))

        XCTAssertFalse(timeline.isTurnOpen, "run state must clear when the turn ends")
        guard case .turnDivider(let turn, let reason, let duration) = timeline.items.last?.kind else {
            return XCTFail("a finished turn needs a visible marker")
        }
        XCTAssertEqual(turn, 4)
        XCTAssertEqual(reason, "completed")
        XCTAssertEqual(duration ?? 0, 4, accuracy: 0.001)

        let completion = try XCTUnwrap(timeline.lastCompletion)
        XCTAssertEqual(completion.turn, 4)
        XCTAssertEqual(completion.duration ?? 0, 4, accuracy: 0.001)
    }

    func testCancelledTurnIsMarkedAsAbnormal() throws {
        var timeline = ChatTimeline()
        _ = timeline.apply(try event(#"{"type":"turn/start","seq":1,"time":1789276358000,"data":{"turn":1}}"#))
        _ = timeline.apply(try event(#"{"type":"turn/end","seq":2,"time":1789276360000,"data":{"turn":1,"reason":{"kind":"cancelled"}}}"#))
        guard case .turnDivider(_, let reason, _) = timeline.items.last?.kind else {
            return XCTFail("expected a divider")
        }
        XCTAssertEqual(reason, "cancelled")
        XCTAssertEqual(ChatTimeline.describe(turnEndReason: reason), "本轮已取消")
    }

    func testPluginNotificationSpliceIsNotRenderedAsAUserMessage() throws {
        // The host splices its own notifications through the same channel as a
        // queued user prompt. Rendering them put a second bubble under the
        // user's message, which reads as "my message was sent twice".
        var timeline = ChatTimeline()
        _ = timeline.apply(try event("""
        {"type":"agent/inbox/spliced","seq":48,"time":1789276358000,
         "data":{"target":"next-step","start":0,
                 "inserted":[{"content":[{"type":"text","text":"The approval policy changed"}],
                              "source":{"kind":"plugin","plugin":"core"},
                              "role":"user","id":"note-1"}]}}
        """))
        XCTAssertTrue(
            timeline.items.isEmpty,
            "a plugin notification was rendered as one of the user's messages"
        )

        // A real user prompt through the same channel still renders.
        _ = timeline.apply(try event("""
        {"type":"agent/inbox/spliced","seq":50,"time":1789276359000,
         "data":{"target":"next-turn","start":0,
                 "inserted":[{"content":[{"type":"text","text":"真正的消息"}],
                              "source":{"kind":"user","rpcId":"req-9"},
                              "role":"user","id":"m-9"}]}}
        """))
        XCTAssertEqual(timeline.items.count, 1)
        guard case .userMessage(let text, _, _, _, _) = timeline.items[0].kind else {
            return XCTFail("expected the user's own message")
        }
        XCTAssertEqual(text, "真正的消息")
    }

    func testBackgroundJobNotificationIsNotRendered() throws {
        var timeline = ChatTimeline()
        _ = timeline.apply(try event("""
        {"type":"agent/inbox/spliced","seq":74,"time":1789276358000,
         "data":{"target":"next-step","start":0,
                 "inserted":[{"content":[{"type":"text","text":"background job bash-1 finished"}],
                              "source":{"kind":"plugin"},
                              "role":"user","id":"job-1"}]}}
        """))
        XCTAssertTrue(timeline.items.isEmpty, "a background-job notice became a user bubble")
    }

    func testImageOnlySpliceRendersThePicture() throws {
        // The agent can only get a picture into a conversation by splicing it
        // in; a caption is optional. This used to be dropped twice over — the
        // image list was hardcoded empty and a text-free message was skipped.
        var timeline = ChatTimeline()
        _ = timeline.apply(try event("""
        {"type":"agent/inbox/spliced","seq":9,"time":1789276358000,
         "data":{"target":"next-turn","start":0,
                 "inserted":[{"content":[{"type":"image","attachment":{
                     "attachmentId":"sha256:abc","mediaType":"image/webp",
                     "width":1206,"height":2622,"bytes":93736,"name":"shot.png"}}],
                   "source":{"kind":"user","rpcId":"req-img"},
                   "role":"user","id":"m-img"}]}}
        """))

        XCTAssertEqual(timeline.items.count, 1, "an image-only message was dropped")
        guard case .userMessage(let text, let images, _, _, _) = timeline.items[0].kind else {
            return XCTFail("expected a user message row")
        }
        XCTAssertTrue(text.isEmpty)
        XCTAssertEqual(images.count, 1, "the picture was dropped from the row")
        XCTAssertEqual(images.first?.attachmentId, "sha256:abc")
        XCTAssertEqual(images.first?.width, 1206)
    }

    func testSpliceKeepsBothTextAndImage() throws {
        var timeline = ChatTimeline()
        _ = timeline.apply(try event("""
        {"type":"agent/inbox/spliced","seq":11,"time":1789276358000,
         "data":{"target":"next-turn","start":0,
                 "inserted":[{"content":[
                     {"type":"text","text":"渲染结果"},
                     {"type":"image","attachment":{
                         "attachmentId":"sha256:def","mediaType":"image/png",
                         "width":800,"height":600,"bytes":1234,"name":"r.png"}}],
                   "source":{"kind":"user","rpcId":"req-both"},
                   "role":"user","id":"m-both"}]}}
        """))
        guard case .userMessage(let text, let images, _, _, _) = timeline.items.first?.kind else {
            return XCTFail("expected a user message row")
        }
        XCTAssertEqual(text, "渲染结果")
        XCTAssertEqual(images.map(\.attachmentId), ["sha256:def"])
    }

    func testAgentSentImageIsMarkedByItsName() throws {
        // The agent's pictures arrive as prompts, which the journal attributes
        // to the user. The sender rides on the attachment name, not the caption
        // — a caption is prose every client shows, and two attempts at hiding a
        // marker in it were visible in practice.
        var timeline = ChatTimeline()
        _ = timeline.apply(try event("""
        {"type":"user/message","seq":5,"time":1789276358000,
         "data":{"content":[
             {"type":"text","text":"桌面截图 09-14 21:01"},
             {"type":"image","attachment":{"attachmentId":"sha256:zz","mediaType":"image/webp",
              "width":2560,"height":1440,"bytes":9000,"name":"desktop.png"}}],
           "source":{"kind":"user","rpcId":"agent-9f1c"},
           "id":"m-agent"}}
        """))

        guard case .userMessage(let text, let images, _, _, let isAgentSent) = timeline.items[0].kind else {
            return XCTFail("expected a user message row")
        }
        XCTAssertTrue(isAgentSent, "an image sent by the agent was not recognised")
        XCTAssertEqual(text, "桌面截图 09-14 21:01", "the caption must be untouched")
        XCTAssertEqual(images.first?.name, "desktop.png")
        XCTAssertNil(ChatTimeline.displayName(images[0]).flatMap { $0 == "desktop.png" ? nil : $0 })
    }

    func testAUserImageIsNotMarkedAsTheAgents() throws {
        var timeline = ChatTimeline()
        _ = timeline.apply(try event("""
        {"type":"user/message","seq":6,"time":1789276358000,
         "data":{"content":[
             {"type":"text","text":"看这张"},
             {"type":"image","attachment":{"attachmentId":"sha256:yy","mediaType":"image/png",
              "width":800,"height":600,"bytes":500,"name":"mine.png"}}],
           "source":{"kind":"user","rpcId":"req-me"},"id":"m-me"}}
        """))
        guard case .userMessage(_, let images, _, _, let isAgentSent) = timeline.items[0].kind else {
            return XCTFail("expected a user message row")
        }
        XCTAssertFalse(isAgentSent, "the user's own picture was treated as the agent's")
        XCTAssertEqual(ChatTimeline.displayName(images[0]), "mine.png")
    }

    // MARK: - Re-entry

    /// Re-opening a session folds its tail a second time.
    ///
    /// The reported symptom: a session made on the phone, left back to the
    /// list, and opened again, showed the same reply once more for every visit
    /// — five visits, five copies of one greeting. The journal held it once, so
    /// the fold was minting a fresh row for a record it had already folded.
    func testReopeningASessionDoesNotDuplicateItsReplies() throws {
        let records = [
            SessionRecord(event: try userMessage(seq: 8, text: "你好")),
            SessionRecord(event: try event(#"{"type":"turn/start","seq":9,"time":1789276358800,"data":{"turn":1}}"#)),
            SessionRecord(event: try assistantMessage(
                seq: 17,
                turn: 1,
                step: 1,
                blocks: #"{"type":"reasoning","text":"想一下"},{"type":"text","text":"你好。有什么需要我做的？"}"#
            )),
            SessionRecord(event: try event(#"{"type":"turn/end","seq":19,"time":1789276359000,"data":{"turn":1,"reason":{"kind":"completed"}}}"#))
        ]

        var timeline = ChatTimeline()
        _ = timeline.reset(with: records)
        let firstVisit = timeline.items.count
        XCTAssertEqual(firstVisit, 4, "user, reasoning, prose, divider")

        // Six more visits: each re-applies the tail the cache already holds.
        for _ in 0..<6 {
            _ = timeline.merge(snapshot: records)
        }

        XCTAssertEqual(
            timeline.items.count,
            firstVisit,
            "re-entering a session must not append rows for records it already folded"
        )
        let prose = timeline.items.filter { item in
            if case .assistantText = item.kind { return true }
            return false
        }
        XCTAssertEqual(prose.count, 1, "the one reply the journal holds must render once")
    }

    /// An older page carries its own turn and step numbers, not fresh ones.
    ///
    /// Row ids used to be keyed by turn, step and a running counter, so folding
    /// a page on its own could mint an id the tail already had — and `prepend`
    /// drops rows whose id it already shows. Real history vanished silently.
    /// Keying by the journal sequence is what keeps the two apart.
    func testPrependingAnOlderPageKeepsRowsThatShareATurnAndStep() throws {
        var timeline = ChatTimeline()
        _ = timeline.apply(try assistantMessage(
            seq: 40,
            turn: 1,
            step: 1,
            blocks: #"{"type":"text","text":"较新的回答"}"#
        ))

        _ = timeline.prepend(older: [
            SessionRecord(event: try assistantMessage(
                seq: 12,
                turn: 1,
                step: 1,
                blocks: #"{"type":"text","text":"更早的回答"}"#
            ))
        ])

        XCTAssertEqual(timeline.items.count, 2, "an older page must not be dropped as a duplicate of the tail")
        XCTAssertEqual(timeline.items.first?.seq, 12, "older history belongs above the tail")
    }
}
