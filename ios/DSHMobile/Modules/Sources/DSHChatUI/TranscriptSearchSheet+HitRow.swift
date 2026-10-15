#if os(iOS)
import DSHDesign
import DSHKit
import SwiftUI

/// 搜索面板命中行的片段渲染。从 TranscriptSearchSheet.swift 拆出（500 行上限）。
extension TranscriptSearchSheet {

    /// 片段按**行内** markdown 渲染（与转写同一套 `InlineMarkdown`），命中处加粗上色。
    ///
    /// 为什么先按字符偏移切成头/命中/尾再分别渲染，而不是整段渲染后回填高亮：
    /// `highlightStart`/`highlightLength` 是**原始 markdown 文本**里的偏移，渲染后
    /// 标记字符被消费、索引体系就变了，映射不回去。切段后命中段整段上色，高亮
    /// 位置永远准确。代价是截断面落在标记中间时（片段本来就是截断摘要，可能截在
    /// 不闭合的 `**`/反引号里）那一段按纯文本兜底显示原始符号——可接受，
    /// 且 `InlineMarkdown.styled` 解析失败时同样回退原文。
    ///
    /// 块级语法（代码围栏、标题、表格）不在命中行展开：摘要是压过空白的行内
    /// 摘录，块结构只会把三行高的行撑爆；行内渲染下它们原样显示，正好兜底。
    func highlighted(_ hit: TranscriptSearchHit) -> Text {
        let characters = Array(hit.snippet)
        let start = min(max(0, hit.highlightStart), characters.count)
        let end = min(characters.count, start + max(0, hit.highlightLength))
        let head = String(characters[0..<start])
        let match = String(characters[start..<end])
        let tail = String(characters[end...])
        var attributed = Self.inlineMarkdown(head)
        var marked = Self.inlineMarkdown(match)
        marked.inlinePresentationIntent =
            (marked.inlinePresentationIntent ?? []).union(.stronglyEmphasized)
        marked.foregroundColor = DSHTheme.brand
        attributed.append(marked)
        attributed.append(Self.inlineMarkdown(tail))
        return Text(attributed)
    }

    /// 行内 markdown → `AttributedString`，解析不了就纯文本原文（兜底）。
    static func inlineMarkdown(_ text: String) -> AttributedString {
        InlineMarkdown.styled(text) ?? AttributedString(text)
    }
}
#endif
