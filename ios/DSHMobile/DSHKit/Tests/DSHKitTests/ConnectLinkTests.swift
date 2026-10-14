import XCTest

@testable import DSHKit

/// 连接 URL 解析的用例（spec 024：`ConnectLink` 从 App 搬进 DSHKit 之后补的）。
///
/// 解析的对象是**别人生成的链接**（桌面端出二维码、测试台造链接），所以编码语义要按生成方
/// 那套来：`URLSearchParams` 是表单编码，空格写作 `+`。这条差别在界面上表现为设备名显示成
/// `Jayant+MacBook+Pro`（2026-10-14 连接管理页实拍）。
final class ConnectLinkTests: XCTestCase {

    private func url(_ string: String) throws -> URL {
        try XCTUnwrap(URL(string: string))
    }

    // MARK: - 编码语义

    func testFormEncodedPlusBecomesSpace() throws {
        let link = ConnectLink(url: try url("dsh://pair?relay=https://relay.example&code=A+B"))
        guard case .pair(_, let code) = try XCTUnwrap(link) else { return XCTFail("应当是 pair") }
        XCTAssertEqual(code, "A B")
    }

    func testEncodedPlusStaysAPlus() throws {
        // `%2B` 才是真正的加号：先还原空格再百分号解码的顺序不能反。
        let link = ConnectLink(url: try url("dsh://pair?relay=https://relay.example&code=A%2BB"))
        guard case .pair(_, let code) = try XCTUnwrap(link) else { return XCTFail("应当是 pair") }
        XCTAssertEqual(code, "A+B")
    }

    func testValueIsTrimmed() throws {
        let link = ConnectLink(url: try url("dsh://direct?host=192.0.2.20&port=54499&token=%20t%20"))
        guard case .direct(_, let token) = try XCTUnwrap(link) else { return XCTFail("应当是 direct") }
        XCTAssertEqual(token, "t")
    }

    // MARK: - 两种产品形状

    func testPairShape() throws {
        let link = ConnectLink(url: try url("dsh://pair?relay=https://relay.example&code=ABCD-1234"))
        guard case .pair(let relay, let code) = try XCTUnwrap(link) else { return XCTFail("应当是 pair") }
        XCTAssertEqual(relay.absoluteString, "https://relay.example")
        XCTAssertEqual(code, "ABCD-1234")
    }

    func testPairShapeWithTripleSlash() throws {
        // 动作既能落在 host，也能落在 path（`dsh://pair…` 与 `dsh:///pair…` 都要认）。
        let link = ConnectLink(url: try url("dsh:///pair?relay=https://relay.example&code=ABCD-1234"))
        guard case .pair = try XCTUnwrap(link) else { return XCTFail("应当是 pair") }
    }

    func testDirectShapeDefaultsToTheDocumentedPort() throws {
        let link = ConnectLink(url: try url("dsh://direct?host=192.0.2.20&token=secret"))
        guard case .direct(let base, let token) = try XCTUnwrap(link) else { return XCTFail("应当是 direct") }
        XCTAssertEqual(base.absoluteString, "http://192.0.2.20:54499")
        XCTAssertEqual(token, "secret")
    }

    func testUnrecognizedShapesAreRejected() throws {
        XCTAssertNil(ConnectLink(url: try url("https://pair?relay=https://relay.example&code=X")))
        XCTAssertNil(ConnectLink(url: try url("dsh://pair?relay=https://relay.example")))
        XCTAssertNil(ConnectLink(url: try url("dsh://direct?host=192.0.2.20")))
        XCTAssertNil(ConnectLink(url: try url("dsh://nonsense?a=b")))
    }

    #if DEBUG
    func testClaimedRelayShapeKeepsTheDeviceName() throws {
        // 这条形状只在 Debug 下存在（自动化配对用），设备名是它唯一带文案的字段。
        let text = "dsh://relay?relay=https://relay.example&agent=agt_1&token=tok"
            + "&name=Jayant+MacBook+Pro"
        let link = ConnectLink(url: try url(text))
        guard case .claimedRelay(_, let agentId, _, let name) = try XCTUnwrap(link) else {
            return XCTFail("应当是 claimedRelay")
        }
        XCTAssertEqual(agentId, "agt_1")
        XCTAssertEqual(name, "Jayant MacBook Pro", "表单编码的空格要还原，否则连接管理页显示成 Jayant+MacBook+Pro")
    }
    #endif
}
