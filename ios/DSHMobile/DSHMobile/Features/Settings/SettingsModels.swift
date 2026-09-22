import DSHKit
import Foundation

// MARK: - The settings document

/// The `settings/describe` answer.
///
/// The document is open-ended: a DSH release can register a namespace, or a
/// field inside one, that this build has never seen. Everything here therefore
/// decodes lossily and keeps the raw `JSONValue` beside the interpreted view, so
/// an unrecognized shape renders read-only instead of failing the screen.
struct SettingsDocument: Sendable {
    let writable: Bool
    let hasDocument: Bool
    let namespaces: [SettingsNamespace]
    /// The response verbatim, for the "原始设置文档" disclosure.
    let raw: JSONValue

    init(raw: JSONValue) {
        self.raw = raw
        let object = raw.objectValue ?? [:]
        writable = object["writable"]?.boolValue ?? false
        hasDocument = object["hasDocument"]?.boolValue ?? false
        namespaces = (object["namespaces"]?.arrayValue ?? [])
            .compactMap { SettingsNamespace(json: $0) }
    }

    func namespace(_ id: String) -> SettingsNamespace? {
        namespaces.first { $0.ns == id }
    }
}

/// One namespace as the host reports it.
///
/// `value` is the redacted resolved value (defaults → base → user), `user` is the
/// raw user layer (a field's presence there means the user overrode it), and
/// `secrets` names every schema-declared secret slot without its value.
struct SettingsNamespace: Sendable, Identifiable {
    let ns: String
    let schema: SettingsSchema
    let value: JSONValue
    let base: JSONValue?
    let user: JSONValue?
    let applies: String
    let secrets: [SettingsSecretSlot]
    let revision: Int
    /// The decoded slice of the raw response, kept for the raw disclosure.
    let raw: JSONValue

    var id: String { ns }

    /// `restart` namespaces only take effect after the host is restarted.
    var needsRestart: Bool { applies == "restart" }

    /// The section title the desktop client would use.
    var title: String { SettingsLabels.namespaceTitle(ns) }

    init?(json: JSONValue) {
        guard let ns = json["ns"]?.stringValue else { return nil }
        self.ns = ns
        self.raw = json
        self.schema = SettingsSchema(envelope: json["schema"] ?? .null)
        self.value = json["value"] ?? .null
        self.base = json["base"]
        self.user = json["user"]
        self.applies = json["applies"]?.stringValue ?? "live"
        self.revision = json["revision"]?.intValue ?? 0
        self.secrets = (json["secrets"]?.arrayValue ?? []).compactMap { slot in
            guard let path = slot["path"]?.arrayValue?.compactMap(\.stringValue), !path.isEmpty else { return nil }
            return SettingsSecretSlot(path: path, isSet: slot["set"]?.boolValue ?? false)
        }
    }

    /// Every secret slot's path, keyed for quick lookup.
    func secretSlot(at path: [String]) -> SettingsSecretSlot? {
        secrets.first { $0.path == path }
    }

    /// Whether the user layer holds a value at `path`.
    func isOverridden(at path: [String]) -> Bool {
        SettingsPath.contains(user, path: path)
    }

