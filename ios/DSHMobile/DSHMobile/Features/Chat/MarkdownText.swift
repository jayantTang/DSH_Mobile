import SwiftUI

/// A block-level Markdown renderer tuned for chat transcripts.
///
/// `AttributedString(markdown:)` only handles inline syntax, so the block
/// structure — fenced code, headings, lists, quotes — is parsed here and each
/// block is handed to the right view. Streaming output is re-parsed on every
/// chunk, so the parse stays linear and allocation-light.
struct MarkdownText: View {
    let text: String
    /// Streaming text is rendered with a trailing caret and skips some work.
    var isStreaming: Bool = false

    var body: some View {
        if isStreaming {
            // Plain text while tokens arrive. Re-parsing markdown on every chunk
            // makes the layout jump: a half-typed heading, table or fence
            // appears, changes shape and disappears again under the reader's
            // eyes. The committed message renders fully formatted a moment
            // later, so nothing is lost by waiting.
            Text(text)
                .font(DSHTheme.Typography.body)
                .foregroundStyle(DSHTheme.labelPrimary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            blocks
        }
    }

    private var blocks: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.tight) {
            ForEach(MarkdownBlock.parse(text)) { block in
                switch block.kind {
                case .paragraph(let content):
                    InlineMarkdown(text: content)
                        .font(DSHTheme.Typography.body)
                        .foregroundStyle(DSHTheme.labelPrimary)
                        // The desktop sets a 16/24 rhythm; SwiftUI's default
                        // leading is noticeably tighter and makes CJK prose
                        // feel cramped.
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                case .heading(let level, let content):
                    InlineMarkdown(text: content)
                        .font(.system(size: level <= 2 ? 18 : 16, weight: .semibold))
                        .foregroundStyle(DSHTheme.labelPrimary)
                        .textSelection(.enabled)
                        .padding(.top, level <= 2 ? DSHTheme.Spacing.hairline : 0)

                case .code(let language, let code):
                    CodeBlock(language: language, code: code)

                case .listItem(let marker, let content):
                    HStack(alignment: .top, spacing: DSHTheme.Spacing.tight) {
                        Text(marker)
                            .font(DSHTheme.Typography.body)
                            .foregroundStyle(DSHTheme.labelTertiary)
                            .frame(minWidth: 18, alignment: .trailing)
                        InlineMarkdown(text: content)
                            .font(DSHTheme.Typography.body)
                            .foregroundStyle(DSHTheme.labelPrimary)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                case .quote(let content):
                    HStack(alignment: .top, spacing: DSHTheme.Spacing.tight) {
                        Rectangle()
                            .fill(DSHTheme.border3)
                            .frame(width: 2)
                        InlineMarkdown(text: content)
                            .font(DSHTheme.Typography.body)
                            .foregroundStyle(DSHTheme.labelSecondary)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                case .table(let headers, let rows):
                    MarkdownTable(headers: headers, rows: rows)

                case .rule:
                    Hairline()
                }
            }
        }
    }
}

/// Inline Markdown: bold, italic, inline code, links.
///
/// Falls back to the raw string when the markup does not parse, so a partial
/// stream never renders as an error.
private struct InlineMarkdown: View {
    let text: String

    var body: some View {
        if let attributed = Self.styled(text) {
            Text(attributed)
        } else {
            Text(text)
        }
    }

    /// Parses inline markdown and gives inline code a monospace face.
    ///
    /// `AttributedString(markdown:)` records `.code` as a presentation intent
    /// but leaves the font alone, so `` `shell` `` rendered identically to the
    /// prose around it.
    static func styled(_ text: String) -> AttributedString? {
        guard var attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return nil }

        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = DSHTheme.Typography.codeInline
        }
        return attributed
    }
}

/// A fenced code block with a language badge and horizontal scrolling.
private struct CodeBlock: View {
    let language: String?
    let code: String
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DSHTheme.Spacing.hairline) {
                Text(language?.isEmpty == false ? language! : "code")
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.labelTertiary)
                Spacer(minLength: 0)
                Button {
                    UIPasteboard.general.string = code
                    didCopy = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        didCopy = false
                    }
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(didCopy ? DSHTheme.success : DSHTheme.labelTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("复制代码")
            }
            .padding(.horizontal, DSHTheme.Spacing.tight)
            .padding(.vertical, 5)

            Hairline()

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(DSHTheme.Typography.code)
                    .foregroundStyle(DSHTheme.labelPrimary)
                    .textSelection(.enabled)
                    .padding(DSHTheme.Spacing.tight)
            }
        }
        .background(DSHTheme.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DSHTheme.Radius.large, style: .continuous)
                .stroke(DSHTheme.border1, lineWidth: 1)
        )
    }
}

