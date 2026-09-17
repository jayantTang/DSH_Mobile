import DSHKit
import SwiftUI

/// A read-only reader for one workspace file.
///
/// Pages arrive 300 lines at a time and render through a `LazyVStack`, so a
/// 100k-line file costs one page of memory and only pays for the rows on screen.
/// The gutter carries real line numbers, and the code is coloured by a
/// line-oriented lexer whose block-comment state is threaded through the page.
struct WorkspaceFileReaderView: View {
    let model: WorkspaceFilesModel
    let path: String
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var rendered: [AttributedString] = []
    @State private var renderedKey: String = ""

    /// A file a browser would render — a report with its pictures — opens
    /// rendered, because that is how it was written to be read. The source is
    /// one tap away for the times it is the thing you want.
    private enum Mode: String, CaseIterable, Identifiable {
        case rendered
        case source

        var id: String { rawValue }
        var label: String { self == .rendered ? "预览" : "源码" }
    }

    private static let renderable: Set<String> = ["html", "htm", "xhtml", "svg"]

    private var isRenderable: Bool {
        Self.renderable.contains((path as NSString).pathExtension.lowercased())
    }

    @State private var mode: Mode = Self.automationMode() ?? .source
    /// Whether a read has already been asked for: asking twice restarts it.
    @State private var readRequested = false

