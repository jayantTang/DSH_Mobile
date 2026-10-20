import DSHCore
import DSHTestingSupport
import XCTest

/// 版本横幅（`UpdateChecker`）：什么时候该提示、什么时候连请求都不该发。
///
/// feed 地址从构造注入，所以这里用 loopback 假服务器而不是打真网络：被测代码自己建
/// `URLSession`（`URLSession.shared`），只有真实 HTTP 地址能进到那条路径
/// （`URLProtocol.registerClass` 看不见它，理由写在 `LoopbackHTTPStub` 的头注里）。
///
/// 断言消息一律 ASCII：check:i18n 扫整棵 Modules 树。
@MainActor
final class UpdateCheckerTests: XCTestCase {

    private static let feedPath = "/app-update.json"

    private var stub: LoopbackHTTPStub!

    override func setUpWithError() throws {
        try super.setUpWithError()
        stub = try LoopbackHTTPStub()
    }

    override func tearDown() {
        stub?.stop()
        stub = nil
        super.tearDown()
    }

    /// `InstallChannel` 住在 DSHFoundation，这个测试 target 不依赖它，所以装法一律靠
    /// 参数类型推断着写（`.overTheAir` 之类），不写下类型的名字。
    /// 装法必须显式给：测试进程里 `InstallChannel.current` 是 `.development`（既没有收据
    /// 也没有描述文件），用默认值会把 OTA 那半条路测成"不查"。
    private func otaChecker() -> UpdateChecker {
        UpdateChecker(feed: feedURL, channel: .overTheAir)
    }

    private var feedURL: URL {
        stub.baseURL.appendingPathComponent("app-update.json")
    }

    private func publish(build: String, shortVersion: String = "9.9.9", status: Int = 200) {
        let body = #"{"shortVersion":"\#(shortVersion)","build":"\#(build)","installPage":"https://example.test/install"}"#
        stub.on(Self.feedPath, answer: .json(body, status: status))
    }

    private func publishRaw(_ body: String, status: Int = 200) {
        stub.on(Self.feedPath, answer: .json(body, status: status))
    }

    // MARK: - 该提示的

    func test_a_newer_published_build_raises_the_banner() async {
        publish(build: "99999999.9999", shortVersion: "9.9.9")
        let checker = otaChecker()

        await checker.refresh()

        XCTAssertEqual(checker.available?.build, "99999999.9999", "a newer build must be offered")
        XCTAssertEqual(checker.available?.shortVersion, "9.9.9")
        XCTAssertEqual(checker.available?.installPage, "https://example.test/install")
        XCTAssertEqual(stub.count(Self.feedPath), 1, "one stamp is one request")
    }

    // MARK: - 不该提示的

    func test_the_installed_build_does_not_raise_the_banner() async {
        publish(build: UpdateChecker.currentBuild)
        let checker = otaChecker()

        await checker.refresh()

        XCTAssertNil(checker.available, "the running build is not newer than itself")
        XCTAssertEqual(stub.count(Self.feedPath), 1, "the feed is still read, it just says nothing")
    }

    /// 用户在后台装完了新版：横幅必须自己下来，不能一直挂着。
    func test_the_banner_comes_down_once_the_installed_build_catches_up() async {
        publish(build: "99999999.9999")
        let checker = otaChecker()
        await checker.refresh()
        XCTAssertNotNil(checker.available, "setup: the newer build is offered")

        publish(build: UpdateChecker.currentBuild)
        await checker.refresh()

        XCTAssertNil(checker.available, "an installed update must take the banner down")
        XCTAssertEqual(stub.count(Self.feedPath), 2, "the check repeats on purpose")
    }

    func test_a_404_leaves_the_banner_down() async {
        publishRaw(#"{"ok":false}"#, status: 404)
        let checker = otaChecker()

        await checker.refresh()

        XCTAssertNil(checker.available, "a missing stamp is not an update")
    }

    func test_malformed_body_leaves_the_banner_down() async {
        publishRaw("<html>this is not json</html>")
        let checker = otaChecker()

        await checker.refresh()

        XCTAssertNil(checker.available, "an unreadable stamp is not an update")
    }

    func test_a_json_answer_missing_fields_leaves_the_banner_down() async {
        publishRaw(#"{"build":"99999999.9999"}"#)
        let checker = otaChecker()

        await checker.refresh()

        XCTAssertNil(checker.available, "a half decoded stamp must not become a banner")
    }

    func test_an_unreachable_feed_leaves_the_banner_down() async {
        publish(build: "99999999.9999")
        let checker = otaChecker()
        stub.stop()

        await checker.refresh()

        XCTAssertNil(checker.available, "being offline is not an update")
    }

    /// 非 OTA 装法（TestFlight / App Store）：这份 feed 说的版本装不上，
    /// 所以既不发请求也不提示——2026-10-11 那条反馈就是点了横幅被要求先删 App。
    func test_a_non_ota_channel_never_asks_the_feed() async {
        publish(build: "99999999.9999")

        let appStore = UpdateChecker(feed: feedURL, channel: .appStore)
        await appStore.refresh()
        XCTAssertNil(appStore.available, "a TestFlight or App Store build must not show the banner")

        let development = UpdateChecker(feed: feedURL, channel: .development)
        await development.refresh()
        XCTAssertNil(development.available, "a simulator or local build must not show the banner")

        XCTAssertEqual(stub.requests.count, 0, "a non OTA install must not even ask")
    }
}
