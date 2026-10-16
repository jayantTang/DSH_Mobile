import SwiftUI
import XCTest
@testable import DSHDesign

/// 语法着色器（`CodeHighlighting.swift`，纯函数）的用例。
///
/// 它是只读渲染路径上唯一做解析的代码：整页喂进来，块注释靠 `CodeLexerState` 跨行走。
/// 着错色只是难看，"卡住"是另一回事——这个文件里的注释记的都是真的卡死过的事故
/// （中文数字触发的死循环、30 万字符一行把 `Text` 摆死），所以这里钉三类东西：
/// 跨行状态、字符串与注释的优先级、长行截断的边界。
///
/// 断言消息一律 ASCII：check:i18n 扫整棵 Modules 树。用例里需要中文时写字面量转义
/// （否则会被当成硬编码文案）。
final class CodeHighlightingTests: XCTestCase {

    private typealias Segment = (text: String, kind: CodeTokenKind)

    private func lex(_ line: String, _ language: CodeLanguage,
                     state: inout CodeLexerState) -> [Segment] {
        CodeHighlighter.segments(line, language: language, state: &state)
    }

    private func texts(_ segments: [Segment], kind: CodeTokenKind) -> [String] {
        segments.filter { $0.kind == kind }.map(\.text)
    }

    private func joined(_ segments: [Segment]) -> String {
        segments.map(\.text).joined()
    }

    /// 一次性的行：状态用完即弃（不需要跨行时用这个）。
    private func lexLine(_ line: String, _ language: CodeLanguage) -> [Segment] {
        var state = CodeLexerState()
        return lex(line, language, state: &state)
    }

    /// 词法器认得的全部语言，与 `CodeLanguage` 的 case 一一对应。
    private static let allLanguages: [CodeLanguage] = [
        .swift, .javascript, .typescript, .python, .json, .shell, .yaml, .markdown, .go, .rust,
        .c, .cpp, .java, .kotlin, .ruby, .php, .sql, .html, .css, .text,
    ]

    // MARK: - Swift

    func test_swift_block_comment_carries_across_lines_and_closes_where_it_says() {
        var state = CodeLexerState()
        let opened = lex("/* a note", .swift, state: &state)
        XCTAssertEqual(texts(opened, kind: .comment), ["/* a note"], "an unterminated block comment is all comment")
        XCTAssertTrue(state.inBlockComment, "the lexer must remember it is inside a block comment")

        let closed = lex("still inside */ let x = 1", .swift, state: &state)
        XCTAssertEqual(texts(closed, kind: .comment), ["still inside */"], "the carried comment ends at the close marker")
        XCTAssertEqual(texts(closed, kind: .keyword), ["let"], "code after the close marker is tokenized normally")
        XCTAssertEqual(texts(closed, kind: .number), ["1"])
        XCTAssertTrue(texts(closed, kind: .punctuation).contains("="), "the assignment is punctuation")
        XCTAssertEqual(joined(closed), "still inside */ let x = 1", "no character may be dropped")
        XCTAssertFalse(state.inBlockComment, "the close marker ends the carried comment")
    }

    func test_swift_keywords_inside_a_string_are_not_coloured() {
        var state = CodeLexerState()
        let line = "let greeting = \"if let for while\""
        let segments = lex(line, .swift, state: &state)
        XCTAssertEqual(texts(segments, kind: .keyword), ["let"],
                       "the keywords inside the string literal must stay part of the string")
        XCTAssertEqual(texts(segments, kind: .string), ["\"if let for while\""])
        XCTAssertEqual(joined(segments), line)
    }

    func test_swift_a_comment_marker_inside_a_string_does_not_start_a_comment() {
        var state = CodeLexerState()
        let line = "let url = \"https://example.test/x\" // real comment"
        let segments = lex(line, .swift, state: &state)
        XCTAssertEqual(texts(segments, kind: .comment), ["// real comment"],
                       "the double slash inside the literal is not a comment marker")
        XCTAssertEqual(texts(segments, kind: .string), ["\"https://example.test/x\""])
        XCTAssertEqual(joined(segments), line)
    }

