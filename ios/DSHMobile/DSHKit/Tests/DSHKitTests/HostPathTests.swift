import XCTest

@testable import DSHKit

/// 宿主目录路径的用例（spec 023 边界收敛：从 App 的 `DirectoryBrowserModel` 抽出）。
///
/// 两条判定看着简单，边界不少：根目录、结尾斜杠、相对路径。原来它们写在 `@Observable`
/// 的模型里，只能靠手点目录页验。
final class HostPathTests: XCTestCase {

    func testParentOfANormalPath() {
        XCTAssertEqual(HostPath.parent(of: "/Users/x/project"), "/Users/x")
        XCTAssertEqual(HostPath.parent(of: "/Users/x"), "/Users")
    }

    func testTrailingSlashIsIgnored() {
        XCTAssertEqual(HostPath.parent(of: "/Users/x/project/"), "/Users/x")
        XCTAssertEqual(HostPath.parent(of: "/Users/"), "/")
    }

    func testRootHasNoParent() {
        XCTAssertNil(HostPath.parent(of: "/"))
    }

    func testSingleComponentRelativePathHasNoParent() {
        XCTAssertNil(HostPath.parent(of: "project"))
        XCTAssertNil(HostPath.parent(of: "project/"))
    }

    func testPathAndItsParentDiffer() {
        // 判据是"结果与自身相同就算没有上一级"，这里把它写成断言。
        for path in ["/a/b", "/a/b/", "/a", "~/x"] {
            if let parent = HostPath.parent(of: path) {
                XCTAssertNotEqual(parent, path)
            }
        }
    }

    func testCanGoUp() {
        XCTAssertTrue(HostPath.canGoUp(from: "/Users/x"))
        XCTAssertFalse(HostPath.canGoUp(from: "/"))
        XCTAssertFalse(HostPath.canGoUp(from: nil), "还没读到目录时不能往上走")
    }
}
