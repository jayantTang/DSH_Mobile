import DSHConnectionAPI
import DSHKit
import DSHSessionsDomain
import DSHTestingSupport
import XCTest

/// 027 — 新建会话里的目录浏览器（`DirectoryBrowserModel`）。
///
/// 它只有一层壳：宿主走它自己的文件系统，一次答一层，手机不拼路径、不缓存层级。
/// 所以可测的东西就三件——空目录怎么显示、失败之后屏幕上的那一层还在不在、
/// 用户看到的失败说的是不是人话。
@MainActor
final class DirectoryBrowserModelTests: SessionsDomainTestCase {

    private static let listMethod = "directoryPicker/list"
    private var browser: DirectoryBrowserModel!

    override func setUp() {
        super.setUp()
        browser = DirectoryBrowserModel()
        browser.attach(to: fake)
    }

    override func tearDown() async throws {
        browser = nil
        try await super.tearDown()
    }

    /// 空目录：照实显示"这一层没有子目录"，不是失败也不是空白。
    func testEmptyLevelIsShownAndTheDraftFollowsTheHost() async throws {
        carrier.unaryResponses[Self.listMethod] = .success(Wire.listing(path: "/Users/tester", entries: []))
        await browser.start()

        XCTAssertEqual(browser.currentPath, "/Users/tester")
        XCTAssertEqual(browser.pathDraft, "/Users/tester", "the path field holds what the host answered")
        XCTAssertTrue(browser.entries.isEmpty)
        XCTAssertFalse(browser.truncated)
        XCTAssertNil(browser.failure)
        XCTAssertFalse(browser.isLoading)
        XCTAssertTrue(browser.canGoUp)
        XCTAssertEqual(browser.crumbs.map(\.name), ["Users", "tester"])

        // 起始这一下是"列宿主家目录"：参数里不带 path，而不是带空串。
        let first = try XCTUnwrap(carrier.calls(to: Self.listMethod).first)
        XCTAssertNil(first.args?["path"])

        // "上一级"就是再问宿主一次，手机自己不做路径拼接。
        await browser.goUp()
        XCTAssertEqual(carrier.calls(to: Self.listMethod).last?.args?["path"]?.stringValue, "/Users")

        // 只有空白的草稿不构成跳转。
        let callsBefore = carrier.calls(to: Self.listMethod).count
        browser.pathDraft = "   "
        await browser.submitDraft()
        XCTAssertEqual(carrier.calls(to: Self.listMethod).count, callsBefore,
                       "a blank draft must not become a request")
        XCTAssertNil(browser.failure)
    }

    /// 失败：留住屏幕上的那一层，并说明原因。
    func testFailureKeepsTheLevelOnScreenAndNamesTheReason() async throws {
        carrier.unaryResponses[Self.listMethod] = .success(
            Wire.listing(path: "/Users/tester", entries: [(name: "proj", path: "/Users/tester/proj")]))
        await browser.start()
        XCTAssertEqual(browser.entries.map(\.name), ["proj"])

        let refusal = DSHRPCFailure(code: "directory-picker/unreadable", message: "permission denied")
        carrier.unaryResponses[Self.listMethod] = .failure(refusal)
        await browser.open("/Users/tester/locked")

        XCTAssertEqual(browser.failure, refusal.localizedDescription)
        XCTAssertFalse(browser.failure?.isEmpty ?? true)
        XCTAssertEqual(browser.currentPath, "/Users/tester",
                       "a failed jump must not throw away the level the user was looking at")
        XCTAssertEqual(browser.pathDraft, "/Users/tester")
        XCTAssertEqual(browser.entries.map(\.name), ["proj"])
        XCTAssertEqual(carrier.calls(to: Self.listMethod).count, 2)

        // pin（已知问题，本次不改产品代码）：`DirectoryBrowserModel.describe(_:)`——把
        // `directory-picker/unavailable` / `exists` 换成用户能动手的那几句——**没有任何调用点**，
        // 两个失败分支都走 `LinkErrors.describe`。所以这里钉住的是"用户看到宿主那句原始说法"。
        XCTAssertFalse(browser.failure?.contains("browse") ?? true,
                       "the friendly wording is not applied today; see the note above")

        // 没连上：不发请求，也不动屏幕上那一层。
        fake.clientOverride = nil
        await browser.open("/Users/tester/proj")
        XCTAssertNotNil(browser.failure)
        XCTAssertNotEqual(browser.failure, refusal.localizedDescription,
                          "the not-connected branch has its own message")
        XCTAssertEqual(browser.currentPath, "/Users/tester")
        XCTAssertEqual(carrier.calls(to: Self.listMethod).count, 2,
                       "no link means no request, not a request that fails")
    }
}
