import SwiftUI

/// A deliberately small, dependency-free syntax highlighter for the file reader.
///
/// It is line-oriented and state-carrying: block comments continue across lines
/// because the reader tokenizes a whole page at once, so a page renders from one
/// pass instead of re-scanning on every scroll step.
///
/// Colours come from `DSHTheme` only. The design system has no dedicated syntax
/// tokens (the desktop client themes code with the same semantic aliases the app
/// already exposes), so each token kind maps onto an existing semantic role.
enum CodeTokenKind: Sendable, Hashable {
    case plain
    case keyword
    case type
    case string
    case number
    case comment
    case property
    case punctuation
}

/// The languages the reader can colour, chosen by file extension.
enum CodeLanguage: String, Sendable {
    case swift
    case javascript
    case typescript
    case python
    case json
    case shell
    case yaml
    case markdown
    case go
    case rust
    case c
    case cpp
    case java
    case kotlin
    case ruby
    case php
    case sql
    case html
    case css
    case text

    static func from(path: String) -> CodeLanguage {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        switch ext {
        case "swift": return .swift
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "ts", "tsx", "mts": return .typescript
        case "py", "pyi": return .python
        case "json", "jsonc", "json5": return .json
        case "sh", "bash", "zsh", "fish", "ksh": return .shell
        case "yml", "yaml": return .yaml
        case "md", "markdown", "mdx": return .markdown
        case "go": return .go
        case "rs": return .rust
        case "c", "h": return .c
        case "cc", "cpp", "cxx", "hpp", "hh", "hxx", "mm": return .cpp
        case "java": return .java
        case "kt", "kts": return .kotlin
        case "rb", "rake", "gemspec": return .ruby
        case "php": return .php
        case "sql": return .sql
        case "html", "htm", "xhtml", "vue", "svelte": return .html
        case "css", "scss", "sass", "less": return .css
        default:
            // Extension-less names DSH users meet constantly.
            switch name {
            case "makefile", "dockerfile", "cmakelists.txt": return .shell
            default: return .text
            }
        }
    }