    /// The credential reference that owns a secret slot, when the schema makes
    /// one discoverable.
    ///
    /// The desktop settings surface writes a secret through the credentials
    /// domain rather than through the settings section. The reference is named by
    /// a sibling field carrying `role: "credential-ref"` — `web-search-deepseek`
    /// pairs `apiKey` with `apiKeyEnv` (default `DEEPSEEK_API_KEY`). Without that
    /// sibling there is no safe way to name the credential, so the row stays
    /// read-only instead of guessing.
    func credentialRef(forSecretAt path: [String]) -> SettingsCredentialRef? {
        guard let field = path.last else { return nil }
        let parent = Array(path.dropLast())
        let parentRef = schema.ref(at: parent) ?? schema.root

        // Prefer the documented pairing inside the same parent object.
        if let parentRef, let dict = parentRef.dict {
            let candidates = dict.compactMap { key, refID -> String? in
                guard schema.ref(refID)?.meta["role"]?.stringValue == "credential-ref" else { return nil }
                return key
            }
            let preferred = SettingsLabels.credentialRefSibling[field]
            let chosen = candidates.first { $0 == preferred } ?? (candidates.count == 1 ? candidates[0] : nil)
            if let chosen, let name = SettingsPath.value(in: value, path: parent + [chosen])?.stringValue,
               !name.isEmpty {
                return SettingsCredentialRef(name: name, path: path)
            }
        }

        // A section-wide fallback: exactly one credential-ref field anywhere.
        var names: [[String]] = []
        collectCredentialRefs(schema: schema, refID: schema.rootID, path: [], into: &names)
        if names.count == 1, let name = SettingsPath.value(in: value, path: names[0])?.stringValue, !name.isEmpty {
            return SettingsCredentialRef(name: name, path: path)
        }
        return nil
    }

    private func collectCredentialRefs(
        schema: SettingsSchema,
        refID: String?,
        path: [String],
        into names: inout [[String]]
    ) {
        guard let ref = schema.ref(refID), names.count <= 1 else { return }
        if ref.meta["role"]?.stringValue == "credential-ref" {
            names.append(path)
            return
        }
        for (key, childID) in (ref.dict ?? [:]).sorted(by: { $0.key < $1.key }) {
            collectCredentialRefs(schema: schema, refID: childID, path: path + [key], into: &names)
        }
    }
}

/// One schema-declared secret slot.
struct SettingsSecretSlot: Sendable, Hashable {
    let path: [String]
    let isSet: Bool
}

/// A secret slot paired with the credential reference that stores it.
struct SettingsCredentialRef: Sendable, Hashable {
    let name: String
    let path: [String]
}

// MARK: - The schemastery envelope

/// The serialized schemastery envelope a namespace ships (`schema.toJSON()`).
///
/// Shape: `{ "uid": <refId>, "refs": { "<refId>": <descriptor> } }` where a
/// descriptor is `{ type, meta, dict?, list?, inner?, value? }`. `dict` maps a
/// field name to another ref id, `list` holds union member refs, `inner` names an
/// array's element ref, and `value` carries a `const`'s literal.
///
/// Schemastery serializes every ref id as a **number** while the `refs` map is
/// keyed by their decimal strings, so each reference is normalized on the way in.
struct SettingsSchema: Sendable {
    let rootID: String?
    private let refs: [String: JSONValue]

    init(envelope: JSONValue) {
        rootID = envelope["uid"].map { String($0.intValue ?? 0) }
        refs = envelope["refs"]?.objectValue ?? [:]
    }

    var root: SettingsSchemaRef? { ref(rootID) }

    func ref(_ id: String?) -> SettingsSchemaRef? {
        guard let id, let json = refs[id] else { return nil }
        return SettingsSchemaRef(id: id, json: json, siblings: refs)
    }

    /// Resolves a path of object keys to the descriptor that types it.
    func ref(at path: [String]) -> SettingsSchemaRef? {
        var current = root
        for key in path {
            guard let ref = current, let childID = ref.dict?[key] else { return nil }
            current = self.ref(childID)
        }
        return current
    }
}

/// One descriptor inside a schema envelope.
struct SettingsSchemaRef: Sendable {
    let id: String
    let type: String
    let meta: [String: JSONValue]
    let dict: [String: String]?
    let list: [String]?
    let inner: String?
    let constValue: JSONValue?
    /// The whole ref map, retained so union members resolve without re-decoding.
    private let siblings: [String: JSONValue]

    init(id: String, json: JSONValue, siblings: [String: JSONValue] = [:]) {
        self.id = id
        self.type = json["type"]?.stringValue ?? "unknown"
        self.meta = json["meta"]?.objectValue ?? [:]
        self.dict = json["dict"]?.objectValue?.compactMapValues(Self.refID)
        self.list = json["list"]?.arrayValue?.compactMap(Self.refID)
        self.inner = Self.refID(json["inner"])
        self.constValue = json["const"] ?? json["value"]
        self.siblings = siblings
    }

