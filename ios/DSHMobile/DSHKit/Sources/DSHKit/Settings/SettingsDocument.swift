import Foundation

// 设置文档的**解析层**（spec 023 的 S3b：纯解析下沉）。
//
// 这一半原来整块住在 App 的 `Features/Settings/SettingsModels.swift` 里，和面向用户的文案
// （`SettingsLabels`）混在同一个文件。其中"把宿主那份开放式 JSON 解析成结构"是纯逻辑、
// 与界面无关，而且**今天一条测试都没有**——宿主加一个命名空间或字段时最容易悄悄走偏的地方。
//
// 分工：**解析与判定在这里**（有单测）；**文案在 App**（`check:i18n` 管着它们），
// 所以 `SettingsNamespace.title` 是 App 侧的一个扩展，不在本文件里。
//
// 导出面的边界（SC-001 的账要记）：App 只用到 `SettingsDocument` / `SettingsNamespace` /
// `SettingsPath`，外加两个出现在签名里的值类型（`SettingsSecretSlot` / `SettingsCredentialRef`）。
// `SettingsSchema` 与 `SettingsSchemaRef` 是解析内部件，**保持 internal**——App 从不直接摸它们。

// MARK: - The settings document

/// The `settings/describe` answer.
///
/// The document is open-ended: a DSH release can register a namespace, or a
/// field inside one, that this build has never seen. Everything here therefore
/// decodes lossily and keeps the raw `JSONValue` beside the interpreted view, so
/// an unrecognized shape renders read-only instead of failing the screen.
public struct SettingsDocument: Sendable {
    public let writable: Bool
    public let hasDocument: Bool
    public let namespaces: [SettingsNamespace]
    /// The response verbatim, for the "原始设置文档" disclosure.
    public let raw: JSONValue

    public init(raw: JSONValue) {
        self.raw = raw
        let object = raw.objectValue ?? [:]
        writable = object["writable"]?.boolValue ?? false
        hasDocument = object["hasDocument"]?.boolValue ?? false
        namespaces = (object["namespaces"]?.arrayValue ?? [])
            .compactMap { SettingsNamespace(json: $0) }
    }

    public func namespace(_ id: String) -> SettingsNamespace? {
        namespaces.first { $0.ns == id }
    }
}

/// One namespace as the host reports it.
///
/// `value` is the redacted resolved value (defaults → base → user), `user` is the
/// raw user layer (a field's presence there means the user overrode it), and
/// `secrets` names every schema-declared secret slot without its value.
public struct SettingsNamespace: Sendable, Identifiable {
    public let ns: String
    /// 只有 App 侧渲染用得到；解析内部件不为它开导出面（见文件头注）。
    let schema: SettingsSchema
    public let value: JSONValue
    public let base: JSONValue?
    public let user: JSONValue?
    public let applies: String
    public let secrets: [SettingsSecretSlot]
    public let revision: Int
    /// The decoded slice of the raw response, kept for the raw disclosure.
    public let raw: JSONValue

    public var id: String { ns }

    /// `restart` namespaces only take effect after the host is restarted.
    public var needsRestart: Bool { applies == "restart" }

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
    public func isOverridden(at path: [String]) -> Bool {
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
    public func credentialRef(forSecretAt path: [String]) -> SettingsCredentialRef? {
        guard let field = path.last else { return nil }
        let parent = Array(path.dropLast())
        let parentRef = schema.ref(at: parent) ?? schema.root

        // Prefer the documented pairing inside the same parent object.
        if let parentRef, let dict = parentRef.dict {
            let candidates = dict.compactMap { key, refID -> String? in
                guard schema.ref(refID)?.meta["role"]?.stringValue == "credential-ref" else { return nil }
                return key
            }
            let preferred = Self.credentialRefSibling[field]
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

    /// The sibling field that names a secret's credential reference.
    ///
    /// 这是**数据结构**（哪个字段配哪个兄弟字段），不是界面文案，所以跟着解析层走。
    static let credentialRefSibling: [String: String] = [
        "apiKey": "apiKeyEnv",
        "key": "keyEnv",
        "token": "tokenEnv",
    ]

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
public struct SettingsSecretSlot: Sendable, Hashable {
    public let path: [String]
    public let isSet: Bool

    public init(path: [String], isSet: Bool) {
        self.path = path
        self.isSet = isSet
    }
}

/// A secret slot paired with the credential reference that stores it.
public struct SettingsCredentialRef: Sendable, Hashable {
    public let name: String
    public let path: [String]

    public init(name: String, path: [String]) {
        self.name = name
        self.path = path
    }
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

/// 在 JSON 里按路径取值 / 写值 / 删值：设置页的读写都走它（纯函数，配单测）。
public enum SettingsPath {
    public static func key(_ path: [String]) -> String { path.joined(separator: ".") }

    /// Whether `json` holds a value at `path`.
    public static func contains(_ json: JSONValue?, path: [String]) -> Bool {
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

    public static func value(in json: JSONValue?, path: [String]) -> JSONValue? {
        guard let json else { return nil }
        var current = json
        for key in path {
            guard case .object(let object) = current, let next = object[key] else { return nil }
            current = next
        }
        return current
    }

    /// Returns `json` with `value` written at `path`, creating objects as needed.
    public static func setting(_ json: JSONValue, path: [String], to value: JSONValue) -> JSONValue {
        guard let head = path.first else { return value }
        var object: [String: JSONValue]
        if case .object(let existing) = json { object = existing } else { object = [:] }
        object[head] = setting(object[head] ?? .object([:]), path: Array(path.dropFirst()), to: value)
        return .object(object)
    }

    /// Returns `json` with the value at `path` removed.
    public static func removing(_ json: JSONValue, path: [String]) -> JSONValue {
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
