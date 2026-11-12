@testable import DSHFeedbackDomain
import DSHFoundation
import Foundation
import RelayKit
import XCTest

/// 仿真器夹具钩子 `-DSHFeedbackAttachmentBytesDir`（仅 DEBUG）。
///
/// 它只替换**字节来源**：命中文件就返回文件字节，否则照原路走网络。sha256 复核、
/// 写缓存、状态机都还是真实那一套——所以这里用真实的 `FeedbackAttachmentCache` 断言
/// 结局，而不是只断言"读到了文件"。
@MainActor
final class FeedbackAttachmentBytesFixtureTests: XCTestCase {

    /// 1×1 的 PNG（能被 ImageIO 解码，也与真实附件同形）。
    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )!

    private func root(_ label: String) -> TempFeedbackRoot {
        let root = TempFeedbackRoot(label: label)
        addTeardownBlock { root.remove() }
        return root
    }

    private func fixtureDirectory(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-attachment-bytes-\(label)-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func attachment(id: String, digest: String) -> FeedbackAttachment {
        FeedbackAttachment(
            attachmentId: id, name: "preview.png", contentType: "image/png",
            byteSize: Self.png.count, sha256: digest, createdAt: Date(),
            preview: FeedbackAttachmentPreview(
                attachmentId: id + "_preview", contentType: "image/png",
                byteSize: Self.png.count, sha256: digest, width: 1, height: 1),
            compressed: false)
    }

    /// 与生产接线同形：先问夹具，未命中就抛"网络不通"（测试里不连网）。
    private func cache(disk: FeedbackAttachmentDisk,
                       directory: URL) -> FeedbackAttachmentCache {
        let arguments = ["-DSHFeedbackAttachmentBytesDir", directory.path]
        return FeedbackAttachmentCache(disk: disk, fetch: { id, progress in
            if let bytes = FeedbackCenter.automationAttachmentBytes(attachmentId: id,
                                                                   arguments: arguments) {
                progress?(bytes.count, bytes.count)
                return bytes
            }
            throw FeedbackClientError.network("offline-in-test")
        })
    }

    // MARK: - 命中

    func testAFileNamedByAttachmentIdIsServedAndEndsLoaded() async throws {
        let directory = try fixtureDirectory("hit")
        try Self.png.write(to: directory.appendingPathComponent("fa_original_fixture"))
        let disk = FeedbackAttachmentDisk(root: root("bytes-hit").url)
        let digest = FeedbackOutgoingAttachment.sha256Hex(Self.png)
        let target = attachment(id: "fa_original_fixture", digest: digest)
        let cache = cache(disk: disk, directory: directory)

        let bytes = await cache.load(target, variant: .original)

        XCTAssertEqual(bytes, Self.png, "命中夹具文件就返回那份字节")
        XCTAssertEqual(cache.state(for: target, variant: .original), .loaded)
        XCTAssertEqual(disk.cachedBytes(sha256: digest), Self.png, "仍然走真实落缓存这一步")
    }

    // MARK: - 未命中

    func testAMissingFileFallsThroughToTheNetworkPath() async throws {
        let directory = try fixtureDirectory("miss")
        let disk = FeedbackAttachmentDisk(root: root("bytes-miss").url)
        let digest = FeedbackOutgoingAttachment.sha256Hex(Self.png)
        let target = attachment(id: "fa_original_fixture", digest: digest)
        let cache = cache(disk: disk, directory: directory)

        let bytes = await cache.load(target, variant: .original)

        XCTAssertNil(bytes)
        guard case .failed = cache.state(for: target, variant: .original) else {
            return XCTFail("文件缺失就该照原路走网络（这里网络不通 → failed），实际："
                           + "\(cache.state(for: target, variant: .original))")
        }
        XCTAssertNil(disk.cachedBytes(sha256: digest), "失败不写缓存")
    }

    // MARK: - 约定与边界

    func testTheFileNameIsTheAttachmentIdNotTheSha256() throws {
        let directory = try fixtureDirectory("naming")
        let digest = FeedbackOutgoingAttachment.sha256Hex(Self.png)
        // 只按 sha256 命名：**不命中**（约定是 attachmentId）。
        try Self.png.write(to: directory.appendingPathComponent(digest))
        let arguments = ["-DSHFeedbackAttachmentBytesDir", directory.path]
        XCTAssertNil(FeedbackCenter.automationAttachmentBytes(attachmentId: "fa_original_fixture",
                                                              arguments: arguments))
        try Self.png.write(to: directory.appendingPathComponent("fa_original_fixture"))
        XCTAssertEqual(FeedbackCenter.automationAttachmentBytes(attachmentId: "fa_original_fixture",
                                                               arguments: arguments), Self.png)
    }

    func testTheHookNeedsAnAbsolutePathAndAKnownArgument() throws {
        let directory = try fixtureDirectory("paths")
        try Self.png.write(to: directory.appendingPathComponent("fa_1"))
        // 没有这个启动参数：完全不生效（生产默认）。
        XCTAssertNil(FeedbackCenter.automationAttachmentBytes(attachmentId: "fa_1", arguments: []))
        // 相对路径不认（启动参数里的路径一律要求绝对路径，与另外两个钩子同一口径）。
        XCTAssertNil(FeedbackCenter.automationAttachmentBytes(
            attachmentId: "fa_1", arguments: ["-DSHFeedbackAttachmentBytesDir", "relative/dir"]))
        // 参数在但后面没有值：不认。
        XCTAssertNil(FeedbackCenter.automationAttachmentBytes(
            attachmentId: "fa_1", arguments: ["-DSHFeedbackAttachmentBytesDir"]))
    }

    /// 文件名若被 sha256 命中，说明有人把约定写反了——断言"仅 sha256 不命中"就是上面那条；
    /// 这里补一条：目录里完全没有这条附件时返回 nil，调用方必须走网络。
    func testAnUnknownAttachmentIdIsNotServed() throws {
        let directory = try fixtureDirectory("unknown")
        try Self.png.write(to: directory.appendingPathComponent("fa_other"))
        XCTAssertNil(FeedbackCenter.automationAttachmentBytes(
            attachmentId: "fa_1",
            arguments: ["-DSHFeedbackAttachmentBytesDir", directory.path]))
    }
}
