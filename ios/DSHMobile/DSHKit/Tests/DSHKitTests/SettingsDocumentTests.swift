import XCTest

@testable import DSHKit

/// 设置文档解析层的用例（spec 023 / S3b，T040）。
///
/// 这一层原来在 App 里、**一条测试都没有**：它是"宿主那份开放式 JSON 怎么解释"的全部规则——
/// 宽容解码、覆盖判定、凭据引用的发现规则。宿主加一个命名空间或改一个字段形状时，
/// 最容易悄悄走偏的就是这里，而界面上只会表现为"某一项显示不对"。
final class SettingsDocumentTests: XCTestCase {

    private func json(_ text: String) -> JSONValue {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    // MARK: - 宽容解码

    func testUnknownShapesDoNotFailTheDocument() {
        let document = SettingsDocument(raw: json(#"{"writable":true,"hasDocument":true,"namespaces":[{}, {"ns":"ui-theme"}]}"#))
        XCTAssertTrue(document.writable)
        XCTAssertTrue(document.hasDocument)
        // 没有 `ns` 的那一条被丢弃，认得的留下——不因为一条坏数据整页失败。
        XCTAssertEqual(document.namespaces.map(\.ns), ["ui-theme"])
    }

    func testMissingFieldsFallBackToDefaults() {
        let document = SettingsDocument(raw: json(#"{}"#))
        XCTAssertFalse(document.writable)
        XCTAssertFalse(document.hasDocument)
        XCTAssertTrue(document.namespaces.isEmpty)
    }

    func testNamespaceLookup() {
        let document = SettingsDocument(raw: json(#"{"namespaces":[{"ns":"locale"},{"ns":"ui-theme"}]}"#))
        XCTAssertEqual(document.namespace("ui-theme")?.ns, "ui-theme")
        XCTAssertNil(document.namespace("nope"))
    }

    func testRestartNamespaceIsRecognised() {
        let document = SettingsDocument(raw: json(#"{"namespaces":[{"ns":"a","applies":"restart"},{"ns":"b"}]}"#))
        XCTAssertTrue(document.namespace("a")?.needsRestart == true)
        XCTAssertFalse(document.namespace("b")?.needsRestart == true, "缺省是 live")
    }

    // MARK: - 覆盖判定

    func testOverrideIsPresenceInTheUserLayer() {
        let document = SettingsDocument(raw: json(#"{"namespaces":[{"ns":"a","user":{"x":{"y":1},"gone":null}}]}"#))
        let ns = document.namespace("a")
        XCTAssertEqual(ns?.isOverridden(at: ["x", "y"]), true)
        XCTAssertEqual(ns?.isOverridden(at: ["x"]), true, "整棵子树在用户层也算覆盖")
        XCTAssertEqual(ns?.isOverridden(at: ["gone"]), false, "显式 null 不算覆盖")
        XCTAssertEqual(ns?.isOverridden(at: ["nope"]), false)
    }

    // MARK: - 路径工具

    func testPathValueAndContains() {
        let root = json(#"{"a":{"b":[1,2]}}"#)
        XCTAssertEqual(SettingsPath.value(in: root, path: ["a", "b"])?.arrayValue?.count, 2)
        XCTAssertNil(SettingsPath.value(in: root, path: ["a", "z"]))
        XCTAssertTrue(SettingsPath.contains(root, path: ["a", "b"]))
        XCTAssertFalse(SettingsPath.contains(root, path: ["a", "z"]))
        XCTAssertEqual(SettingsPath.key(["a", "b"]), "a.b")
    }

    func testSettingCreatesIntermediateObjects() {
        let updated = SettingsPath.setting(json(#"{}"#), path: ["a", "b"], to: .string("v"))
        XCTAssertEqual(SettingsPath.value(in: updated, path: ["a", "b"])?.stringValue, "v")
        // 已有别的分支时不许把它们冲掉。
        let merged = SettingsPath.setting(updated, path: ["a", "c"], to: .string("w"))
        XCTAssertEqual(SettingsPath.value(in: merged, path: ["a", "b"])?.stringValue, "v")
        XCTAssertEqual(SettingsPath.value(in: merged, path: ["a", "c"])?.stringValue, "w")
    }

    func testRemovingTakesOnlyTheNamedLeaf() {
        let root = json(#"{"a":{"b":1,"c":2}}"#)
        let trimmed = SettingsPath.removing(root, path: ["a", "b"])
        XCTAssertNil(SettingsPath.value(in: trimmed, path: ["a", "b"]))
        XCTAssertEqual(SettingsPath.value(in: trimmed, path: ["a", "c"])?.intValue, 2)
        // 删不存在的路径不改动原结构。
        XCTAssertEqual(SettingsPath.value(in: SettingsPath.removing(root, path: ["a", "z"]), path: ["a", "c"])?.intValue, 2)
    }

    // MARK: - 凭据引用的发现规则

    /// `web-search-deepseek` 的形状：`apiKey` 是密钥，兄弟字段 `apiKeyEnv` 带 role 标记。
    private func namespaceWithPairedCredential() -> SettingsNamespace? {
        let document = SettingsDocument(raw: json(#"""
        {"namespaces":[{
          "ns":"web-search-deepseek",
          "value":{"apiKeyEnv":"DEEPSEEK_API_KEY"},
          "schema":{"uid":1,"refs":{
            "1":{"type":"object","dict":{"apiKey":2,"apiKeyEnv":3}},
            "2":{"type":"string","meta":{"role":"secret"}},
            "3":{"type":"string","meta":{"role":"credential-ref"}}
          }}
        }]}
        """#))
        return document.namespace("web-search-deepseek")
    }

    func testCredentialRefUsesTheDocumentedSibling() {
        let ref = namespaceWithPairedCredential()?.credentialRef(forSecretAt: ["apiKey"])
        XCTAssertEqual(ref?.name, "DEEPSEEK_API_KEY")
        XCTAssertEqual(ref?.path, ["apiKey"], "引用要指回被它命名的那个密钥槽")
    }

    func testCredentialRefRefusesWhenMetadataIsMissing() {
        // 没有 role 标记的兄弟字段：**不猜**，返回 nil（那一行保持只读）。
        let document = SettingsDocument(raw: json(#"""
        {"namespaces":[{
          "ns":"x",
          "value":{"apiKeyEnv":"SHOULD_NOT_BE_USED"},
          "schema":{"uid":1,"refs":{
            "1":{"type":"object","dict":{"apiKey":2,"apiKeyEnv":3}},
            "2":{"type":"string","meta":{"role":"secret"}},
            "3":{"type":"string"}
          }}
        }]}
        """#))
        XCTAssertNil(document.namespace("x")?.credentialRef(forSecretAt: ["apiKey"]))
    }

    func testCredentialRefUsesTheOnlyCandidateAsASectionWideFallback() {
        // 同父对象里没有兄弟字段，但整个 section 只有一个 credential-ref：可以用。
        let document = SettingsDocument(raw: json(#"""
        {"namespaces":[{
          "ns":"x",
          "value":{"env":{"KEY_NAME":"MY_KEY"}},
          "schema":{"uid":1,"refs":{
            "1":{"type":"object","dict":{"apiKey":2,"env":4}},
            "2":{"type":"string","meta":{"role":"secret"}},
            "4":{"type":"object","dict":{"KEY_NAME":3}},
            "3":{"type":"string","meta":{"role":"credential-ref"}}
          }}
        }]}
        """#))
        XCTAssertEqual(document.namespace("x")?.credentialRef(forSecretAt: ["apiKey"])?.name, "MY_KEY")
    }

    func testEmptyCredentialNameIsNotARef() {
        let document = SettingsDocument(raw: json(#"""
        {"namespaces":[{
          "ns":"x",
          "value":{"apiKeyEnv":""},
          "schema":{"uid":1,"refs":{
            "1":{"type":"object","dict":{"apiKey":2,"apiKeyEnv":3}},
            "2":{"type":"string","meta":{"role":"secret"}},
            "3":{"type":"string","meta":{"role":"credential-ref"}}
          }}
        }]}
        """#))
        XCTAssertNil(document.namespace("x")?.credentialRef(forSecretAt: ["apiKey"]))
    }

    // MARK: - 密钥槽

    func testSecretSlotsSkipEntriesWithoutAPath() {
        let document = SettingsDocument(raw: json(#"""
        {"namespaces":[{"ns":"x","secrets":[{"path":["apiKey"],"set":true},{"set":true},{"path":[]}]}]}
        """#))
        let slots = document.namespace("x")?.secrets ?? []
        XCTAssertEqual(slots.count, 1, "没路径或空路径的条目要跳过，不是造出一个空槽")
        XCTAssertEqual(slots.first?.path, ["apiKey"])
        XCTAssertEqual(slots.first?.isSet, true)
    }

    // MARK: - schema 里的数字 ref id

    func testSchemaResolvesNumericRefIDsFromTheEnvelope() {
        // refs 的键是十进制字符串、值里引用的是数字：必须在入口归一化，否则一条都查不到。
        let document = SettingsDocument(raw: json(#"""
        {"namespaces":[{
          "ns":"x",
          "value":{"outer":{"inner":"v"}},
          "schema":{"uid":1,"refs":{
            "1":{"type":"object","dict":{"outer":2}},
            "2":{"type":"object","dict":{"inner":3}},
            "3":{"type":"string"}
          }}
        }]}
        """#))
        let ns = document.namespace("x")
        XCTAssertEqual(ns?.credentialRef(forSecretAt: []) , nil)
        // 走到两层：能取到值就说明 ref 链解对了（否则 credentialRef 那条路早就断了）。
        XCTAssertEqual(SettingsPath.value(in: ns?.value, path: ["outer", "inner"])?.stringValue, "v")
    }
}