    func test_swift_a_block_comment_opener_inside_a_string_does_not_open_one() {
        var state = CodeLexerState()
        let line = "let pattern = \"/* not a comment */\""
        let segments = lex(line, .swift, state: &state)
        XCTAssertEqual(texts(segments, kind: .comment), [], "a quoted opener stays inside the string")
        XCTAssertEqual(texts(segments, kind: .string), ["\"/* not a comment */\""])
        XCTAssertFalse(state.inBlockComment)
    }

    func test_swift_unclosed_block_comment_swallows_the_rest_of_the_page() {
        var state = CodeLexerState()
        let first = lex("/* open", .swift, state: &state)
        XCTAssertEqual(texts(first, kind: .comment), ["/* open"])
        XCTAssertTrue(state.inBlockComment)

        let second = lex("no close here", .swift, state: &state)
        XCTAssertEqual(joined(second), "no close here", "the whole line is shown")
        XCTAssertEqual(texts(second, kind: .comment), ["no close here"])
        XCTAssertTrue(texts(second, kind: .keyword).isEmpty, "nothing is coloured inside an open comment")
        XCTAssertTrue(state.inBlockComment, "an unclosed comment stays open across the line")

        let third = lex("closed */ var y = 2", .swift, state: &state)
        XCTAssertEqual(texts(third, kind: .comment), ["closed */"])
        XCTAssertEqual(texts(third, kind: .keyword), ["var"])
        XCTAssertEqual(texts(third, kind: .number), ["2"])
        XCTAssertFalse(state.inBlockComment)
    }

    /// 缺陷钉住（现状，不是期望）：Swift 的块注释允许嵌套，这个词法器只找第一个 `*/`，
    /// 剩下的 `*/` 掉进正文。真嵌套要改成计数深度，改完这条用例跟着改。
    func test_swift_nested_block_comment_is_not_nested_today() {
        var state = CodeLexerState()
        let line = "/* outer /* inner */ tail */"
        let segments = lex(line, .swift, state: &state)
        XCTAssertEqual(texts(segments, kind: .comment), ["/* outer /* inner */"],
                       "the lexer stops at the first close marker")
        XCTAssertTrue(texts(segments, kind: .plain).joined().contains("tail */"),
                      "the leftover close marker falls through as plain text")
        XCTAssertEqual(joined(segments), line, "no character may be dropped")
        XCTAssertFalse(state.inBlockComment)
    }

    func test_swift_unterminated_string_runs_to_the_end_of_the_line() {
        var state = CodeLexerState()
        let line = "let s = \"never closed"
        let segments = lex(line, .swift, state: &state)
        XCTAssertEqual(texts(segments, kind: .string), ["\"never closed"])
        XCTAssertEqual(joined(segments), line)
        XCTAssertFalse(state.inBlockComment, "an open quote must not leak into the block-comment state")
    }

    /// 中文数字触发的死循环（注释在源码里记着：「两个入口」把阅读器挂死过）。
    /// `Character.isNumber` 对 两/三/十/万 为真、`isNumberBody` 为假，老写法在那个分支里
    /// 既不消费字符也不推进下标。字面量写成转义，源码里不带 CJK。
    func test_swift_cjk_numerals_are_not_number_tokens_and_do_not_stall_the_lexer() {
        var state = CodeLexerState()
        let line = "\u{4E24}\u{4E2A}\u{5165}\u{53E3} = 1"
        let segments = lex(line, .swift, state: &state)
        XCTAssertEqual(joined(segments), line, "every character survives tokenizing")
        XCTAssertEqual(texts(segments, kind: .number), ["1"], "only the ASCII digit is a number literal")
        XCTAssertFalse(state.inBlockComment)
    }

    // MARK: - Python

