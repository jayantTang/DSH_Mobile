import DSHConnectionAPI
import DSHFoundation
import DSHKit
import Foundation

/// 运行中宿主排队的一条输入（输入区上方条带的一行，**不进转写**）。
///
/// 唯一所有者是宿主：`remote` 来自 `session/control`；`local` 是本地发送的乐观回显，
/// 靠 `rpcId` 与宿主项合并（设计 `20261026-排队输入-设计.md` §3）。
public struct QueuedInput: Identifiable {
    public enum Placement: Equatable {
        case queued
        case steering
        case context

        public var wire: SessionQueuedItem.Placement {
            switch self {
            case .queued: return .queued
            case .steering: return .steering
            case .context: return .context
            }
        }
    }

    /// 宿主队列项的 id；本地乐观项没有宿主 id 时为 nil。
    public let id: String
    public let rpcId: String?
    public let placement: Placement
    public let text: String
    /// 宿主给的图片元数据（远程项）。
    public let images: [ContentBlock.ImageAttachment]
    /// 本地待发图片（只有乐观项有；UI 用它的 `preview` 画 30pt 缩略图）。
    public let draftImages: [ComposerDraftImage]
    public let isLocal: Bool

    public init(id: String, rpcId: String?, placement: Placement, text: String,
                images: [ContentBlock.ImageAttachment] = [],
                draftImages: [ComposerDraftImage] = [], isLocal: Bool) {
        self.id = id
        self.rpcId = rpcId
        self.placement = placement
        self.text = text
        self.images = images
        self.draftImages = draftImages
        self.isLocal = isLocal
    }
}

/// 本地乐观排队项（发送时立刻入队，控制帧/提升后让位）。
struct OptimisticQueuedInput {
    let rpcId: String
    let placement: QueuedInput.Placement
    let text: String
    let draftImages: [ComposerDraftImage]

    var asQueuedInput: QueuedInput {
        QueuedInput(id: "local-\(rpcId)", rpcId: rpcId, placement: placement,
                    text: text, draftImages: draftImages, isLocal: true)
    }
}

/// 排队输入的订阅、合并与动作（`session/control` + `session/updateQueue`）。
///
/// 纪律：队列**不写进 timeline**，也不参与折叠；转写里的 `isPending` 乐观用户行
/// 由 `displayRowsFor` 隐藏，改由这条条带呈现。
public extension ChatModel {

    /// 当前会话的排队输入（宿主快照 + 本地乐观，按 rpcId 去重；FIFO 顺序）。
    var queuedInputs: [QueuedInput] { mergedQueuedInputs() }

    /// 有控制流 + 至少一条可寻址的宿主项时，条带上的动作才可用。
    var canMutateQueuedInput: Bool { queueControlAvailable }

    // MARK: - 订阅

