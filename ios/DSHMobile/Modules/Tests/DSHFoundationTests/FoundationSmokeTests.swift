import XCTest
@testable import DSHFoundation

/// 模块骨架测试：真实迁移（T008）后替换为各文件的行为用例。
@MainActor
final class FoundationSmokeTests: XCTestCase {
    func test_keychain_roundtrip() throws {
        let account = "test.\(UUID().uuidString)"
        try Keychain.set("v", for: account)
        XCTAssertEqual(Keychain.get(account), "v")
        Keychain.remove(account)
        XCTAssertNil(Keychain.get(account))
    }

    func test_install_channel_baseline() {
        XCTAssertEqual(InstallChannel.current, .development)
        XCTAssertFalse(InstallChannel.development.acceptsInAppUpdate)
        XCTAssertTrue(InstallChannel.overTheAir.acceptsInAppUpdate)
    }

    func test_connector_baseline_version() {
        XCTAssertEqual(ConnectorBaseline.minVersion, "0.3.1")
    }

    func test_session_view_log_scope_isolation() {
        let log = SessionViewLog(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        log.useScope("a")
        log.markViewed("s1", at: 100)
        XCTAssertEqual(log.lastViewed("s1"), 100)
        log.useScope("b")
        XCTAssertNil(log.lastViewed("s1"))
    }
}
