import Foundation
import XCTest

@testable import DSHKit

/// Audits the transcript fold against real journal history.
///
/// The reported symptom was a message that "shows up twice" after sending from
/// the phone. The journal itself turned out to contain each message exactly
/// once, so the question is whether the *fold* can produce two rows from one
/// record — via a queued splice, a plugin injection, or a warm-cache merge.
///
/// This runs the real fold over the developer's own sessions rather than a
/// fixture, so it covers the actual mix of events those conversations contain.
/// Nothing is written and no prompt is sent.
final class LiveDuplicateAuditTests: XCTestCase {

    private struct EndpointFile: Decodable {
        let url: String
        let port: Int?
    }

    private func makeCarrier() throws -> HTTPCarrier {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/desktop-shell/endpoint.json")
        guard let data = try? Data(contentsOf: path) else {
            throw XCTSkip("no DSH endpoint.json")
        }
        let endpoint = try JSONDecoder().decode(EndpointFile.self, from: data)
        guard let components = URLComponents(string: endpoint.url),
              let host = components.host,
              let port = components.port ?? endpoint.port,
              let url = URL(string: "http://\(host):\(port)"),
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value
        else { throw XCTSkip("could not parse the DSH endpoint") }
        return HTTPCarrier(baseURL: url, credential: .launchToken(token), timeout: 30)
    }

    func testFoldingRealHistoryNeverRendersAUserMessageTwice() async throws {
        let carrier = try makeCarrier()
        let client = DSHClient(carrier: carrier)
        defer { Task { await carrier.close() } }

        let sessions = try await client.sessions()
        let candidates = sessions.items
            .filter { !$0.blank && !$0.isSubagent && $0.asOfSeq > 0 }
            .sorted { $0.asOfSeq > $1.asOfSeq }
            .prefix(10)

        var audited = 0
        var totalUserMessages = 0
        var failures: [String] = []

        for session in candidates {
            let page: SessionPage
            do {
                page = try await client.sessionPage(
                    SessionPageRequest(address: session.address, throughSeq: session.asOfSeq, maxMessages: 120)
                )
            } catch {
                continue
            }

            // What the journal says a person wrote, keyed by the request id
            // that ties a queued splice to the durable message it becomes.
            // Counting both forms through one identity is what makes this an
            // exact check rather than a text comparison: a message that
            // legitimately appears twice has two ids, and one message that
            // appears in both forms has one.
            func identity(_ rpcId: String?, fallback: String) -> String {
                rpcId.map { "rpc:\($0)" } ?? fallback
            }

            var expected = Set<String>()
            for record in page.records {
                let event = record.event
                switch event.type {
                case "user/message":
                    let kind = event.data["source"]?["kind"]?.stringValue ?? "user"
                    guard kind == "user" else { continue }
                    expected.insert(identity(event.data["source"]?["rpcId"]?.stringValue,
                                             fallback: "msg:\(event.seq)"))
                case "agent/inbox/spliced":
                    let inserted = event.data["inserted"]?.arrayValue ?? []
                    guard !inserted.isEmpty else { continue }
                    let item = inserted[0]
                    let kind = item["source"]?["kind"]?.stringValue ?? "user"
                    guard kind == "user" else { continue }
                    expected.insert(identity(item["source"]?["rpcId"]?.stringValue,
                                             fallback: "splice:\(event.seq)"))
                default:
                    break
                }
            }

            var timeline = ChatTimeline()
            _ = timeline.reset(with: page.records)

            let userRows = timeline.items.filter { item in
                if case .userMessage = item.kind { return true }
                return false
            }

            audited += 1
            totalUserMessages += expected.count

            if userRows.count != expected.count {
                let renderedTexts = userRows.compactMap { item -> String? in
                    if case .userMessage(let text, _, _, _, _) = item.kind { return text }
                    return nil
                }
                let nonHuman = page.records.compactMap { record -> String? in
                    let event = record.event
                    guard event.type == "user/message" || event.type == "agent/inbox/spliced" else { return nil }
                    let source = event.type == "user/message"
                        ? event.data["source"]
                        : event.data["inserted"]?.arrayValue?.first?["source"]
                    let kind = source?["kind"]?.stringValue ?? "user"
                    guard kind != "user" else { return nil }
                    let blocks = event.data["content"]?.arrayValue
                        ?? event.data["inserted"]?.arrayValue?.first?["content"]?.arrayValue
                        ?? []
                    return blocks.compactMap { $0["text"]?.stringValue }.joined().prefix(30).description
                }
                failures.append(
                    """
                    \(session.sessionId) [\(session.displayTitle)]:
                      human messages in the page = \(expected.count)
                      rendered user rows         = \(userRows.count)
                      rendered: \(renderedTexts.map { String($0.prefix(26)) })
                      non-human records present: \(nonHuman)
                    """
                )
            }
        }

        XCTAssertGreaterThan(audited, 0, "no session history could be read")
        XCTAssertTrue(
            failures.isEmpty,
            "the fold rendered the wrong number of user messages in \(failures.count) session(s):\n"
            + failures.joined(separator: "\n")
        )
        print("DSHAUDIT audited \(audited) sessions, \(totalUserMessages) human messages, 0 duplicates")
    }
}
