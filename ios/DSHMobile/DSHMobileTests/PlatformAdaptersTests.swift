import XCTest

@testable import DSHMobile

/// 平台相邻代码的隔离单测（spec 023 的 S4 / T050）。
///
/// 这一组用例要证明的事：**"留在 iOS 侧"不等于"只能靠仿真器截图验"**。下面三块都碰平台 API
/// （Bundle / Security.framework / 启动参数），但只要有可注入的缝或纯函数，就能在
/// `xcodebuild test` 里断言——不启界面、不截图。
///
/// 断言消息一律 ASCII：`check:i18n` 扫的是整棵 `DSHMobile/` 树（含本 target），中文测试字面量会被
/// 当成硬编码的界面文案报出来（与 `HostSmokeTests` 同一条约定）。
///
/// 同一批里**没有** `SessionAlerts`：它的 `UserDefaults.standard` 与
/// `UNUserNotificationCenter.current()` 是硬连接（`private let`），写不出隔离的用例——
/// 那是"缺注入面"的缺口，记在 `specs/023-app-dshkit-boundary/s4-evidence.md` 里，
/// 不靠改动用户的模拟器设置来凑一条测试。
@MainActor
final class PlatformAdaptersTests: XCTestCase {

    // 构建号比较的用例已随逻辑搬进 DSHKit（`DSHKitTests/BuildStampTests.swift`）：
    // 同一类判断只留一份实现，用例也只留一份，免得两处断言各自漂移。

    // MARK: - 钥匙串（只用测试账号，收尾必删）

    private let testAccount = "dsh-unit-test.round-trip"

    override func tearDown() {
        // 不给模拟器留垃圾：这个账号名专门为此存在，不会撞上任何真实档案。
        Keychain.remove(testAccount)
        super.tearDown()
    }

    func testKeychainRoundTrip() {
        Keychain.remove(testAccount)
        XCTAssertNil(Keychain.get(testAccount), "the test account starts clean")
        do {
            try Keychain.set("secret-value", for: testAccount)
        } catch {
            return XCTFail("keychain write failed: \(error)")
        }
        XCTAssertEqual(Keychain.get(testAccount), "secret-value")
    }

    func testKeychainOverwriteWins() {
        try? Keychain.set("first", for: testAccount)
        try? Keychain.set("second", for: testAccount)
        XCTAssertEqual(Keychain.get(testAccount), "second", "writing the same account twice must update, not fail")
    }

    func testKeychainRemoveMakesItDisappear() {
        try? Keychain.set("value", for: testAccount)
        Keychain.remove(testAccount)
        XCTAssertNil(Keychain.get(testAccount))
    }

    func testKeychainMissingAccountIsNilNotCrash() {
        Keychain.remove("dsh-unit-test.never-written")
        XCTAssertNil(Keychain.get("dsh-unit-test.never-written"))
    }

    // MARK: - 安装渠道判定

    func testOnlyOverTheAirAcceptsInAppUpdate() {
        // 文案与横幅的判据：只有 OTA 装法能靠这个横幅真的装上。
        XCTAssertTrue(InstallChannel.overTheAir.acceptsInAppUpdate)
        XCTAssertFalse(InstallChannel.appStore.acceptsInAppUpdate)
        XCTAssertFalse(InstallChannel.development.acceptsInAppUpdate)
    }

    func testChannelRawValuesMatchTheLaunchArgumentVocabulary() {
        // `-DSHInstallChannel overTheAir|appStore|development` 直接吃这三个值，改名会让钩子失效。
        XCTAssertEqual(InstallChannel(rawValue: "overTheAir"), .overTheAir)
        XCTAssertEqual(InstallChannel(rawValue: "appStore"), .appStore)
        XCTAssertEqual(InstallChannel(rawValue: "development"), .development)
        XCTAssertNil(InstallChannel(rawValue: "ota"))
    }

    func testSimulatorBuildIsDevelopmentWithoutReceiptOrProfile() {
        // 仿真器里既没有 App Store 收据也没有内嵌描述文件——这是环境事实，
        // 用例把它写下来：哪天这条红了，说明判定逻辑或构建配置变了。
        XCTAssertEqual(InstallChannel.current, .development)
    }
}