    func member(_ id: String) -> SettingsSchemaRef? {
        guard let json = siblings[id] else { return nil }
        return SettingsSchemaRef(id: id, json: json, siblings: siblings)
    }

    /// A ref id is a JSON number in the envelope and a decimal string in the map.
    static func refID(_ value: JSONValue?) -> String? {
        if let text = value?.stringValue, !text.isEmpty { return text }
        if let number = value?.intValue { return String(number) }
        return nil
    }
}

// MARK: - Interpreted fields

enum SettingsPath {
    static func key(_ path: [String]) -> String { path.joined(separator: ".") }

    /// Whether `json` holds a value at `path`.
    static func contains(_ json: JSONValue?, path: [String]) -> Bool {
        guard !path.isEmpty else { return json != nil && json?.isNull == false }
        guard let json else { return false }
        var current = json
        for (index, key) in path.enumerated() {
            guard case .object(let object) = current, let next = object[key] else { return false }
            current = next
            if index == path.count - 1 { return !current.isNull }
        }
        return false
    }

    static func value(in json: JSONValue?, path: [String]) -> JSONValue? {
        guard let json else { return nil }
        var current = json
        for key in path {
            guard case .object(let object) = current, let next = object[key] else { return nil }
            current = next
        }
        return current
    }

    /// Returns `json` with `value` written at `path`, creating objects as needed.
    static func setting(_ json: JSONValue, path: [String], to value: JSONValue) -> JSONValue {
        guard let head = path.first else { return value }
        var object: [String: JSONValue]
        if case .object(let existing) = json { object = existing } else { object = [:] }
        object[head] = setting(object[head] ?? .object([:]), path: Array(path.dropFirst()), to: value)
        return .object(object)
    }

    /// Returns `json` with the value at `path` removed.
    static func removing(_ json: JSONValue, path: [String]) -> JSONValue {
        guard let head = path.first else { return json }
        guard case .object(var object) = json else { return json }
        if path.count == 1 {
            object.removeValue(forKey: head)
        } else if let child = object[head] {
            object[head] = removing(child, path: Array(path.dropFirst()))
        }
        return .object(object)
    }
}

// MARK: - Labels

/// Desktop-matching copy for namespaces, fields and enum values.
///
/// The settings document only carries machine names. Translating the ones the
/// desktop client already names keeps the two clients reading identically, and
/// anything unknown falls back to the raw key so a new DSH field is still
/// visible rather than blank.
enum SettingsLabels {

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

    /// The sibling field that names a secret's credential reference.
    static let credentialRefSibling: [String: String] = [
        "apiKey": "apiKeyEnv",
        "key": "keyEnv",
        "token": "tokenEnv",
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
        return "需匹配主机要求的格式"
    }
}

enum SettingsValueText {

    static func summary(value: JSONValue?) -> String {
        guard let value else { return "—" }
        switch value {
        case .null: return "—"
        case .bool(let flag): return flag ? "开" : "关"
        case .int, .double: return numberText(value)
        case .string(let text): return text.isEmpty ? "（空）" : text
        case .array(let items):
            if items.isEmpty { return "（空列表）" }
            if items.count <= 3, items.allSatisfy({ $0.stringValue != nil || $0.intValue != nil || $0.boolValue != nil }) {
                return items.map { scalarText($0) }.joined(separator: "、")
            }
            return "\(items.count) 项"
        case .object(let object):
            if object.isEmpty { return "（空对象）" }
            return object.keys.sorted().prefix(3).joined(separator: "、") + (object.count > 3 ? " …" : "")
        }
    }

    private static func scalarText(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): return text
        case .int, .double: return numberText(value)
        case .bool(let flag): return flag ? "开" : "关"
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
    static func pretty(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return value.compactDescription
        }
        return text
    }
}
