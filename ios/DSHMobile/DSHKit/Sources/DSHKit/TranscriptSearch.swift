import Foundation

/// One hit of an in-transcript search.
public struct TranscriptSearchHit: Identifiable, Sendable, Equatable {
    /// 命中的那一行（`TimelineItem.id`），点结果就是滚到它。
    public let id: String
    public let role: Role
    /// 命中处附近的一小段文字（换行压成空格），用来在结果列表里看上下文。
    public let snippet: String
    /// 要高亮的那段在 `snippet` 里的位置（字符偏移）。用偏移而不是
    /// `Range<String.Index>`：结果要跨线程/跨视图传递，偏移是稳的。
    public let highlightStart: Int
    public let highlightLength: Int
    public let seq: Int

    public enum Role: String, Sendable {
        /// 我自己发的。
        case me
        /// 助手正文。
        case agent
        /// 工具调用（名字、参数摘要、结果文本）。
        case tool
    }

    public init(id: String, role: Role, snippet: String, highlightStart: Int,
                highlightLength: Int, seq: Int) {
        self.id = id
        self.role = role
        self.snippet = snippet
        self.highlightStart = highlightStart
        self.highlightLength = highlightLength
        self.seq = seq
    }
}

/// 在**已加载**的转写里按关键词找行。
///
/// 为什么在客户端搜：host 有 `session/search`，但这个部署把它关了
/// （`session-query` 索引 `openAt: "never"`，2026-09-24 实测返回
/// `session search is disabled`），而且那是电脑端的部署配置，别人装 DSH 也未必开。
/// 转写本来就在手机上，搜它既不用等网络，也不把会话内容发给任何地方。
///
/// 代价是**只搜得到已经加载的那一段历史**。所以调用方要能把"上面还有更早的"
/// 这件事告诉读者，并允许继续往上取（`ChatModel.loadOlder`）之后再搜一次。
public enum TranscriptSearch {

    /// 一条结果最多带多少字上下文。
    static let snippetRadius = 36

    /// `query` 为空时返回空数组（不返回全部）：面板里空搜索框不该刷出一屏结果。
    ///
    /// - Parameters:
    ///   - items: 已加载的转写行，顺序就是时间顺序。
    ///   - query: 关键词，大小写与附加符号不敏感。
    ///   - onlyMine: 只看我自己发的（对应「我原来问过什么」）。
    ///   - limit: 结果上限，避免一屏几千条。
    public static func hits(
        in items: [TimelineItem],
        query: String,
        onlyMine: Bool = false,
        limit: Int = 200
    ) -> [TranscriptSearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var found: [TranscriptSearchHit] = []
        // 从**新到旧**：读者问的多半是刚才那件事，先看到最近的那条。
        for item in items.reversed() {
            if found.count >= limit { break }
            guard let (role, text) = searchable(item), let _ = text.range(of: needle, options: options) else {
                continue
            }
            if onlyMine, role != .me { continue }
            guard let range = text.range(of: needle, options: options) else { continue }
            let snippet = makeSnippet(text, range: range)
            found.append(TranscriptSearchHit(
                id: item.id,
                role: role,
                snippet: snippet.text,
                highlightStart: snippet.highlightStart,
                highlightLength: snippet.highlightLength,
                seq: item.seq
            ))
        }
        return found
    }

    /// 只看自己问过的：不输入关键词时的默认列表（由近及远）。
    ///
    /// 这是「只看我的提问」真正的默认态——读者点这颗胶囊是想**浏览**自己问过什么，
    /// 而不是先想一个关键词。所以这里不过滤、不取样，把 `items` 里的用户行全部倒序列出。
    public static func myQuestions(in items: [TimelineItem], limit: Int = 400) -> [TranscriptSearchHit] {
        var found: [TranscriptSearchHit] = []
        for item in items.reversed() {
            if found.count >= limit { break }
            guard case .userMessage(let text, _, _, _, _) = item.kind else { continue }
            let snippet = collapsed(text)
            guard !snippet.isEmpty else { continue }
            found.append(TranscriptSearchHit(id: item.id, role: .me, snippet: snippet,
                                             highlightStart: 0, highlightLength: 0, seq: item.seq))
        }
        return found
    }

    /// 把消息正文压成一行、留一段够认出来的长度（列表里每行最多显示三行）。
    static func collapsed(_ text: String, limit: Int = 160) -> String {
        var out = ""
        var pendingSpace = false
        for character in text {
            if character.isWhitespace || character.isNewline {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.append(character)
            if out.count >= limit { break }
        }
        return out
    }

    /// 这一行参与搜索的文字，以及它算哪种角色；不参与搜索的行返回 nil。
    ///
    /// 思考过程（`reasoning`）不进搜索：它又长又碎，读者要找的是"我说过什么、
    /// 助手答过什么、跑过什么命令"。结构分隔行同理。
    static func searchable(_ item: TimelineItem) -> (TranscriptSearchHit.Role, String)? {
        switch item.kind {
        case .userMessage(let text, _, _, _, _):
            return (.me, text)
        case .assistantText(let text):
            return (.agent, text)
        case .toolCall(let invocation):
            let parts = [invocation.name, invocation.summary, invocation.resultText]
                .filter { !$0.isEmpty }
            return parts.isEmpty ? nil : (.tool, parts.joined(separator: "\n"))
        case .reasoning, .notice, .turnDivider, .unknown:
            return nil
        }
    }

    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// 命中处前后各取 `snippetRadius` 个字符，并把换行/连续空白压成单个空格。
    ///
    /// 高亮位置用**字符偏移**算：先按原始文本算出保留区间，再压空白，压的时候
    /// 同步记录命中起点落在了哪个偏移上，这样即使前面有被压掉的空白也对得上。
    static func makeSnippet(_ text: String, range: Range<String.Index>)
        -> (text: String, highlightStart: Int, highlightLength: Int) {
        let characters = Array(text)
        let lower = text.distance(from: text.startIndex, to: range.lowerBound)
        let length = text.distance(from: range.lowerBound, to: range.upperBound)
        let start = max(0, lower - snippetRadius)
        let end = min(characters.count, lower + length + snippetRadius)

        var out = ""
        var highlightStart = 0
        var highlightLength = 0
        var pendingSpace = false
        for index in start..<end {
            let character = characters[index]
            let isSpace = character.isWhitespace || character.isNewline
            if isSpace {
                // 只有当后面还有内容时才落一个空格，避免片段以空格开头。
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            if index == lower { highlightStart = out.count }
            out.append(character)
            if index >= lower, index < lower + length { highlightLength += 1 }
        }

        // 两端被裁过就加省略号；加在前面时高亮起点要跟着挪。
        if start > 0 {
            out = "…" + out
            highlightStart += 1
        }
        if end < characters.count { out += "…" }
        return (out, highlightStart, max(0, highlightLength))
    }
}
