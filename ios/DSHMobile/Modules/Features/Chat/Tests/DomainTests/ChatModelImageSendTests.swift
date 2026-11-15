@testable import DSHChatDomain
import DSHConnectionAPI
import DSHCore
import DSHKit
import DSHTestingSupport
import XCTest

/// 图片发送：预览/原图上电脑 → `_link/imageCommit` → prompt 只带收据。
///
/// 这些用例走真实 `ChatSendService.send()`（真实上传通道调用顺序、真实 prompt
/// 编码），只有连接层是假的。断言的是线上形状与失败后的草稿恢复，不是"某个方法
/// 被调用过"。
@MainActor
final class ChatModelImageSendTests: XCTestCase {

    private var carrier: FakeCarrier!
    private var hub: HostEventHub!
    private var link: FakeLinkService!
    private var model: ChatModel!
    private var profile: ConnectionProfile!

    /// 上传时读到的真实字节：`(name, data)`。证明上传的是预览 / 原图那一份，
    /// 而不是文件名相同的别的东西。
    private var uploadedBytes: [(name: String, data: Data)] = []
    private var uploadedPaths: [String] = []
    /// 电脑端的暂存路径（`StagedFile.path`），也就是 `_link/imageCommit` 必须引用的路径。
    private var stagedPaths: [String] = []

    override func setUp() {
        super.setUp()
        carrier = FakeCarrier()
        hub = HostEventHub()
        link = FakeLinkService(
            profiles: [TestFixtures.relayProfile()],
            state: .connected(hostHome: "/Users/tester")
        )
        profile = TestFixtures.relayProfile()
        link.activeProfile = profile
        link.clientOverride = HostClientFactory.make(carrier: carrier)
        model = ChatModel()
        model.attach(store: link, hub: hub)
    }

