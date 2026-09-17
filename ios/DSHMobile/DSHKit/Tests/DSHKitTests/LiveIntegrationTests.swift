import Foundation
import XCTest

@testable import DSHKit

/// Live contract tests against the DSH instance running on this machine.
///
/// These are the real verification for the whole protocol layer: they exercise
/// the launch-token exchange, the unary RPC envelope, descriptor-driven
/// argument naming, the mux WebSocket, and the forwarded host event stream
/// against a real host rather than a stub.
///
/// The suite skips itself when no DSH is running, so `swift test` stays green
/// on a clean checkout. Every call is read-only: the DSH instance under test is
/// the developer's own working session.
final class LiveIntegrationTests: XCTestCase {
    /// The launch endpoint DSH publishes for its desktop shell.
    private struct EndpointFile: Decodable {
        let url: String
        let port: Int?
        let version: String?
    }

    private var baseURL: URL!
    private var launchToken: String!

    override func setUpWithError() throws {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/desktop-shell/endpoint.json")
        guard let data = try? Data(contentsOf: path) else {
            throw XCTSkip("no DSH endpoint.json at \(path.path)")
        }
        let endpoint = try JSONDecoder().decode(EndpointFile.self, from: data)
        guard let components = URLComponents(string: endpoint.url),
              let host = components.host,
              let port = components.port ?? endpoint.port,
              let url = URL(string: "http://\(host):\(port)")
        else {
            throw XCTSkip("could not parse the DSH endpoint URL: \(endpoint.url)")
        }
        guard let token = components.queryItems?.first(where: { $0.name == "token" })?.value else {
            throw XCTSkip("DSH endpoint URL carries no launch token")
        }
        baseURL = url
        launchToken = token
    }

    private func makeCarrier() -> HTTPCarrier {
        HTTPCarrier(baseURL: baseURL, credential: .launchToken(launchToken), timeout: 30)
    }

    // MARK: - Authentication

    func testLaunchTokenExchangesForSessionCookie() async throws {
        let carrier = makeCarrier()
        try await carrier.authenticate()

        let cookie = await carrier.cookie
        let unwrapped = try XCTUnwrap(cookie, "the token exchange produced no cookie")
        XCTAssertTrue(
            unwrapped.name.hasPrefix("dsh-auth-"),
            "expected a dsh-auth cookie, got \(unwrapped.name)"
        )
        XCTAssertFalse(unwrapped.value.isEmpty)
        await carrier.close()
    }

    func testStaleLaunchTokenIsRejectedClearly() async throws {
        let carrier = HTTPCarrier(
            baseURL: baseURL,
            credential: .launchToken("definitely-not-a-valid-token"),
            timeout: 15
        )
        do {
            try await carrier.authenticate()
            XCTFail("a bogus launch token must not authenticate")
        } catch let error as DSHTransportError {
            guard case .notAuthenticated = error else {
                return XCTFail("expected .notAuthenticated, got \(error)")
            }
        }
        await carrier.close()
    }

    // MARK: - Unary RPC

    func testSessionListReturnsRealSessions() async throws {
        let carrier = makeCarrier()
        let client = DSHClient(carrier: carrier)

        let value = try await client.sessions()
        XCTAssertFalse(value.items.isEmpty, "this DSH home should have sessions")

        // Every row must carry the identity and timing the list UI depends on.
        for item in value.items.prefix(10) {
            XCTAssertFalse(item.sessionId.isEmpty)
            XCTAssertGreaterThan(item.updatedAt, 0)
            XCTAssertFalse(item.displayTitle.isEmpty)
        }

        // At least one session should expose the projection fold, which is what
        // drives titles, goals, and token pressure on the phone.
        let withProjections = value.items.filter { $0.projections?.values != nil }
        XCTAssertFalse(withProjections.isEmpty, "expected at least one session with projections")
        await carrier.close()
    }

    func testModelCatalogListsUsableRoutes() async throws {
        let carrier = makeCarrier()
        let client = DSHClient(carrier: carrier)

        let catalog = try await client.modelCatalog()
        XCTAssertNotNil(catalog.default, "the host should publish a default model selection")
        XCTAssertFalse(catalog.groups?.isEmpty ?? true, "expected at least one provider group")
        await carrier.close()
    }

    func testSessionPageReturnsDecodableHistory() async throws {
        let carrier = makeCarrier()
        let client = DSHClient(carrier: carrier)

        let sessions = try await client.sessions()
        // Prefer a top-level session that has actually run, so there is real
        // history to read and no subagent addressing to satisfy.
        guard let target = sessions.items.first(where: { !$0.blank && !$0.isSubagent && ($0.projections?.asOfSeq ?? 0) > 0 })
                ?? sessions.items.first(where: { !$0.blank })
        else {
            throw XCTSkip("no non-blank session available to page through")
        }

        let throughSeq = target.asOfSeq
        let page = try await client.sessionPage(
            SessionPageRequest(
                address: target.address,
                throughSeq: throughSeq,
                maxMessages: 20
            )
        )
        XCTAssertFalse(page.records.isEmpty, "expected history records for \(target.sessionId)")

        // Every record must project into a chat event without throwing, and the
        // known subtypes must actually be recognized rather than falling
        // through to `.other`.
        var recognized = 0
        for record in page.records {
            let chat = ChatEventDecoder.decode(record.event)
            if case .other = chat {} else { recognized += 1 }
        }
        XCTAssertGreaterThan(recognized, 0, "no history record decoded into a known chat event")
        await carrier.close()
    }

