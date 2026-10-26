import Foundation

/// 超长 assistant 消息的**显示行**切分（纯函数）。
///
/// 只做文本边界判断，不解析 Markdown 语义；渲染仍交给 `MarkdownText`。
/// 规则见 `maintainers/设计/20261026-长回答拆行-方案.md`：
/// - 代码围栏内不拆；
/// - 表格按表头 + 每 N 行重复表头拆；
/// - 普通段落按累计字符数分组，单段过长再按行/句切；
/// - 短消息返回单段，调用方据此不拆。
public enum AssistantTextSplitter {

    public static func split(_ text: String,
                             maxChars: Int = 1_200,
                             tableRowsPerChunk: Int = 12) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [text] }
        let blocks = parseBlocks(normalized)
        var out: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { out.append(trimmed) }
            current = ""
        }
        func append(_ block: String) {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if current.isEmpty {
                current = trimmed
                return
            }
            if current.count + 2 + trimmed.count <= maxChars {
                current += "\n\n" + trimmed
            } else {
                flush()
                current = trimmed
            }
        }

        for block in blocks {
            switch block {
            case .code(let body):
                // 围栏不拆：整块进当前分组；超过上限也保持完整。
                append(body)
            case .table(let header, let separator, let rows):
                for chunk in rows.chunked(into: max(1, tableRowsPerChunk)) {
                    append(([header, separator] + chunk).joined(separator: "\n"))
                }
            case .text(let body):
                for piece in splitLongParagraph(body, maxChars: maxChars) {
                    append(piece)
                }
            }
        }
        flush()
        return out.isEmpty ? [text] : out
    }

    // MARK: - 块解析

    private enum Block {
        case text(String)
        case code(String)
        case table(header: String, separator: String, rows: [String])
    }

    private static func parseBlocks(_ text: String) -> [Block] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String] = []
        var fence: String?
        var index = 0

        func flushParagraph() {
            let body = paragraph.joined(separator: "\n")
            if !body.trimmingCharacters(in: .whitespaces).isEmpty { blocks.append(.text(body)) }
            paragraph.removeAll(keepingCapacity: true)
        }
        func flushCode() {
            if !code.isEmpty { blocks.append(.code(code.joined(separator: "\n"))) }
            code.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let marker = fence {
                code.append(line)
                if trimmed.hasPrefix(marker) { fence = nil; flushCode() }
                index += 1
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                fence = String(trimmed.prefix(3))
                code.append(line)
                index += 1
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }
            // 表格：当前行含 |，下一行是分隔行（--- 与 | : - 组成）。
            if trimmed.contains("|"), index + 1 < lines.count,
               isTableSeparator(lines[index + 1]) {
                flushParagraph()
                let header = line
                let separator = lines[index + 1]
                var rows: [String] = []
                var cursor = index + 2
                while cursor < lines.count {
                    let candidate = lines[cursor]
                    let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
                    if candidateTrimmed.isEmpty || !candidateTrimmed.contains("|") { break }
                    rows.append(candidate)
                    cursor += 1
                }
                blocks.append(.table(header: header, separator: separator, rows: rows))
                index = cursor
                continue
            }
            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        flushCode()
        return blocks
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") else { return false }
        let allowed = CharacterSet(charactersIn: "|-: \t")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// 单段过长：先按行分组；单行仍过长再按句号/分号切，最后硬切。
    private static func splitLongParagraph(_ text: String, maxChars: Int) -> [String] {
        guard text.count > maxChars else { return [text] }
        var out: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { out.append(current); current = "" }
        }
        for line in text.components(separatedBy: "\n") {
            if line.count > maxChars {
                flush()
                out.append(contentsOf: splitSentences(line, maxChars: maxChars))
                continue
            }
            if current.isEmpty {
                current = line
            } else if current.count + 1 + line.count <= maxChars {
                current += "\n" + line
            } else {
                flush()
                current = line
            }
        }
        flush()
        return out.isEmpty ? [text] : out
    }

    private static func splitSentences(_ line: String, maxChars: Int) -> [String] {
        var out: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { out.append(current); current = "" }
        }
        for character in line {
            current.append(character)
            if "。；;.".contains(character), current.count >= maxChars / 2 {
                flush()
            } else if current.count >= maxChars {
                flush()
            }
        }
        flush()
        return out.isEmpty ? [line] : out
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
