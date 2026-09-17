import Foundation
import XCTest

@testable import DSHKit

/// The answer shape a question sheet sends back.
///
/// These cases exist because the phone used to append the typed text to
/// `selected`, which is not what the host reads: free text has its own field,
/// and for a single-select question the typed answer replaces the choice. The
/// desktop composer sends the same shape, so these pin parity with it.
final class UserQuestionAnswerTests: XCTestCase {

    private func encoded(_ answer: UserQuestionsAnswer) throws -> [[String: Any]] {
        let data = try JSONEncoder().encode(answer)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["answers"] as? [[String: Any]] ?? []
    }

    func testTypedAnswerReplacesASingleSelectChoice() throws {
        let answer = UserQuestionsAnswer(drafts: [
            UserQuestionDraft(id: "q1", selected: ["要"], custom: "先放着，等我有空", allowsMultiple: false),
        ])
        let first = try XCTUnwrap(try encoded(answer).first)
        XCTAssertEqual(first["custom"] as? String, "先放着，等我有空")
        XCTAssertEqual(first["selected"] as? [String], [], "单选的文字回答就是答案本身，不应再带勾选项")
    }

    func testTypedAnswerAccompaniesAMultiSelectChoice() throws {
        let answer = UserQuestionsAnswer(drafts: [
            UserQuestionDraft(id: "q1", selected: ["A", "B"], custom: "再补一点", allowsMultiple: true),
        ])
        let first = try XCTUnwrap(try encoded(answer).first)
        XCTAssertEqual(first["selected"] as? [String], ["A", "B"])
        XCTAssertEqual(first["custom"] as? String, "再补一点")
    }

    func testAChoiceWithoutTextCarriesNoCustomField() throws {
        let answer = UserQuestionsAnswer(drafts: [
            UserQuestionDraft(id: "q1", selected: ["要"], custom: "   ", allowsMultiple: false),
        ])
        let first = try XCTUnwrap(try encoded(answer).first)
        XCTAssertEqual(first["selected"] as? [String], ["要"])
        XCTAssertNil(first["custom"], "只有空白的输入不算回答")
    }

    func testAnEmptyDraftStillAnswersTheQuestion() throws {
        // Skipping is expressed as an empty answer, not a missing one: the host
        // matches answers to questions by id.
        let answer = UserQuestionsAnswer(drafts: [
            UserQuestionDraft(id: "q7", selected: [], custom: "", allowsMultiple: false),
        ])
        let first = try XCTUnwrap(try encoded(answer).first)
        XCTAssertEqual(first["id"] as? String, "q7")
        XCTAssertEqual(first["selected"] as? [String], [])
        XCTAssertNil(first["custom"])
    }

    func testTextIsTrimmedBeforeItGoesOut() throws {
        let answer = UserQuestionsAnswer(drafts: [
            UserQuestionDraft(id: "q1", selected: [], custom: "  行  ", allowsMultiple: false),
        ])
        XCTAssertEqual(try encoded(answer).first?["custom"] as? String, "行")
    }

    func testADetailFieldOnTheQuestionSurvivesDecoding() throws {
        // The host sends supporting detail alongside a question; the sheet shows
        // it, so a missing field here would silently drop it.
        let json = """
        {"questions":[{"id":"q1","question":"选哪个？","detail":"两个都能用，区别在成本。",
                       "options":[{"label":"A"},{"label":"B","description":"更贵"}],"multiSelect":false}]}
        """
        let request = try JSONDecoder().decode(UserQuestionsRequest.self, from: Data(json.utf8))
        let question = try XCTUnwrap(request.questions.first)
        XCTAssertEqual(question.detail, "两个都能用，区别在成本。")
        XCTAssertEqual(question.options?.count, 2)
        XCTAssertEqual(question.options?.last?.description, "更贵")
        XCTAssertFalse(question.allowsMultiple)
    }
}
