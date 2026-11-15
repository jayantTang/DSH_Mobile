@testable import DSHChatDomain
import DSHConnectionAPI
import DSHKit
import XCTest

/// 原图状态机（契约 §2.4 / SR-02.11 / SR-08.02）。
///
/// 这些用例只用真实字节：分片是真切开的、SHA-256 是按字节算的、磁盘缓存是临时
/// 目录里真读写的。没有 sleep、没有"等待状态变过去"，每个 `await` 返回时状态已经
/// 写定；"没有自动重试"因此可以直接用调用次数断言。
@MainActor
final class AttachmentImageVariantsTests: XCTestCase {

    private var cacheRoot: URL!
    private var diskCache: AttachmentDiskCache!
    private var variants: AttachmentImageVariants!
    private var stub: Stub!

    override func setUp() {
        super.setUp()
        cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-variants-\(UUID().uuidString)", isDirectory: true)
        diskCache = AttachmentDiskCache(root: cacheRoot)
        stub = Stub()
        variants = AttachmentImageVariants(
            diskCache: diskCache,
            scope: "test-scope",
            lookupLoader: { [stub] id in try stub!.lookup(id) },
            chunkLoader: { [stub] id, offset, length in try await stub!.chunk(id, offset, length) }
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheRoot)
        variants = nil
        diskCache = nil
        stub = nil
        cacheRoot = nil
        super.tearDown()
    }

    // MARK: - 元数据

    func testAvailableLookupBecomesReadyWithoutDownloadingBytes() async {
        let meta = metadata(bytes: 600 * 1024, id: "sha256:original")
        stub.lookupResults = [.success(.available(meta))]

        await variants.lookupOriginal(sessionId: "s-1", attachment: preview("sha256:preview"))

        XCTAssertEqual(variants.state(sessionId: "s-1", attachmentId: "sha256:preview"),
                       .ready(meta))
        XCTAssertEqual(variants.originalMetadata(sessionId: "s-1", attachmentId: "sha256:preview"),
                       meta)
        XCTAssertEqual(stub.lookupCalls, 1)
        XCTAssertEqual(stub.chunkOffsets, [], "查元数据不得读字节")
        XCTAssertNil(variants.originalData(sessionId: "s-1", attachmentId: "sha256:preview"))
    }

    func testMissingCleanedAndUnsupportedAllBecomeUnavailableAndAreNotRetried() async {
        let cases: [(Result<ImageOriginalLookup, any Error>, String)] = [
            (.success(.unavailable(reason: "missing")), "missing"),
            (.failure(DSHRPCFailure(code: "image-original/cleaned", message: "gone")), "cleaned"),
            (.failure(DSHRPCFailure(code: "link/unsupported", message: "old connector")), "unsupported"),
        ]
        for (index, entry) in cases.enumerated() {
            let image = preview("sha256:preview-\(index)")
            stub.lookupResults = [entry.0]

            await variants.lookupOriginal(sessionId: "s-1", attachment: image)
            let state = variants.state(sessionId: "s-1", attachmentId: image.attachmentId)
            XCTAssertEqual(state, .unavailable(reason: entry.1))

            // 再查、再下载都不该再发请求：不可用是终态，不是网络失败。
            await variants.lookupOriginal(sessionId: "s-1", attachment: image)
            await variants.downloadOriginal(sessionId: "s-1", attachment: image)
            XCTAssertEqual(stub.lookupCalls, index + 1,
                           "\(entry.1) 被自动重试了")
            XCTAssertEqual(stub.chunkOffsets, [], "不可用时不能下载字节")
        }
    }

    /// 「默认不下载原图」：只读状态、字节、展示图都不该发任何请求；
    /// 只有显式 `lookupOriginal` 才查元数据，查元数据本身也不读字节。
    func testNothingIsRequestedUntilTheUserAsks() async {
        let image = preview("sha256:preview")

        _ = variants.state(sessionId: "s-1", attachmentId: image.attachmentId)
        _ = variants.originalMetadata(sessionId: "s-1", attachmentId: image.attachmentId)
        _ = variants.originalData(sessionId: "s-1", attachmentId: image.attachmentId)
        XCTAssertEqual(stub.lookupCalls, 0, "列表/首帧不得自动查原图")
        XCTAssertEqual(stub.chunkOffsets, [], "列表/首帧不得自动取原图字节")

        stub.lookupResults = [.success(.available(metadata(bytes: 600 * 1024, id: "sha256:o")))]
        await variants.lookupOriginal(sessionId: "s-1", attachment: image)
        XCTAssertEqual(stub.lookupCalls, 1)
        XCTAssertEqual(stub.chunkOffsets, [], "查元数据仍然不读字节")
    }