    var keywords: Set<String> {
        switch self {
        case .swift:
            return ["actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class",
                    "continue", "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough",
                    "false", "fileprivate", "final", "for", "func", "get", "guard", "if", "import", "in", "indirect",
                    "init", "inout", "internal", "is", "isolated", "lazy", "let", "mutating", "nil", "nonisolated",
                    "open", "operator", "override", "private", "protocol", "public", "repeat", "required", "rethrows",
                    "return", "self", "set", "some", "static", "struct", "subscript", "super", "switch", "throw",
                    "throws", "true", "try", "typealias", "var", "where", "while", "willSet", "didSet", "weak",
                    "unowned", "convenience", "consuming", "borrowing", "sending"]
        case .javascript, .typescript:
            return ["async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default",
                    "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "function", "if",
                    "implements", "import", "in", "instanceof", "interface", "let", "new", "null", "of", "package",
                    "private", "protected", "public", "readonly", "return", "satisfies", "static", "super", "switch",
                    "this", "throw", "true", "try", "type", "typeof", "undefined", "var", "void", "while", "yield",
                    "declare", "namespace", "as", "is", "keyof", "infer", "never", "unknown", "any", "string",
                    "number", "boolean", "symbol", "bigint", "object"]
        case .python:
            return ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif",
                    "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is",
                    "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "True", "try", "while",
                    "with", "yield", "match", "case", "self"]
        case .json:
            return ["true", "false", "null"]
        case .shell:
            return ["case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in",
                    "local", "readonly", "return", "select", "then", "until", "while", "cd", "echo", "exit", "set",
                    "source", "sudo", "shift", "trap"]
        case .yaml:
            return ["true", "false", "null", "yes", "no", "on", "off"]
        case .go:
            return ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for",
                    "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select",
                    "struct", "switch", "type", "var", "nil", "true", "false", "iota", "string", "int", "bool",
                    "byte", "rune", "error", "any"]
        case .rust:
            return ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern",
                    "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub",
                    "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe",
                    "use", "where", "while", "Some", "None", "Ok", "Err"]
        case .c, .cpp, .java, .kotlin:
            return ["auto", "break", "case", "catch", "char", "class", "const", "constexpr", "continue", "default",
                    "delete", "do", "double", "else", "enum", "explicit", "extern", "false", "final", "float", "for",
                    "friend", "fun", "goto", "if", "import", "inline", "int", "interface", "internal", "long",
                    "namespace", "new", "null", "nullptr", "object", "override", "package", "private", "protected",
                    "public", "register", "return", "short", "signed", "sizeof", "static", "struct", "super",
                    "switch", "synchronized", "template", "this", "throw", "throws", "true", "try", "typedef",
                    "typename", "union", "unsigned", "val", "var", "virtual", "void", "volatile", "while", "bool",
                    "suspend", "when"]
        case .ruby:
            return ["alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif",
                    "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo",
                    "rescue", "retry", "return", "self", "super", "then", "true", "undef", "unless", "until", "when",
                    "while", "yield", "require", "attr_accessor"]
        case .php:
            return ["abstract", "array", "as", "break", "case", "catch", "class", "clone", "const", "continue",
                    "declare", "default", "do", "echo", "else", "elseif", "empty", "enddeclare", "endfor", "endforeach",
                    "endif", "endswitch", "endwhile", "extends", "final", "finally", "fn", "for", "foreach",
                    "function", "global", "if", "implements", "include", "instanceof", "interface", "isset", "list",
                    "match", "namespace", "new", "or", "print", "private", "protected", "public", "readonly",
                    "require", "return", "static", "switch", "throw", "trait", "try", "unset", "use", "var", "while",
                    "yield", "true", "false", "null"]
        case .sql:
            return ["add", "all", "alter", "and", "as", "asc", "begin", "between", "by", "case", "cast", "check",
                    "column", "commit", "constraint", "create", "database", "default", "delete", "desc", "distinct",
                    "drop", "else", "end", "exists", "foreign", "from", "full", "group", "having", "if", "in",
                    "index", "inner", "insert", "into", "is", "join", "key", "left", "like", "limit", "not", "null",
                    "offset", "on", "or", "order", "outer", "primary", "references", "right", "rollback", "select",
                    "set", "table", "then", "union", "unique", "update", "values", "view", "when", "where"]
        case .html, .css, .markdown, .text:
            return []
        }
    }

    var lineComments: [String] {
        switch self {
        case .swift, .javascript, .typescript, .go, .rust, .c, .cpp, .java, .kotlin: return ["//"]
        case .python, .shell, .yaml, .ruby: return ["#"]
        case .php: return ["//", "#"]
        case .sql: return ["--"]
        case .css: return []
        case .json, .html, .markdown, .text: return []
        }
    }

    var blockComment: (open: String, close: String)? {
        switch self {
        case .swift, .javascript, .typescript, .go, .rust, .c, .cpp, .java, .kotlin, .css, .sql, .php:
            return ("/*", "*/")
        case .python: return ("\"\"\"", "\"\"\"")
        case .html: return ("<!--", "-->")
        default: return nil
        }
    }

    /// Languages where a capitalized identifier usually names a type.
    var coloursTypeNames: Bool {
        switch self {
        case .swift, .java, .kotlin, .rust, .go, .c, .cpp, .typescript: return true
        default: return false
        }
    }

    var stringsAreQuoted: Bool {
        switch self {
        case .json, .javascript, .typescript, .swift, .go, .rust, .c, .cpp, .java, .kotlin, .python, .ruby,
             .php, .sql, .yaml, .shell:
            return true
        default:
            return false
        }
    }
}

/// Carries cross-line lexer state through a page.
struct CodeLexerState: Sendable {
    var inBlockComment = false
}

enum CodeHighlighter {

