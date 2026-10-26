import DSHKit
import Foundation

/// 收起态运行行的唯一文本口径：`12 步 · 思考 328 字` / `12 步 · 命令 git status`。
/// 纯值、无视图依赖；字数由调用方从流式正文取，命令/动作来自 `runningDetail`。
public struct RunningLineDescriptor: Equatable, Sendable {
    public let stepCount: Int
    public let activity: TimelineProcessActivity?
    public let detail: String
    public let generatedChars: Int

    public init(stepCount: Int, activity: TimelineProcessActivity?,
                detail: String, generatedChars: Int) {
        self.stepCount = max(0, stepCount)
        self.activity = activity
        self.detail = detail
        self.generatedChars = max(0, generatedChars)
    }

    public var text: String {
        var parts: [String] = []
        if stepCount > 0 { parts.append(String(localized: "\(stepCount) 步")) }
        if let activity {
            let label = Self.label(activity)
            parts.append(detail.isEmpty ? label : "\(label) \(detail)")
        } else if generatedChars > 0 {
            parts.append(String(localized: "思考 \(generatedChars) 字"))
        } else {
            parts.append(String(localized: "思考中"))
        }
        return parts.joined(separator: " · ")
    }

    static func label(_ activity: TimelineProcessActivity) -> String {
        switch activity {
        case .read: return String(localized: "读取")
        case .write: return String(localized: "写入")
        case .edit: return String(localized: "编辑")
        case .search: return String(localized: "搜索")
        case .commands: return String(localized: "命令")
        case .code: return String(localized: "代码")
        case .web: return String(localized: "网页")
        case .subagents: return String(localized: "子代理")
        case .questions: return String(localized: "提问")
        case .plan: return String(localized: "计划")
        case .tools: return String(localized: "工具")
        }
    }
}
