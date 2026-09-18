import DSHKit
import SwiftUI

/// A unified diff, rendered the way the desktop client renders one: a file
/// header, `@@` hunk headers, then one row per line with added lines on
/// `DSHTheme.diffAdded` and removed lines on `DSHTheme.diffRemoved`.
///
/// Rows are lazy, so a large patch costs only what is on screen. Long lines wrap
/// instead of scrolling sideways: a phone has no room for a two-axis scroll
/// inside a sheet, and wrapping keeps every character reachable.
struct UnifiedDiffView: View {
    let diff: UnifiedDiff
    /// Opens a file the patch names, when the caller can serve it.
    var onOpenFile: ((String) -> Void)?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(diff.files) { file in
                fileHeader(file)
                ForEach(file.hunks) { hunk in
                    hunkHeader(hunk)
                    ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                        DiffLineRow(line: line)
                    }
                }
            }
        }
    }

    private func fileHeader(_ file: UnifiedDiff.File) -> some View {
        HStack(spacing: DSHTheme.Spacing.tight) {
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(DSHTheme.labelTertiary)
            Text(file.displayPath)
                .font(DSHTheme.Typography.code)
                .foregroundStyle(DSHTheme.labelPrimary)
                .lineLimit(1)
                .truncationMode(.head)
            if file.isNew {
                Badge(text: "已新增", tone: .success)
            } else if file.isDeleted {
                Badge(text: "已删除", tone: .danger)
            }
            Spacer(minLength: 0)
            if let onOpenFile {
                Button("打开") { onOpenFile(file.displayPath) }
                    .font(DSHTheme.Typography.micro)
                    .buttonStyle(.borderless)
                    .foregroundStyle(DSHTheme.brand)
            }
        }
        .padding(.horizontal, DSHTheme.Spacing.tight)
        .padding(.vertical, DSHTheme.Spacing.hairline)
        .background(DSHTheme.layer2)
        .frame(minHeight: 32)
    }

    private func hunkHeader(_ hunk: UnifiedDiff.Hunk) -> some View {
        Text(hunk.header)
            .font(DSHTheme.Typography.code)
            .foregroundStyle(DSHTheme.labelTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DSHTheme.Spacing.tight)
            .padding(.vertical, 2)
            .background(DSHTheme.layer3)
    }
}

/// One row of a diff: gutter numbers, the marker, and the text.
struct DiffLineRow: View {
    let line: UnifiedDiff.Line

    private var background: Color {
        switch line.kind {
        case .added: return DSHTheme.diffAdded
        case .removed: return DSHTheme.diffRemoved
        case .context, .meta: return .clear
        }
    }

    private var markerColor: Color {
        switch line.kind {
        case .added: return DSHTheme.success
        case .removed: return DSHTheme.danger
        case .context, .meta: return DSHTheme.labelDimmed
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: DSHTheme.Spacing.hairline) {
            Text(line.oldNumber.map(String.init) ?? "")
                .frame(width: 30, alignment: .trailing)
            Text(line.newNumber.map(String.init) ?? "")
                .frame(width: 30, alignment: .trailing)
            Text(line.marker)
                .foregroundStyle(markerColor)
                .frame(width: 10, alignment: .center)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(DSHTheme.labelPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(DSHTheme.Typography.code)
        .foregroundStyle(DSHTheme.labelTertiary)
        .padding(.horizontal, DSHTheme.Spacing.hairline)
        .padding(.vertical, 0.5)
        .background(background)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(line.kind == .added ? "新增" : line.kind == .removed ? "删除" : "上下文") \(line.text)")
    }
}
