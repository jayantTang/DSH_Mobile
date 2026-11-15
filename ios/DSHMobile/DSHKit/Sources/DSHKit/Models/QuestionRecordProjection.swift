import Foundation

/// 一批已作答的问题与答案的**显示投影**（SR-02.16）。
///
/// 它只在 DSHKit 内部使用：`TimelineItem.Kind.questionRecord` 只带三份平行数组
/// （标题 / 问题 / 答案），不含模型类型——`check:public-api` 的导出面预算不允许
/// 为一个显示行再加一棵公开类型树，而折叠、搜索、渲染都只需要这些文字。
///
/// 三个输入口，同一份投影：
/// - 实时/完整历史：`tool/call` 的参数（问题）+ `tool/result` 的正文（答案）；
/// - 折叠页：连接器下发的 `+link/question` 记录；
/// - 计时提问的迟到回复：`user/message` 的 `source.kind == "user-question-reply"`。
struct QuestionRecordProjection: Sendable, Equatable {
    /// 线类型（连接器 `QUESTION_RECORD_TYPE`）。
    static let recordType = "+link/question"

    let callId: String
    /// 与 `questions` / `answers` 同下标；没有标题时是空串。
    let headers: [String]
    /// 问题文字；参数缺失或形状不认识时是空串（只显示答案）。
    let questions: [String]
    /// 答案文字（多个选项用 `, ` 连接）；被跳过的题是空串。
    let answers: [String]

    var isEmpty: Bool { questions.isEmpty && answers.isEmpty }

    /// 会带回答案批次的工具名（与连接器 `question-record.js` 同一张表）。
    static func isQuestionTool(_ name: String) -> Bool {
        name == "ask_user_question" || name == "request_user_input"
    }

    /// 搜索用正文：问题与答案按显示顺序拼起来，不带装饰。
    var searchText: String {
        (questions + answers)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// 内容量：重复到达时用它决定保留哪一份（更完整的那份胜出）。
    var textLength: Int {
        headers.reduce(0) { $0 + $1.count }
            + questions.reduce(0) { $0 + $1.count }
            + answers.reduce(0) { $0 + $1.count }
    }

    /// 同一调用的两份记录合并：文字更完整的一份为准。问题与答案是平行数组，
    /// 不能从两份里各取一半拼成一行（会把答案配到别的问题上）。
    func merging(_ other: QuestionRecordProjection) -> QuestionRecordProjection {
        other.textLength > textLength ? other : self
    }

    // MARK: - 解码

    /// 解码连接器下发的 `+link/question` 记录。形状不对时返回 nil，不造半条记录。
    static func decode(_ data: JSONValue) -> QuestionRecordProjection? {
        guard case .object = data else { return nil }
        guard let callId = data["callId"]?.stringValue, !callId.isEmpty else { return nil }
        guard let answers = answers(data["answers"]), !answers.isEmpty else { return nil }
        return make(callId: callId, questions: questions(data["questions"]) ?? [], answers: answers)
    }

    /// 实时路径：`tool/call` 的原始参数 + `tool/result` 的正文。
    ///
    /// 结果 `{pending:true}`（计时提问的超时）不是答案批次，返回 nil；参数坏掉时
    /// 仍保留答案（问题文字按缺失处理）。
    static func fromToolResult(callId: String, arguments: String, resultText: String) -> QuestionRecordProjection? {
        guard !callId.isEmpty else { return nil }
        guard let value = jsonValue(resultText) else { return nil }
        guard value["pending"]?.boolValue != true else { return nil }
        guard let answers = answers(value["answers"]), !answers.isEmpty else { return nil }
        let questions = jsonValue(arguments).flatMap { questions($0["questions"]) } ?? []
        return make(callId: callId, questions: questions, answers: answers)
    }

    /// 迟到回复：`user/message` 正文里的 `{questions, answers}`；`callId` 来自消息的
    /// `source`（正文里的 `callId` 只在部分宿主版本里出现，不能依赖）。
    static func fromLateReply(callId: String, text: String) -> QuestionRecordProjection? {
        guard !callId.isEmpty else { return nil }
        guard let value = jsonValue(text) else { return nil }
        // 只认这个来源的载荷；同一来源的其它形状按普通消息处理（不吞正文）。
        if let kind = value["kind"]?.stringValue, kind != "answer_to_pending_question" { return nil }
        guard let answers = answers(value["answers"]), !answers.isEmpty else { return nil }
        return make(callId: callId, questions: questions(value["questions"]) ?? [], answers: answers)
    }

    // MARK: - JSON

    private static func jsonValue(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    struct ParsedQuestion {
        let id: String
        let question: String
        let header: String?
    }

    struct ParsedAnswer {
        let id: String
        let values: [String]
    }

    /// 问题清单：严格配对。任何一项缺 `id` / `question` 就整份不要，避免把答案
    /// 配到错的问题上。
    private static func questions(_ value: JSONValue?) -> [ParsedQuestion]? {
        guard let items = value?.arrayValue, !items.isEmpty else { return nil }
        var out: [ParsedQuestion] = []
        for item in items {
            guard let id = item["id"]?.stringValue, !id.isEmpty,
                  let text = item["question"]?.stringValue
            else { return nil }
            let header = item["header"]?.stringValue
            out.append(ParsedQuestion(
                id: id,
                question: text,
                header: header?.isEmpty == true || header == text ? nil : header))
        }
        return out
    }

    /// 答案批次：字段坏掉返回 nil；空数组保留为空（调用方据此不发记录）。
    private static func answers(_ value: JSONValue?) -> [ParsedAnswer]? {
        guard let items = value?.arrayValue else { return nil }
        var out: [ParsedAnswer] = []
        for item in items {
            guard let id = item["id"]?.stringValue, !id.isEmpty else { return nil }
            guard let selected = item["selected"]?.arrayValue,
                  selected.allSatisfy({ $0.stringValue != nil })
            else { return nil }
            if let custom = item["custom"], custom.stringValue == nil { return nil }
            let customText = item["custom"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            out.append(ParsedAnswer(
                id: id,
                values: selected.compactMap(\.stringValue) + (customText.isEmpty ? [] : [customText])))
        }
        return out
    }

    /// 按问题 id 配对，产出三份平行数组。答案里没有对应问题的条目补在末尾，
    /// 问题文字留空（AR-02.16.01 的降级口径）。
    private static func make(callId: String,
                             questions: [ParsedQuestion],
                             answers: [ParsedAnswer]) -> QuestionRecordProjection {
        var headers: [String] = []
        var questionTexts: [String] = []
        var answerTexts: [String] = []
        var used = Set<String>()
        for question in questions {
            let answer = answers.first { $0.id == question.id }
            used.insert(question.id)
            headers.append(question.header ?? "")
            questionTexts.append(question.question)
            answerTexts.append(answer?.values.joined(separator: ", ") ?? "")
        }
        for answer in answers where !used.contains(answer.id) {
            headers.append("")
            questionTexts.append("")
            answerTexts.append(answer.values.joined(separator: ", "))
        }
        return QuestionRecordProjection(
            callId: callId, headers: headers, questions: questionTexts, answers: answerTexts)
    }
}
