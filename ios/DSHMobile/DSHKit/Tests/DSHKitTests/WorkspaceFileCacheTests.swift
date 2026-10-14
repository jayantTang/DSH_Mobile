import XCTest

@testable import DSHKit

/// 工作区文件缓存的用例（从 App 搬进 DSHKit 的判定，原来一条测试都没有）。
///
/// 每条都对着一个真实踩过的坑：版本化目录（改过的文件不能显示成旧内容）、大小不符即残骸、
/// `.part` 不参与淘汰（裁掉活前缀会让随后的 publish 失败）、`digest` 不能用 `hashValue`。
final class WorkspaceFileCacheTests: XCTestCase {

    private var root: URL!
    private var cache: WorkspaceFileCache!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-wfc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cache = WorkspaceFileCache(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    // MARK: - 纯函数

    func testNameTakesTheLastComponentAndBoundsIt() {
        XCTAssertEqual(WorkspaceFileCache.name(for: "/a/b/report.pdf"), "report.pdf")
        XCTAssertEqual(WorkspaceFileCache.name(for: "拍照 2026.png"), "拍照 2026.png")
        XCTAssertEqual(WorkspaceFileCache.name(for: ""), "file")
        XCTAssertEqual(WorkspaceFileCache.name(for: "x/\(String(repeating: "a", count: 300))").count, 120)
    }

    func testDigestIsStableAcrossCalls() {
        // 关键：不能是 `hashValue`（每次启动都变，会把昨天的缓存目录变成孤儿）。
        XCTAssertEqual(WorkspaceFileCache.digest("scope~path"), WorkspaceFileCache.digest("scope~path"))
        XCTAssertNotEqual(WorkspaceFileCache.digest("a"), WorkspaceFileCache.digest("b"))
        XCTAssertEqual(WorkspaceFileCache.digest(""), "1505")   // 5381 的十六进制，钉住算法而非"某个哈希"
    }

    // MARK: - 版本化目录

    func testDifferentVersionsLandInDifferentDirectories() {
        let old = cache.destination(scopeId: "s", path: "/a/b.txt", version: "1")
        let new = cache.destination(scopeId: "s", path: "/a/b.txt", version: "2")
        XCTAssertNotEqual(old, new, "宿主改了文件就是新版本、新目录：旧副本不可能被当成今天的内容")
        XCTAssertEqual(old.lastPathComponent, new.lastPathComponent, "文件名保持可读")
    }

    func testSameVersionIsStable() {
        XCTAssertEqual(cache.destination(scopeId: "s", path: "/a/b.txt", version: "1"),
                       cache.destination(scopeId: "s", path: "/a/b.txt", version: "1"))
    }

    func testPartialIsTheDestinationWithPartExtension() {
        let complete = cache.destination(scopeId: "s", path: "a.txt", version: "v")
        XCTAssertEqual(cache.partial(scopeId: "s", path: "a.txt", version: "v").pathExtension, "part")
        XCTAssertEqual(cache.partial(scopeId: "s", path: "a.txt", version: "v")
            .deletingPathExtension(), complete)
    }

    // MARK: - 发布 / 命中 / 残骸

    func testPublishMovesPartialIntoPlace() throws {
        let partial = cache.partial(scopeId: "s", path: "a.txt", version: "v")
        try write(partial, bytes: 10)
        let published = try cache.publish(scopeId: "s", path: "a.txt", version: "v")
        XCTAssertEqual(published, cache.destination(scopeId: "s", path: "a.txt", version: "v"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: published.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path), "发布之后不该留 .part")
    }

    func testPublishReplacesAnExistingFile() throws {
        let complete = cache.destination(scopeId: "s", path: "a.txt", version: "v")
        try write(complete, bytes: 3)
        try write(cache.partial(scopeId: "s", path: "a.txt", version: "v"), bytes: 7)
        let published = try cache.publish(scopeId: "s", path: "a.txt", version: "v")
        let size = try FileManager.default.attributesOfItem(atPath: published.path)[.size] as? Int
        XCTAssertEqual(size, 7, "同版本重下要覆盖，不是并存")
    }

    func testExistingReturnsTheFileWhenTheSizeMatches() throws {
        let url = cache.destination(scopeId: "s", path: "a.txt", version: "v")
        try write(url, bytes: 5)
        let hit = cache.existing(scopeId: "s", path: "a.txt", version: "v", bytes: 5)
        XCTAssertEqual(hit?.bytes, 5)
        XCTAssertEqual(hit?.url, url)
    }

    func testExistingDropsDebrisWhenTheSizeDisagrees() throws {
        let url = cache.destination(scopeId: "s", path: "a.txt", version: "v")
        try write(url, bytes: 5)
        XCTAssertNil(cache.existing(scopeId: "s", path: "a.txt", version: "v", bytes: 9),
                     "大小不符是中断写入的残骸，不是命中")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "残骸要就地删掉")
    }

