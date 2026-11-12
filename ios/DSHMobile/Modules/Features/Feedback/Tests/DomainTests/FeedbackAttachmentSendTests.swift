@testable import DSHFeedbackDomain
import DSHFoundation
import DSHTestingSupport
import Foundation
import RelayKit
import XCTest

/// 发送编排（v4）：先传附件、全部成功后再提交。
///
/// 这些用例只驱动 `FeedbackSendJob` 与两根落盘（待上传队列 / 附件字节），不碰
/// 界面：四种结局（成功 / 失败 / 取消 / 超时归失败）都要落到可见状态，而且
/// **附件失败时一个字节的正文都不许提交**。
@MainActor
final class FeedbackAttachmentSendTests: FeedbackCenterTestCase {

    /// 服务端下发的附件能力（用例里把上限压小，便于构造边界）。
    static let openLimits = FeedbackLimits(
        attachments: FeedbackAttachmentLimits(
            maxPerMessage: 8, maxFileBytes: 1024, maxTotalBytes: 4096, types: ["png"]))

    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    private func attachment(_ name: String = "a.png") -> FeedbackOutgoingAttachment {
        FeedbackOutgoingAttachment(name: name, contentType: "image/png", data: png,
                                   width: 10, height: 20)
    }

    /// 一个逻辑附件：单文件模式（主对象就是 original，没有第二份字节）。
    private func prepared(_ name: String = "a.png", slot: Int = 0) -> FeedbackPreparedAttachment {
        FeedbackPreparedAttachment(slot: slot, primary: attachment(name))
    }

    /// 配对模式：预览 + 原图两份字节（原图用同样的 PNG，只为验证"两行"）。
    private func paired(slot: Int = 0) -> FeedbackPreparedAttachment {
        FeedbackPreparedAttachment(
            slot: slot,
            primary: FeedbackOutgoingAttachment(name: "a.jpg", contentType: "image/jpeg",
                                                data: png, width: 10, height: 20,
                                                role: .preview),
            original: FeedbackOutgoingAttachment(name: "a.jpg", contentType: "image/jpeg",
                                                 data: png, width: 20, height: 40,
                                                 role: .original))
    }

