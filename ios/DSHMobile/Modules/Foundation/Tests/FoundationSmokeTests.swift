import XCTest
@testable import DSHFoundation

/// 平台适配用例（自 DSHMobileTests/PlatformAdaptersTests 迁入，025）。
/// 断言消息一律 ASCII：check:i18n 扫整棵 Modules 树，中文字面量会报硬编码。
@MainActor
final class FoundationSmokeTests: XCTestCase {

    // MARK: - Keychain（只用测试账号，收尾必删）
    //
    // 只在 macOS 跑：裸 xctest 包在 iOS 仿真器上没有钥匙串 entitlement（-34018），
    // iOS 侧覆盖由 DSHMobileTests 宿主冒烟保留一条（025 P5）。
#if os(macOS)

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
#endif

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

// MARK: - PathFormat（028 缺陷3：分量比较，不是字符串前缀）

extension FoundationSmokeTests {
    func test_short_replaces_home_at_component_boundary() {
        XCTAssertEqual(PathFormat.short("/Users/tester/work/x", home: "/Users/tester"), "~/work/x")
    }

    func test_short_does_not_shrink_sibling_prefix() {
        // /Users/testerworkshop 以 /Users/tester 开头但不是它的子路径
        XCTAssertEqual(PathFormat.short("/Users/testerworkshop/x", home: "/Users/tester"), "/Users/testerworkshop/x")
        XCTAssertEqual(PathFormat.short("/Users/tester2/x", home: "/Users/tester"), "/Users/tester2/x")
    }

    func test_short_home_itself_and_trailing_slash() {
        XCTAssertEqual(PathFormat.short("/Users/tester", home: "/Users/tester"), "~")
        XCTAssertEqual(PathFormat.short("/Users/tester/work", home: "/Users/tester/"), "~/work")
    }

    func test_short_no_home_passthrough() {
        XCTAssertEqual(PathFormat.short("/tmp/x", home: nil), "/tmp/x")
        XCTAssertEqual(PathFormat.short("/tmp/x", home: ""), "/tmp/x")
    }
}
