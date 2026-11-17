import DSHConnectionAPI
import DSHCore
import DSHFoundation
import DSHKit
import Foundation
import RelayKit

/// 上行发送服务：文本走管道或旧 echo 路径，文件走中转上传。
/// 只持 ChatModel 的弱引用，状态仍归 ChatModel 所有。
@MainActor
final class ChatSendService {
    private unowned let model: ChatModel

    /// 一次失败但可能已被宿主收下的发送。重发同样内容时复用它，宿主按
    /// requestId 去重，避免“响应丢了、用户再点一次”变成两条 prompt。
    private struct RetryTicket {
        let sessionId: String
        let text: String
        let imageIds: [UUID]
        let mode: SessionPromptRequest.Mode
        let requestId: String
    }
    private var retryTicket: RetryTicket?

    init(model: ChatModel) { self.model = model }

    private var draft: String {
        get { model.draft }
        set { model.draft = newValue }
    }
    private var draftImages: [ComposerDraftImage] {
        get { model.draftImages }
        set { model.draftImages = newValue }
    }
    private var store: (any LinkService)? { model.store }
    private var session: SessionSummary? { model.session }
    private var steerNext: Bool { model.steerNext }
    private var isRunning: Bool { model.isRunning }
    private var pipelineBridge: ChatPipelineBridge? { model.pipelineBridge }
    private var composer: ComposerState { model.composer }
    private var timeline: ChatTimeline {
        get { model.timeline }
        set { model.timeline = newValue }
    }
    private var messageLayer: MessageLayer? { model.messageLayer }
    private var sessionScope: String? { model.sessionScope }
    private var scrollSignal: Int {
        get { model.scrollSignal }
        set { model.scrollSignal = newValue }
    }
    private var sendSignal: Int {
        get { model.sendSignal }
        set { model.sendSignal = newValue }
    }
    private var isAwaitingTurnStart: Bool {
        get { model.isAwaitingTurnStart }
        set { model.isAwaitingTurnStart = newValue }
    }
    private var awaitingTimeout: Task<Void, Never>? {
        get { model.awaitingTimeout }
        set { model.awaitingTimeout = newValue }
    }
    private var lastError: String? {
        get { model.lastError }
        set { model.lastError = newValue }
    }
    private var isUploadingFile: String? {
        get { model.isUploadingFile }
        set { model.isUploadingFile = newValue }
    }
    private func noteWantsBottom() { model.noteWantsBottom() }


    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = draftImages
        guard !text.isEmpty || !images.isEmpty,
              let link = store,
              let client = link.chatHost,
              let session
        else { return }
        let owner = session.sessionId

        let mode: SessionPromptRequest.Mode = (steerNext && isRunning) ? .steer : .queue
        // T022：管道模式下纯文本走 MessagePipeline（乐观插入贴底 → 落库 pending →
        // 网络 → 下行 rpcId 确认原地替换）。带附件仍走旧路径——附件的压缩/上传与
        // echo 耦合在现有 send 里，管道化留给后续任务（本任务不接管）。
        if images.isEmpty, pipelineBridge != nil {
            await sendViaPipeline(text: text, mode: mode, owner: owner)
            return
        }
        // Which conversation this text belongs to, fixed here: the user may
        // switch away while the send is in flight, and neither the clear nor a
        // failure's restore may land on whatever happens to be on screen then.
        // Cleared optimistically so the field empties the instant you send, but
        // restored if the host refuses — losing typed text to a transient
        // failure is worse than seeing it come back.
        draft = ""
        composer.discard(sessionId: owner)

