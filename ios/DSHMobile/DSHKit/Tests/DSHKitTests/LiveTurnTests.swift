import Foundation
import XCTest

@testable import DSHKit

/// Reproduces the "I sent a message and nothing came back" failure.
///
/// The phone's transcript froze even though the desktop ran the turn to
/// completion. Both transports were verified to deliver the frames, so the
/// fault had to be in decoding or folding them — and a single undecodable frame
/// is enough, because the follow stream is driven by `for try await`: one throw
/// ends the stream and the transcript silently stops updating for good.
///
/// This test therefore drives a real turn through a throwaway session and
/// asserts the whole lifecycle arrives. It is deliberately end-to-end rather
/// than a fixture test: the frame mix the host actually emits is the thing that
/// broke it.
final class LiveTurnTests: XCTestCase {

    private struct EndpointFile: Decodable {
        let url: String
        let port: Int?
    }

    private func makeCarrier() throws -> HTTPCarrier {
        // Opt-in: this test drives a real model turn, which costs tokens and
        // leaves a session behind in the developer's own DSH. It must never run
        // as part of an ordinary `swift test`.
        guard ProcessInfo.processInfo.environment["DSH_LIVE_TURN"] == "1" else {
            throw XCTSkip("set DSH_LIVE_TURN=1 to run the live turn test")
        }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/desktop-shell/endpoint.json")
        guard let data = try? Data(contentsOf: path) else {
            throw XCTSkip("no DSH endpoint.json; skipping live turn test")
        }
        let endpoint = try JSONDecoder().decode(EndpointFile.self, from: data)
        guard let components = URLComponents(string: endpoint.url),
              let host = components.host,
              let port = components.port ?? endpoint.port,
              let url = URL(string: "http://\(host):\(port)"),
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value
        else {
            throw XCTSkip("could not parse the DSH endpoint URL")
        }
        return HTTPCarrier(baseURL: url, credential: .launchToken(token), timeout: 30)
    }

    func testFollowDeliversAWholeTurnTriggeredByOurOwnPrompt() async throws {
        let carrier = try makeCarrier()
        let client = DSHClient(carrier: carrier)

        // A throwaway session, so no existing conversation is disturbed.
        let created = try await client.createSession(
            SessionCreateRequest(cwd: NSTemporaryDirectory(), agentPreset: "standard")
        )
        guard let sessionId = created["sessionId"]?.stringValue ?? created["id"]?.stringValue else {
            return XCTFail("session/create returned no id: \(created.compactDescription)")
        }
        defer { Task { await carrier.close() } }

        let stream = await client.follow(
            SessionFollowRequest(
                address: .session(sessionId: sessionId),
                maxMessages: 5,
                assistantStream: true
            )
        )

        // Collect frames, recording any decode failure verbatim: the failure
        // text is the whole point of this test.
        let collected = FrameLog()
        let consumer = Task {
            do {
                for try await frame in stream {
                    await collected.record(frame)
                }
                await collected.finish(error: nil)
            } catch {
                await collected.finish(error: String(describing: error))
            }
        }

        // Let the snapshot land before prompting, mirroring how the app behaves.
        try await Task.sleep(for: .seconds(1))
        try await client.prompt(
            SessionPromptRequest(
                sessionId: sessionId,
                mode: .queue,
                content: [.text("你好")]
            )
        )

        // The turn is a real model call; give it room but do not hang forever.
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if await collected.sawTurnEnd { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        consumer.cancel()

        let report = await collected.report()
        XCTAssertNil(
            report.error,
            "the follow stream ended with an error after \(report.total) frames — this is exactly the freeze the phone saw: \(report.error ?? "")"
        )
        XCTAssertTrue(report.sawSnapshot, "no opening snapshot")
        XCTAssertTrue(report.sawTurnStart, "the turn never started; frames seen: \(report.summary)")
        XCTAssertTrue(report.sawAssistantMessage, "no committed assistant message; frames seen: \(report.summary)")
        XCTAssertTrue(report.sawTurnEnd, "the turn never ended; frames seen: \(report.summary)")

        // The three defects reported from on-device use, asserted against the
        // real frame mix rather than a fixture.
        let timeline = report.timeline

        // 1. The message must appear once. The host journals a queued prompt
        //    twice (inbox splice, then the promoted message) under one request
        //    id; keying them apart showed every sent message twice.
        let userRows = timeline.items.filter { item in
            if case .userMessage = item.kind { return true }
            return false
        }
        XCTAssertEqual(
            userRows.count, 1,
            "the prompt rendered \(userRows.count) times; rows: \(timeline.items.map(\.id))"
        )

        // 2. Injected context must not become a chat bubble. The host journals
        //    its runtime-context injection as a `user/message` with a plugin
        //    source, which used to show up as a wall of internal text.
        for item in timeline.items {
            if case .userMessage(let text, _, _, _, _) = item.kind {
                XCTAssertFalse(
                    text.hasPrefix("Current runtime context"),
                    "the host's injected context leaked into the transcript"
                )
            }
        }

        // 3. The run must end visibly and clear its state; a stuck stop button
        //    came from never clearing it.
        XCTAssertFalse(timeline.isTurnOpen, "the transcript still reports an open turn after turn/end")
        guard case .turnDivider(_, let reason, let duration) = timeline.items.last?.kind else {
            return XCTFail("the turn left no visible completion marker; rows: \(timeline.items.map(\.id))")
        }
        XCTAssertEqual(reason, "completed")
        XCTAssertNotNil(duration, "the completion marker should carry the turn's duration")
        XCTAssertNotNil(timeline.lastCompletion, "no completion was recorded for the done indicator")
    }
}

/// Collects frames across the consumer task and the test body.
private actor FrameLog {
    private(set) var sawSnapshot = false
    private(set) var sawTurnStart = false
    private(set) var sawAssistantMessage = false
    private(set) var sawTurnEnd = false
    private(set) var total = 0
    private(set) var error: String?
    private var counts: [String: Int] = [:]
    /// The same frames folded the way the app folds them.
    private(set) var timeline = ChatTimeline()

    func record(_ frame: SessionFollowFrame) {
        total += 1
        switch frame {
        case .snapshot(let snapshot):
            sawSnapshot = true
            counts["snapshot", default: 0] += 1
            _ = timeline.reset(with: snapshot.records)
        case .event(let event):
            counts["event/\(event.type)", default: 0] += 1
            _ = timeline.apply(event)
            switch event.type {
            case "turn/start": sawTurnStart = true
            case "turn/end": sawTurnEnd = true
            case "assistant/message": sawAssistantMessage = true
            default: break
            }
        case .assistantStream(let assistantFrame):
            switch assistantFrame {
            case .start: counts["assistant-stream/start", default: 0] += 1
            case .chunk: counts["assistant-stream/chunk", default: 0] += 1
            case .end: counts["assistant-stream/end", default: 0] += 1
            case .unknown(let type, _): counts["assistant-stream?\(type)", default: 0] += 1
            }
        case .unknown(let type, _):
            counts["unknown/\(type)", default: 0] += 1
        }
    }

    func finish(error: String?) {
        if self.error == nil { self.error = error }
    }

    var summary: [String: Int] { counts }

    func report() -> (error: String?, total: Int, sawSnapshot: Bool, sawTurnStart: Bool, sawAssistantMessage: Bool, sawTurnEnd: Bool, summary: [String: Int], timeline: ChatTimeline) {
        (error, total, sawSnapshot, sawTurnStart, sawAssistantMessage, sawTurnEnd, counts, timeline)
    }
}
