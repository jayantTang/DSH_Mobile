@testable import DSHChatDomain
import XCTest

final class AssistantTextSplitterTests: XCTestCase {

    func test_a_short_message_is_not_split() {
        let text = "第一段\n\n第二段"
        XCTAssertEqual(AssistantTextSplitter.split(text), [text])
    }

    func test_a_fenced_code_block_is_never_split() {
        let code = "```swift\n" + String(repeating: "let value = 1\n", count: 80) + "```"
        let parts = AssistantTextSplitter.split("开头\n\n" + code, maxChars: 200)
        XCTAssertTrue(parts.contains { $0.contains("```swift") && $0.hasSuffix("```") },
                      "围栏必须整块保留：\(parts)")
        XCTAssertTrue(parts.allSatisfy { $0.contains("```") == false || ($0.hasPrefix("```") || $0.contains("```swift")) })
    }

    func test_a_long_table_repeats_the_header_and_splits_rows() {
        let header = "| 项目 | 结果 |"
        let separator = "| --- | --- |"
        let rows = (1...30).map { "| 第\($0)行 | ok |" }
        let text = ([header, separator] + rows).joined(separator: "\n")
        let parts = AssistantTextSplitter.split(text, maxChars: 200, tableRowsPerChunk: 10)
        XCTAssertGreaterThan(parts.count, 1)
        // 每段都以表头/分隔行开头，行数不超过 12（10 行数据 + 2 行表头）。
        for part in parts {
            let lines = part.components(separatedBy: "\n")
            XCTAssertEqual(lines[0], header)
            XCTAssertEqual(lines[1], separator)
            XCTAssertLessThanOrEqual(lines.count, 12)
        }
        XCTAssertTrue(parts.first?.contains("第1行") == true)
        XCTAssertTrue(parts.last?.contains("第30行") == true)
    }

    func test_a_long_paragraph_is_split_under_the_limit() {
        let paragraph = (1...120).map { "第\($0)句说明。" }.joined()
        let parts = AssistantTextSplitter.split(paragraph, maxChars: 200)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 220 }, "parts: \(parts.map(\.count))")
        XCTAssertEqual(parts.joined().replacingOccurrences(of: "\n", with: ""), paragraph)
    }

    func test_paragraphs_are_grouped_up_to_the_limit() {
        let text = (1...20).map { "第\($0)段，" + String(repeating: "内容", count: 30) }.joined(separator: "\n\n")
        let parts = AssistantTextSplitter.split(text, maxChars: 300)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 320 })
        XCTAssertEqual(parts.joined(separator: "\n\n"), text)
    }
}