    // MARK: - 分片下载与校验

    func testChunkedDownloadAssemblesBytesInOrderAndVerifiesTheHash() async throws {
        let bytes = Self.deterministicBytes(count: 600 * 1024)
        let meta = metadata(bytes: bytes.count, id: Self.sha256ID(bytes))
        stub.lookupResults = [.success(.available(meta))]
        stub.chunkBody = { offset, length in
            let end = min(bytes.count, offset + length)
            return ImageOriginalChunk(
                data: bytes.subdata(in: offset..<end),
                offset: offset,
                eof: end == bytes.count,
                bytes: bytes.count
            )
        }
        // 预览缓存里先放一份：原图下载不得覆盖它（SR-08.02）。
        let previewBytes = Data("preview-bytes".utf8)
        diskCache.save(previewBytes, scope: "test-scope",
                       attachmentId: "sha256:preview", variant: "preview-variant")

        await variants.downloadOriginal(sessionId: "s-1", attachment: preview("sha256:preview"))

        XCTAssertEqual(variants.state(sessionId: "s-1", attachmentId: "sha256:preview"),
                       .ready(meta))
        XCTAssertEqual(variants.originalData(sessionId: "s-1", attachmentId: "sha256:preview"),
                       bytes, "拼接结果必须与源字节逐字节一致")
        XCTAssertEqual(stub.chunkOffsets, [0, 512 * 1024], "分片必须按 offset 顺序、每片 512 KiB")
        XCTAssertEqual(stub.chunkLengths, [512 * 1024, bytes.count - 512 * 1024])
        XCTAssertEqual(diskCache.load(scope: "test-scope", attachmentId: "sha256:preview",
                                      variant: "preview-variant"), previewBytes,
                       "原图落盘只写自己的 variant，预览缓存原样保留")
        XCTAssertNil(diskCache.load(scope: "test-scope", attachmentId: "sha256:preview"),
                     "原图不得写进预览的缓存条目")
    }

    /// 分片请求的键必须是**预览**的 attachmentId：连接器的索引以预览 id 为键，
    /// 原图 id 只是校验摘要。传成原图 id 的教训来自 2026-11-15 的仿真器实测
    /// （表现成一直「正在下载原图」或「原图不可用」）。
    func testChunkRequestsAreKeyedByThePreviewAttachmentId() async throws {
        let bytes = Self.deterministicBytes(count: 600 * 1024)
        let meta = metadata(bytes: bytes.count, id: Self.sha256ID(bytes))
        stub.lookupResults = [.success(.available(meta))]
        stub.chunkBody = { offset, length in
            let end = min(bytes.count, offset + length)
            return ImageOriginalChunk(
                data: bytes.subdata(in: offset..<end), offset: offset,
                eof: end >= bytes.count, bytes: bytes.count
            )
        }

        await variants.lookupOriginal(sessionId: "s-1", attachment: preview("sha256:preview"))
        await variants.downloadOriginal(sessionId: "s-1", attachment: preview("sha256:preview"))

        XCTAssertEqual(stub.chunkIds, Array(repeating: "sha256:preview", count: stub.chunkOffsets.count),
                       "分片必须按预览 id 取，不能拿原图的摘要当键")
        XCTAssertEqual(variants.state(sessionId: "s-1", attachmentId: "sha256:preview"),
                       .ready(meta))
    }

    func testProgressIsObservableBetweenChunks() async throws {
        let bytes = Self.deterministicBytes(count: 600 * 1024)
        let meta = metadata(bytes: bytes.count, id: Self.sha256ID(bytes))
        stub.lookupResults = [.success(.available(meta))]
        let probe = ProgressProbe()
        probe.variants = variants
        stub.chunkBody = { offset, length in
            let end = min(bytes.count, offset + length)
            return ImageOriginalChunk(
                data: bytes.subdata(in: offset..<end), offset: offset,
                eof: end == bytes.count, bytes: bytes.count
            )
        }
        stub.beforeChunk = { offset, _ in
            guard offset > 0 else { return }
            let current = await MainActor.run { () -> Double? in
                guard let variants = probe.variants,
                      case .loading(let progress) = variants.state(
                          sessionId: "s-1", attachmentId: "sha256:preview"
                      )
                else { return nil }
                return progress
            }
            probe.progress = current
        }

        await variants.downloadOriginal(sessionId: "s-1", attachment: preview("sha256:preview"))

        let observed = try XCTUnwrap(probe.progress)
        XCTAssertEqual(observed, Double(512 * 1024) / Double(bytes.count), accuracy: 0.0001,
                       "第二片开始前，第一片的进度必须已经写进状态")
        XCTAssertEqual(variants.state(sessionId: "s-1", attachmentId: "sha256:preview"),
                       .ready(meta))
    }

