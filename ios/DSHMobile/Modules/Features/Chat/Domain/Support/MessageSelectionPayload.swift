import DSHKit

/// What a transcript row can hand to the "read this message on its own" page.
///
/// Only rows whose text a person plausibly wants to copy answer with a payload;
/// everything else (dividers, notices, unknown events) returns nil and gets no
/// long-press menu at all.
public extension TimelineItem {
    public var selectableMessage: (title: String, text: String, isMonospaced: Bool)? {
        switch kind {
        case .userMessage(let text, _, _, _, let isAgentSent):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (isAgentSent ? "助手的消息" : "我的消息", text, false)

        case .assistantText(let text):
            let body = fullText ?? text
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ("助手的回答", body, false)

        case .toolCall(let invocation):
            let body = Self.plainText(of: invocation)
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ("工具 · \(invocation.name)", body, true)

        case .reasoning, .notice, .turnDivider, .unknown, .gap, .processHeader,
             .processStep, .runningLine, .processPlaceholder:
            // 占位行不是会话内容（它是显示态的提示），没有可复制/可单独阅读的正文。
            return nil
        }
    }

    /// A tool call as the plain text of `name` + arguments + output.
    ///
    /// The card on screen folds, tints and prefixes its lines; none of that
    /// belongs in what gets copied, so the raw argument string is used rather
    /// than the card's decorated rendering.
    private static func plainText(of invocation: ToolInvocation) -> String {
        var parts: [String] = [invocation.name]
        let arguments = invocation.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if !arguments.isEmpty {
            parts.append(arguments)
        } else if !invocation.summary.isEmpty {
            parts.append(invocation.summary)
        }
        let result = invocation.resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !result.isEmpty {
            parts.append(result)
        }
        return parts.joined(separator: "\n\n")
    }
}
