import Foundation
import XCTest

@testable import DSHKit

/// The git payloads are produced by the connector and consumed here, so these
/// tests pin the *decoding*: which fields are optional, what a missing one means,
/// and that the shapes the connector actually sends survive a round trip.
final class GitClientTests: XCTestCase {

    /// Answers each `_link/git*` call with a canned payload, and records what was
    /// asked for.
    private final class Recorder: DSHCarrier, @unchecked Sendable {
        struct Call { let method: String; let args: [String: Any] }

        private let lock = NSLock()
        private(set) var calls: [Call] = []
        var payloads: [String: String] = [:]

        func unary<Args: Encodable & Sendable, Value: Decodable & Sendable>(
            method: String,
            args: Args,
            as valueType: Value.Type
        ) async throws -> Value {
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(args))
            let object = encoded as? [String: Any] ?? [:]
            lock.withLock { calls.append(Call(method: method, args: object)) }
            guard let json = payloads[method] ?? payloads["*"] else {
                throw DSHRPCFailure(code: "git/failed", message: "no payload for \(method)")
            }
            return try JSONDecoder().decode(Value.self, from: Data(json.utf8))
        }

        func stream<Args: Encodable & Sendable>(
            endpoint: String,
            args: Args
        ) async -> AsyncThrowingStream<JSONValue, any Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func eventResult(_ result: JSONValue) async throws {}
        func close() async {}
    }

    private func client(_ recorder: Recorder) -> GitClient {
        GitClient(carrier: recorder)
    }

    func testStatusDecodesTheConnectorShape() async throws {
        let recorder = Recorder()
        recorder.payloads["_link/gitStatus"] = """
        {"root":"/Users/x/demo","insideWorkTree":true,"hasHead":true,
         "branch":{"head":"main","oid":"abc","upstream":"origin/main","ahead":2,"behind":1,"detached":false},
         "files":[
           {"path":"src/app.js","originalPath":null,"index":"M","worktree":".","kind":"modified","staged":true,"unstaged":false,"conflicted":false},
           {"path":"说明 文档.md","originalPath":"旧 名.md","index":"R","worktree":".","kind":"renamed","staged":true,"unstaged":false,"conflicted":false},
           {"path":"新文件.txt","originalPath":null,"index":".","worktree":"?","kind":"untracked","staged":false,"unstaged":true,"conflicted":false}
         ],
         "truncated":false}
        """

        let status = try await client(recorder).status(cwd: "/Users/x/demo")

        XCTAssertEqual(status.root, "/Users/x/demo")
        XCTAssertEqual(status.branch.head, "main")
        XCTAssertEqual(status.branch.ahead, 2)
        XCTAssertEqual(status.branch.behind, 1)
        XCTAssertEqual(status.branch.label, "main")
        XCTAssertEqual(status.files.count, 3)
        XCTAssertEqual(status.files[0].statusLabel, "已修改")
        XCTAssertTrue(status.files[0].staged)
        XCTAssertEqual(status.files[1].kind, .renamed)
        XCTAssertEqual(status.files[1].originalPath, "旧 名.md")
        XCTAssertEqual(status.files[2].kind, .untracked)
        XCTAssertEqual(status.files[2].directory, "")
        XCTAssertEqual(status.files[0].directory, "src", "目录聚合要靠这个")
        XCTAssertEqual(status.files[0].name, "app.js")
    }

    func testStatusSurvivesMissingOptionalFields() async throws {
        let recorder = Recorder()
        // A connector that predates a field, or a super-brief answer: the app
        // must degrade to "no changes", not refuse to open.
        recorder.payloads["_link/gitStatus"] = #"{"root":"/repo"}"#

        let status = try await client(recorder).status(cwd: "/repo")

        XCTAssertEqual(status.files, [])
        XCTAssertTrue(status.hasHead)
        XCTAssertEqual(status.branch.label, "未知分支")
    }

    func testDetachedHeadSaysSo() async throws {
        let recorder = Recorder()
        recorder.payloads["_link/gitStatus"] = """
        {"root":"/repo","hasHead":true,"branch":{"head":null,"detached":true},"files":[]}
        """
        let status = try await client(recorder).status(cwd: "/repo")
        XCTAssertEqual(status.branch.label, "游离 HEAD")
    }

    func testDiffCarriesThePatchAndTheUntrackedFlag() async throws {
        let recorder = Recorder()
        recorder.payloads["_link/gitDiff"] = """
        {"root":"/repo","path":"notes.txt","staged":false,"untracked":true,"binary":false,
         "text":"diff --git a/notes.txt b/notes.txt\\n@@ -0,0 +1 @@\\n+第一行\\n","truncated":false}
        """

        let patch = try await client(recorder).diff(cwd: "/repo", path: "notes.txt")

        XCTAssertFalse(patch.binary)
        XCTAssertTrue(patch.untracked)
        XCTAssertFalse(patch.isEmpty)
        XCTAssertTrue(patch.text.contains("+第一行"))
        // The parser the reader uses has to find a hunk in it.
        XCTAssertFalse(UnifiedDiff.parse(patch.text).isEmpty)
        let call = recorder.calls.first
        XCTAssertEqual(call?.method, "_link/gitDiff")
        XCTAssertEqual(call?.args["path"] as? String, "notes.txt")
        XCTAssertEqual(call?.args["staged"] as? Bool, false)
    }

    func testABinaryPatchIsFlaggedRatherThanShown() async throws {
        let recorder = Recorder()
        recorder.payloads["_link/gitDiff"] = """
        {"path":"logo.png","staged":false,"untracked":false,"binary":true,"text":"","truncated":false}
        """
        let patch = try await client(recorder).diff(cwd: "/repo", path: "logo.png")
        XCTAssertTrue(patch.binary)
        XCTAssertTrue(patch.isEmpty, "二进制没有可显示的文本差异")
    }

    func testLogPageDecodesCommitsAndPaging() async throws {
        let recorder = Recorder()
        recorder.payloads["_link/gitLog"] = """
        {"root":"/repo","hasMore":true,"skip":0,"commits":[
          {"sha":"1111111111111111111111111111111111111111","short":"1111111","author":"张三",
           "date":"2026-09-18T10:00:00+08:00","subject":"第一个提交","refs":["HEAD -> main"]},
          {"sha":"2222222222222222222222222222222222222222","short":"2222222","author":"李四",
           "date":"2026-09-17T10:00:00+08:00","subject":"第二个提交","refs":[]}
        ]}
        """

        let page = try await client(recorder).log(cwd: "/repo", skip: 0, limit: 2)

        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.commits.map(\.subject), ["第一个提交", "第二个提交"])
        XCTAssertEqual(page.commits[0].refs, ["HEAD -> main"])
        let args = recorder.calls.first?.args
        XCTAssertEqual(args?["limit"] as? Int, 2)
        XCTAssertEqual(args?["skip"] as? Int, 0)
    }

    func testCommitDetailDecodesItsFileList() async throws {
        let recorder = Recorder()
        recorder.payloads["_link/gitShow"] = """
        {"root":"/repo","commit":{"sha":"abc","short":"abc1234","author":"张三",
          "date":"2026-09-18T10:00:00+08:00","subject":"改两个文件","refs":[]},
         "files":[{"path":"a.txt","originalPath":null,"additions":3,"deletions":1,"binary":false},
                  {"path":"图片.png","originalPath":null,"additions":null,"deletions":null,"binary":true}]}
        """

        let detail = try await client(recorder).show(cwd: "/repo", sha: "abc1234")

        XCTAssertEqual(detail.commit?.subject, "改两个文件")
        XCTAssertEqual(detail.files.count, 2)
        XCTAssertEqual(detail.files[0].additions, 3)
        XCTAssertTrue(detail.files[1].binary)
        XCTAssertNil(detail.files[1].additions)
    }

    func testAFileAtARevisionDecodesToBytes() async throws {
        let recorder = Recorder()
        let body = "# fixture\n\n一句话。\n"
        recorder.payloads["_link/gitFile"] = """
        {"root":"/repo","rev":"abc1234","path":"README.md","bytes":\(body.utf8.count),
         "data":"\(Data(body.utf8).base64EncodedString())"}
        """

        let file = try await client(recorder).file(cwd: "/repo", rev: "abc1234", path: "README.md")

        XCTAssertEqual(file.rev, "abc1234")
        XCTAssertEqual(file.bytes, body.utf8.count)
        XCTAssertEqual(file.contents.flatMap { String(data: $0, encoding: .utf8) }, body)
    }

    func testRefusalsArriveAsBranchableCodes() async throws {
        for code in ["git/not-a-repo", "git/no-commits", "git/unavailable", "git/too-large"] {
            let recorder = Recorder()
            recorder.payloads["_link/gitStatus"] = nil
            do {
                _ = try await client(recorder).status(cwd: "/repo")
                XCTFail("\(code) 应该抛错")
            } catch let failure as DSHRPCFailure {
                XCTAssertEqual(failure.code, "git/failed")
            }
        }
    }
}