    /// 缺陷钉住（现状，不是期望）：Python 的块注释开闭是同一个 `"""`，而实现是在 `rest`
    /// （**含**开引号）里找闭合，于是开引号立刻匹配到自己 —— 三引号永远只是一个三字符注释，
    /// `inBlockComment` 对 Python 永远为 false，那条 `blockComment` 分支实际是死代码，
    /// docstring 正文不着色。修法是先跨过开引号再找闭合；改完这几条期望值跟着改。
    func test_python_triple_quote_is_only_a_three_character_comment_today() {
        var state = CodeLexerState()
        let line = "x = 1  \"\"\"start of the doc"
        let segments = lex(line, .python, state: &state)
        XCTAssertEqual(texts(segments, kind: .comment), ["\"\"\""],
                       "the opener matches itself as the close marker, so only three characters are a comment")
        XCTAssertEqual(texts(segments, kind: .number), ["1"], "code before the opener is tokenized normally")
        XCTAssertTrue(texts(segments, kind: .plain).joined().contains("start of the doc"),
                      "the body of the docstring stays plain text")
        XCTAssertFalse(state.inBlockComment, "nothing is carried over to the next line")
        XCTAssertEqual(joined(segments), line, "no character may be dropped")
    }

    /// 同一个缺陷的另一面：`"""` 成对出现时，两个引号各自成为一条三字符注释，正文夹在中间。
    func test_python_a_triple_quote_pair_on_one_line_becomes_two_short_comments() {
        let line = "\"\"\"doc\"\"\""
        let segments = lexLine(line, .python)
        XCTAssertEqual(texts(segments, kind: .comment), ["\"\"\"", "\"\"\""])
        XCTAssertTrue(texts(segments, kind: .plain).joined().contains("doc"))
        XCTAssertEqual(joined(segments), line)
    }

    func test_python_hash_inside_a_string_is_not_a_comment() {
        var state = CodeLexerState()
        let quoted = "note = \"# not a comment\""
        let segments = lex(quoted, .python, state: &state)
        XCTAssertEqual(texts(segments, kind: .comment), [], "a hash inside a literal is not a comment")
        XCTAssertEqual(texts(segments, kind: .string), ["\"# not a comment\""])
        XCTAssertEqual(joined(segments), quoted)

        let trailing = lex("x = 1  # real comment", .python, state: &state)
        XCTAssertEqual(texts(trailing, kind: .comment), ["# real comment"])
        XCTAssertEqual(texts(trailing, kind: .keyword), [], "python keywords are not in this line")
    }

    func test_python_keywords_are_coloured_and_identifiers_are_not() {
        var state = CodeLexerState()
        let line = "def greet(name): return name"
        let segments = lex(line, .python, state: &state)
        XCTAssertEqual(texts(segments, kind: .keyword), ["def", "return"])
        XCTAssertEqual(texts(segments, kind: .type), [], "python does not colour capitalized names as types")
        XCTAssertEqual(texts(segments, kind: .punctuation), ["(", ")", ":"])
        XCTAssertEqual(joined(segments), line)
    }

    /// 「未闭合的三引号」在 Python 上根本走不到：开引号自己闭合自己，所以下一行照常着色。
    /// 同上，是缺陷钉住。
    func test_python_an_unclosed_triple_quote_does_not_swallow_the_next_line() {
        var state = CodeLexerState()
        _ = lex("x = 1  \"\"\"open", .python, state: &state)
        XCTAssertFalse(state.inBlockComment, "the opener closes on itself")
        let next = lex("def helper():", .python, state: &state)
        XCTAssertEqual(texts(next, kind: .comment), [], "the next line is not a comment")
        XCTAssertEqual(texts(next, kind: .keyword), ["def"])
    }

    // MARK: - JavaScript / TypeScript

    func test_javascript_trailing_comment_and_template_string() {
        var state = CodeLexerState()
        let line = "const t = `// not a comment`; // real"
        let segments = lex(line, .javascript, state: &state)
        XCTAssertEqual(texts(segments, kind: .comment), ["// real"],
                       "only the slash pair outside the template literal starts a comment")
        XCTAssertEqual(texts(segments, kind: .string), ["`// not a comment`"])
        XCTAssertEqual(texts(segments, kind: .keyword), ["const"])
        XCTAssertTrue(texts(segments, kind: .punctuation).contains(";"))
        XCTAssertEqual(joined(segments), line)
    }

