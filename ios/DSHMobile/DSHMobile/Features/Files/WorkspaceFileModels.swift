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
struct WorkspaceFileScope: Sendable, Hashable, Identifiable {
    /// Stable identity so the browser can be presented with `sheet(item:)`.
    var id: String { "\(sessionId)|\(workspaceRoot ?? "")" }

    let sessionId: String
    /// The session's working directory, when the summary carried one.
    let workspaceRoot: String?
    /// The host's home directory, for shortening displayed paths.
    let hostHome: String?

    init(sessionId: String, workspaceRoot: String? = nil, hostHome: String? = nil) {
        self.sessionId = sessionId
        self.workspaceRoot = workspaceRoot
        self.hostHome = hostHome
    }

    init(summary: SessionSummary, hostHome: String? = nil) {
        self.sessionId = summary.address.primarySessionId
        self.workspaceRoot = summary.cwd
        self.hostHome = hostHome
    }

    init(sessionId: String, hostHome: String?) {
        self.sessionId = sessionId
        self.workspaceRoot = nil
        self.hostHome = hostHome
    }

    /// A path relative to the workspace root, for display.
    func displayPath(_ absolute: String) -> String {
        if let root = workspaceRoot, !root.isEmpty, absolute.hasPrefix(root) {
            let relative = String(absolute.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return relative.isEmpty ? (root as NSString).lastPathComponent : relative
        }
        return PathFormat.short(absolute, home: hostHome)
    }
}

// MARK: - Directory listing

/// `workspaceFiles/list` — one directory's direct children.
struct WorkspaceDirectoryListing: Sendable {
    /// The listed directory as a workspace path; empty for the root.
    let path: String
    let entries: [WorkspaceDirectoryEntry]
    /// Whether the host's entry cap dropped children.
    let truncated: Bool

    init?(json: JSONValue) {
        guard json.objectValue != nil else { return nil }
        path = json["path"]?.stringValue ?? ""
        truncated = json["truncated"]?.boolValue ?? false
        entries = (json["entries"]?.arrayValue ?? []).compactMap { WorkspaceDirectoryEntry(json: $0) }
    }
}

struct WorkspaceDirectoryEntry: Sendable, Hashable, Identifiable {
    enum Kind: String, Sendable {
        case file
        case directory
        case other
    }

    let name: String
    let kind: Kind
    let size: Int?

    var id: String { name }

    init?(json: JSONValue) {
        guard let name = json["name"]?.stringValue, !name.isEmpty else { return nil }
        self.name = name
        self.kind = Kind(rawValue: json["type"]?.stringValue ?? "") ?? .other
        self.size = json["size"]?.intValue
    }

    /// A child's path is its parent's joined with the name.
    func path(in parent: String) -> String {
        parent.isEmpty ? name : "\(parent)/\(name)"
    }

    var isDirectory: Bool { kind == .directory }
    var isFile: Bool { kind == .file }

    var sizeText: String? {
        guard let size else { return nil }
        return ByteFormat.compact(size)
    }
}

// MARK: - File read

/// `workspaceFiles/read` — one page of lines from a UTF-8 file.
struct WorkspaceFileText: Sendable {
    let absolutePath: String
    /// Opaque freshness token, echoed back as-is and never parsed.
    let version: String
    /// The complete file's size, when the backend reports it.
    let bytes: Int?
    /// 1-based first line of this page.
    let offset: Int
    let text: String
    /// How many lines this page holds; `0` past the last line.
    let lines: Int
    let eof: Bool

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
    var contentLines: [String] {
        if lines == 0 { return [] }
        if text.isEmpty { return [""] }
        return text.components(separatedBy: "\n")
    }

    /// The 1-based line number of the last line on this page.
    var lastLine: Int { offset + max(0, lines - 1) }
}

// MARK: - Change set

/// One observation from `workspaceFiles/changes`.
///
/// The host reports observations, not deltas: a present file carries its
/// freshness token, an absent one says the file was observed gone. There is no
/// baseline content on the wire, which is why this screen shows the observed set
/// and renders a textual diff only when a deployment also sends patch text.
struct WorkspaceChange: Sendable, Hashable, Identifiable {
    let absolutePath: String
    let version: String?
    let absent: Bool

    var id: String { absolutePath }

    var statusLabel: String { absent ? "已删除" : "已变更" }

    init(absolutePath: String, version: String?, absent: Bool) {
        self.absolutePath = absolutePath
        self.version = version
        self.absent = absent
    }