    @MainActor
    func startQueueSubscription(for summary: SessionSummary) {
        queueTask?.cancel()
        queueTask = nil
        remoteQueue = []
        queueControlAvailable = true
        guard let client = store?.chatHost else {
            queueControlAvailable = false
            return
        }
        let sessionId = summary.sessionId
        queueTask = Task { [weak self] in
            let frames = await client.sessionControlFrames()
            do {
                for try await frame in frames {
                    guard !Task.isCancelled else { return }
                    self?.applyQueueFrame(frame, sessionId: sessionId)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                // 旧连接器没有 `session/control`：退回“只显示本地乐观队列”。
                self?.queueControlAvailable = false
                ChatProbe.shared.probeNote?("queue.unavailable", [
                    "session": sessionId, "reason": String(describing: error),
                ], true)
            }
        }
    }

    @MainActor
    func stopQueueSubscription() {
        queueTask?.cancel()
        queueTask = nil
        remoteQueue = []
        optimisticQueue = []
        locallyWithdrawnQueuedRpcIds = []
        queueControlAvailable = true
    }

    @MainActor
    func applyQueueFrame(_ frame: SessionControlFrame, sessionId: String) {
        switch frame {
        case .baseline(let queues, let inboxes, _):
            // 宿主实际下发的是 `inbox` 投影（`next-turn`）；`queues` 字段是旧形态。
            remoteQueue = queues[sessionId] ?? inboxes[sessionId] ?? []
        case .queue(let frameSession, let items):
            guard frameSession == sessionId else { return }
            remoteQueue = items
        case .projection(let frameSession, let key, let value):
            guard frameSession == sessionId, key == "inbox" else { return }
            remoteQueue = SessionControlFrame.inboxItems(value)
        case .other:
            return
        }
        ChatProbe.shared.probeNote?("queue.frame", [
            "session": sessionId, "remote": String(remoteQueue.count),
        ], false)
    }

    // MARK: - 本地乐观入队 / 撤回

    @MainActor
    func enqueueOptimisticQueued(rpcId: String, placement: QueuedInput.Placement,
                                 text: String, draftImages: [ComposerDraftImage]) {
        optimisticQueue.removeAll { $0.rpcId == rpcId }
        optimisticQueue.append(OptimisticQueuedInput(
            rpcId: rpcId, placement: placement, text: text, draftImages: draftImages))
    }

    @MainActor
    func withdrawOptimisticQueued(rpcId: String) {
        locallyWithdrawnQueuedRpcIds.insert(rpcId)
        optimisticQueue.removeAll { $0.rpcId == rpcId }
    }

    // MARK: - 动作（steer / remove）

    /// 立即插入当前轮次。返回是否已受理（失败会写错误条）。
    @discardableResult
    @MainActor
    func steerQueuedInput(_ item: QueuedInput) async -> Bool {
        await mutateQueuedInput(item, action: .steer)
    }

    /// 撤回（不发送）。点正文撤回时由调用方把 `text` 放回输入框。
    @discardableResult
    @MainActor
    func removeQueuedInput(_ item: QueuedInput) async -> Bool {
        await mutateQueuedInput(item, action: .remove)
    }

    @MainActor
    private func mutateQueuedInput(_ item: QueuedInput, action: QueueAction) async -> Bool {
        guard let sessionId = session?.sessionId, let client = store?.chatHost else {
            return false
        }
        let remote = remoteQueue.first {
            ($0.rpcId != nil && $0.rpcId == item.rpcId) || $0.id == item.id
        }
        // 只在本机回显里存在（控制帧还没到/旧连接器）：本地撤回即可，
        // 宿主若之后提升它，会作为正常用户消息进入转写（设计 §3 的降级）。
        guard let remote, queueControlAvailable else {
            if let rpcId = item.rpcId {
                withdrawOptimisticQueued(rpcId: rpcId)
            }
            remoteQueue.removeAll { $0.id == item.id }
            return true
        }
        do {
            try await client.updateQueue(sessionId: sessionId, itemId: remote.id,
                                         action: action)
            remoteQueue.removeAll { $0.id == remote.id }
            if let rpcId = remote.rpcId { withdrawOptimisticQueued(rpcId: rpcId) }
            ChatProbe.shared.probeNote?("queue.mutate", [
                "session": sessionId, "item": remote.id,
                "action": action == .steer ? "steer" : "remove",
            ], true)
            return true
        } catch {
            lastError = LinkErrors.describe(error)
            ChatProbe.shared.probeNote?("queue.mutateFailed", [
                "session": sessionId, "item": remote.id,
                "reason": String(describing: error),
            ], true)
            return false
        }
    }

    /// 撤回后把正文放回输入框（点正文 = 撤回并编辑）。
    @MainActor
    func restoreQueuedText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if composer.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            composer.draft = text
        } else {
            composer.draft += "\n" + text
        }
    }

    // MARK: - 合并

    @MainActor
    func mergedQueuedInputs() -> [QueuedInput] {
        var out: [QueuedInput] = remoteQueue.map { queued in
            QueuedInput(id: queued.id, rpcId: queued.rpcId,
                        placement: QueuedInput.Placement(wire: queued.placement),
                        text: queued.text, images: queued.images, isLocal: false)
        }
        var seenRpcIds = Set(remoteQueue.compactMap(\.rpcId))
        for optimistic in optimisticQueue {
            if locallyWithdrawnQueuedRpcIds.contains(optimistic.rpcId) { continue }
            if seenRpcIds.contains(optimistic.rpcId) { continue }
            if locallySettled(rpcId: optimistic.rpcId) { continue }
            seenRpcIds.insert(optimistic.rpcId)
            out.append(optimistic.asQueuedInput)
        }
        return out
    }

    /// 这条本地回显是否已经被宿主收下：落定的用户行出现，或者发送失败行出现。
    ///
    /// 提升后队列帧也会把它删掉；这里兜住"控制帧没到/旧连接器"的那条路。
    @MainActor
    private func locallySettled(rpcId: String) -> Bool {
        timeline.items.contains { item in
            guard case .userMessage(_, _, _, let isPending, _) = item.kind,
                  item.id == "user-\(rpcId)" else { return false }
            return !isPending || item.sendFailed || item.sendUnconfirmed
        }
    }
}

private extension QueuedInput.Placement {
    init(wire: SessionQueuedItem.Placement) {
        switch wire {
        case .queued: self = .queued
        case .steering: self = .steering
        case .context: self = .context
        }
    }
}
