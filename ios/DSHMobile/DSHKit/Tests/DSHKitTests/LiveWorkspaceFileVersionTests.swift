import Foundation
import XCTest

@testable import DSHKit

/// Does `workspaceFiles/stat`'s `version` actually change when a file's content
/// changes?
///
/// This is the one assumption P-13's `ETag` rests on. The plan is to derive
/// `ETag: "dsh-<version>-<size>"` from a stat and have the resuming client send
/// `If-Range` with it, so a file that changed under an interrupted download is
/// re-fetched from the start instead of being spliced together from two
/// different contents. If `version` did **not** move when content did, that
/// check would compare a token against itself forever, the relay would always
/// answer `206`, and the splice would be silent — a corrupt file that looks
/// downloaded.
///
/// The architect flagged this as an unchecked assumption
/// (`arch-review-batch2.md` §6-2: "我假设「内容变 → version 变」，但没有逐行核对
/// Host 侧实现"). This turns the assumption into a measurement: it mutates a
/// scratch file and watches the token.
///
/// **Skips when no DSH is running**, like the rest of the live suite, so a
/// clean checkout stays green. The file it writes is its own scratch file under
/// the temporary directory — not a repository or session file.
final class LiveWorkspaceFileVersionTests: XCTestCase {
    private struct EndpointFile: Decodable {
        let url: String
        let port: Int?
    }

    private var client: DSHClient!

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
              let base = URL(string: "http://\(host):\(port)"),
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value
        else {
            throw XCTSkip("could not parse the DSH endpoint URL")
        }
        client = DSHClient(carrier: HTTPCarrier(
            baseURL: base, credential: .launchToken(token), timeout: 30
        ))
    }

    /// The measurement the plan depends on: content change → version change,
    /// no change → same version.
    ///
    /// Both halves matter and they pull in opposite directions. A version that
    /// never moves breaks the `If-Range` safety check; a version that moves on
    /// every *read* would throw away resume data that was perfectly valid. The
    /// second assertion is what keeps the token from being a nonce.
    func testVersionMovesWithContentAndHoldsOtherwise() async throws {
        // The scope is a **session**, not a path: `workspaceFileScope` resolves a
        // session identity to its workspace root (`gateway/lookup-not-found`
        // otherwise — found the hard way). The file therefore lives in a scratch
        // directory *inside this repository*, which is the workspace the session
        // has.
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DSHKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // DSHKit
            .deletingLastPathComponent()   // DSHMobile
            .deletingLastPathComponent()   // ios
            .deletingLastPathComponent()   // repository root
        let scratch = repository.appendingPathComponent(".version-pin-scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let file = scratch.appendingPathComponent("content.bin")
        try Data("first".utf8).write(to: file)

        // The scope is a session id the suite cannot invent, so this one skips
        // rather than fails without it — the same bargain the rest of the live
        // suite makes when no DSH is running. CI and `swift test` therefore stay
        // green; the reading is taken by supplying a live session.
        guard let scope = ProcessInfo.processInfo.environment["DSH_VERSION_PIN_SCOPE"],
              !scope.isEmpty
        else {
            throw XCTSkip("set DSH_VERSION_PIN_SCOPE to a live session id to take this reading")
        }
        let path = file.path

        let first = try await client.workspaceFileStat(scopeId: scope, path: path)
        let firstVersion = try XCTUnwrap(first["version"]?.stringValue, "stat returned no version")
        XCTAssertFalse(firstVersion.isEmpty, "the version token is empty")

        // Same bytes, read twice: the token must be stable, or nothing can ever
        // be resumed.
        let repeatStat = try await client.workspaceFileStat(scopeId: scope, path: path)
        XCTAssertEqual(
            repeatStat["version"]?.stringValue, firstVersion,
            "the version moved between two stats of an untouched file"
        )

        // Content changes. This is the assertion the ETag plan rests on.
        //
        // `write(to:)` replaces the file, which changes both size and mtime — the
        // same way a rebuild or a re-export of the user's file does. A file
        // rewritten with *identical* content is allowed to keep its version (the
        // token is built from identity/freshness, not from a content hash), and
        // that is fine: identical bytes need no invalidation.
        try Data("second content, longer".utf8).write(to: file)

        let afterChange = try await client.workspaceFileStat(scopeId: scope, path: path)
        let changedVersion = try XCTUnwrap(afterChange["version"]?.stringValue)
        XCTAssertNotEqual(
            changedVersion, firstVersion,
            "content changed but the version did not — an If-Range check on this token would never fire"
        )
        // Printed so the reading is auditable, not just asserted: the shape of the
        // token is what tells a reader it carries freshness.
        print("VERSION-PIN first=\(firstVersion) after=\(changedVersion)")

        // And a file that is gone must not answer with the old version: that is
        // the case where a resume would otherwise continue into a file that no
        // longer exists.
        try FileManager.default.removeItem(at: file)
        do {
            _ = try await client.workspaceFileStat(scopeId: scope, path: path)
            XCTFail("stat of a deleted file answered instead of failing")
        } catch {
            // Expected: `workspace-file/not-found`.
        }
    }
}
