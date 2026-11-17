import XCTest

@testable import DSHKit

/// 图片变体的支持判定（IR-10 / SR-10.01）。
///
/// 两个判据的来历：能力位是 0.8.2 才加进 `_link/hello` 的，而 `_link/imageCommit`
/// 从 0.8.1 就有。只看能力位会让 0.8.1 的用户在 App 升级后退回内联预览——新版本
/// 已有的功能不能因缺一条后来才加的能力位而消失，所以版本基线也要认。
final class ImageVariantSupportTests: XCTestCase {

    private func supported(_ capabilities: [String] = [], _ version: String? = nil) -> Bool {
        ImageVariantSupport.supported(capabilities: Set(capabilities), connectorVersion: version)
    }

    func testCapabilityAloneIsEnough() {
        XCTAssertTrue(supported(["image-variants"], nil))
    }

    func testVersionBaselineKeepsTheMethodAvailableWithoutTheCapabilityBit() {
        // 0.8.1 声明能力位的版本还不存在，但它有这两个方法：不能退化成内联预览。
        XCTAssertTrue(supported([], "0.8.1"))
        XCTAssertTrue(supported([], "0.8.2"))
        XCTAssertTrue(supported([], "1.0.0"))
        // 预发布同一版本号不当作更旧（HostVersion 的既有口径）。
        XCTAssertTrue(supported([], "0.8.1-rc.2"))
    }

    func testOlderConnectorsFallBack() {
        XCTAssertFalse(supported([], "0.8.0"))
        XCTAssertFalse(supported([], "0.6.6"))
        XCTAssertFalse(supported([], "0.3.1"))
    }

    func testUnreadableVersionIsNotGuessed() {
        // 读不出数字就不猜：宁可多传一份内联预览，也不把一次 404 当网络故障弹出来。
        XCTAssertFalse(supported([], nil))
        XCTAssertFalse(supported([], ""))
        XCTAssertFalse(supported([], "git-1cf9b07"))
        XCTAssertFalse(supported([], "v0.8.2"))
    }

    func testOtherCapabilitiesDoNotEnableImages() {
        XCTAssertFalse(supported(["dir-mtimes", "jobs-roster"], "0.7.0"))
    }
}