    /// Tokenizes one line, advancing `state` past any unterminated block comment.
    static func segments(
        _ line: String,
        language: CodeLanguage,
        state: inout CodeLexerState
    ) -> [(text: String, kind: CodeTokenKind)] {
        let characters = Array(line)
        var output: [(text: String, kind: CodeTokenKind)] = []
        var plain = ""

        func flushPlain() {
            if !plain.isEmpty {
                output.append((plain, .plain))
                plain = ""
            }
        }
        func emit(_ text: String, _ kind: CodeTokenKind) {
            flushPlain()
            output.append((text, kind))
        }

        if language == .markdown {
            return markdownSegments(line)
        }

        var index = 0

        // Finish a block comment carried over from an earlier line.
        if state.inBlockComment, let close = language.blockComment?.close {
            if let range = line.range(of: close) {
                let text = String(line[line.startIndex ..< range.upperBound])
                emit(text, .comment)
                index = line.distance(from: line.startIndex, to: range.upperBound)
                state.inBlockComment = false
            } else {
                return [(line, .comment)]
            }
        }

        let lineComments = language.lineComments
        let block = language.blockComment

        while index < characters.count {
            let character = characters[index]

            // Line comment: the rest of the line is a comment.
            if let prefix = lineComments.first(where: { matches(characters, at: index, prefix: $0) }) {
                let start = index
                index += prefix.count
                emit(String(characters[start...]), .comment)
                break
            }

            // Block comment open.
            if let block, matches(characters, at: index, prefix: block.open) {
                let rest = String(characters[index...])
                if let range = rest.range(of: block.close) {
                    let text = String(rest[rest.startIndex ..< range.upperBound])
                    emit(text, .comment)
                    index += text.count
                } else {
                    emit(rest, .comment)
                    state.inBlockComment = true
                    index = characters.count
                }
                continue
            }

            // Quoted string, with backslash escapes.
            if language.stringsAreQuoted, character == "\"" || character == "'" || character == "`" {
                let start = index
                index += 1
                var escaped = false
                while index < characters.count {
                    let current = characters[index]
                    if escaped {
                        escaped = false
                    } else if current == "\\" {
                        escaped = true
                    } else if current == character {
                        index += 1
                        break
                    }
                    index += 1
                }
                let text = String(characters[start ..< min(index, characters.count)])
                emit(text, isPropertyKey(characters, from: index) ? .property : .string)
                continue
            }

            // Number literal. A `-` only starts one when nothing identifier-like
            // precedes it, so `a-5` stays one identifier while `-5` is a number.
            //
            // `isNumberBody` is required here, not decorative: `Character.isNumber`
            // is true for Chinese numerals — 两, 三, 十, 万 — and those are not
            // number-body characters, so the loop below would not consume
            // anything and the lexer would spin forever on the first one it met.
            // That is what hung the source view on the first report containing
            // 「两个入口」.
            let before = previous(characters, before: index)
            let beforeThat = index >= 2 ? characters[index - 2] : nil
            let startsNumber = !isIdentifierCharacter(before)
                || (before == "-" && !isIdentifierCharacter(beforeThat))
            if character.isNumber, isNumberBody(character), startsNumber {
                let start = index
                while index < characters.count, isNumberBody(characters[index]) {
                    index += 1
                }
                emit(String(characters[start ..< index]), .number)
                continue
            }

            // Identifier or keyword.
            if isIdentifierStart(character) {
                let start = index
                while index < characters.count, isIdentifierCharacter(characters[index]) {
                    index += 1
                }
                // A character can be an identifier start and not an identifier
                // body under some Unicode classification; take it as plain text
                // rather than standing still.
                guard index > start else {
                    plain.append(character)
                    index += 1
                    continue
                }
                let word = String(characters[start ..< index])
                if language.keywords.contains(word) {
                    emit(word, .keyword)
                } else if language.coloursTypeNames, let first = word.first, first.isUppercase {
                    emit(word, .type)
                } else if isPropertyKey(characters, from: index) {
                    emit(word, .property)
                } else {
                    plain += word
                }
                continue
            }

            if "{}[]()<>,;:=".contains(character) {
                emit(String(character), .punctuation)
            } else {
                plain.append(character)
            }
            index += 1
        }

        flushPlain()
        return output
    }

    /// How much of one line is worth laying out.
    ///
    /// A file is not obliged to have newlines. A one-line report with embedded
    /// images is 300,000 characters on a single row, and asking a `Text` to lay
    /// that out hangs the reader — which is exactly what happened to the first
    /// HTML report opened on a phone. Long lines are cut for display and said to
    /// be cut; the file itself is untouched, and the web view renders such a
    /// document properly.
    static let displayLimit = 2_000

