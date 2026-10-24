import DSHConnectionAPI
import DSHFilesDomain
import DSHKit
import DSHTestingSupport
import Foundation

/// 027 — what the DSHFilesDomain cases share: the scope a browser is opened for,
/// a fake link whose `DSHClient` is a `FakeCarrier`, and the payload shapes the
/// host and the connector actually answer with.
///
/// The payloads are written as JSON on purpose. `WorkspaceDirectoryListing`,
/// `WorkspaceDirectoryEntry` and `WorkspaceFileText` only have internal
/// initialisers, so a case in another module reaches them exactly the way the
/// app does — through the wire — instead of through a fixture initialiser that
/// no product path uses.
///
/// Assertion messages stay ASCII: `check:i18n` scans this whole tree, and a CJK
/// literal that is not a key in `Localizable.strings` is reported as a hardcoded
/// string. The CJK strings that do appear here are copies of existing keys.
enum FilesSeam {
    static let sessionId = "s-1"
    static let workRoot = "/Users/tester/work"
    static let hostHome = "/Users/tester"

    static func scope(
        sessionId: String = sessionId,
        root: String? = workRoot,
        home: String? = hostHome
    ) -> WorkspaceFileScope {
        WorkspaceFileScope(sessionId: sessionId, workspaceRoot: root, hostHome: home)
    }

    /// A link that looks connected and whose client is `carrier`.
    ///
    /// `FakeLinkService` is main-actor isolated, so this one is too; everything
    /// else here is a pure value or a payload.
    @MainActor
    static func link(_ carrier: FakeCarrier, capabilities: Set<String> = []) -> FakeLinkService {
        let fake = FakeLinkService(state: .connected(hostHome: hostHome), capabilities: capabilities)
        fake.clientOverride = HostClientFactory.make(carrier: carrier)
        return fake
    }

    // MARK: - Wire payloads

    /// `workspaceFiles/list`.
    static func listing(path: String, entries: [JSONValue], truncated: Bool = false) -> JSONValue {
        .object([
            "path": .string(path),
            "truncated": .bool(truncated),
            "entries": .array(entries),
        ])
    }

    static func entry(_ name: String, type: String, size: Int? = nil, mtimeMs: Int? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["name": .string(name), "type": .string(type)]
        if let size { fields["size"] = .int(size) }
        if let mtimeMs { fields["mtimeMs"] = .int(mtimeMs) }
        return .object(fields)
    }

    /// One `workspaceFiles/read` page.
    static func page(
        absolutePath: String,
        offset: Int,
        text: String,
        lines: Int,
        eof: Bool,
        version: String = "v1",
        bytes: Int? = nil
    ) -> JSONValue {
        var fields: [String: JSONValue] = [
            "absolutePath": .string(absolutePath),
            "version": .string(version),
            "offset": .int(offset),
            "text": .string(text),
            "lines": .int(lines),
            "eof": .bool(eof),
        ]
        if let bytes { fields["bytes"] = .int(bytes) }
        return .object(fields)
    }

    /// `_link/gitStatus`.
    static func gitStatus(
        root: String,
        branch: String = "main",
        files: [JSONValue] = [],
        truncated: Bool = false
    ) -> JSONValue {
        .object([
            "root": .string(root),
            "hasHead": .bool(true),
            "branch": .object([
                "head": .string(branch),
                "ahead": .int(0),
                "behind": .int(0),
                "detached": .bool(false),
            ]),
            "files": .array(files),
            "truncated": .bool(truncated),
        ])
    }

    static func change(_ path: String, kind: String = "modified", staged: Bool = false) -> JSONValue {
        .object([
            "path": .string(path),
            "kind": .string(kind),
            "staged": .bool(staged),
            "unstaged": .bool(true),
        ])
    }

    /// `_link/gitLog`.
    static func gitLog(
        commits: [JSONValue],
        hasMore: Bool,
        skip: Int,
        root: String = workRoot
    ) -> JSONValue {
        .object([
            "root": .string(root),
            "commits": .array(commits),
            "hasMore": .bool(hasMore),
            "skip": .int(skip),
        ])
    }

    static func commit(_ sha: String, subject: String = "a change") -> JSONValue {
        .object([
            "sha": .string(sha),
            "short": .string(String(sha.prefix(7))),
            "author": .string("tester"),
            "date": .string("2026-01-01"),
            "subject": .string(subject),
        ])
    }

    /// A session-list row, decoded the way the app receives it.
    static func summary(
        sessionId: String,
        cwd: String? = workRoot,
        parentSessionId: String? = nil,
        origin: String? = nil
    ) throws -> SessionSummary {
        var fields: [String: JSONValue] = [
            "sessionId": .string(sessionId),
            "updatedAt": .int(0),
            "running": .bool(false),
            "blank": .bool(false),
        ]
        if let cwd { fields["cwd"] = .string(cwd) }
        if let parentSessionId { fields["parentSessionId"] = .string(parentSessionId) }
        if let origin { fields["origin"] = .string(origin) }
        return try JSONValue.object(fields).decoded(as: SessionSummary.self)
    }
}
