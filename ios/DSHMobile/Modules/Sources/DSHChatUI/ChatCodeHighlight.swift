#if os(iOS)
import DSHDesign
import DSHKit
import SwiftUI

/// 聊天代码块高亮（spec 009「剩余卡顿源①②」/ tasks T020）。
///
/// 纪律：流式期间代码块降级为纯文本（`MarkdownText(isStreaming:)` 整块走纯文本），
/// 消息结束后的第一次完整渲染才算一次高亮，结果进 **A 类** TypesetCache
/// （环境无关——配色全是语义色，深浅色切换由 SwiftUI 动态求值）；
/// key 带消息身份 + 内容 hash，命中不重算，重进会话/滚动回收回来都直接命中。
enum ChatCodeHighlight {

    /// App 级排版缓存（T007 的 DSHKit TypesetCache；这里只用到 A 类）。
    /// A 类单体小（几百行的 AttributedString），条数上限沿用默认。
    static let cache = TypesetCache(bBytesLimit: 8 * 1024 * 1024)

    /// 高亮一段代码：先查 A 类缓存，未命中用文件阅读器同款词法器算一次并回填。
    static func highlighted(code: String, language: String?, cacheKey: String) -> AttributedString {
        let key = "\(cacheKey)|\(language ?? "")|\(hash(code))"
        if let hit = cache.aValue(for: key) as? AttributedString {
            return hit
        }
        let lines = code.components(separatedBy: "\n")
        let highlightedLines = CodeHighlighter.page(
            lines, language: CodeLanguage.from(fence: language))
        var result = AttributedString()
        for (index, line) in highlightedLines.enumerated() {
            if index > 0 { result.append(AttributedString("\n")) }
            result.append(line)
        }
        cache.setA(result, for: key)
        return result
    }

    /// FNV-1a（64 位）：确定性、无需真随机——cache 只活在本进程，
    /// 但跨启动稳定的 key 让"同一条消息重进会话"天然命中。
    private static func hash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }
}

extension CodeLanguage {
    /// 围栏语言名 → 词法器语言。围栏写的是语言名不是文件扩展名
    /// （"swift" / "js" / "c++"），认不出的按纯文本渲染，不报错。
    static func from(fence: String?) -> CodeLanguage {
        guard let fence else { return .text }
        switch fence.lowercased() {
        case "swift": return .swift
        case "js", "jsx", "javascript", "node": return .javascript
        case "ts", "tsx", "typescript": return .typescript
        case "py", "python", "python3": return .python
        case "json", "jsonc", "json5": return .json
        case "sh", "bash", "zsh", "shell", "console": return .shell
        case "yml", "yaml": return .yaml
        case "md", "markdown": return .markdown
        case "go", "golang": return .go
        case "rs", "rust": return .rust
        case "c", "h": return .c
        case "c++", "cpp", "cc", "cxx", "hpp", "objc", "objective-c": return .cpp
        case "java": return .java
        case "kt", "kts", "kotlin": return .kotlin
        case "rb", "ruby": return .ruby
        case "php": return .php
        case "sql", "mysql", "pgsql", "sqlite": return .sql
        case "html", "xml", "vue", "svelte": return .html
        case "css", "scss", "sass", "less": return .css
        default: return .text
        }
    }
}
#endif
