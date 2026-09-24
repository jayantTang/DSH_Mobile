import Testing
@testable import DSHKit

/// The rule that stops a host notice from becoming a wall of text.
///
/// Regression: a compaction re-emitted a 703-line tool result as an orphan, the
/// transcript rendered it as a notice, and the notice had no cap — the phone
/// showed a screen-filling block that could not be folded (2026-09-24).
struct NoticeFoldingTests {

    @Test func shortNoticeIsShownWhole() {
        let text = "上下文压缩完成"
        let folded = NoticeFolding.fold(text)
        #expect(folded.text == text)
        #expect(folded.hiddenLines == 0)
        #expect(folded.isTruncated == false)
    }

    @Test func longNoticeKeepsTwelveLinesAndCountsTheRest() {
        let text = (1...40).map { "第 \($0) 行" }.joined(separator: "\n")
        let folded = NoticeFolding.fold(text)
        #expect(folded.text.components(separatedBy: "\n").count == NoticeFolding.lineLimit)
        #expect(folded.hiddenLines == 40 - NoticeFolding.lineLimit)
        #expect(folded.isTruncated)
        #expect(folded.text.hasPrefix("第 1 行"))
        #expect(!folded.text.contains("第 13 行"))
    }

    @Test func aSingleEnormousLineIsClippedByCharacters() {
        // One line means no hidden *lines*: the label must not promise a line
        // count, and the text still has to get shorter.
        let text = String(repeating: "x", count: NoticeFolding.characterLimit * 3)
        let folded = NoticeFolding.fold(text)
        #expect(folded.hiddenLines == 0)
        #expect(folded.isTruncated)
        #expect(folded.text.count == NoticeFolding.characterLimit + 1, "clipped text plus the ellipsis")
        #expect(folded.text.hasSuffix("…"))
    }

    @Test func exactlyAtTheLimitIsNotTruncated() {
        let text = (1...NoticeFolding.lineLimit).map { "第 \($0) 行" }.joined(separator: "\n")
        let folded = NoticeFolding.fold(text)
        #expect(folded.isTruncated == false)
        #expect(folded.text == text)
    }
}