    func testExistingWithoutAnExpectedSizeAcceptsAnythingPresent() throws {
        let url = cache.destination(scopeId: "s", path: "a.txt", version: "v")
        try write(url, bytes: 4)
        XCTAssertEqual(cache.existing(scopeId: "s", path: "a.txt", version: "v", bytes: nil)?.bytes, 4)
    }

    func testMissingFileIsNotAHit() {
        XCTAssertNil(cache.existing(scopeId: "s", path: "nope.txt", version: "v", bytes: 1))
    }

    // MARK: - 丢弃

    func testDiscardRemovesTheWholeVersionDirectory() throws {
        let url = cache.destination(scopeId: "s", path: "a.txt", version: "v")
        try write(url, bytes: 1)
        cache.discard(scopeId: "s", path: "a.txt", version: "v")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    func testDiscardPartialLeavesTheCompleteCopyAlone() throws {
        let url = cache.destination(scopeId: "s", path: "a.txt", version: "v")
        try write(url, bytes: 1)
        let partial = cache.partial(scopeId: "s", path: "a.txt", version: "v")
        try write(partial, bytes: 99)
        cache.discardPartial(scopeId: "s", path: "a.txt", version: "v")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "放弃这次下载不该动已完成的副本")
    }

    func testClearEmptiesEverything() throws {
        try write(cache.destination(scopeId: "s1", path: "a.txt", version: "v"), bytes: 1)
        try write(cache.destination(scopeId: "s2", path: "b.txt", version: "v"), bytes: 1)
        cache.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    // MARK: - 淘汰

    func testTrimDoesNothingUnderBudget() throws {
        let url = cache.destination(scopeId: "s", path: "a.txt", version: "v")
        try write(url, bytes: 10)
        cache.trim(budget: 1_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testTrimDropsTheOldestFirst() throws {
        let old = cache.destination(scopeId: "s", path: "old.txt", version: "v")
        let fresh = cache.destination(scopeId: "s", path: "new.txt", version: "v")
        try write(old, bytes: 100)
        try write(fresh, bytes: 100)
        // 把 old 的修改时间拨到一分钟前，让"最旧先丢"可判定。
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)],
                                              ofItemAtPath: old.path)
        cache.trim(budget: 150)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "最旧的先走")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testTrimNeverTouchesPartFiles() throws {
        // 回归：`.part` 是有人正在下的活前缀，裁掉它会让随后的 publish 失败。
        let partial = cache.partial(scopeId: "s", path: "live.bin", version: "v")
        let complete = cache.destination(scopeId: "s", path: "old.txt", version: "v")
        try write(partial, bytes: 400)
        try write(complete, bytes: 400)
        cache.trim(budget: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path), ".part 不参与淘汰")
        XCTAssertFalse(FileManager.default.fileExists(atPath: complete.path), "完整文件照常被丢")
    }

    func testTrimSkipsPartFilesInTheTotalToo() throws {
        // 既不计入总量也不进删除名单：半到达的文件不该成为"某个完整文件因此活下来"的理由。
        let partial = cache.partial(scopeId: "s", path: "live.bin", version: "v")
        let complete = cache.destination(scopeId: "s", path: "small.txt", version: "v")
        try write(partial, bytes: 10_000)
        try write(complete, bytes: 10)
        cache.trim(budget: 100)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: complete.path), "只按完整文件算总量，10 字节没超")
    }
}
