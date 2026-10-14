import XCTest

@testable import DSHKit

/// App 构建号比较的用例（从 App 单测搬来：这段逻辑进了 DSHKit，用例跟着走）。
///
/// 为什么它单独于 `HostVersionTests`：两者长得像但语义不同（见 `BuildStamp` 头注），
/// 所以用例故意把差异也钉住——畸形输入这一档，两边给的答案不一样，且都是对的。
final class BuildStampTests: XCTestCase {

    func testNewerBuildStampWins() {
        XCTAssertTrue(BuildStamp.isNewer("20261014.1450", than: "20261013.2359"))
        XCTAssertFalse(BuildStamp.isNewer("20261013.2359", than: "20261014.1450"))
        XCTAssertFalse(BuildStamp.isNewer("20261014.1450", than: "20261014.1450"))
    }

    func testMissingComponentsCountAsZero() {
        // "20261014.1" 与 "20261014.1.0" 是同一个构建号。
        XCTAssertFalse(BuildStamp.isNewer("20261014.1", than: "20261014.1.0"))
        XCTAssertTrue(BuildStamp.isNewer("20261014.1.0.1", than: "20261014.1"))
        XCTAssertTrue(BuildStamp.isNewer("20261014.2", than: "20261014.1.9"))
    }

    func testTwelveDigitLegacyStampComparesNumerically() {
        XCTAssertTrue(BuildStamp.isNewer("202610141200", than: "202610131200"))
        XCTAssertFalse(BuildStamp.isNewer("202610131200", than: "202610141200"))
    }

    func testEmptyInputsAreNeverNewer() {
        XCTAssertFalse(BuildStamp.isNewer("", than: "1"))
        XCTAssertFalse(BuildStamp.isNewer("1", than: ""))
        XCTAssertFalse(BuildStamp.isNewer("", than: ""))
    }

    func testNonNumericPartsReadAsZero() {
        XCTAssertFalse(BuildStamp.isNewer("abc.1", than: "1"))
        XCTAssertTrue(BuildStamp.isNewer("2.abc", than: "1.999"))
    }

    func testBuildStampAndHostVersionDeliberatelyDifferOnGarbage() {
        // 构建号：畸形段读作 0，所以 "9.9" 比 "abc" 新。
        XCTAssertTrue(BuildStamp.isNewer("9.9", than: "abc"))
        // 主机/连接器版本：读不出数字前缀就"不说"，返回 false。
        XCTAssertFalse(HostVersion.isOlder("abc", than: "9.9"))
        XCTAssertFalse(HostVersion.isOlder("9.9", than: "abc"))
    }
}