    func test_javascript_unclosed_block_comment_carries_to_the_next_line() {
        var state = CodeLexerState()
        _ = lex("/* open", .javascript, state: &state)
        XCTAssertTrue(state.inBlockComment)
        let closed = lex("*/ let x = 1", .javascript, state: &state)
        XCTAssertEqual(texts(closed, kind: .comment), ["*/"])
        XCTAssertEqual(texts(closed, kind: .keyword), ["let"])
        XCTAssertFalse(state.inBlockComment)
    }

    func test_typescript_type_names_and_object_keys_get_their_own_kinds() {
        var state = CodeLexerState()
        let line = "interface Node { id: number }"
        let segments = lex(line, .typescript, state: &state)
        XCTAssertEqual(texts(segments, kind: .keyword), ["interface", "number"])
        XCTAssertEqual(texts(segments, kind: .type), ["Node"], "a capitalized name is a type in TypeScript")
        XCTAssertEqual(texts(segments, kind: .property), ["id"], "a name followed by a colon is a key")
        XCTAssertEqual(texts(segments, kind: .punctuation), ["{", ":", "}"])
        XCTAssertEqual(joined(segments), line)
    }

    func test_a_scope_operator_is_not_a_property_separator() {
        var state = CodeLexerState()
        let line = "let v = Foo::Bar"
        let segments = lex(line, .swift, state: &state)
        XCTAssertEqual(texts(segments, kind: .property), [], "a double colon is a scope operator, not a key")
        XCTAssertEqual(texts(segments, kind: .type), ["Foo", "Bar"])
    }

    // MARK: - 全语言

    /// 词法器只许重排、不许吞字符：任一语言下拼回来必须等于原行。
    func test_every_language_reproduces_its_input_character_for_character() {
        let samples: [(CodeLanguage, String)] = [
            (.swift, "let x = Foo(1) // note"),
            (.python, "def f(x): return x + 1  # note"),
            (.javascript, "const a = {b: 1}; // note"),
            (.typescript, "interface N { id: number }"),
            (.json, "{\"a\": 1, \"b\": true}"),
            (.shell, "if [ -f x ]; then echo hi; fi"),
            (.yaml, "key: \"value\"  # note"),
            (.go, "func main() { fmt.Println(\"hi\") }"),
            (.rust, "let mut v: Vec<u8> = vec![];"),
            (.c, "int main(void) { return 0; }"),
            (.cpp, "std::vector<int> v; // note"),
            (.java, "public class A { int x = 1; }"),
            (.kotlin, "val x: Int = 1 // note"),
            (.ruby, "def hi; puts \"x\"; end # note"),
            (.php, "<?php echo \"hi\"; // note"),
            (.sql, "SELECT id FROM t -- note"),
            (.html, "<!-- note --> <div class=\"x\">hi</div>"),
            (.css, "a { color: red; } /* note */"),
            (.markdown, "some `code` here"),
            (.text, "plain text"),
        ]
        XCTAssertEqual(Set(samples.map(\.0.rawValue)), Set(Self.allLanguages.map(\.rawValue)),
                       "every language needs a sample line")
        for (language, sample) in samples {
            var state = CodeLexerState()
            let segments = lex(sample, language, state: &state)
            XCTAssertEqual(joined(segments), sample,
                           "\(language.rawValue) must not lose or duplicate characters")
            XCTAssertFalse(state.inBlockComment,
                           "\(language.rawValue) sample must not leave the lexer inside a comment")
        }
    }