    private func beginJSON(_ id: String = "fa_1", state: String = "pending") -> LoopbackHTTPStub.Answer {
        .json(#"{"ok":true,"attachmentId":"\#(id)","state":"\#(state)","byteSize":8,\#(shaField)"createdAt":1000}"#)
    }

    private var shaField: String {
        #""sha256":"\#(FeedbackOutgoingAttachment.sha256Hex(png))","#
    }

    private func uploadJSON(_ id: String = "fa_1") -> LoopbackHTTPStub.Answer {
        .json(#"{"ok":true,"attachmentId":"\#(id)","state":"stored","byteSize":8,\#(shaField)"storedAt":1500}"#)
    }

    private func submitJSON(bound: Int) -> LoopbackHTTPStub.Answer {
        .json(#"{"ok":true,"threadId":"th_new","ticketKey":"fk_new","createdAt":2000,"messageId":"fm_1","attachmentsBound":\#(bound)}"#)
    }

    private func makeJob(
        _ stub: LoopbackHTTPStub,
        root: TempFeedbackRoot,
        text: String = "body",
        attachments: [FeedbackPreparedAttachment]? = nil,
        clientRef: String = "ref-1",
        limits: FeedbackLimits = FeedbackAttachmentSendTests.openLimits,
        reply: (threadId: String, ticketKey: String?)? = nil
    ) -> FeedbackSendJob {
        FeedbackSendJob(
            client: RelayFeedbackClient(relayURL: stub.baseURL, deviceToken: "dt_test"),
            clientRef: clientRef, text: text, subject: nil,
            attachments: attachments ?? [prepared()],
            limits: limits,
            disk: FeedbackAttachmentDisk(root: root.url),
            pendingStore: FeedbackPendingUploadStore(root: root.url),
            reply: reply,
            technical: ("1.0", "iPhone15,4", "18.2")
        )
    }

    // MARK: - 附件失败：一个字节的正文都不提交

    func testAttachmentFailureSubmitsNothingAndKeepsTheDraftForRetry() async throws {
        let stub = try makeStub()
        let root = makeRoot("attach-fail")
        stub.on("/feedback/attachment/begin", answer: beginJSON())
        stub.on("/feedback/attachment/upload", answer: .json(
            #"{"ok":false,"error":{"code":"feedback/too-large"}}"#, status: 413))
        stub.on("/feedback/submit", answer: submitJSON(bound: 1))

        let outcome = await makeJob(stub, root: root).run()

        XCTAssertEqual(outcome, .failed(.client(.tooLong)))
        XCTAssertEqual(stub.count("/feedback/submit"), 0, "附件失败时正文不许提交")
        let queue = FeedbackPendingUploadStore(root: root.url).queue(for: "ref-1")
        XCTAssertEqual(queue.map(\.slot), [0], "待上传记录留着，下一次重试接着传")
        XCTAssertEqual(queue.first?.attachmentId, "fa_1")
    }

    // MARK: - 只发正文

    func testTextOnlyDiscardsDraftsAndStillSendsTheLetter() async throws {
        let stub = try makeStub()
        let root = makeRoot("attach-text-only")
        stub.on("/feedback/attachment/begin", answer: beginJSON())
        stub.on("/feedback/attachment/upload", answer: .json(
            #"{"ok":false,"error":{"code":"feedback/too-large"}}"#, status: 413))
        stub.on("/feedback/attachment/discard", answer: .json(
            #"{"ok":true,"attachmentId":"fa_1","deleted":true}"#))
        stub.on("/feedback/submit", answer: submitJSON(bound: 0))

        let job = makeJob(stub, root: root)
        let failed = await job.run()
        XCTAssertEqual(failed, .failed(.client(.tooLong)))
        XCTAssertEqual(stub.count("/feedback/submit"), 0)

        let outcome = await job.sendTextOnly()

        guard case .sent(let receipt) = outcome else {
            return XCTFail("expected the text-only send to succeed, got \(outcome)")
        }
        XCTAssertEqual(receipt.attachmentsBound, 0)
        XCTAssertEqual(stub.count("/feedback/attachment/discard"), 1, "先把已传的草稿 reap 掉")
        XCTAssertEqual(stub.count("/feedback/submit"), 1)
        let body = try XCTUnwrap(stub.requests("/feedback/submit").first?.json)
        XCTAssertEqual(body["text"] as? String, "body")
        XCTAssertEqual(body["clientRef"] as? String, "ref-1", "discard 全成功 → 沿用同一个 clientRef")
        XCTAssertTrue(FeedbackPendingUploadStore(root: root.url).queue(for: "ref-1").isEmpty)
    }

    // MARK: - 取消

    func testCancelDiscardsTheUploadedDraftAndDropsTheQueue() async throws {
        let stub = try makeStub()
        let root = makeRoot("attach-cancel")
        stub.on("/feedback/attachment/discard", answer: .json(
            #"{"ok":true,"attachmentId":"fa_1","deleted":true}"#))
        // 模拟一次中断：队列里已经有一条传过、还没绑定的草稿。
        let pending = FeedbackPendingUploadStore(root: root.url)
        var uploads = pending.load()
        uploads.put(FeedbackPendingUpload(
            slot: 0, attachmentId: "fa_1", state: "stored", name: "a.png",
            contentType: "image/png", byteSize: 8,
            sha256: FeedbackOutgoingAttachment.sha256Hex(png), createdAt: Date()), for: "ref-1")
        pending.save(uploads)

        let outcome = await makeJob(stub, root: root).cancel()

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(stub.count("/feedback/attachment/discard"), 1)
        XCTAssertEqual(stub.count("/feedback/submit"), 0, "取消不提交正文")
        XCTAssertTrue(pending.queue(for: "ref-1").isEmpty)
    }

    // MARK: - 重试不重传已存附件

    func testRetryDoesNotReuploadAnAlreadyStoredAttachment() async throws {
        let stub = try makeStub()
        let root = makeRoot("attach-retry")
        stub.on("/feedback/attachment/begin", answer: beginJSON(state: "stored"))
        stub.on("/feedback/attachment/upload", answer: uploadJSON())
        stub.on("/feedback/submit", answer: submitJSON(bound: 1))

        let outcome = await makeJob(stub, root: root).run()

        guard case .sent(let receipt) = outcome else {
            return XCTFail("expected a sent receipt, got \(outcome)")
        }
        XCTAssertEqual(receipt.attachmentsBound, 1)
        XCTAssertEqual(receipt.messageId, "fm_1")
        XCTAssertEqual(stub.count("/feedback/attachment/upload"), 0,
                       "begin 的幂等命中说它已经是 stored：不再重传字节")
        XCTAssertEqual(stub.count("/feedback/submit"), 1)
    }

    // MARK: - attachmentsBound 与本地不一致

    func testBoundMismatchIsAFailureInsteadOfSilentlyMissingAttachments() async throws {
        let stub = try makeStub()
        let root = makeRoot("attach-mismatch")
        stub.on("/feedback/attachment/begin", answer: beginJSON())
        stub.on("/feedback/attachment/upload", answer: uploadJSON())
        stub.on("/feedback/submit", answer: submitJSON(bound: 0))

        let outcome = await makeJob(stub, root: root).run()

        XCTAssertEqual(outcome, .failed(.boundMismatch(local: 1, bound: 0)))
        XCTAssertEqual(FeedbackSendJob.clientError(for: .boundMismatch(local: 1, bound: 0)),
                       .decoding("attachments-bound-mismatch local=1 bound=0"))
    }

    // MARK: - 本地校验（不发任何请求）

    func testLimitsRejectTheQueueBeforeAnyRequest() async throws {
        let stub = try makeStub()
        let root = makeRoot("attach-limits")
        let tight = FeedbackLimits(attachments: FeedbackAttachmentLimits(
            maxPerMessage: 1, maxFileBytes: 1024, maxTotalBytes: 4096, types: ["png"]))

        let outcome = await makeJob(stub, root: root,
                                    attachments: [prepared("a.png", slot: 0),
                                                  prepared("b.png", slot: 1)],
                                    limits: tight).run()

        XCTAssertEqual(outcome, .failed(.attachmentLimit(limit: 1, requested: 2)))
        XCTAssertTrue(stub.requests.isEmpty, "本地能判的错误不应该发请求")

        let closed = FeedbackLimits()
        let closedOutcome = await makeJob(stub, root: root, limits: closed).run()
        XCTAssertEqual(closedOutcome, .failed(.attachmentsUnavailable),
                       "服务端没有 limits.attachments 就是关闭附件，不拿常量兜底")
        XCTAssertTrue(stub.requests.isEmpty)
    }

    // MARK: - 待上传队列：7 天过期

    func testPendingUploadsExpireAfterSevenDays() throws {
        let root = makeRoot("attach-expiry")
        let store = FeedbackPendingUploadStore(root: root.url)
        let now = Date()
        var uploads = FeedbackPendingUploads()
        uploads.put(FeedbackPendingUpload(
            slot: 0, name: "old.png", contentType: "image/png", byteSize: 8,
            sha256: "old", createdAt: now.addingTimeInterval(-8 * 24 * 3600)), for: "ref-old")
        uploads.put(FeedbackPendingUpload(
            slot: 0, name: "fresh.png", contentType: "image/png", byteSize: 8,
            sha256: "fresh", createdAt: now.addingTimeInterval(-24 * 3600)), for: "ref-fresh")
        store.save(uploads)

        var loaded = store.load()
        let dropped = loaded.prune(now: now)
        store.save(loaded)

        XCTAssertEqual(dropped, ["ref-old"])
        XCTAssertTrue(store.queue(for: "ref-old").isEmpty)
        XCTAssertEqual(store.queue(for: "ref-fresh").map(\.name), ["fresh.png"],
                       "7 天内的记录留着，跨重启还能接着传")
    }

    /// 清缓存只有一个入口：镜像、附件字节、待上传队列一起清。
    func testClearingTheMirrorAlsoDropsAttachmentBytesAndPendingUploads() async throws {
        let stub = try makeStub()
        let root = makeRoot("attach-clear")
        let disk = FeedbackAttachmentDisk(root: root.url)
        let pending = FeedbackPendingUploadStore(root: root.url)
        disk.stage(attachment(), clientRef: "ref-1", slot: 0, role: .original)
        disk.storeCache(png, sha256: "cache-digest")
        var uploads = FeedbackPendingUploads()
        uploads.put(FeedbackPendingUpload(slot: 0, name: "a.png", contentType: "image/png",
                                          byteSize: 8, sha256: "x", createdAt: Date()),
                    for: "ref-1")
        pending.save(uploads)

        let center = FeedbackCenter(store: root.store(), minimumRefreshInterval: 0,
                                    endpointProvider: {
            FeedbackCenter.Endpoint(url: stub.baseURL, deviceToken: nil)
        }, attachmentDisk: disk, pendingUploads: pending)
        center.clearLocalMirror()

        XCTAssertNil(disk.stagedBytes(clientRef: "ref-1", slot: 0, role: .original))
        XCTAssertNil(disk.cachedBytes(sha256: "cache-digest"))
        XCTAssertTrue(pending.queue(for: "ref-1").isEmpty)
    }
}
