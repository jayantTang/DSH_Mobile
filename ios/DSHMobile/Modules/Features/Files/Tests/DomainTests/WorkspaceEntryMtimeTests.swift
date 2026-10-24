import DSHFilesDomain
import DSHKit
import DSHTestingSupport
import XCTest

/// `mtimeMs` 的解析（设计 20261024-工作区文件修改时间 §M3）。
///
/// 三态：有 / 无 / 畸形。畸形不许把整条目录打不开——解析失败的只是那一个字段。
///
/// 走模型而不是直接解 JSON：`WorkspaceDirectoryEntry.init(json:)` 与
/// `WorkspaceDirectoryListing.init(json:)` 都是 internal，而 `FilesSeams` 的注释也写明
/// "a case in another module reaches them exactly the way the app does — through the wire"。
@MainActor
final class WorkspaceEntryMtimeTests: XCTestCase {

    /// Held for the life of the case: the model keeps its store weakly.
    private var link: FakeLinkService!

    override func tearDown() {
        link = nil
        super.tearDown()
    }

    /// 用一份 `workspaceFiles/list` 回包跑一次真实的加载，返回模型看到的行。
    private func load(_ entries: [JSONValue]) async -> [WorkspaceDirectoryEntry] {
        let carrier = FakeCarrier()
        let model = WorkspaceFilesModel(scope: FilesSeam.scope())
        link = FilesSeam.link(carrier)
        model.attach(to: link)
        carrier.unaryResponses["workspaceFiles/list"] = .success(FilesSeam.listing(path: "", entries: entries))
        await model.loadDirectory("")
        return model.visibleEntries
    }

    func test_entry_carries_mtime_as_an_absolute_instant() async throws {
        let rows = await load([FilesSeam.entry("a.txt", type: "file", size: 5, mtimeMs: 1_761_263_400_000)])
        let value = try XCTUnwrap(rows.first)
        XCTAssertEqual(value.mtime, Date(timeIntervalSince1970: 1_761_263_400))
    }

    func test_entry_without_mtime_has_nil() async throws {
        let rows = await load([FilesSeam.entry("a.txt", type: "file", size: 5)])
        XCTAssertNil(try XCTUnwrap(rows.first).mtime, "without the connector patch there is no time to show")
    }

    func test_a_null_mtime_is_the_same_as_absent() async throws {
        let rows = await load([.object(["name": .string("a.txt"), "type": .string("file"), "mtimeMs": .null])])
        XCTAssertNil(try XCTUnwrap(rows.first).mtime)
    }

    func test_a_malformed_mtime_does_not_lose_the_row() async throws {
        let malformed: [JSONValue] = [
            .string("yesterday"),
            .bool(true),
            .object(["ms": .int(1)]),
            .array([.int(1)]),
            .double(1e30),
        ]
        for value in malformed {
            let rows = await load([.object(["name": .string("a.txt"), "type": .string("file"), "mtimeMs": value])])
            let entry = try XCTUnwrap(rows.first, "a malformed mtimeMs must not lose the row")
            XCTAssertNil(entry.mtime, "malformed reads as unknown, never an invented time")
            XCTAssertEqual(entry.name, "a.txt")
        }
    }

    func test_a_directory_row_also_carries_mtime() async throws {
        let rows = await load([
            FilesSeam.entry("src", type: "directory", mtimeMs: 1_700_000_000_000),
            FilesSeam.entry("notes.txt", type: "file", size: 1024),
        ])
        let dir = try XCTUnwrap(rows.first { $0.name == "src" })
        XCTAssertEqual(dir.mtime, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(dir.isDirectory)
        XCTAssertNil(dir.sizeText, "a directory has no size but does have a time")
        XCTAssertEqual(rows.first { $0.name == "notes.txt" }?.sizeText, "1.0 KB", "the pre-existing fields are unchanged")
    }
}