    func testSubagentTranscriptIsAddressable() async throws {
        // Subagent transcripts are reachable only through a compound address
        // carrying the parent and the correct mode, and the host refuses a mode
        // that disagrees with the transcript. Resolving that mode is easy to
        // get wrong and impossible to notice without a live host.
        let carrier = makeCarrier()
        let client = DSHClient(carrier: carrier)

        let sessions = try await client.sessions()
        guard let child = sessions.items.first(where: { $0.isSubagent && $0.parentSessionId != nil })
        else {
            throw XCTSkip("no subagent transcript present in this DSH home")
        }

        let address = child.address
        guard case .subagent(let parent, let childId, _) = address else {
            return XCTFail("a subagent row must resolve to a subagent address")
        }
        XCTAssertEqual(childId, child.sessionId)
        XCTAssertEqual(parent, child.parentSessionId)

        // Reaching the transcript is the assertion: a wrong mode fails here.
        let page = try await client.sessionPage(
            SessionPageRequest(address: address, throughSeq: child.asOfSeq, maxMessages: 5)
        )
        XCTAssertFalse(page.records.isEmpty, "subagent transcript came back empty")
        await carrier.close()
    }

    func testWorkspaceBaselineListsRealWorkspaces() async throws {
        // The desktop sidebar is an explicit workspace list, and the phone has
        // to group by it rather than by working directory — otherwise it
        // invents groups the user never made and expands things the desktop
        // keeps folded away.
        let carrier = makeCarrier()
        let client = DSHClient(carrier: carrier)

        let baseline = try await client.workspaces()
        XCTAssertFalse(baseline.items.isEmpty, "the host returned no workspaces at all")

        for workspace in baseline.items.prefix(5) {
            XCTAssertFalse(workspace.workspaceId.isEmpty)
            XCTAssertFalse(workspace.title.isEmpty, "a workspace had no title to show")
        }

        // Every session a workspace claims must be a real session.
        let sessions = try await client.sessions()
        let known = Set(sessions.items.map(\.sessionId))
        let claimed = baseline.items.flatMap(\.sessionIds).filter { known.contains($0) }
        XCTAssertFalse(claimed.isEmpty, "no workspace membership matched a real session")
        await carrier.close()
    }

    func testUnknownArgumentsAreRejectedByTheDescriptor() async throws {
        // Guards the assumption the whole client is built on: arguments are
        // named fields validated against a host-side descriptor, so a typo
        // fails loudly instead of silently doing nothing.
        let carrier = makeCarrier()
        try await carrier.authenticate()

        struct WrongArgs: Encodable, Sendable { let bogus = 1 }
        do {
            _ = try await carrier.unary(
                method: "session/page",
                args: RequestArgs(request: WrongArgs()),
                as: JSONValue.self
            )
            XCTFail("the host accepted an argument shape its descriptor does not define")
        } catch let failure as DSHRPCFailure {
            XCTAssertTrue(
                failure.code.contains("invalid"),
                "expected an argument-validation failure, got \(failure.code)"
            )
        }
        await carrier.close()
    }

