import DSHKit
import Foundation

// 解析层已搬进 DSHKit（`Sources/DSHKit/Settings/SettingsDocument.swift`，spec 023 的 S3b）：
// 打开面的 JSON 怎么解释、哪些项被覆盖、凭据引用叫什么名字，都在那边并有单测。
// 本文件只剩**文案**（`SettingsLabels`）与一处给分区标题用的扩展。

// MARK: - Labels

/// Desktop-matching copy for namespaces, fields and enum values.
///
/// The settings document only carries machine names. Translating the ones the
/// desktop client already names keeps the two clients reading identically, and
/// anything unknown falls back to the raw key so a new DSH field is still
/// visible rather than blank.
public enum SettingsLabels {

    private static let namespaceTitles: [String: String] = [
        "agent-default-model": "默认模型",
        "subagent-model-selection": "子代理模型",
        "ui-theme": "外观",
        "locale": "语言与区域",
        "ui-onboarding": "新手引导",
        "ui-conversation": "对话输入",
        "ui-chat": "对话显示",
        "web-search-deepseek": "网页搜索",
        "llm-deepseek": "模型适配器 · DeepSeek",
        "llm-pi-ai": "模型适配器 · 自定义提供方",
        "agent-loop": "代理循环",
        "agent-presets": "代理预设",
        "shell": "终端",
        "permission": "权限",
    ]

    private static let fieldLabels: [String: String] = [
        "enabled": "启用",
        "allowedModels": "可选择的模型",
        "preference": "偏好",
        "fontSize": "字号大小",
        "welcomeNoticeVersion": "欢迎提示版本",
        "busyEnter": "繁忙时的发送行为",
        "transcriptView": "对话显示",
        "apiKey": "API 密钥",
        "apiKeyEnv": "凭证引用",
        "baseURL": "接口地址",
        "apiVersion": "API 版本",
        "maxTokens": "最大输出 token 数",
        "maxUses": "单次请求最多搜索次数",
        "defaultContextWindow": "默认上下文窗口",
        "models": "模型目录",
        "streamIdleTimeoutMs": "单流空闲超时（毫秒）",
        "maxRequestFilesBytes": "单次请求文件上限（字节）",
        "maxInlineRequestImageBytes": "内联图片上限（字节）",
        "maxImagesPerRequest": "单次请求图片数",
        "imageOffloadByteQuantum": "图片转存字节量子",
        "inlineImageOffloadByteQuantum": "内联图片转存量子",
        "imageOffloadCountQuantum": "图片转存数量量子",
        "filesApiTimeoutMs": "文件接口超时（毫秒）",
        "fileExpiresAfterSeconds": "文件过期时间（秒）",
        "fileRefreshMarginSeconds": "文件刷新余量（秒）",
        "fileQuotaCleanupBatch": "配额清理批量",
        "maxParallelToolCalls": "并行工具调用数",
        "cwd": "工作目录",
        "timeoutMs": "命令超时（毫秒）",
        "maxTimeoutMs": "最大超时（毫秒）",
        "maxOutputBytes": "输出上限（字节）",
        "maxSpillBytes": "溢出转存上限（字节）",
        "graceMs": "终止宽限期（毫秒）",
        "defaultPreset": "默认权限模式",
        "default": "默认预设",
        "providers": "提供方",
        "mode": "模式",
        "maxRetries": "最大重试次数",
        "retryableCodes": "可重试的错误码",
        "backoff": "退避策略",
        "initialDelayMs": "初始延迟（毫秒）",
        "maxDelayMs": "最大延迟（毫秒）",
        "jitterRatio": "抖动比例",
        "id": "标识",
        "name": "显示名称",
        "description": "说明",
        "contextWindow": "上下文窗口",
        "inputModalities": "输入模态",
        "imagePixelBudget": "图片像素预算",
        "imageMaxBytes": "图片字节上限",
        "systemPromptUpdate": "系统提示词更新",
        "thinking": "思考",
        "omitWhenOff": "关闭时省略",
        "minimal": "最低",
        "low": "低",
        "medium": "中",
        "high": "高",
    ]