    /// The mode an unattended run asked for, if any.
    private static func automationMode() -> Mode? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DSHFileMode"),
              index + 1 < arguments.count
        else { return nil }
        return Mode(rawValue: arguments[index + 1])
        #else
        return nil
        #endif
    }

    private var language: CodeLanguage { CodeLanguage.from(path: path) }

    var body: some View {
        NavigationStack {
            Group {
                if isRenderable, mode == .rendered {
                    // Content, not a screen: this view already owns the bar and
                    // the mode switch.
                    WorkspaceHTMLPreviewView(model: model, path: path, title: title)
                } else {
                    content
                }
            }
            .background(DSHTheme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isRenderable {
                    // Two explicit buttons rather than a segmented picker: a
                    // picker renders its segments as elements that carry no
                    // stable identifier, which makes "switch to the source"
                    // impossible to drive and awkward to assert on.
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 0) {
                            ForEach(Mode.allCases) { candidate in
                                Button {
                                    mode = candidate
                                } label: {
                                    Text(candidate.label)
                                        .font(DSHTheme.Typography.caption)
                                        .padding(.horizontal, DSHTheme.Spacing.standard)
                                        .padding(.vertical, 6)
                                        .background(mode == candidate ? DSHTheme.layer3 : .clear)
                                        .foregroundStyle(mode == candidate
                                                         ? DSHTheme.labelPrimary
                                                         : DSHTheme.labelSecondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("files.mode.\(candidate.rawValue)")
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.small))
                        .overlay(
                            RoundedRectangle(cornerRadius: DSHTheme.Radius.small)
                                .stroke(DSHTheme.border2, lineWidth: 1)
                        )
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onAppear {
            // Only when the run did not ask for a specific mode.
            if isRenderable, Self.automationMode() == nil { mode = .rendered }
        }
        // Reading the text is needed whenever the reader is showing it, and not
        // needed at all while the web preview is up. Checking that inside the
        // task rather than in a guard before it matters: the guards used to run
        // before the mode had been decided, so a file opened straight into
        // source mode was never read and the screen sat on "正在读取…" forever.
        .task { await readIfShowingText() }
        .onAppear { readIfShowingTextInBackground() }
        .onChange(of: mode) { _, _ in readIfShowingTextInBackground() }
        .onChange(of: model.file?.text) { _, _ in rebuild() }
    }

    /// Reads the file unless the web preview is what is on screen.
    ///
    /// Only ever once. `onAppear` and the mode change both ask for this, and a
    /// second read that starts while the first is still in flight resets the
    /// phase to "loading" every time it is asked for — which is what left the
    /// source view spinning forever on a file big enough to need a moment. A
    /// small file finished between triggers, so the problem only showed up on
    /// the real report.
    private func readIfShowingText() async {
        guard !(isRenderable && mode == .rendered) else { return }
        guard !readRequested else {
            if model.file != nil { rebuild() }
            return
        }
        readRequested = true
        await model.openFile(path: path)
        rebuild()
    }

    private func readIfShowingTextInBackground() {
        Task { await readIfShowingText() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.filePhase {
        case .idle, .loading:
            VStack(spacing: DSHTheme.Spacing.standard) {
                ProgressView()
                Text("正在读取…")
                    .font(DSHTheme.Typography.caption)
                    .foregroundStyle(DSHTheme.labelSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ErrorStateView(message: message) {
                Task {
                    await model.openFile(path: path)
                    rebuild()
                }
            }

        case .loaded:
            if let file = model.file {
                loaded(file: file)
            } else {
                EmptyStateView(icon: "doc", title: "没有内容", message: "这个文件是空的。")
            }
        }
    }

    private func loaded(file: WorkspaceFileText) -> some View {
        VStack(spacing: 0) {
            header(file: file)
            Hairline()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rendered.enumerated()), id: \.offset) { index, line in
                        CodeLineRow(
                            attributed: line,
                            number: file.offset + index,
                            gutter: gutterWidth(total: file.lastLine)
                        )
                    }
                }
                .padding(.vertical, DSHTheme.Spacing.tight)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(DSHTheme.codeBackground)
            footer(file: file)
        }
    }

    /// The line range the reader currently holds, said the way the desktop
    /// client says it.
    private func header(file: WorkspaceFileText) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DSHTheme.Spacing.tight) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.scope.displayPath(file.absolutePath))
                    .font(DSHTheme.Typography.code)
                    .foregroundStyle(DSHTheme.labelPrimary)
                    .lineLimit(2)
                Text(subtitle(file: file))
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.labelTertiary)
            }
            Spacer(minLength: 0)
            if language != .text {
                Badge(text: language.rawValue, tone: .neutral)
            }
            if let bytes = file.bytes {
                Badge(text: ByteFormat.compact(bytes), tone: .neutral)
            }
        }
        .padding(.horizontal, DSHTheme.Spacing.standard)
        .padding(.vertical, DSHTheme.Spacing.tight)
    }

    private func subtitle(file: WorkspaceFileText) -> String {
        if file.eof {
            return "共 \(file.lastLine) 行"
        }
        return "显示 1 – \(file.lastLine) 行，还有更多"
    }

    @ViewBuilder
    private func footer(file: WorkspaceFileText) -> some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: DSHTheme.Spacing.standard) {
                if file.eof {
                    Text("已到文件末尾")
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelTertiary)
                } else {
                    Button("加载更多") {
                        Task {
                            await model.loadMore()
                            rebuild()
                        }
                    }
                    .font(DSHTheme.Typography.caption)
                    .buttonStyle(.bordered)
                    .tint(DSHTheme.brand)
                    .frame(minHeight: 44)
                    Text("单页最多 \(WorkspaceFilesModel.pageLines) 行")
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DSHTheme.Spacing.standard)
            .padding(.vertical, DSHTheme.Spacing.hairline)
        }
        .background(DSHTheme.layer1)
    }

    private func gutterWidth(total: Int) -> CGFloat {
        // Four digits plus padding before the width starts eating the code.
        let digits = max(2, min(5, String(max(total, 1)).count))
        return CGFloat(digits) * 8 + 6
    }

    /// Re-tokenizes the current page. Cheap enough to run on the main actor for
    /// a 300-line page, and it keeps the highlighter stateless between pages.
    private func rebuild() {
        guard let file = model.file else {
            rendered = []
            renderedKey = ""
            return
        }
        let key = "\(file.offset)-\(file.lines)-\(file.version)"
        guard key != renderedKey else { return }
        renderedKey = key
        rendered = CodeHighlighter.page(file.contentLines, language: language)
    }
}

/// One line of code: a right-aligned line number and the coloured text.
struct CodeLineRow: View {
    let attributed: AttributedString
    let number: Int
    let gutter: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: DSHTheme.Spacing.tight) {
            Text(String(number))
                .font(DSHTheme.Typography.code)
                .foregroundStyle(DSHTheme.labelDimmed)
                .frame(width: gutter, alignment: .trailing)
            Text(attributed)
                .font(DSHTheme.Typography.code)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DSHTheme.Spacing.tight)
        .padding(.vertical, 0.5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("第 \(number) 行")
    }
}