    init?(change json: JSONValue) {
        guard let path = json["absolutePath"]?.stringValue, !path.isEmpty else { return nil }
        self.absolutePath = path
        self.version = json["version"]?.stringValue
        self.absent = json["absent"]?.boolValue ?? false
    }
}

/// One frame of the change feed.
enum WorkspaceChangeFrame: Sendable {
    case ready
    case change(WorkspaceChange)
    /// A frame this build does not model; ignored rather than fatal.
    case other

    init(json: JSONValue) {
        switch json["kind"]?.stringValue {
        case "ready":
            self = .ready
        case "change":
            if let change = json["change"].flatMap(WorkspaceChange.init(change:)) {
                self = .change(change)
            } else {
                self = .other
            }
        default:
            self = .other
        }
    }
}

/// A host-provided change set with textual patches, when a deployment sends one.
///
/// Nothing in the captured samples carries this shape — `workspaceFiles/changes`
/// is an observation feed — but a richer or future answer is parsed rather than
/// dropped, so the diff renderer has a real input whenever one exists.
struct WorkspaceChangeSet: Sendable {
    struct Entry: Sendable, Identifiable, Hashable {
        let path: String
        let status: String?
        let patch: String?
        let additions: Int?
        let deletions: Int?

        var id: String { path }

        var statusLabel: String {
            switch status?.lowercased() {
            case "added", "add", "new", "created": return "已新增"
            case "deleted", "remove", "removed": return "已删除"
            case "modified", "modify", "changed", "updated": return "已修改"
            case "renamed", "rename": return "已重命名"
            default: return status ?? "已修改"
            }
        }
    }

    var entries: [Entry] = []

    init() {}

    init?(json: JSONValue) {
        let files = json["files"]?.arrayValue ?? json["entries"]?.arrayValue ?? json["changes"]?.arrayValue
        guard let files else { return nil }
        entries = files.compactMap { entry in
            let path = entry["path"]?.stringValue
                ?? entry["absolutePath"]?.stringValue
                ?? entry["file"]?.stringValue
            guard let path, !path.isEmpty else { return nil }
            let patch = entry["patch"]?.stringValue
                ?? entry["diff"]?.stringValue
                ?? entry["unifiedDiff"]?.stringValue
            return Entry(
                path: path,
                status: entry["status"]?.stringValue ?? entry["kind"]?.stringValue,
                patch: patch,
                additions: entry["additions"]?.intValue ?? entry["added"]?.intValue,
                deletions: entry["deletions"]?.intValue ?? entry["removed"]?.intValue
            )
        }
    }

    /// Every unified diff the host included, parsed for rendering.
    var diffs: [UnifiedDiff] {
        entries.compactMap(\.patch).compactMap { text in
            let parsed = UnifiedDiff.parse(text)
            return parsed.isEmpty ? nil : parsed
        }
    }
}

// MARK: - Unified diff

/// A parsed unified diff (`diff --git` / `---` / `+++` / `@@`).
///
/// Parsing is deliberately forgiving: a patch with no `diff --git` header still
/// renders, and a line the grammar does not recognize becomes context rather
/// than being dropped.
struct UnifiedDiff: Sendable {
    struct Line: Sendable, Hashable {
        enum Kind: Sendable, Hashable {
            case context
            case added
            case removed
            case meta
        }

        let kind: Kind
        let text: String
        let oldNumber: Int?
        let newNumber: Int?

        var marker: String {
            switch kind {
            case .context: return " "
            case .added: return "+"
            case .removed: return "-"
            case .meta: return "\\"
            }
        }
    }

    struct Hunk: Sendable, Identifiable {
        let index: Int
        let header: String
        let oldStart: Int
        let newStart: Int
        let lines: [Line]

        var id: Int { index }
    }

    struct File: Sendable, Identifiable {
        let index: Int
        let oldPath: String?
        let newPath: String?
        let hunks: [Hunk]

        var id: Int { index }

        var displayPath: String {
            let raw = newPath ?? oldPath ?? ""
            for prefix in ["a/", "b/"] where raw.hasPrefix(prefix) {
                return String(raw.dropFirst(prefix.count))
            }
            return raw
        }

        var isNew: Bool { (oldPath ?? "/dev/null").hasSuffix("/dev/null") }
        var isDeleted: Bool { (newPath ?? "/dev/null").hasSuffix("/dev/null") }
    }

    let files: [File]