    func testHashMismatchFailsWithoutBecomingReadyOrWritingTheCache() async {
        let bytes = Self.deterministicBytes(count: 1024)
        // 元数据自称是另一份字节的哈希：模拟传输损坏 / 索引指错对象。
        let meta = metadata(bytes: bytes.count, id: Self.sha256ID(Data("other".utf8)))
        stub.lookupResults = [.success(.available(meta))]
        stub.chunkBody = { offset, length in
            let end = min(bytes.count, offset + length)
            return ImageOriginalChunk(
                data: bytes.subdata(in: offset..<end), offset: offset,
                eof: end == bytes.count, bytes: bytes.count
            )
        }
        let previewBytes = Data("preview".utf8)
        diskCache.save(previewBytes, scope: "test-scope",
                       attachmentId: "sha256:preview", variant: "preview-variant")

        await variants.downloadOriginal(sessionId: "s-1", attachment: preview("sha256:preview"))

        guard case .failed(let message) = variants.state(
            sessionId: "s-1", attachmentId: "sha256:preview"
        ) else {
            return XCTFail("哈希不匹配必须是失败态，不能变成 ready")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertNil(variants.originalData(sessionId: "s-1", attachmentId: "sha256:preview"))
        XCTAssertNil(diskCache.load(scope: "test-scope", attachmentId: "sha256:preview",
                                    variant: AttachmentImageVariants.cacheVariant(meta)),
                     "校验不通过绝不写缓存")
        XCTAssertEqual(diskCache.load(scope: "test-scope", attachmentId: "sha256:preview",
                                      variant: "preview-variant"), previewBytes,
                       "原图失败不污染预览缓存")
    }

    func testTruncatedOriginalIsRejectedEvenWhenTheChunkSaysEOF() async {
        let bytes = Self.deterministicBytes(count: 1000)
        let meta = metadata(bytes: 2000, id: Self.sha256ID(bytes))
        stub.lookupResults = [.success(.available(meta))]
        stub.chunkBody = { _, _ in
            ImageOriginalChunk(data: bytes, offset: 0, eof: true, bytes: 2000)
        }

        await variants.downloadOriginal(sessionId: "s-1", attachment: preview("sha256:preview"))

        guard case .failed = variants.state(
            sessionId: "s-1", attachmentId: "sha256:preview"
        ) else {
            return XCTFail("截断的内容不得标记完成（SR-08.02）")
        }
        XCTAssertNil(variants.originalData(sessionId: "s-1", attachmentId: "sha256:preview"))
    }

    // MARK: - 离线与手动重试

    func testOfflineDownloadFailsOnceAndOnlyRetriesWhenAskedAgain() async throws {
        let bytes = Self.deterministicBytes(count: 2048)
        let meta = metadata(bytes: bytes.count, id: Self.sha256ID(bytes))
        let offline = DSHRPCFailure(code: "host/offline", message: "computer offline")
        stub.lookupResults = [.success(.available(meta))]
        stub.chunkBody = { _, _ in throw offline }

        await variants.downloadOriginal(sessionId: "s-1", attachment: preview("sha256:preview"))

        guard case .failed(let message) = variants.state(
            sessionId: "s-1", attachmentId: "sha256:preview"
        ) else {
            return XCTFail("离线应落成可重试的失败态")
        }
        XCTAssertEqual(message, LinkErrors.describe(offline),
                       "文案要能行动：说清电脑不在线，而不是内部错误原文")
        XCTAssertEqual(stub.chunkOffsets, [0], "失败后不得自动重试")

        // 用户再点一次：同样的调用成功，状态回到 ready。
        stub.chunkBody = { offset, length in
            let end = min(bytes.count, offset + length)
            return ImageOriginalChunk(
                data: bytes.subdata(in: offset..<end), offset: offset,
                eof: end == bytes.count, bytes: bytes.count
            )
        }
        await variants.downloadOriginal(sessionId: "s-1", attachment: preview("sha256:preview"))

        XCTAssertEqual(variants.state(sessionId: "s-1", attachmentId: "sha256:preview"),
                       .ready(meta))
        XCTAssertEqual(variants.originalData(sessionId: "s-1", attachmentId: "sha256:preview"),
                       bytes)
        XCTAssertEqual(stub.chunkOffsets.count, 2, "只有用户再点一次才发第二次请求")
    }

    func testRetryAfterHashMismatchCanSucceedWithCorrectMetadata() async {
        let bytes = Self.deterministicBytes(count: 4096)
        let wrong = metadata(bytes: bytes.count, id: Self.sha256ID(Data("wrong".utf8)))
        let right = metadata(bytes: bytes.count, id: Self.sha256ID(bytes))
        stub.lookupResults = [.success(.available(wrong))]
        stub.chunkBody = { offset, length in
            let end = min(bytes.count, offset + length)
            return ImageOriginalChunk(
                data: bytes.subdata(in: offset..<end), offset: offset,
                eof: end == bytes.count, bytes: bytes.count
            )
        }
        let image = preview("sha256:preview")
        await variants.downloadOriginal(sessionId: "s-1", attachment: image)
        guard case .failed = variants.state(sessionId: "s-1", attachmentId: image.attachmentId) else {
            return XCTFail("先失败")
        }

        // 连接器补好了索引：下一次查询拿到正确元数据，重试成功。
        stub.lookupResults = [.success(.available(right))]
        await variants.downloadOriginal(sessionId: "s-1", attachment: image)

        XCTAssertEqual(variants.state(sessionId: "s-1", attachmentId: image.attachmentId),
                       .ready(right))
        XCTAssertEqual(variants.originalData(sessionId: "s-1", attachmentId: image.attachmentId),
                       bytes)
    }

    // MARK: - Fixtures

    private func preview(_ id: String) -> ContentBlock.ImageAttachment {
        ContentBlock.ImageAttachment(
            attachmentId: id, mediaType: "image/jpeg", bytes: 12,
            width: 10, height: 10, name: "photo.jpg"
        )
    }

    private func metadata(bytes: Int, id: String) -> ImageOriginalMetadata {
        ImageOriginalMetadata(attachmentId: id, name: "photo.heic",
                              bytes: bytes, mediaType: "image/heic")
    }

    static func sha256ID(_ data: Data) -> String {
        "sha256:" + AttachmentImageVariants.sha256Hex(data)
    }

    static func deterministicBytes(count: Int) -> Data {
        Data((0..<count).map { UInt8(($0 &* 31 &+ 7) % 251) })
    }

    /// 可编程的原图加载器：记录调用、按脚本回值。
    final class Stub: @unchecked Sendable {
        private let lock = NSLock()
        private var storedLookups: [Result<ImageOriginalLookup, any Error>] = []
        private var lookupCount = 0
        private var chunkCalls: [(id: String, offset: Int, length: Int)] = []
        private var body: (@Sendable (Int, Int) throws -> ImageOriginalChunk)?
        var beforeChunk: (@Sendable (Int, Int) async -> Void)?

        var lookupResults: [Result<ImageOriginalLookup, any Error>] {
            get { lock.withLock { storedLookups } }
            set { lock.withLock { storedLookups = newValue } }
        }

        var chunkBody: (@Sendable (Int, Int) throws -> ImageOriginalChunk)? {
            get { lock.withLock { body } }
            set { lock.withLock { body = newValue } }
        }

        var lookupCalls: Int { lock.withLock { lookupCount } }
        var chunkOffsets: [Int] { lock.withLock { chunkCalls.map(\.offset) } }
        var chunkIds: [String] { lock.withLock { chunkCalls.map(\.id) } }
        var chunkLengths: [Int] { lock.withLock { chunkCalls.map(\.length) } }

        func lookup(_ attachmentId: String) throws -> ImageOriginalLookup {
            let result: Result<ImageOriginalLookup, any Error>? = lock.withLock {
                lookupCount += 1
                let index = min(lookupCount - 1, max(storedLookups.count - 1, 0))
                return storedLookups.isEmpty ? nil : storedLookups[index]
            }
            guard let result else {
                throw NSError(domain: "Stub", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "no lookup stub"])
            }
            return try result.get()
        }

        func chunk(_ attachmentId: String, _ offset: Int, _ length: Int) async throws -> ImageOriginalChunk {
            let body: (@Sendable (Int, Int) throws -> ImageOriginalChunk)? = lock.withLock {
                chunkCalls.append((id: attachmentId, offset: offset, length: length))
                return self.body
            }
            await beforeChunk?(offset, length)
            guard let body else {
                throw NSError(domain: "Stub", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "no chunk stub"])
            }
            return try body(offset, length)
        }
    }

    /// 在第二片请求前读一次真实状态（用于证明进度可观察）。
    final class ProgressProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var storedVariants: AttachmentImageVariants?
        private var storedProgress: Double?

        var variants: AttachmentImageVariants? {
            get { lock.withLock { storedVariants } }
            set { lock.withLock { storedVariants = newValue } }
        }

        var progress: Double? {
            get { lock.withLock { storedProgress } }
            set { lock.withLock { storedProgress = newValue } }
        }
    }
}
