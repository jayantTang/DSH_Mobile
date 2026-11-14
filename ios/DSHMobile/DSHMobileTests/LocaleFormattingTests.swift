import XCTest
@testable import DSHFilesUI

/// SR-09.04: git dates follow the current locale instead of a fixed MM-dd HH:mm.
@MainActor
final class LocaleFormattingTests: XCTestCase {
    func testGitShortDateIsNotTheOldFixedPattern() {
        let text = GitDateText.short("2026-11-14T12:34:56+0000")
        XCTAssertFalse(text.isEmpty)
        XCTAssertNil(text.range(of: #"^\d{2}-\d{2} \d{2}:\d{2}$"#, options: .regularExpression),
                     "git date still uses the fixed MM-dd HH:mm pattern: \(text)")
    }
}
