import XCTest
@testable import DSHFoundation

/// 平台适配用例（自 DSHMobileTests/PlatformAdaptersTests 迁入，025）。
/// 断言消息一律 ASCII：check:i18n 扫整棵 Modules 树，中文字面量会报硬编码。
@MainActor
final class FoundationSmokeTests: XCTestCase {

    // MARK: - Keychain（只用测试账号，收尾必删）

    private let testAccount = "dsh-unit-test.round-trip"

    override func tearDown() {
        Keychain.remove(testAccount)
        super.tearDown()
    }

    func testKeychainRoundTrip() throws {
        Keychain.remove(testAccount)
        XCTAssertNil(Keychain.get(testAccount), "the test account starts clean")
        try Keychain.set("secret-value", for: testAccount)
        XCTAssertEqual(Keychain.get(testAccount), "secret-value")
    }

    func testKeychainOverwriteWins() throws {
        try Keychain.set("first", for: testAccount)
        try Keychain.set("second", for: testAccount)
        XCTAssertEqual(Keychain.get(testAccount), "second")
    }

    func testKeychainRemoveMakesItDisappear() throws {
        try Keychain.set("value", for: testAccount)
        Keychain.remove(testAccount)
        XCTAssertNil(Keychain.get(testAccount))
    }

    func testKeychainMissingAccountIsNil() {
        Keychain.remove("dsh-unit-test.never-written")
        XCTAssertNil(Keychain.get("dsh-unit-test.never-written"))
    }

    // MARK: - InstallChannel

    func testOnlyOverTheAirAcceptsInAppUpdate() {
        XCTAssertTrue(InstallChannel.overTheAir.acceptsInAppUpdate)
        XCTAssertFalse(InstallChannel.appStore.acceptsInAppUpdate)
        XCTAssertFalse(InstallChannel.development.acceptsInAppUpdate)
    }

    func testChannelRawValuesMatchLaunchArguments() {
        XCTAssertEqual(InstallChannel(rawValue: "overTheAir"), .overTheAir)
        XCTAssertEqual(InstallChannel(rawValue: "appStore"), .appStore)
        XCTAssertEqual(InstallChannel(rawValue: "development"), .development)
        XCTAssertNil(InstallChannel(rawValue: "ota"))
    }

    // MARK: - ConnectorBaseline

    func test_connector_baseline_version() {
        XCTAssertEqual(ConnectorBaseline.minVersion, "0.3.1")
    }

    // MARK: - SessionViewLog

    func test_session_view_log_scope_isolation() {
        let log = SessionViewLog(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        log.useScope("a")
        log.markViewed("s1", at: 100)
        XCTAssertEqual(log.lastViewed("s1"), 100)
        log.useScope("b")
        XCTAssertNil(log.lastViewed("s1"))
    }
}
