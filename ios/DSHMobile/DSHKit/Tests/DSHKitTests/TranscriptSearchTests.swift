import XCTest
@testable import DSHKit

/// 会话内搜索：命中的角色、只看我的、片段与高亮偏移。
final class TranscriptSearchTests: XCTestCase {

    private func user(_ id: String, seq: Int, _ text: String) -> TimelineItem {
        TimelineItem(id: id, kind: .userMessage(text: text, images: [], isSteering: false,
                                                isPending: false, isAgentSent: false), seq: seq)
    }

    private func assistant(_ id: String, seq: Int, _ text: String) -> TimelineItem {
        TimelineItem(id: id, kind: .assistantText(text: text), seq: seq)
    }

    private func tool(_ id: String, seq: Int, name: String, summary: String, result: String) -> TimelineItem {
        var invocation = ToolInvocation(callId: "c\(seq)", name: name, arguments: "{}",
                                        summary: summary, resultBlocks: [], isError: false,
                                        isRunning: false, turn: 1, step: 1)
        if !result.isEmpty { invocation.resultBlocks = [.text(result)] }
        return TimelineItem(id: id, kind: .toolCall(invocation), seq: seq)
    }

    private func reasoning(_ id: String, seq: Int, _ text: String) -> TimelineItem {
        TimelineItem(id: id, kind: .reasoning(text: text), seq: seq)
    }

    func testEmptyQueryFindsNothing() {
        let items = [user("u1", seq: 1, "历史记录在哪里看"), assistant("a1", seq: 2, "在设置里")]
        XCTAssertTrue(TranscriptSearch.hits(in: items, query: "   ").isEmpty)
    }

    func testMatchesAllRolesAndOrdersNewestFirst() {
        let items = [
            user("u1", seq: 1, "先问 History 是什么"),
            assistant("a1", seq: 2, "History 是一个私密枢纽"),
            tool("t1", seq: 3, name: "bash", summary: "grep History x.py", result: "History: 4 处"),
            reasoning("r1", seq: 4, "History 应该指浏览记录"),
        ]
        let hits = TranscriptSearch.hits(in: items, query: "history")
        XCTAssertEqual(hits.map(\.id), ["t1", "a1", "u1"], "从新到旧，且思考过程不参与")
        XCTAssertEqual(hits.map(\.role), [.tool, .agent, .me])
    }

    func testCaseAndDiacriticInsensitive() {
        let items = [assistant("a1", seq: 1, "Café 的 RÉSUMÉ 在这里")]
        XCTAssertEqual(TranscriptSearch.hits(in: items, query: "resume").count, 1)
        XCTAssertEqual(TranscriptSearch.hits(in: items, query: "CAFÉ").count, 1)
    }

    func testOnlyMineDropsAgentAndToolHits() {
        let items = [
            user("u1", seq: 1, "搜一下 History"),
            assistant("a1", seq: 2, "History 是浏览记录"),
            tool("t1", seq: 3, name: "web_search", summary: "History", result: "…"),
        ]
        let hits = TranscriptSearch.hits(in: items, query: "History", onlyMine: true)
        XCTAssertEqual(hits.map(\.id), ["u1"])
        XCTAssertEqual(hits.first?.role, .me)
    }

    func testSnippetHighlightsTheMatchAfterWhitespaceCollapse() {
        let long = String(repeating: "前", count: 50) + "\n\n  目标词\n" + String(repeating: "后", count: 50)
        let items = [assistant("a1", seq: 1, long)]
        let hit = try! XCTUnwrap(TranscriptSearch.hits(in: items, query: "目标词").first)
        let characters = Array(hit.snippet)
        let highlighted = String(characters[hit.highlightStart..<(hit.highlightStart + hit.highlightLength)])
        XCTAssertEqual(highlighted, "目标词")
        XCTAssertTrue(hit.snippet.hasPrefix("…"), "被裁过的片段要有省略号")
        XCTAssertTrue(hit.snippet.hasSuffix("…"))
        XCTAssertFalse(hit.snippet.contains("\n"), "换行要压成空格")
        XCTAssertFalse(hit.snippet.contains("  "), "连续空白压成一个")
    }

    func testLimitCapsResults() {
        let items = (1...30).map { user("u\($0)", seq: $0, "关键词 \($0)") }
        XCTAssertEqual(TranscriptSearch.hits(in: items, query: "关键词", limit: 5).count, 5)
    }

    func testToolResultTextIsSearchable() {
        let items = [tool("t1", seq: 1, name: "bash", summary: "ls", result: "README.md\nPackage.swift")]
        XCTAssertEqual(TranscriptSearch.hits(in: items, query: "Package.swift").map(\.id), ["t1"])
    }
}