    /// Tokenizes a whole page, so block comments carry across lines.
    static func page(_ lines: [String], language: CodeLanguage) -> [AttributedString] {
        var state = CodeLexerState()
        return lines.map { line in
            let shown = line.count > displayLimit ? truncated(line) : line
            return attributed(segments(shown, language: language, state: &state))
        }
    }

    /// The head of an over-long line, with how much was dropped.
    private static func truncated(_ line: String) -> String {
        let head = String(line.prefix(displayLimit))
        let dropped = line.count - displayLimit
        return head + "… 本行还有 \(dropped) 个字符未显示"
    }

    static func attributed(_ segments: [(text: String, kind: CodeTokenKind)]) -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            var piece = AttributedString(segment.text)
            piece.foregroundColor = color(for: segment.kind)
            if segment.kind == .comment {
                piece.inlinePresentationIntent = .emphasized
            }
            result.append(piece)
        }
        return result
    }

    /// Syntax colours use only tokens the design system already defines.
    static func color(for kind: CodeTokenKind) -> Color {
        switch kind {
        case .plain: return DSHTheme.labelPrimary
        case .keyword: return DSHTheme.brand
        case .type: return DSHTheme.brandBright
        case .string: return DSHTheme.success
        case .number: return DSHTheme.syntaxNumber
        case .comment: return DSHTheme.labelTertiary
        case .property: return DSHTheme.labelSecondary
        case .punctuation: return DSHTheme.labelSecondary
        }
    }

    // MARK: - Character helpers

    private static func matches(_ characters: [Character], at index: Int, prefix: String) -> Bool {
        let prefixCharacters = Array(prefix)
        guard index + prefixCharacters.count <= characters.count else { return false }
        for offset in 0 ..< prefixCharacters.count where characters[index + offset] != prefixCharacters[offset] {
            return false
        }
        return true
    }

    private static func previous(_ characters: [Character], before index: Int) -> Character? {
        index > 0 ? characters[index - 1] : nil
    }

    private static func isIdentifierStart(_ character: Character) -> Bool {
        character.isLetter || character == "_" || character == "$" || character == "@"
    }

    private static func isIdentifierCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber || character == "_" || character == "$" || character == "-"
    }

    private static func isNumberBody(_ character: Character) -> Bool {
        character.isHexDigit || character == "." || character == "_" || "xXoObBeE".contains(character)
    }

    /// Whether the next meaningful character is `:`, which makes the token a key.
    private static func isPropertyKey(_ characters: [Character], from index: Int) -> Bool {
        var cursor = index
        while cursor < characters.count, characters[cursor] == " " {
            cursor += 1
        }
        guard cursor < characters.count else { return false }
        if characters[cursor] == ":" {
            // `::` is a scope operator, not a key separator.
            if cursor + 1 < characters.count, characters[cursor + 1] == ":" { return false }
            return true
        }
        if characters[cursor] == "=" {
            return false
        }
        return false
    }

    /// Markdown gets headings, bullets and code spans; prose stays plain.
    private static func markdownSegments(_ line: String) -> [(text: String, kind: CodeTokenKind)] {
        if line.hasPrefix("#") {
            return [(line, .keyword)]
        }
        if line.hasPrefix("```") || line.hasPrefix("~~~") {
            return [(line, .comment)]
        }
        if line.hasPrefix("> ") {
            return [(line, .comment)]
        }
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return [("- ", .punctuation), (String(line.dropFirst(2)), .plain)]
        }
        var output: [(text: String, kind: CodeTokenKind)] = []
        var plain = ""
        var inCode = false
        for character in line {
            if character == "`" {
                if !plain.isEmpty {
                    output.append((plain, .plain))
                    plain = ""
                }
                output.append(("`", .punctuation))
                inCode.toggle()
                continue
            }
            if inCode {
                if let last = output.last, last.kind == .string {
                    output[output.count - 1] = (last.text + String(character), .string)
                } else {
                    output.append((String(character), .string))
                }
            } else {
                plain.append(character)
            }
        }
        if !plain.isEmpty { output.append((plain, .plain)) }
        return output
    }
}
