import DSHKit
import Foundation

/// 作答记录的展示文字（SR-02.16）。
///
/// 行本身只带三份平行数组（标题 / 问题 / 答案）；这里把「标题 + 问题 + 答案」
/// 组合成可复制正文，并给列表签名一个内容键。放在领域层而不是视图层，是为了
/// 单测能钉住「跳过的题写已跳过」「问题文字缺失时只复制答案」这两条口径。
public extension TimelineItem {
    /// 一题一段的可复制正文；不是作答记录时返回 nil。
    ///
    /// 与桌面 `QuestionReplyBubble` 的复制口径一致（`replyClipboardText`）：
    /// 标题优先 `header — question`，答案用 `, ` 连接；跳过的题写 `已跳过`。
    var questionRecordCopyText: String? {
        guard case .questionRecord(let headers, let questions, let answers) = kind else { return nil }
        let skipped = String(localized: "已跳过")
        let lines: [String] = answers.indices.compactMap { index in
            let header = headers.indices.contains(index) ? headers[index] : ""
            let question = questions.indices.contains(index) ? questions[index] : ""
            let answer = answers[index]
            let heading = [header, question]
                .filter { !$0.isEmpty }
                .joined(separator: " — ")
            if heading.isEmpty { return answer.isEmpty ? nil : answer }
            return "\(heading)\n\(answer.isEmpty ? skipped : answer)"
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n\n")
    }

    /// 行内容签名的一部分：任意一份数组变化都要让列表重载该行。
    var questionRecordContentKey: String? {
        guard case .questionRecord(let headers, let questions, let answers) = kind else { return nil }
        return headers.joined(separator: "\u{1E}") + "\u{1D}"
            + questions.joined(separator: "\u{1E}") + "\u{1D}"
            + answers.joined(separator: "\u{1E}")
    }
}