    override func tearDown() async throws {
        await model.close()
        hub.stop()
        model = nil
        hub = nil
        carrier = nil
        link = nil
        profile = nil
        uploadedBytes = []
        uploadedPaths = []
        stagedPaths = []
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func openSession() async throws {
        await model.open(try ChatSeam.summary(id: "s-1", asOfSeq: 12))
        let subscribed = await eventually { self.carrier.calls(to: "session/follow").count == 1 }
        XCTAssertTrue(subscribed, "open() never subscribed")
    }

    private func eventually(deadline: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    private func previewData(_ text: String) -> Data { Data(text.utf8) }

    private func draftImage(
        _ name: String,
        previewText: String,
        original: Data?,
        disposition: ComposerDraftImage.OriginalDisposition = .keep
    ) -> ComposerDraftImage {
        let preview = previewData(previewText)
        return ComposerDraftImage(
            mediaType: "image/jpeg",
            base64: preview.base64EncodedString(),
            name: name,
            preview: NSObject(),
            originalData: original,
            originalMediaType: original == nil ? nil : "image/heic",
            originalName: original == nil ? nil : "\(name).heic",
            previewBytes: preview.count,
            originalBytes: original?.count,
            originalDisposition: disposition
        )
    }

    /// 上传成功、并读回真实字节。
    private func stubUploads() {
        link.uploadFileStub = { [weak self] url, name, sessionId in
            let data = (try? Data(contentsOf: url)) ?? Data()
            self?.uploadedBytes.append((name: name, data: data))
            self?.uploadedPaths.append(url.path)
            let staged = "/Users/tester/.dsh/inbox/\(sessionId)/\(UUID().uuidString)-\(name)"
            self?.stagedPaths.append(staged)
            return StagedFile(path: staged, bytes: data.count)
        }
    }

    private func commitPayload(previewReceipt: String, fileReceipt: String? = nil) -> JSONValue {
        var object: [String: JSONValue] = [
            "preview": .object([
                "receiptId": .string(previewReceipt),
                "image": .object([
                    "attachmentId": .string("sha256:\(previewReceipt)"),
                    "mediaType": .string("image/jpeg"),
                    "bytes": .int(1234),
                    "width": .int(100),
                    "height": .int(80),
                ]),
            ])
        ]
        if let fileReceipt { object["fileReceiptId"] = .string(fileReceipt) }
        return .object(object)
    }

    // MARK: - 成功路径

    func testSendUploadsPreviewAndOriginalThenPromptsWithReceiptsInOrder() async throws {
        try await openSession()
        stubUploads()
        carrier.unaryResponses["session/prompt"] = .success(.object([:]))
        carrier.unaryResponses["_link/imageCommit"] = .success(commitPayload(previewReceipt: "rcpt-p1"))

        let preview = previewData("preview-bytes")
        let original = Data("original-heic-bytes".utf8)
        let image = draftImage("photo-1.jpg", previewText: "preview-bytes", original: original)
        model.draft = "看看这张"
        model.addDraftImages([image])

        await model.send()

        XCTAssertEqual(model.lastError, nil)
        XCTAssertEqual(model.draft, "")

        // 上传：预览一次、原图一次，字节原样。
        XCTAssertEqual(link.uploadFileCalls.count, 2)
        XCTAssertEqual(uploadedBytes.first?.data, preview)
        XCTAssertEqual(uploadedBytes.last?.data, original,
                       "原图字节必须原样上传，不能被预览替换")
        // 暂存名必须互不相同：预览与原图的显示名常常相同（都叫 photo-1.jpg），
        // 用显示名暂存会落成同一个路径，后传的原图覆盖预览，连接器读到的字节
        // 就与声明的媒体类型不符（Host 直接拒收）。
        XCTAssertNotEqual(link.uploadFileCalls[0].name, link.uploadFileCalls[1].name,
                          "预览与原图的暂存名不能相同")
        XCTAssertTrue(link.uploadFileCalls[0].name.hasPrefix("preview-"))
        XCTAssertTrue(link.uploadFileCalls[1].name.hasPrefix("original-"))

        // 提交：暂存路径来自上传回包，原图作为变体（不是文件）。
        let commit = try XCTUnwrap(carrier.calls(to: "_link/imageCommit").first)
        XCTAssertEqual(commit.args?["sessionId"]?.stringValue, "s-1")
        XCTAssertEqual(commit.args?["preview"]?["path"]?.stringValue, stagedPaths.first)
        XCTAssertEqual(commit.args?["preview"]?["name"]?.stringValue, "photo-1.jpg",
                       "显示名仍是用户看到的那个名字，与暂存文件名无关")
        XCTAssertEqual(commit.args?["original"]?["path"]?.stringValue, stagedPaths.last)
        XCTAssertNil(commit.args?["sendOriginalAsFile"])

        // prompt：文字第一段，然后预览收据。
        let request = try XCTUnwrap(carrier.calls(to: "session/prompt").first?.args?["request"])
        let content = try XCTUnwrap(request["content"]?.arrayValue)
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"]?.stringValue, "text")
        XCTAssertEqual(content[0]["text"]?.stringValue, "看看这张")
        XCTAssertEqual(content[1]["type"]?.stringValue, "file")
        XCTAssertEqual(content[1]["receiptId"]?.stringValue, "rcpt-p1")

        // 暂存文件在提交后删掉（只删本 App 建的）。
        for path in uploadedPaths {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                           "发送完成后暂存文件必须删除：\(path)")
        }
    }

    func testSendAsFileAppendsTheFileReceiptAfterThePreview() async throws {
        try await openSession()
        stubUploads()
        carrier.unaryResponses["session/prompt"] = .success(.object([:]))
        // 一次提交同时带预览收据与文件收据：prompt 里两个 `.file` 必须按这个顺序。
        carrier.unaryResponses["_link/imageCommit"] = .success(
            commitPayload(previewReceipt: "rcpt-p2", fileReceipt: "rcpt-file2")
        )

        let bigOriginal = Data(repeating: 0x41, count: 21 * 1024 * 1024)
        let image = draftImage("big.heic", previewText: "preview-big",
                               original: bigOriginal, disposition: .sendAsFile)
        model.draft = ""
        model.addDraftImages([image])

        await model.send()

        XCTAssertEqual(model.lastError, nil)
        let request = try XCTUnwrap(carrier.calls(to: "session/prompt").first?.args?["request"])
        let content = try XCTUnwrap(request["content"]?.arrayValue)
        XCTAssertEqual(content.count, 2, "只有一张图：预览收据 + 文件收据")
        XCTAssertEqual(content[0]["type"]?.stringValue, "file")
        XCTAssertEqual(content[0]["receiptId"]?.stringValue, "rcpt-p2")
        XCTAssertEqual(content[1]["type"]?.stringValue, "file")
        XCTAssertEqual(content[1]["receiptId"]?.stringValue, "rcpt-file2")

        let commit = try XCTUnwrap(carrier.calls(to: "_link/imageCommit").first)
        XCTAssertEqual(commit.args?["sendOriginalAsFile"]?.boolValue, true,
                       "超限原图必须按文件发送，不产生原图变体")
        XCTAssertEqual(uploadedBytes.last?.data.count, bigOriginal.count,
                       "超限判定的依据是真实字节数")
    }

    // MARK: - 旧连接器回退

    func testUnsupportedCommitFallsBackToInlinePreviewInsteadOfLosingTheImage() async throws {
        try await openSession()
        stubUploads()
        carrier.unaryResponses["session/prompt"] = .success(.object([:]))
        carrier.unaryResponses["_link/imageCommit"] = .failure(
            DSHRPCFailure(code: "link/unsupported", message: "connector too old")
        )

        let preview = previewData("legacy-preview")
        let image = draftImage("photo-1.jpg", previewText: "legacy-preview",
                               original: Data("orig".utf8))
        model.draft = "老连接器也要能发"
        model.addDraftImages([image])

        await model.send()

        XCTAssertNil(model.lastError, "回退不是失败")
        XCTAssertEqual(model.draftImages.count, 0)
        let request = try XCTUnwrap(carrier.calls(to: "session/prompt").first?.args?["request"])
        let content = try XCTUnwrap(request["content"]?.arrayValue)
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"]?.stringValue, "text")
        XCTAssertEqual(content[1]["type"]?.stringValue, "image")
        XCTAssertEqual(content[1]["data"]?.stringValue, preview.base64EncodedString(),
                       "回退路径必须把预览字节原样内联")
        XCTAssertEqual(content[1]["mediaType"]?.stringValue, "image/jpeg")
    }

    // MARK: - 失败恢复

    func testCommitFailureRestoresTextAndImageIncludingOriginalBytes() async throws {
        try await openSession()
        stubUploads()
        carrier.unaryResponses["_link/imageCommit"] = .failure(
            DSHRPCFailure(code: "image/upload-failed", message: "the connector refused")
        )

        let preview = previewData("preview-keep")
        let original = Data("original-keep".utf8)
        let image = draftImage("photo-1.jpg", previewText: "preview-keep", original: original)
        model.draft = "这张要留下"
        model.addDraftImages([image])

        await model.send()

        XCTAssertTrue(carrier.calls(to: "session/prompt").isEmpty,
                      "提交失败就不该继续发 prompt")
        XCTAssertEqual(model.draft, "这张要留下", "文字必须回到输入框")
        let restored = try XCTUnwrap(model.draftImages.first)
        XCTAssertEqual(restored.id, image.id)
        XCTAssertEqual(restored.base64, preview.base64EncodedString())
        XCTAssertEqual(restored.originalData, original, "原图字节必须一起恢复，否则重试会降级成只有预览")
        XCTAssertEqual(restored.originalDisposition, .keep)
        let error = try XCTUnwrap(model.lastError)
        XCTAssertFalse(error.isEmpty)

        // 重试沿用同一个 requestId（宿主按它去重）。
        carrier.unaryResponses["_link/imageCommit"] = .success(commitPayload(previewReceipt: "rcpt-retry"))
        carrier.unaryResponses["session/prompt"] = .success(.object([:]))
        await model.send()
        let ids = carrier.calls(to: "session/prompt").compactMap {
            $0.args?["request"]?["requestId"]?.stringValue
        }
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(model.draftImages.count, 0, "重试成功后草稿清空")
    }

    func testNetworkFailureDuringUploadIsNotTreatedAsAnOldConnector() async throws {
        try await openSession()
        link.uploadFileStub = { _, _, _ in
            throw DSHRPCFailure(code: "host/offline", message: "the computer is not online")
        }

        let image = draftImage("photo-1.jpg", previewText: "offline-preview", original: nil,
                               disposition: .unavailable)
        model.draft = "离线"
        model.addDraftImages([image])

        await model.send()

        XCTAssertTrue(carrier.calls(to: "_link/imageCommit").isEmpty,
                      "上传就失败了，不该再提交")
        XCTAssertTrue(carrier.calls(to: "session/prompt").isEmpty)
        XCTAssertEqual(model.draft, "离线")
        XCTAssertEqual(model.draftImages.count, 1,
                       "网络失败不能把图当旧连接器回退掉，也不能丢")
        XCTAssertFalse(try XCTUnwrap(model.lastError).isEmpty)
    }

    func testUploadedScratchCopiesAreRemovedEvenWhenCommitFails() async throws {
        try await openSession()
        stubUploads()
        carrier.unaryResponses["_link/imageCommit"] = .failure(
            DSHRPCFailure(code: "image/upload-failed", message: "nope")
        )
        let image = draftImage("photo-1.jpg", previewText: "scratch", original: Data("orig".utf8))
        model.draft = ""
        model.addDraftImages([image])

        await model.send()

        XCTAssertEqual(uploadedPaths.count, 2)
        for path in uploadedPaths {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                           "失败路径同样要清理临时文件：\(path)")
        }
    }

}
