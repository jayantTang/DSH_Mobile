import DSHConnectionAPI
import DSHCore
import DSHFoundation
import DSHKit
import Foundation

/// 上行发送服务：文本走管道或旧 echo 路径，文件走中转上传。
/// 只持 ChatModel 的弱引用，状态仍归 ChatModel 所有。
@MainActor
final class ChatSendService {
    private unowned let model: ChatModel

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
        guard !text.isEmpty || !images.isEmpty, let client = store?.chatHost, let session else { return }
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
        // this optimistic row instead of showing the message twice.
        let requestId = UUID().uuidString
        enqueueOptimisticQueue(requestId: requestId, text: text, images: images, mode: mode)
        timeline.echoUserPrompt(requestId: requestId, text: text)
        scrollSignal += 1
        sendSignal += 1
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
            try await client.prompt(
                SessionPromptRequest(
                    requestId: requestId,
                    sessionId: session.sessionId,
                    mode: mode,
                    content: ChatModel.promptContent(text: text, images: images)
                )
            )
        } catch {
            isAwaitingTurnStart = false
            // Back to the conversation it was typed in — visible if the user is
            // still there, waiting quietly if they have moved on.
            // `session` was captured by the guard at the top of this function,
            // so it is this send's own session — not whatever is on screen now.
            model.withdrawOptimisticQueued(rpcId: requestId)
            composer.restore(text: text, images: images, for: owner,
                             isCurrent: session.sessionId == owner)
            lastError = LinkErrors.describe(error)
        }
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
        sendSignal += 1
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
        enqueueOptimisticQueue(requestId: requestId.uuidString, text: text,
                               images: [], mode: mode)
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