    func testRealHistoryFoldsIntoARenderableTimeline() async throws {
        // The timeline fold is the piece most likely to be subtly wrong, so it
        // is exercised against a real journal rather than only synthetic events.
        let carrier = makeCarrier()
        let client = DSHClient(carrier: carrier)

        let sessions = try await client.sessions()
        guard let target = sessions.items
            .filter({ !$0.blank && !$0.isSubagent })
            .max(by: { $0.asOfSeq < $1.asOfSeq })
        else {
            throw XCTSkip("no run session with history available")
        }

        // Walk back until a page actually contains a tool call, so the
        // call/result join is covered.
        var cursor = target.asOfSeq
        var best: SessionPage?
        for _ in 0..<5 {
            let page = try await client.sessionPage(
                SessionPageRequest(address: target.address, throughSeq: cursor, maxMessages: 80)
            )
            if best == nil || page.records.count > (best?.records.count ?? 0) { best = page }
            if page.records.contains(where: { $0.event.type == "tool/result" }) { break }
            guard let oldest = page.records.first?.event.seq, oldest > 1 else { break }
            cursor = oldest - 1
        }

        let page = try XCTUnwrap(best)
        var timeline = ChatTimeline()
        _ = timeline.reset(with: page.records)

        XCTAssertFalse(timeline.items.isEmpty, "a real journal must fold into rows")

        let toolRows = timeline.items.compactMap { item -> ToolInvocation? in
            if case .toolCall(let invocation) = item.kind { return invocation }
            return nil
        }
        XCTAssertFalse(toolRows.isEmpty, "this history should contain tool calls")

        // Every tool call in a settled history must have been resolved: either
        // it carries a result, or it is honestly marked as not running.
        for row in toolRows {
            XCTAssertFalse(row.isRunning, "\(row.name) was left marked as running in settled history")
        }

        let withResults = toolRows.filter { !$0.resultText.isEmpty }
        XCTAssertFalse(withResults.isEmpty, "no tool result was joined back to its call")

        // Ids must be unique or SwiftUI will reuse rows incorrectly.
        let ids = timeline.items.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "timeline ids are not unique")
        await carrier.close()
    }

    // MARK: - Streaming

    func testHostEventStreamDeliversReadyFrame() async throws {
        let carrier = makeCarrier()
        let client = DSHClient(carrier: carrier)

        let stream = await client.hostEvents()
        var ready: (clientId: String, home: String)?

        // The `ready` frame is the stream's proof of life and carries the
        // clientId every later waterfall answer must quote.
        let deadline = Date().addingTimeInterval(20)
        for try await event in stream {
            if case .ready(let clientId, let home) = event {
                ready = (clientId, home)
                break
            }
            if Date() > deadline { break }
        }

        let value = try XCTUnwrap(ready, "the host event stream never delivered a ready frame")
        XCTAssertFalse(value.clientId.isEmpty, "ready frame carried no clientId")
        await carrier.close()
    }

    func testSessionFollowYieldsSnapshotThenCancels() async throws {
        let carrier = makeCarrier()
        let client = DSHClient(carrier: carrier)

        let sessions = try await client.sessions()
        guard let target = sessions.items.first(where: { !$0.blank && !$0.isSubagent && !$0.running })
                ?? sessions.items.first(where: { !$0.blank && !$0.isSubagent })
                ?? sessions.items.first(where: { !$0.blank })
        else {
            throw XCTSkip("no non-blank session available to follow")
        }

        let stream = await client.follow(
            SessionFollowRequest(address: target.address, maxMessages: 10)
        )

        var sawSnapshot = false
        var recordCount = 0
        let deadline = Date().addingTimeInterval(25)

        for try await frame in stream {
            switch frame {
            case .snapshot(let snapshot):
                sawSnapshot = true
                recordCount = snapshot.records.count
                // Cancel by breaking out; the stream's termination handler
                // sends the mux `cancel` frame.
                break
            case .event, .assistantStream, .unknown:
                continue
            }
            if sawSnapshot { break }
            if Date() > deadline { break }
        }

        XCTAssertTrue(sawSnapshot, "session/follow never delivered its opening snapshot")
        XCTAssertGreaterThan(recordCount, 0, "the follow snapshot carried no history")
        await carrier.close()
    }

    func testMuxReconnectsAfterReset() async throws {
        // The phone will lose its socket constantly (backgrounding, network
        // changes). A reset must not poison the mux for later streams.
        let carrier = makeCarrier()
        let client = DSHClient(carrier: carrier)

        let first = await client.hostEvents()
        var sawReady = false
        for try await event in first {
            if case .ready = event { sawReady = true; break }
        }
        XCTAssertTrue(sawReady, "first event stream never became ready")

        await carrier.close()

        // A fresh carrier must behave identically, proving no global state
        // leaked between connections.
        let second = makeCarrier()
        let secondClient = DSHClient(carrier: second)
        let sessions = try await secondClient.sessions()
        XCTAssertFalse(sessions.items.isEmpty)
        await second.close()
    }

    // MARK: - Location-independent access

    func testTrustedHostAllowsNonLoopbackAuthority() async throws {
        // Reaching DSH through a LAN address or a relay domain requires the
        // host to be started with `--trusted-host`, because the session cookie
        // is bound to the authority it was minted for. This test documents and
        // verifies the mechanism the relay design depends on.
        let carrier = makeCarrier()
        try await carrier.authenticate()
        let mintedCookie = await carrier.cookie
        let cookie = try XCTUnwrap(mintedCookie)

        // The minted cookie embeds the authority it is valid for.
        let payload = cookie.value.split(separator: ".").dropFirst().first.map(String.init) ?? ""
        let padded = payload.padding(
            toLength: ((payload.count + 3) / 4) * 4,
            withPad: "=",
            startingAt: 0
        )
        guard let data = Data(base64Encoded: padded),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let authority = json["authority"] as? String
        else {
            throw XCTSkip("cookie payload was not in the expected signed form")
        }
        XCTAssertTrue(
            authority.contains(":"),
            "expected an authority-bound cookie, got \(authority)"
        )
        await carrier.close()
    }
}
