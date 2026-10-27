@testable import DSHFeedbackDomain
import Foundation
import RelayKit
import XCTest

/// 正文长度的双约束（字符 + UTF-8 字节）：发送窗口与回信输入框读同一套判定，
/// 上限来自服务端下发的 `limits`，缺失时用编译期默认 4000 / 12000。
final class FeedbackDraftLengthTests: XCTestCase {

    /// 汉字 3 字节：4000 个正好 12000 字节，可发；4001 个字符先触顶。
    func test_hanzi_is_bounded_by_the_same_character_count_as_the_server() {
        let limits = FeedbackLimits.fallback
        let hanzi = String(repeating: "\u{4F1A}", count: 4_000)
        XCTAssertEqual(hanzi.utf8.count, 12_000)
        XCTAssertEqual(FeedbackDraftLength.overflow(hanzi, limits: limits), .none)
        XCTAssertTrue(FeedbackDraftLength.canSend(hanzi, limits: limits))
        XCTAssertEqual(FeedbackDraftLength.remaining(hanzi, limits: limits), 0)

        let tooManyChars = String(repeating: "\u{4F1A}", count: 4_001)
        XCTAssertEqual(FeedbackDraftLength.overflow(tooManyChars, limits: limits), .characters)
        XCTAssertFalse(FeedbackDraftLength.canSend(tooManyChars, limits: limits))
        XCTAssertEqual(FeedbackDraftLength.remaining(tooManyChars, limits: limits), -1)
    }

    /// emoji 4 字节：3000 个刚好 12000 字节，可发；3001 个字符数没超、字节先触顶。
    func test_emoji_trips_the_byte_limit_before_the_character_limit() {
        let limits = FeedbackLimits.fallback
        let emoji = String(repeating: "\u{1F600}", count: 3_000)
        XCTAssertEqual(emoji.count, 3_000)
        XCTAssertEqual(emoji.utf8.count, 12_000)
        XCTAssertEqual(FeedbackDraftLength.overflow(emoji, limits: limits), .none)
        XCTAssertTrue(FeedbackDraftLength.canSend(emoji, limits: limits))

        let tooManyBytes = String(repeating: "\u{1F600}", count: 3_001)
        XCTAssertEqual(tooManyBytes.count, 3_001, "still under the character limit")
        XCTAssertEqual(FeedbackDraftLength.overflow(tooManyBytes, limits: limits), .bytes)
        XCTAssertFalse(FeedbackDraftLength.canSend(tooManyBytes, limits: limits))
    }

    /// 服务端下发的值说了算：换成更小的上限，同一条正文的结论跟着变。
    func test_server_limits_win_over_the_compile_time_default() {
        let tight = FeedbackLimits(textChars: 10, textBytes: 12)
        let text = String(repeating: "a", count: 11)
        XCTAssertEqual(FeedbackDraftLength.overflow(text, limits: tight), .characters)
        XCTAssertFalse(FeedbackDraftLength.canSend(text, limits: tight))
        XCTAssertTrue(FeedbackDraftLength.canSend(String(repeating: "a", count: 10), limits: tight))
    }

    /// 空白不算可发；只有空白也发不出去。
    func test_blank_text_is_never_sendable() {
        XCTAssertFalse(FeedbackDraftLength.canSend("   \n", limits: .fallback))
        XCTAssertFalse(FeedbackDraftLength.canSend("", limits: .fallback))
        XCTAssertTrue(FeedbackDraftLength.canSend("x", limits: FeedbackLimits(textChars: 1, textBytes: 1)))
    }

    /// 解码：服务端只给了一部分字段时，其余退默认；整个 `limits` 缺失也一样。
    func test_missing_limit_fields_fall_back_per_field() throws {
        let partial = try JSONDecoder().decode(FeedbackLimits.self, from: Data(
            #"{"textChars":5000}"#.utf8))
        XCTAssertEqual(partial.textChars, 5_000)
        XCTAssertEqual(partial.textBytes, FeedbackLimits.fallback.textBytes)
        XCTAssertEqual(partial.subjectChars, FeedbackLimits.fallback.subjectChars)

        let full = try JSONDecoder().decode(FeedbackLimits.self, from: Data(
            #"{"textChars":4000,"textBytes":12000,"subjectChars":80,"maxTicketPairs":200}"#.utf8))
        XCTAssertEqual(full, .fallback)
    }
}