    private static let valueLabels: [String: String] = [
        "light": "浅色",
        "dark": "深色",
        "system": "跟随系统",
        "queue": "排队发送",
        "steer": "插话发送",
        "enabled": "启用",
        "disabled": "关闭",
        "off": "关闭",
        "max": "最高",
        "normal": "标准",
        "compact": "紧凑",
        "read-only": "仅可查看",
        "workspace-write": "工作区内修改",
        "danger-full-access": "完全权限",
        "text": "文本",
        "image": "图片",
        "always": "总是",
        "in-history": "历史中",
        "thinking.enabled": "启用思考",
        "thinking.effort": "思考强度",
        "thinking.budget": "思考预算",
        "low": "低",
        "medium": "中",
        "high": "高",
    ]

    /// A field whose name collides across namespaces needs its parent's help.
    /// 表里存的是中文标签，出口统一本地化一次：这些字符串不是 `Text` 字面量，
    /// 不包一层就不会走 Localizable.strings（设置页曾经整页中文就是这么来的）。
    private static func localized(_ text: String) -> String {
        String(localized: String.LocalizationValue(text))
    }

    static func fieldLabel(_ name: String, namespace: String, path: [String]) -> String {
        if name == "preference" {
            if namespace == "ui-theme" { return localized("外观") }
            if namespace == "locale" { return localized("语言") }
        }
        if name == "default" { return localized(path.count > 1 ? "默认值" : "默认预设") }
        return localized(fieldLabels[name] ?? name)
    }

    static func namespaceTitle(_ ns: String) -> String { localized(namespaceTitles[ns] ?? ns) }

    static func valueLabel(_ value: JSONValue, fallback: String) -> String {
        guard let raw = value.stringValue else { return fallback }
        return localized(valueLabels[raw] ?? raw)
    }

    /// Orders fields the way a person scans them: switches and the primary
    /// choice first, then provider/model identity, then the long tail
    /// alphabetically.
    static func sortRank(_ name: String) -> Int {
        switch name {
        case "enabled": return 0
        case "preference", "defaultPreset", "default": return 1
        case "provider": return 2
        case "model": return 3
        case "reasoningEffort": return 4
        case "transcriptView", "busyEnter", "fontSize": return 5
        case "defaultContextWindow": return 6
        case "maxTokens": return 7
        default: return 100
        }
    }

    /// A plain-language hint derived from the schema's own constraints.
    static func patternHint(_ meta: [String: JSONValue]) -> String? {
        guard meta["pattern"] != nil else { return nil }
        return String(localized: "需匹配主机要求的格式")
    }
}

public enum SettingsValueText {

    static func summary(value: JSONValue?) -> String {
        guard let value else { return "—" }
        switch value {
        case .null: return "—"
        case .bool(let flag): return flag ? String(localized: "开") : String(localized: "关")
        case .int, .double: return numberText(value)
        case .string(let text): return text.isEmpty ? String(localized: "（空）") : text
        case .array(let items):
            if items.isEmpty { return String(localized: "（空列表）") }
            if items.count <= 3, items.allSatisfy({ $0.stringValue != nil || $0.intValue != nil || $0.boolValue != nil }) {
                return items.map { scalarText($0) }.joined(separator: "、")
            }
            return String(localized: "\(items.count) 项")
        case .object(let object):
            if object.isEmpty { return String(localized: "（空对象）") }
            return object.keys.sorted().prefix(3).joined(separator: "、") + (object.count > 3 ? " …" : "")
        }
    }

    private static func scalarText(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): return text
        case .int, .double: return numberText(value)
        case .bool(let flag): return flag ? String(localized: "开") : String(localized: "关")
        default: return value.compactDescription
        }
    }

    /// Integer values render without a decimal tail; sizes get digit grouping.
    static func numberText(_ value: JSONValue) -> String {
        if let int = value.intValue, value.doubleValue.map({ $0.rounded() == $0 }) == true {
            return int.formatted(.number.grouping(.automatic))
        }
        if let double = value.doubleValue {
            return double.formatted(.number.precision(.fractionLength(0...4)))
        }
        return value.compactDescription
    }

    /// A pretty-printed rendering for raw disclosures.
    public static func pretty(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return value.compactDescription
        }
        return text
    }
}

// MARK: - 分区标题

public extension SettingsNamespace {
    /// The section title the desktop client would use.
    ///
    /// 文案留在 App：它是界面语言，由 `check:i18n` 与 `Localizable.strings` 管；
    /// 解析层（DSHKit）不认识"外观""语言与区域"这些词。
    public var title: String { SettingsLabels.namespaceTitle(ns) }
}
