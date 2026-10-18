import XCTest
@testable import DSHKit

/// 「打开子会话」这条详情路径（活动面板的行、转写里 subagent 卡的「打开子会话 ›」）
/// 唯一的输入是列表行 → `SessionSummary.address`。宿主对这个地址做 **mode 校验**：
/// 传一个和真身不符的 mode，就回 `subagent/unauthorized`
/// （"subagent mode does not match the supplied address"）；只有 `mode:"unknown"`
/// 跳过校验（`dsh-api-session-controller` 的 `validateAddress`）。
///
/// 实测（2026-10-19 本机 `session/list`，317 条 `origin:"subagent"` 行）：
/// 194 条**没有** `projections.values.subagent`（嵌套子智能体、历史行）。按
/// `.oneShot` 猜着去问其中 60 条，**25 条被宿主拒为 `subagent/unauthorized`**
/// ——这就是"有的子智能体点开是报错、有的又是对的"：被拒的是真身
/// `continuable`、被我们按一次性猜的那些。
///
/// 这几条用例是**红线**：现在的实现不满足（会红），修好后自动转绿。判据取自
/// 宿主自己的校验规则，不是对实现的复述。
final class SubagentAddressModeTests: XCTestCase {

    // MARK: - Helpers

    private func decodeRow(_ json: String) throws -> SessionSummary {
        try JSONDecoder().decode(SessionSummary.self, from: Data(json.utf8))
    }

    /// 地址发出去时 `mode` 到底是什么串：红线断言看这一个值。
    private func wireMode(of address: SessionAddress) throws -> String? {
        let data = try JSONEncoder().encode(address)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "address must encode as an object"
        )
        return object["mode"] as? String
    }

    /// 一行的公共外壳：子会话行，只改 `values` 里有什么。
    private func row(values: String, parent: String = "parent-1") -> String {
        """
        {"sessionId":"child-1","updatedAt":1791815149814,"running":false,"blank":false,
         "parentSessionId":"\(parent)","origin":"subagent",
         "projections":{"asOfSeq":12,"values":{\(values)}}}
        """
    }

    // MARK: - 红线：拿不到 mode 不许猜

    /// 没有 `subagent` 投影（本机 194/317 条就是这样）时，地址的 mode 必须是
    /// 宿主会放行的 `unknown`，不能猜成 `one-shot`。
    ///
    /// 猜错的后果是确定的：宿主拿真实 mode 比对，不符即拒；而 `unknown` 明写在
    /// 宿主的校验里，是"不知道"的唯一合法表达。
    func testRowWithoutSubagentProjectionSendsUnknownMode() throws {
        let summary = try decodeRow(row(values: ""))
        XCTAssertEqual(summary.subagentMode, nil, "没有投影就没有 mode 可读")
        XCTAssertEqual(
            try wireMode(of: summary.address), "unknown",
            "拿不到 mode 时只能发 unknown；猜成 one-shot 会让真身为 continuable 的子会话打不开（宿主回 subagent/unauthorized）"
        )
    }

    /// 投影里是**这一版不认识**的 mode（宿主已有 `external`，桌面端也显示，
    /// 见 `dsh-subagent` 的 catalog：`one-shot` / `continuable` / `external`）时，
    /// 同样不许降级成 `one-shot`。
    func testUnrecognizedModeIsNotDowngradedToOneShot() throws {
        let summary = try XCTUnwrap(
            try? decodeRow(row(values: #""subagent":{"mode":"external","label":"外部任务"}"#)),
            "宿主给出这一版不认识的 mode 时，整条列表行仍必须能解码：一行解不开就是整份 session/list 解不开"
        )
        XCTAssertNotEqual(
            try wireMode(of: summary.address), "one-shot",
            "不认识的 mode 不是 one-shot 的同义词；猜错等于把能打开的会话变成报错页"
        )
    }

    /// 同一件事的另一面：地址本身解码时，不认识的 mode 也不许被静默改成
    /// `one-shot`（`SessionAddress.init(from:)` 里那句 `?? .oneShot`）。
    func testAddressDecodingDoesNotCoerceUnknownMode() throws {
        let json = #"{"kind":"subagent","parentSessionId":"p","childSessionId":"c","mode":"external"}"#
        guard let address = try? JSONDecoder().decode(SessionAddress.self, from: Data(json.utf8)) else {
            return // 解码直接拒绝也可以：只要不是"悄悄当成 one-shot"
        }
        XCTAssertNotEqual(
            try wireMode(of: address), "one-shot",
            "无法表达的 mode 不能被改写成 one-shot"
        )
    }

    // MARK: - 不该被"改坏"的既有行为

    /// 拿得到 mode 的行必须原样发出去：修"不许猜"不能把确定的值也抹成 unknown。
    func testKnownModeIsSentVerbatim() throws {
        let continuable = try decodeRow(row(values: #""subagent":{"mode":"continuable","label":"审查契约","seq":3}"#))
        XCTAssertEqual(try wireMode(of: continuable.address), "continuable")
        XCTAssertEqual(continuable.subagentLabel, "审查契约")

        let oneShot = try decodeRow(row(values: #""subagent":{"mode":"one-shot"}"#))
        XCTAssertEqual(try wireMode(of: oneShot.address), "one-shot")
    }

    /// 子会话地址的另外两个字段（父 id、子 id）无论 mode 从哪来都不能变。
    func testParentAndChildIdentityAreIndependentOfMode() throws {
        for values in ["", #""subagent":{"mode":"continuable"}"#] {
            let summary = try decodeRow(row(values: values, parent: "parent-9"))
            guard case .subagent(let parent, let child, _) = summary.address else {
                return XCTFail("origin=subagent 且带 parentSessionId 的行必须是子会话地址")
            }
            XCTAssertEqual(parent, "parent-9")
            XCTAssertEqual(child, "child-1")
        }
    }
}