    func test_empty_input_yields_no_segments() {
        for language in Self.allLanguages {
            var state = CodeLexerState()
            let segments = lex("", language, state: &state)
            XCTAssertEqual(segments.count, 0, "\(language.rawValue): an empty line has no tokens")
            XCTAssertFalse(state.inBlockComment, "\(language.rawValue): an empty line opens nothing")
        }

        var state = CodeLexerState()
        _ = lex("/* open", .swift, state: &state)
        let insideComment = lex("", .swift, state: &state)
        XCTAssertEqual(joined(insideComment), "", "an empty line inside a comment contributes no text")
    }

    func test_markdown_lines_keep_their_own_rules() {
        let heading = lexLine("# Title", .markdown)
        XCTAssertEqual(texts(heading, kind: .keyword), ["# Title"], "a heading line is one keyword run")

        let bullet = lexLine("- item", .markdown)
        XCTAssertEqual(texts(bullet, kind: .punctuation), ["- "])
        XCTAssertEqual(texts(bullet, kind: .plain), ["item"])

        let fence = lexLine("```swift", .markdown)
        XCTAssertEqual(texts(fence, kind: .comment), ["```swift"])

        let span = lexLine("see `x` now", .markdown)
        XCTAssertEqual(texts(span, kind: .punctuation), ["`", "`"])
        XCTAssertEqual(texts(span, kind: .string), ["x"])
        XCTAssertEqual(texts(span, kind: .plain), ["see ", " now"])
    }

    // MARK: - 长行截断

    func test_a_long_line_is_cut_for_display_and_the_cut_is_said_out_loud() {
        XCTAssertEqual(CodeHighlighter.displayLimit, 2_000,
                       "the display limit is a contract with the reader, not a tuning knob")
        let long = String(repeating: "a", count: 2_500)
        let rendered = String(CodeHighlighter.page([long], language: .swift)[0].characters)
        XCTAssertTrue(rendered.hasPrefix(String(long.prefix(2_000))), "the head of the line is shown as-is")
        XCTAssertGreaterThan(rendered.count, 2_000, "the reader must be told that part of the line is missing")
        let note = String(rendered.dropFirst(2_000))
        XCTAssertTrue(note.hasPrefix("\u{2026}"), "the cut is marked with an ellipsis")
        XCTAssertTrue(note.contains("500"), "the note counts the characters that were dropped")
        XCTAssertLessThan(note.count, 60, "the note is a short suffix, not a second copy of the line")
    }

    func test_a_line_exactly_at_the_display_limit_is_left_alone() {
        let exact = String(repeating: "b", count: 2_000)
        let rendered = String(CodeHighlighter.page([exact], language: .text)[0].characters)
        XCTAssertEqual(rendered, exact, "the limit is inclusive: nothing is cut at exactly 2000 characters")

        let over = exact + "c"
        let overRendered = String(CodeHighlighter.page([over], language: .text)[0].characters)
        XCTAssertTrue(overRendered.hasPrefix(exact), "the first 2000 characters are kept")
        XCTAssertNotEqual(overRendered, over, "one character over the limit is still reported")
    }

    // MARK: - 与色板的关系

    /// 语法色不许自己造：每个 token 种类都必须落在 `DSHTheme` 的某个 token 上。
    func test_every_token_kind_takes_its_colour_from_a_theme_token() {
        let table: [(CodeTokenKind, String, Color)] = [
            (.plain, "plain", DSHTheme.labelPrimary),
            (.keyword, "keyword", DSHTheme.brand),
            (.type, "type", DSHTheme.brandBright),
            (.string, "string", DSHTheme.success),
            (.number, "number", DSHTheme.syntaxNumber),
            (.comment, "comment", DSHTheme.labelTertiary),
            (.property, "property", DSHTheme.labelSecondary),
            (.punctuation, "punctuation", DSHTheme.labelSecondary),
        ]
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            for (kind, name, token) in table {
                let expected = resolvedToken(token, scheme)
                let actual = resolvedToken(CodeHighlighter.color(for: kind), scheme)
                XCTAssertTrue(actual.near(expected),
                              "colour for \(name) resolved \(actual), expected the theme token \(expected)")
            }
        }
    }
}
