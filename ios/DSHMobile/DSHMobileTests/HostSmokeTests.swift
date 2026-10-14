import XCTest

@testable import DSHMobile

/// 测试宿主自身的冒烟用例（spec 023 T010）。
///
/// 这个 target 存在的理由是"不依赖 UI 的判断要能在快闸里验"：`xcodebuild test` 会把测试包注入
/// App 进程，但不建主界面、不截图、不做手势。下面三条断言钉的就是这个前提——前提没了，
/// 后面所有放进来的用例都会变成慢闸（要人看图）。
///
/// 断言消息与夹具字符串一律用 ASCII：测试代码不是界面文案，写中文会让 `check:i18n` 按
/// "硬编码字符串"报出来（它扫的是整棵 `DSHMobile/` 树，包括本 target）。
final class HostSmokeTests: XCTestCase {

    /// 测试宿主下必须识别出"这是测试"，否则 `RootView` 会被无谓地建起来。
    func testUnitTestHostIsDetected() {
        XCTAssertTrue(
            DSHMobileApp.isUnitTestHost,
            "App did not detect the unit-test host: XCTestConfigurationFilePath is missing or read differently"
        )
    }

    /// 宿主环境变量读到的值与 App 自己的判断一致（防止两边各读一份、各写一套判断）。
    func testHostDetectionMatchesEnvironment() {
        let fromEnvironment = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        XCTAssertEqual(DSHMobileApp.isUnitTestHost, fromEnvironment)
    }

    /// 这个 target 该装的正是"平台专有但不含 UI"的代码：这里拿演示模式的脱敏函数做代表。
    /// 它在截图流程里用得上，但本身是纯函数——不需要界面、不需要中转、不需要看图判定。
    func testPlatformAdjacentCodeIsTestableWithoutUILaunch() {
        XCTAssertFalse(DemoMode.isOn, "demo mode must stay off unless -DSHDemoMode is passed")
        XCTAssertEqual(DemoMode.homePlaceholder, "/Users/you")
        // isOn == false 时两个脱敏函数原样返回（调用点不用加门，见 DemoMode 的头注）。
        XCTAssertEqual(DemoMode.maskedHostName("Jane's MacBook Pro"), "Jane's MacBook Pro")
        XCTAssertEqual(DemoMode.maskedEndpoint("dsh://direct?host=10.0.0.5"),
                       "dsh://direct?host=10.0.0.5")
    }
}