        // The request id is minted here because the host stores it on the
        // durable message's source; that is what lets the transcript replace
        // this optimistic row instead of showing the message twice. If this is
        // the same text/images/session as a failed attempt, reuse its id: the
        // host persists it and dedupes the retry (verified against the host on
        // 2026-11-02). A changed draft gets a new id.
        let imageIds = images.map(\.id)
        let requestId: String
        if let ticket = retryTicket,
           ticket.sessionId == owner,
           ticket.text == text,
           ticket.imageIds == imageIds,
           ticket.mode == mode {
            requestId = ticket.requestId
            retryTicket = nil
        } else {
            requestId = UUID().uuidString
            retryTicket = nil
        }
        enqueueOptimisticQueue(requestId: requestId, text: text, images: images, mode: mode)
        timeline.echoUserPrompt(requestId: requestId, text: text)
        scrollSignal += 1
        // 发送自己的消息一律贴底（spec 009「跟底两态」钦定例外，tasks T017）。
        noteWantsBottom()
        isAwaitingTurnStart = true
        // If the host is already mid-turn the message sits in its queue, and
        // `timeline.isTurnOpen` already reports running; otherwise a turn
        // starts within a second. Either way this must not latch forever.
        awaitingTimeout?.cancel()
        awaitingTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.isAwaitingTurnStart = false
        }

        // Cleared only once the bytes are on their way; a failed send puts the
        // pictures back alongside the text.
        draftImages.removeAll()

        do {
            // 图片先经现有文件上传通道落到电脑（`StagedFile.path`），再让连接器
            // 把预览交给 Host、把原图存成变体。旧连接器在任一步回 `unsupported`
            // 时整批退回内联预览——发得出去比走新路更重要。
            let content = try await uploadedPromptContent(
                text: text, images: images, owner: owner,
                requestId: requestId, client: client, link: link
            )
            try await client.prompt(
                SessionPromptRequest(
                    requestId: requestId,
                    sessionId: session.sessionId,
                    mode: mode,
                    content: content
                )
            )
        } catch {
            isAwaitingTurnStart = false
            isUploadingFile = nil
            // Back to the conversation it was typed in — visible if the user is
            // still there, waiting quietly if they have moved on.
            // `session` was captured by the guard at the top of this function,
            // so it is this send's own session — not whatever is on screen now.
            model.withdrawOptimisticQueued(rpcId: requestId)
            composer.restore(text: text, images: images, for: owner,
                             isCurrent: session.sessionId == owner)
            retryTicket = RetryTicket(sessionId: owner, text: text,
                                      imageIds: imageIds, mode: mode,
                                      requestId: requestId)
            lastError = LinkErrors.describe(error)
        }
    }

    // MARK: - 图片变体上行

    /// 把每张图上传到电脑并提交，返回 prompt 内容的全部段落。
    ///
    /// 每张图逐阶段写 `uploadState`（写暂存文件 → 已落盘 → 已提交），所以排队条带
    /// 与输入区的进度来自真实阶段。任何一张失败都抛出：由 `send()` 恢复草稿，
    /// 已上传的暂存文件由每张图自己的 `defer` 删掉。
    private func uploadedPromptContent(
        text: String,
        images: [ComposerDraftImage],
        owner: String,
        requestId: String,
        client: any ChatHosting,
        link: any LinkService
    ) async throws -> [PromptContentPart] {
        guard !images.isEmpty else {
            return ChatModel.promptContent(text: text, images: images)
        }
        isUploadingFile = images.count == 1
            ? images[0].name
            : "\(images.count) 张图片"
        defer { isUploadingFile = nil }

        var commits: [ComposerImageCommit] = []
        // 能力探测先行（IR-10 / SR-10.01）：握手没声明 `image-variants` 就整批走内联预览，
        // 连暂存文件都不上传。旧连接器不认识 `_link/imageCommit` 时会把它转发给宿主并拿到
        // 非 JSON 的 404，等到失败再回退等于白传两份字节、再闪一条原始报文。
        var variantsUnsupported = !link.supports(LinkHandshake.Capability.imageVariants)
        for image in images {
            if variantsUnsupported {
                commits.append(.inline(image.id))
                continue
            }
            do {
                commits.append(
                    try await commitImage(image, owner: owner, requestId: requestId,
                                          client: client, link: link)
                )
            } catch {
                guard Self.canFallBackToInline(error) else {
                    updateUploadState(image.id,
                                      .failed(message: LinkErrors.describe(error)),
                                      requestId: requestId)
                    throw error
                }
                variantsUnsupported = true
                commits.append(.inline(image.id))
            }
        }
        return ChatModel.promptContent(text: text, images: images, commits: commits)
    }

    /// 一张图的提交：预览 + 可选原图先落电脑暂存区，再 `_link/imageCommit`。
    private func commitImage(
        _ image: ComposerDraftImage,
        owner: String,
        requestId: String,
        client: any ChatHosting,
        link: any LinkService
    ) async throws -> ComposerImageCommit {
        // 预览生成失败但原图可用的那张图：按**文件**发送（SR-02.07「预览失败但原图可用」）。
        // 没有预览就不提交预览——拿原图顶替预览会绕开 2560/4MP 口径。
        let previewData = image.previewData
        let fileOnly = (previewData?.isEmpty ?? true)
        guard !fileOnly || image.originalData != nil else {
            throw ComposerImageUploadError.previewMissing(name: image.name)
        }
        // 本次提交自己建一个暂存子目录：两张同名图（都叫 photo-1.jpg）不会互相覆盖，
        // 删也只删自己这一个目录（曾经在失败分支删掉整个暂存根目录）。
        let scratch = OutgoingFiles.directory()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        updateUploadState(image.id, .uploading(progress: 0.1), requestId: requestId)
        var stagedPreview: StagedFile?
        if let previewData, !previewData.isEmpty {
            // 暂存文件**不能**用显示名：预览与原图的显示名通常相同（都叫 photo.png），
            // 同名会落成同一个路径，后传的原图把预览覆盖掉 —— 连接器读到的就是原图
            // 字节配着预览的声明类型（Host 会拒："Declared image type does not match
            // its bytes"，2026-11-15 仿真器实测）。显示名仍走 `ImageVariantUpload.name`。
            let stagedName = "preview-\(UUID().uuidString).\(Self.uploadExtension(image.mediaType))"
            let previewURL = try writeScratch(previewData, name: stagedName, in: scratch)
            stagedPreview = try await link.uploadFile(
                fileURL: previewURL, name: stagedName, sessionId: owner
            )
        }
        updateUploadState(image.id, .uploading(progress: 0.45), requestId: requestId)

        var originalUpload: ImageVariantUpload?
        var sendAsFile = false
        if let originalData = image.originalData,
           !originalData.isEmpty,
           image.originalDisposition != .unavailable {
            let originalName = image.originalName ?? image.name
            let stagedName = "original-\(UUID().uuidString)."
                + Self.uploadExtension(image.originalMediaType ?? "image/jpeg")
            let originalURL = try writeScratch(originalData, name: stagedName, in: scratch)
            let stagedOriginal = try await link.uploadFile(
                fileURL: originalURL, name: stagedName, sessionId: owner
            )
            originalUpload = ImageVariantUpload(
                path: stagedOriginal.path,
                mediaType: image.originalMediaType ?? image.mediaType,
                name: originalName
            )
            // 超限/不可解码（以及没有预览）的原图按普通文件走，绝不冒充原图变体。
            sendAsFile = image.originalDisposition == .sendAsFile || fileOnly
        }
        updateUploadState(image.id, .uploading(progress: 0.75), requestId: requestId)

        let previewUpload = stagedPreview.map {
            ImageVariantUpload(path: $0.path, mediaType: image.mediaType, name: image.name)
        }
        let value = try await client.commitImage(
            sessionId: owner,
            preview: previewUpload,
            original: originalUpload,
            sendOriginalAsFile: sendAsFile
        )
        updateUploadState(image.id, .uploading(progress: 1), requestId: requestId)
        return ComposerImageCommit(
            imageId: image.id,
            previewReceiptId: value.preview?.receiptId,
            fileReceiptId: value.fileReceiptId,
            usedInlineFallback: false
        )
    }

    /// 暂存文件的扩展名（只影响电脑上那份临时文件，不影响显示名）。
    static func uploadExtension(_ mediaType: String) -> String {
        switch mediaType {
        case "image/png": return "png"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        case "image/heic", "image/heif": return "heic"
        default: return "jpg"
        }
    }

    /// 把一份字节写进本次提交自己的暂存子目录（`Caches/outgoing-files/<uuid>/`）。
    private func writeScratch(_ data: Data, name: String, in directory: URL) throws -> URL {
        let fileName = name.isEmpty ? "image" : name
        let url = directory.appendingPathComponent(fileName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func updateUploadState(_ imageId: UUID,
                                   _ state: ComposerDraftImage.UploadState,
                                   requestId: String) {
        model.updateDraftImageUploadState(imageId, state: state, rpcId: requestId)
    }

    /// 这次失败是不是"旧连接器没有图片变体/文件桥"——只有能力缺失才回退内联。
    ///
    /// 网络失败**不**回退：内联同样发不出去，回退只会把一张图变成两条失败记录。
    private static func canFallBackToInline(_ error: any Error) -> Bool {
        if error is ImageVariantsUnsupported { return true }
        if let failure = error as? DSHRPCFailure {
            return failure.code == "link/unsupported" || failure.code == "file/unsupported"
        }
        if let unavailable = error as? RelayFileTransfer.Unavailable {
            switch unavailable {
            case .connectorTooOld, .noRelay:
                return true
            default:
                return false
            }
        }
        return false
    }

    /// T022 管道发送（纯文本、渲染数据源已切 009 时）：乐观插入由管道快照流
    /// 进入时间线（贴底），requestId 就是管道 clientId，确认走下行 rpcId 回流
    /// 原地替换——不经过旧的 `echoUserPrompt` 回声（身份只有一套）。
    /// 发送失败行留在时间线上可点重发，所以草稿不回填（文字没丢，行还在）。
    func sendViaPipeline(text: String, mode: SessionPromptRequest.Mode, owner: String) async {
        guard let layer = messageLayer, let scope = sessionScope else { return }
        draft = ""
        composer.discard(sessionId: owner)
        scrollSignal += 1
        // 发送自己的消息一律贴底（spec 009「跟底两态」钦定例外，tasks T017）。
        noteWantsBottom()
        isAwaitingTurnStart = true
        awaitingTimeout?.cancel()
        awaitingTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.isAwaitingTurnStart = false
        }
        let ref = MessageSessionRef(scope: scope, sessionId: owner)
        let requestId = UUID()
        let echo = PerformanceTrace.begin(.sendEcho)
        enqueueOptimisticQueue(requestId: requestId.uuidString, text: text,
                               images: [], mode: mode)
        PerformanceTrace.end(echo)
        model.pendingSendVisible = PerformanceTrace.begin(.sendVisible)
        sendSignal += 1
        do {
            _ = try await layer.send(text: text, to: ref, steer: mode == .steer,
                                     requestId: requestId)
        } catch {
            // 行已由管道标 failed（可点重发）；错误同时上错误条。
            model.withdrawOptimisticQueued(rpcId: requestId.uuidString)
            isAwaitingTurnStart = false
            lastError = LinkErrors.describe(error)
        }
    }

    /// 本地乐观排队（输入区条带先显示；控制帧按 rpcId 合并，提升后移除）。
    private func enqueueOptimisticQueue(requestId: String, text: String,
                                        images: [ComposerDraftImage],
                                        mode: SessionPromptRequest.Mode) {
        model.enqueueOptimisticQueued(
            rpcId: requestId,
            placement: mode == .steer ? .steering : .queued,
            text: text,
            draftImages: images)
    }

    /// Uploads one file and tells the agent where it landed.
    ///
    /// There is **one** route for file bytes now (the relay's HTTPS surface with
    /// a background task), and it is a *file* route: iOS only continues
    /// file-based tasks after the app is suspended, so a file has to stay a file
    /// all the way down. This entry point therefore writes the bytes to disk
    /// first and hands the URL to `sendFile(named:fileURL:)` — it is a
    /// migration shim, not a second implementation. Its remaining caller is the
    /// DEBUG automation hook `-DSHUploadFile`, which the next batch deletes
    /// together with this method.
    func sendFile(named name: String, data: Data) async {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("incoming-staged", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let url = scratch.appendingPathComponent(name.isEmpty ? "file" : name)
            try data.write(to: url)
            defer { try? FileManager.default.removeItem(at: scratch) }
            await sendFile(named: name, fileURL: url)
        } catch {
            lastError = String(
                localized: "文件「\(name)」没发出去：\(LinkErrors.describe(error))。可以再点一次发送。"
            )
        }
    }

    /// Uploads a file the caller already has as a URL on disk.
    ///
    /// There is **one** route for file bytes (the relay's HTTPS surface with a
    /// background task); `ConnectionStore` decides whether that route exists at
    /// all from here, and a "no" is an error, not another path. This end hands
    /// over a file and, when it fails, says so in words the person can act on.
    ///
    /// **The staged copy is deleted when this returns, whichever way it went**
    /// (P-3). Only a copy this app made is deletable — `OutgoingFiles.remove`
    /// checks the path against the staging root, so the file behind
    /// `-DSHUploadFilePath` or a path the user picked in Files is never
    /// touched. Leaving it behind was a disk leak that only grew, because
    /// nothing else ever deleted one.
    func sendFile(named name: String, fileURL: URL) async {
        guard let session, let store else { return }
        let owner = session.sessionId
        isUploadingFile = name
        defer {
            isUploadingFile = nil
            // After the await, never before: the background task reads this
            // file, and a delete that beat it would be the F-2 crash face.
            OutgoingFiles.remove(fileURL)
        }

        do {
            let staged = try await store.uploadFile(
                fileURL: fileURL,
                name: name,
                sessionId: session.sessionId
            )
            await model.announceStagedFile(staged, name: name, owner: owner)
        } catch {
            // 落盘日志：大文件走的是"用户看不见进度"的那条路（后台上传、中转桥接、
            // 连接器落盘），失败只会体现在输入框没动静。没有这一行时，真机上
            // 「发了没反应」与「后端没收到」无法区分。
            DSHLog.push("file send failed: \(name) "
                + "(\(FileTransferAdapter.fileSize(fileURL)) bytes) — \(LinkErrors.describe(error))")
            // 给用户的那句话：说清**哪个文件**、**为什么**、**能做什么**。
            // 不再把内部错误原文丢出去（"中转没有返回落盘路径"就是反面样本）。
            lastError = String(
                localized: "文件「\(name)」没发出去：\(LinkErrors.describe(error))。可以再点一次发送。"
            )
        }
    }
}

/// 图片上行在自己这一侧就失败（不是连接器拒绝）。
enum ComposerImageUploadError: LocalizedError {
    /// 草稿里没有预览字节（预览生成失败且没有可发的图）：不能静默丢图。
    case previewMissing(name: String)

    var errorDescription: String? {
        switch self {
        case .previewMissing(let name):
            // 复用现有文案键（"文件「%@」没发出去：%@。可以再点一次发送。"）：
            // 说清是哪张、为什么、能做什么，不新增本地化资源。
            let reason = String(localized: "图片加载失败")
            return String(
                localized: "文件「\(name)」没发出去：\(reason)。可以再点一次发送。"
            )
        }
    }
}
