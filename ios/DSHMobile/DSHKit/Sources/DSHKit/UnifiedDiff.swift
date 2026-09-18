import Foundation

// MARK: - Unified diff

/// A parsed unified diff (`diff --git` / `---` / `+++` / `@@`).
///
/// Parsing is deliberately forgiving: a patch with no `diff --git` header still
/// renders, and a line the grammar does not recognize becomes context rather
/// than being dropped.
public struct UnifiedDiff: Sendable {
    public struct Line: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            case context
            case added
            case removed
            case meta
        }

        public let kind: Kind
        public let text: String
        public let oldNumber: Int?
        public let newNumber: Int?

        public var marker: String {
            switch kind {
            case .context: return " "
            case .added: return "+"
            case .removed: return "-"
            case .meta: return "\\"
            }
        }
    }

    public struct Hunk: Sendable, Identifiable {
        public let index: Int
        public let header: String
        public let oldStart: Int
        public let newStart: Int
        public let lines: [Line]

        public var id: Int { index }
    }

    public struct File: Sendable, Identifiable {
        public let index: Int
        public let oldPath: String?
        public let newPath: String?
        public let hunks: [Hunk]

        public var id: Int { index }

        public var displayPath: String {
            let raw = newPath ?? oldPath ?? ""
            for prefix in ["a/", "b/"] where raw.hasPrefix(prefix) {
                return String(raw.dropFirst(prefix.count))
            }
            return raw
        }

        public var isNew: Bool { (oldPath ?? "/dev/null").hasSuffix("/dev/null") }
        public var isDeleted: Bool { (newPath ?? "/dev/null").hasSuffix("/dev/null") }
    }

    public let files: [File]

    public init(files: [File]) { self.files = files }

    public var isEmpty: Bool { files.isEmpty }

    public var additions: Int {
        files.flatMap(\.hunks).flatMap(\.lines).filter { $0.kind == .added }.count
    }

    public var deletions: Int {
        files.flatMap(\.hunks).flatMap(\.lines).filter { $0.kind == .removed }.count
    }

    /// Parses one unified diff. Accepts `@@` hunks with or without file headers.
    public static func parse(_ text: String) -> UnifiedDiff {
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