// MARK: - Block parsing

/// One parsed Markdown block.
struct MarkdownBlock: Identifiable {
    enum Kind {
        case paragraph(String)
        case heading(level: Int, text: String)
        case code(language: String?, code: String)
        case listItem(marker: String, text: String)
        case quote(String)
        case table(headers: [String], rows: [[String]])
        case rule
    }

    let id: Int
    let kind: Kind

    /// Splits Markdown into blocks in a single pass.
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var buffer: [String] = []
        var index = 0

        func flushParagraph() {
            guard !buffer.isEmpty else { return }
            let joined = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeAll(keepingCapacity: true)
            guard !joined.isEmpty else { return }
            blocks.append(MarkdownBlock(id: index, kind: .paragraph(joined)))
            index += 1
        }

        var lines = text.components(separatedBy: .newlines)[...]

        while let line = lines.first {
            lines = lines.dropFirst()
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code: consume until the closing fence.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                while let next = lines.first {
                    lines = lines.dropFirst()
                    if next.trimmingCharacters(in: .whitespaces).hasPrefix(fence) { break }
                    code.append(next)
                }
                blocks.append(
                    MarkdownBlock(
                        id: index,
                        kind: .code(language: language.isEmpty ? nil : language, code: code.joined(separator: "\n"))
                    )
                )
                index += 1
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(MarkdownBlock(id: index, kind: .rule))
                index += 1
                continue
            }

            // A table has to be recognised before anything else: its rows are
            // ordinary text to every other rule, and the desktop client emits
            // them often enough that rendering them raw is very visible.
            if trimmed.hasPrefix("|") {
                var tableLines = [line]
                while let next = lines.first,
                      next.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    tableLines.append(next)
                    lines = lines.dropFirst()
                }
                if let table = parseTable(tableLines) {
                    flushParagraph()
                    blocks.append(MarkdownBlock(id: index, kind: .table(headers: table.headers, rows: table.rows)))
                    index += 1
                    continue
                }
                // Not actually a table: keep the lines as prose rather than
                // losing them.
                buffer.append(contentsOf: tableLines)
                continue
            }

            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(MarkdownBlock(id: index, kind: .heading(level: heading.level, text: heading.text)))
                index += 1
                continue
            }

            if trimmed.hasPrefix("> ") {
                flushParagraph()
                blocks.append(
                    MarkdownBlock(
                        id: index,
                        kind: .quote(String(trimmed.dropFirst(2)))
                    )
                )
                index += 1
                continue
            }

            if let item = parseListItem(line) {
                flushParagraph()
                blocks.append(MarkdownBlock(id: index, kind: .listItem(marker: item.marker, text: item.text)))
                index += 1
                continue
            }

            buffer.append(line)
        }

        flushParagraph()
        return blocks
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        for character in line {
            if character == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.hasPrefix(" ") else { return nil }
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    /// Splits pipe-delimited rows into a header and body.
    ///
    /// Returns nil unless the second row is a real alignment separator, so a
    /// single stray `|` in prose is not mistaken for a table.
    static func parseTable(_ lines: [String]) -> (headers: [String], rows: [[String]])? {
        guard lines.count >= 2 else { return nil }

        func cells(_ line: String) -> [String] {
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("|") { text.removeFirst() }
            if text.hasSuffix("|") { text.removeLast() }
            return text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }

        let headers = cells(lines[0])
        let separator = cells(lines[1])
        guard !headers.isEmpty,
              separator.count == headers.count,
              separator.allSatisfy({ $0.contains("-") })
        else { return nil }

        let rows = lines.dropFirst(2)
            .map(cells)
            .filter { row in !row.allSatisfy { $0.isEmpty } }
        return (headers, rows)
    }

    private static func parseListItem(_ line: String) -> (marker: String, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for bullet in ["- ", "* ", "+ "] where trimmed.hasPrefix(bullet) {
            return ("•", String(trimmed.dropFirst(bullet.count)))
        }
        // Ordered lists: "12. text"
        guard let dot = trimmed.firstIndex(of: "."), dot > trimmed.startIndex else { return nil }
        let number = trimmed[trimmed.startIndex..<dot]
        guard number.allSatisfy(\.isNumber), trimmed.index(after: dot) < trimmed.endIndex,
              trimmed[trimmed.index(after: dot)] == " " else { return nil }
        return ("\(number).", String(trimmed[trimmed.index(dot, offsetBy: 2)...]))
    }
}


