import DSHDesign
import DSHKit
import Foundation

// MARK: - Scope

/// Which workspace the file browser is looking at.
///
/// `workspaceFiles/*` names its scope `workspaceFileScopeId` on the wire, and the
/// host types that field as a **Session id** (see
/// `@deepseek-ai/dsh-api-workspace-files`: every method takes the Session
/// identity and the host resolves it to a workspace root "without loading its
/// event body or activating an Agent"). The captured
/// `session/canOpenWorkspacePath` sample is unrelated to this: that endpoint
/// takes no arguments and answers whether the *host* can hand a path to its
/// native opener, so it cannot supply the scope.
///
/// For a subagent transcript the row's own `sessionId` is the child's id, and
/// `SessionSummary.address.primarySessionId` returns exactly that value for both
/// plain and subagent rows, so a row's `sessionId` is always the scope.
public struct WorkspaceFileScope: Sendable, Hashable, Identifiable {
    /// Stable identity so the browser can be presented with `sheet(item:)`.
    public var id: String { "\(sessionId)|\(workspaceRoot ?? "")" }

    public let sessionId: String
    /// The session's working directory, when the summary carried one.
    public let workspaceRoot: String?
    /// The host's home directory, for shortening displayed paths.
    public let hostHome: String?

    public init(sessionId: String, workspaceRoot: String? = nil, hostHome: String? = nil) {
        self.sessionId = sessionId
        self.workspaceRoot = workspaceRoot
        self.hostHome = hostHome
    }

    public init(summary: SessionSummary, hostHome: String? = nil) {
        self.sessionId = summary.address.primarySessionId
        self.workspaceRoot = summary.cwd
        self.hostHome = hostHome
    }

    public init(sessionId: String, hostHome: String?) {
        self.sessionId = sessionId
        self.workspaceRoot = nil
        self.hostHome = hostHome
    }

    /// A path relative to the workspace root, for display.
    public func displayPath(_ absolute: String) -> String {
        if let root = workspaceRoot, !root.isEmpty, absolute.hasPrefix(root) {
            let relative = String(absolute.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return relative.isEmpty ? (root as NSString).lastPathComponent : relative
        }
        return PathFormat.short(absolute, home: hostHome)
    }
}

// MARK: - Directory listing

/// `workspaceFiles/list` — one directory's direct children.
public struct WorkspaceDirectoryListing: Sendable {
    /// The listed directory as a workspace path; empty for the root.
    public let path: String
    public let entries: [WorkspaceDirectoryEntry]
    /// Whether the host's entry cap dropped children.
    public let truncated: Bool

    init?(json: JSONValue) {
        guard json.objectValue != nil else { return nil }
        path = json["path"]?.stringValue ?? ""
        truncated = json["truncated"]?.boolValue ?? false
        entries = (json["entries"]?.arrayValue ?? []).compactMap { WorkspaceDirectoryEntry(json: $0) }
    }
}

public struct WorkspaceDirectoryEntry: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable {
        case file
        case directory
        case other
    }

    public let name: String
    public let kind: Kind
    public let size: Int?

    public var id: String { name }

    init?(json: JSONValue) {
        guard let name = json["name"]?.stringValue, !name.isEmpty else { return nil }
        self.name = name
        self.kind = Kind(rawValue: json["type"]?.stringValue ?? "") ?? .other
        self.size = json["size"]?.intValue
    }

    /// A child's path is its parent's joined with the name.
    public func path(in parent: String) -> String {
        parent.isEmpty ? name : "\(parent)/\(name)"
    }

    public var isDirectory: Bool { kind == .directory }
    public var isFile: Bool { kind == .file }

    public var sizeText: String? {
        guard let size else { return nil }
        return ByteFormat.compact(size)
    }
}

// MARK: - File read

/// `workspaceFiles/read` — one page of lines from a UTF-8 file.
public struct WorkspaceFileText: Sendable {
    public let absolutePath: String
    /// Opaque freshness token, echoed back as-is and never parsed.
    public let version: String
    /// The complete file's size, when the backend reports it.
    public let bytes: Int?
    /// 1-based first line of this page.
    public let offset: Int
    public let text: String
    /// How many lines this page holds; `0` past the last line.
    public let lines: Int
    public let eof: Bool

    init(
        absolutePath: String,
        version: String,
        bytes: Int?,
        offset: Int,
        text: String,
        lines: Int,
        eof: Bool
    ) {
        self.absolutePath = absolutePath
        self.version = version
        self.bytes = bytes
        self.offset = offset
        self.text = text
        self.lines = lines
        self.eof = eof
    }

    init?(json: JSONValue) {
        guard json.objectValue != nil else { return nil }
        absolutePath = json["absolutePath"]?.stringValue ?? ""
        version = json["version"]?.stringValue ?? ""
        bytes = json["bytes"]?.intValue
        offset = json["offset"]?.intValue ?? 1
        text = json["text"]?.stringValue ?? ""
        lines = json["lines"]?.intValue ?? 0
        eof = json["eof"]?.boolValue ?? true
    }

    /// The page's lines, as the host defines them: `\n`-separated with no
    /// trailing terminator.
    public var contentLines: [String] {
        if lines == 0 { return [] }
        if text.isEmpty { return [""] }
        return text.components(separatedBy: "\n")
    }

    /// The 1-based line number of the last line on this page.
    public var lastLine: Int { offset + max(0, lines - 1) }
}

// MARK: - Formatting

public enum ByteFormat {
    /// Compact byte sizes for dense rows, matching the desktop client's style.
    public static func compact(_ bytes: Int) -> String {
        switch bytes {
        case ..<(1024): return "\(bytes) B"
        case ..<(1024 * 1024): return String(format: "%.1f KB", Double(bytes) / 1024)
        case ..<(1024 * 1024 * 1024): return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        default: return String(format: "%.1f GB", Double(bytes) / (1024 * 1024 * 1024))
        }
    }
}