    var isEmpty: Bool { files.isEmpty }

    var additions: Int {
        files.flatMap(\.hunks).flatMap(\.lines).filter { $0.kind == .added }.count
    }

    var deletions: Int {
        files.flatMap(\.hunks).flatMap(\.lines).filter { $0.kind == .removed }.count
    }

    /// Parses one unified diff. Accepts `@@` hunks with or without file headers.
    static func parse(_ text: String) -> UnifiedDiff {
        var files: [File] = []
        var currentOld: String?
        var currentNew: String?
        var hunks: [Hunk] = []
        var hunkHeader: String?
        var hunkOldStart = 0
        var hunkNewStart = 0
        var lines: [Line] = []
        var oldNumber = 0
        var newNumber = 0
        var sawHeader = false

        func flushFile() {
            guard !hunks.isEmpty || currentOld != nil || currentNew != nil else { return }
            files.append(File(index: files.count, oldPath: currentOld, newPath: currentNew, hunks: hunks))
            hunks = []
            currentOld = nil
            currentNew = nil
        }

        for raw in text.components(separatedBy: "\n") {
            if raw.hasPrefix("diff --git") {
                flushFile()
                sawHeader = true
                continue
            }
            if raw.hasPrefix("--- ") {
                currentOld = String(raw.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if raw.hasPrefix("+++ ") {
                currentNew = String(raw.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if raw.hasPrefix("@@") {
                if let header = hunkHeader {
                    hunks.append(
                        Hunk(
                            index: hunks.count,
                            header: header,
                            oldStart: hunkOldStart,
                            newStart: hunkNewStart,
                            lines: lines
                        )
                    )
                }
                let parsed = parseHunkHeader(raw)
                hunkHeader = raw
                hunkOldStart = parsed.old
                hunkNewStart = parsed.new
                oldNumber = parsed.old
                newNumber = parsed.new
                lines = []
                sawHeader = true
                continue
            }
            // Outside any hunk, a non-header line is a patch preamble.
            guard hunkHeader != nil else { continue }
            // An empty element, from the patch's own trailing newline, is not a
            // diff line: a real empty context line is written as a single space.
            if raw.isEmpty { continue }

            if raw.hasPrefix("\\") {
                lines.append(Line(kind: .meta, text: raw, oldNumber: nil, newNumber: nil))
                continue
            }
            if raw.hasPrefix("+") {
                lines.append(Line(kind: .added, text: String(raw.dropFirst()), oldNumber: nil, newNumber: newNumber))
                newNumber += 1
                continue
            }
            if raw.hasPrefix("-") {
                lines.append(Line(kind: .removed, text: String(raw.dropFirst()), oldNumber: oldNumber, newNumber: nil))
                oldNumber += 1
                continue
            }
            let content = raw.hasPrefix(" ") ? String(raw.dropFirst()) : raw
            lines.append(Line(kind: .context, text: content, oldNumber: oldNumber, newNumber: newNumber))
            oldNumber += 1
            newNumber += 1
        }

        if let header = hunkHeader {
            hunks.append(
                Hunk(
                    index: hunks.count,
                    header: header,
                    oldStart: hunkOldStart,
                    newStart: hunkNewStart,
                    lines: lines
                )
            )
        }
        flushFile()

        guard sawHeader else { return UnifiedDiff(files: []) }
        return UnifiedDiff(files: files)
    }

    /// `@@ -12,7 +12,9 @@ optional section heading`
    private static func parseHunkHeader(_ header: String) -> (old: Int, new: Int) {
        var old = 1
        var new = 1
        for part in header.split(separator: " ") {
            if part.hasPrefix("-"), let value = Int(String(part.dropFirst().split(separator: ",").first ?? "")) {
                old = value
            } else if part.hasPrefix("+"), let value = Int(String(part.dropFirst().split(separator: ",").first ?? "")) {
                new = value
            }
        }
        return (old, new)
    }
}

// MARK: - Formatting

enum ByteFormat {
    /// Compact byte sizes for dense rows, matching the desktop client's style.
    static func compact(_ bytes: Int) -> String {
        switch bytes {
        case ..<(1024): return "\(bytes) B"
        case ..<(1024 * 1024): return String(format: "%.1f KB", Double(bytes) / 1024)
        case ..<(1024 * 1024 * 1024): return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        default: return String(format: "%.1f GB", Double(bytes) / (1024 * 1024 * 1024))
        }
    }
}