/// A Markdown table rendered as a real grid.
///
/// The whole grid scrolls horizontally rather than squeezing every column into a
/// phone: tables in DSH output (comparisons, file inventories) are wide.
///
/// Every cell is given a **concrete width** and the rows are stacked by hand —
/// `VStack` of `HStack`s, not `Grid`. That is not cosmetic either, and it is the
/// second time this view has been fixed for the same class of bug:
///
/// * A `Grid` inside a horizontal `ScrollView` measures its rows before the
///   width is known, so a cell that only carried `maxWidth` reported one line of
///   height while drawing several — rows overlapped (the wide Spark table in a
///   real transcript exposed that).
/// * A concrete width fixed the plain cells but not the ones holding inline
///   code: `Text(AttributedString)` with a `.font` set per run still reported a
///   single-line height for a cell that wrapped over three lines, so the cell
///   was drawn three lines tall inside a one-line row and the next row's text
///   landed on top of it (the report-comparison table, whose cells are full of
///   `` `code` `` spans, exposed that).
///
/// With an `HStack` a row's height is simply its tallest child, and
/// `.fixedSize(vertical:)` makes each cell compute that height at its own width
/// before the row exists. Keep both: the widths and the hand-stacked rows are
/// what make the wrap deterministic.
private struct MarkdownTable: View {
    let headers: [String]
    let rows: [[String]]

    /// Wide enough for a short sentence per line, so a column never becomes one
    /// word per line; narrow enough that two columns still fit a phone.
    private static let minTextWidth: CGFloat = 132
    private static let maxColumnWidth: CGFloat = 240
    private static let columnPadding: CGFloat = 16

    private var columnCount: Int {
        max(headers.count, rows.map(\.count).max() ?? 0)
    }

    /// Column widths are content-proportional.
    ///
    /// A fixed width for every column wastes most of a phone's screen on the
    /// `#` column of a numbered table, which is exactly what a real Spark-tuning
    /// table looks like. Weighting by the longest cell keeps that column narrow
    /// and gives the room to the columns that have something to say.
    private var widths: [CGFloat] {
        let longest = (0..<columnCount).map { index -> String in
            let header = headers.indices.contains(index) ? headers[index] : ""
            let cells = rows.compactMap { $0.indices.contains(index) ? $0[index] : nil }
            return ([header] + cells).max(by: { $0.count < $1.count }) ?? header
        }
        func textWidth(_ column: String) -> CGFloat {
            // CJK glyphs are about twice the advance width of a Latin one.
            let units = column.reduce(into: 0.0) { total, character in
                total += character.unicodeScalars.contains { $0.value > 0x2E80 } ? 2 : 1
            }
            // Capped at the equivalent of four lines: past that the wrap is fine.
            let wanted = max(Self.minTextWidth, min(units, 34) * 7 + 8)
            return min(wanted + Self.columnPadding, Self.maxColumnWidth)
        }
        return longest.map(textWidth)
    }

    var body: some View {
        // Read once: the width walk covers every cell in the table.
        let widths = self.widths
        let total = widths.reduce(0, +)
        return ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                row(headers, widths: widths, isHeader: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in
                    row(cells, widths: widths, isHeader: false)
                }
            }
            // The stack must not try to fill the scroll view: its width is the
            // sum of the columns, which is what makes the table scroll instead
            // of squeezing.
            .frame(width: total, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous)
                    .stroke(DSHTheme.border2, lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ cells: [String], widths: [CGFloat], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<columnCount, id: \.self) { index in
                cell(cells.indices.contains(index) ? cells[index] : "",
                     isHeader: isHeader, isFirstColumn: index == 0, width: widths[index])
            }
        }
    }

    @ViewBuilder
    private func cell(_ text: String, isHeader: Bool, isFirstColumn: Bool, width: CGFloat) -> some View {
        // Inline markdown, not `Text(text)`: table cells in real transcripts
        // contain emphasis and inline code, and rendering the raw source leaked
        // literal `**` into the table.
        InlineMarkdown(text: text)
            .font(isHeader ? DSHTheme.Typography.micro : DSHTheme.Typography.caption)
            .foregroundStyle(isHeader ? DSHTheme.labelSecondary : DSHTheme.labelPrimary)
            .multilineTextAlignment(.leading)
            // Wrap at the column width, then take the height that wrap needs.
            // Without `fixedSize` a cell whose runs carry their own fonts (inline
            // code) reports a single line and the row is built too short.
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width - Self.columnPadding, alignment: .leading)
            .padding(.horizontal, Self.columnPadding / 2)
            .frame(width: width, alignment: .leading)
            .padding(.vertical, 6)
            .background(isHeader ? DSHTheme.layer3 : (isFirstColumn ? DSHTheme.layer2 : .clear))
            .overlay(alignment: .bottom) {
                Rectangle().fill(DSHTheme.border1).frame(height: 1)
            }
    }
}
