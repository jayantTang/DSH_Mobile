import DSHFoundation
import Foundation
import RelayKit

/// 一次发送里附件那一阶段的失败分类（界面据此决定给哪三个动作）。
public enum FeedbackSendFailure: Sendable, Equatable {
    /// 网络/协议层失败；`FeedbackClientError` 那一份映射是唯一的，不在这里另造。
    case client(FeedbackClientError)
    /// 附件个数超过服务端下发的上限。
    case attachmentLimit(limit: Int, requested: Int)
    /// 单个文件超过上限。
    case fileTooLarge(name: String, limit: Int)
    /// 附件合计超过上限。
    case totalTooLarge(limit: Int)
    /// 服务端没有附件能力（`limits.attachments` 缺失），或类型不在白名单。
    case attachmentsUnavailable
    /// 服务端说绑了几个、本地以为有几个：不一致就是失败，不许静默少图。
    case boundMismatch(local: Int, bound: Int)
}

/// 一次发送的终局。
public enum FeedbackSendOutcome: Sendable, Equatable {
    case sent(FeedbackSendReceipt)
    case failed(FeedbackSendFailure)
    case cancelled
}

/// 发送成功的那张回执（新信与回信共用一个形状）。
public struct FeedbackSendReceipt: Sendable, Equatable {
    public let threadId: String
    public let messageId: String
    /// 新信才有（服务端只回一次取件凭据）。
    public let ticketKey: String?
    public let createdAt: Date?
    /// 服务端真的绑定了几个附件。
    public let attachmentsBound: Int
}

/// 一次发送的**唯一所有者**：先传附件（槽位 0…n-1），全部成功后再提交正文。
///
/// 四种结局都落到 ``outcome``：`sent` / `failed`（可重试）/ `cancelled`；`run()` 与
/// `sendTextOnly()` 都是幂等的——同一个 `clientRef` 重来不会重复建信，也不会重传
/// 已经 `stored` 的附件（`begin` 的幂等命中会告诉我们它已经在服务端）。
///
/// 状态归属：草稿的**本地**事实在 ``FeedbackPendingUploads``（`clientRef` 为键，
/// 跨重启可重试、7 天过期）；**服务端**事实只有 `messageId IS NULL` 的草稿行。
/// 这里不缓存任何一份服务端状态。
/// 发送按钮的判定：**正文非空 或 至少 1 个附件**，且各上限都在范围内。
///
/// 写信页与回信框共用这一个判据（同一个 `FeedbackComposerView`），算术仍来自
/// ``FeedbackDraftLength``（不在这里重写一份）。
public enum FeedbackSendPolicy {
    public static func canSend(text: String, subject: String = "",
                               attachments: [FeedbackPreparedAttachment] = [],
                               limits: FeedbackLimits) -> Bool {
        guard subject.count <= limits.subjectChars else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && attachments.isEmpty { return false }
        if !trimmed.isEmpty {
            guard FeedbackDraftLength.canSend(trimmed, limits: limits) else { return false }
        }
        return attachmentViolation(attachments, limits: limits) == nil
    }

    /// 附件超限的原因（nil = 在范围内）。与 job 的本地校验同一套数字，没有第二份常量。
    ///
    /// 输入是**逻辑附件**数组（2026-11-12）：条数按 slot 去重，单文件上限逐份字节判，
    /// 合计按两份之和判。
    public static func attachmentViolation(
        _ attachments: [FeedbackPreparedAttachment], limits: FeedbackLimits
    ) -> FeedbackSendFailure? {
        guard !attachments.isEmpty else { return nil }
        guard let attachmentLimits = limits.attachments else { return .attachmentsUnavailable }
        let slots = Set(attachments.map(\.slot))
        if slots.count > attachmentLimits.maxPerMessage {
            return .attachmentLimit(limit: attachmentLimits.maxPerMessage,
                                    requested: slots.count)
        }
        for item in attachments {
            for part in item.parts where part.byteSize > attachmentLimits.maxFileBytes {
                return .fileTooLarge(name: part.name, limit: attachmentLimits.maxFileBytes)
            }
        }
        let total = attachments.reduce(0) { $0 + $1.byteSize }
        if total > attachmentLimits.maxTotalBytes {
            return .totalTooLarge(limit: attachmentLimits.maxTotalBytes)
        }
        return nil
    }
}

@MainActor
@Observable
public final class FeedbackSendJob {

    public enum Phase: Sendable, Equatable {
        case idle
        case uploading(done: Int, total: Int)
        case submitting
        case finished
    }

    /// 一个槽位此刻的样子（与 C4/C7/C8 的状态词一一对应）。
    public enum SlotPhase: Sendable, Equatable {
        case waiting
        case uploading
        case uploaded
        case failed
        case cancelled
    }

    /// 这一封信的幂等键，同时是附件草稿的归集键。`只发正文` 在 discard 失败时会换成
    /// 一个新的 ref（旧草稿交给 7 天 TTL），所以它不是常量。
    public private(set) var clientRef: String
    public private(set) var phase: Phase = .idle
    public private(set) var outcome: FeedbackSendOutcome?
    /// 每个槽位的状态，键是 `slot`；UI 的缩略图蒙层、行状态词与"重试"按钮都读它。
    public private(set) var slotPhases: [Int: SlotPhase] = [:]
    /// 本次失败的具体原因（UI 据此选 C8 的四句话之一）。
    public private(set) var failure: FeedbackSendFailure?

    private let client: RelayFeedbackClient
    private let text: String
    private let subject: String?
    private let attachments: [FeedbackPreparedAttachment]
    private let limits: FeedbackLimits
    private let disk: FeedbackAttachmentDisk
    private let pendingStore: FeedbackPendingUploadStore
    /// 回信才有：目标线程与可选取件凭据（团队侧/设备绑定可以不给）。
    private let reply: (threadId: String, ticketKey: String?)?
    private let technical: (appVersion: String, deviceModel: String, systemVersion: String)
    private var cancelled = false

    public init(
        client: RelayFeedbackClient,
        clientRef: String,
        text: String,
        subject: String? = nil,
        attachments: [FeedbackPreparedAttachment] = [],
        limits: FeedbackLimits,
        disk: FeedbackAttachmentDisk = FeedbackAttachmentDisk(),
        pendingStore: FeedbackPendingUploadStore = FeedbackPendingUploadStore(),
        reply: (threadId: String, ticketKey: String?)? = nil,
        technical: (appVersion: String, deviceModel: String, systemVersion: String)
    ) {
        self.client = client
        self.clientRef = clientRef
        self.text = text
        self.subject = subject
        self.attachments = attachments
        self.limits = limits
        self.disk = disk
        self.pendingStore = pendingStore
        self.reply = reply
        self.technical = technical
    }

    /// 一次发送是不是还在飞（界面据此禁用按钮、显示计数）。
    public var isRunning: Bool {
        switch phase {
        case .uploading, .submitting: return true
        case .idle, .finished: return false
        }
    }

    /// 已经定局（成功或取消）：`failed` 是**可重试**的，不是终局。
    private var isTerminal: Bool {
        switch outcome {
        case .sent, .cancelled: return true
        case .failed, nil: return false
        }
    }

    /// 重试前把上一次性失败清掉：`failed` 不封口，成功与取消才封口。
    private func reopenIfNeeded() {
        guard !isTerminal else { return }
        outcome = nil
        phase = .idle
    }

    // MARK: - 主流程

    /// 先传附件、再提交。附件一个都没带时就是纯文本提交（与旧行为逐字一致）。
    public func run() async -> FeedbackSendOutcome {
        if let outcome, isTerminal { return outcome }
        reopenIfNeeded()
        if let invalid = validate() { return finish(.failed(invalid)) }
        guard !attachments.isEmpty else { return await submitOnly() }

        var queue = restoredQueue()
        slotPhases = Dictionary(uniqueKeysWithValues: attachments.map { ($0.slot, .waiting) })
        failure = nil
        phase = .uploading(done: 0, total: attachments.count)
        var done = 0
        for item in attachments {
            if cancelled { return await cancelNow(queue: queue) }
            mark(.uploading, slot: item.slot)
            // 一个槽位两份字节：先主对象（配对的图片就是预览），再原图。
            for part in item.parts {
                if let invalid = await upload(slot: item.slot, attachment: part, queue: &queue) {
                    mark(.failed, slot: item.slot)
                    failure = invalid
                    return finish(.failed(invalid))
                }
            }
            mark(.uploaded, slot: item.slot)
            done += 1
            phase = .uploading(done: done, total: attachments.count)
        }
        if cancelled { return await cancelNow(queue: queue) }
        return await submit(queue: queue)
    }

    /// "只发正文"：放弃这次要带的附件，用正文把那封信发出去。
    ///
    /// 先尽力 `discard` 已传的草稿（回收配额）；**discard 全部成功**时沿用同一个
    /// `clientRef`（服务端按它幂等，重试也只建一条线程），失败就换一个新 ref，
    /// 旧草稿交给 7 天 TTL——绝不把没删掉的草稿绑进这封信。
    public func sendTextOnly() async -> FeedbackSendOutcome {
        if let outcome, isTerminal { return outcome }
        reopenIfNeeded()
        let queue = restoredQueue()
        var discardedEveryDraft = true
        for item in queue {
            guard let attachmentId = item.attachmentId else { continue }
            do {
                try await client.discardAttachment(attachmentId: attachmentId,
                                                   clientRef: clientRef,
                                                   ticketKey: reply?.ticketKey)
            } catch {
                discardedEveryDraft = false
            }
        }
        if !discardedEveryDraft {
            clientRef = UUID().uuidString
        }
        clearLocalDraft()
        return await submitOnly()
    }

    /// 取消：停下剩余上传，尽力删掉已传的草稿，丢掉本地暂存。
    public func cancel() async -> FeedbackSendOutcome {
        if let outcome, isTerminal { return outcome }
        reopenIfNeeded()
        cancelled = true
        let queue = restoredQueue()
        return await cancelNow(queue: queue)
    }

    // MARK: - 附件阶段

    /// 本地能判的校验（个数 / 单文件 / 合计 / 服务端有没有附件能力）。
    private func validate() -> FeedbackSendFailure? {
        // 判据只有一份：与发送按钮读同一个纯函数（设计 §4.3「一个事实一个所有者」）。
        FeedbackSendPolicy.attachmentViolation(attachments, limits: limits)
    }

    /// 上一轮留下的队列（跨重启）：按 slot 复用 `attachmentId` 与 `state`。
    private func restoredQueue() -> [FeedbackPendingUpload] {
        pendingStore.queue(for: clientRef)
    }

    /// 用 `(slot, role)` 换掉队列里的那条记录（同一个槽位有两行，不能按 slot 覆盖）。
    private func replace(_ queue: inout [FeedbackPendingUpload], with item: FeedbackPendingUpload) {
        queue = queue.filter { !($0.slot == item.slot && $0.role == item.role) } + [item]
    }

    private func persist(_ queue: [FeedbackPendingUpload]) {
        var uploads = pendingStore.load()
        if queue.isEmpty {
            uploads.remove(clientRef: clientRef)
        } else {
            for item in queue { uploads.put(item, for: clientRef) }
        }
        pendingStore.save(uploads)
    }

    /// 传一个槽位：`begin`（幂等）→ 只在该行还没 `stored` 时 `upload`。
    ///
    /// 返回非 nil 表示这一轮到此失败（调用方直接收尾，不提交正文）。
    private func mark(_ phase: SlotPhase, slot: Int) {
        slotPhases[slot] = phase
    }

    private func upload(slot: Int, attachment: FeedbackOutgoingAttachment,
                        queue: inout [FeedbackPendingUpload]) async -> FeedbackSendFailure? {
        let role = attachment.role
        var item = queue.first(where: { $0.slot == slot && $0.role == role }) ?? FeedbackPendingUpload(
            slot: slot, role: role, name: attachment.name, contentType: attachment.contentType,
            byteSize: attachment.byteSize, sha256: attachment.sha256, createdAt: Date())
        do {
            let draft = try await client.beginAttachment(
                clientRef: clientRef, slot: slot,
                threadId: reply?.threadId, ticketKey: reply?.ticketKey,
                name: attachment.name, contentType: attachment.contentType,
                byteSize: attachment.byteSize, sha256: attachment.sha256,
                width: attachment.width, height: attachment.height,
                role: role.rawValue
            )
            item.attachmentId = draft.attachmentId
            item.state = draft.state
            replace(&queue, with: item)
            persist(queue)
            guard !draft.isStored else { return nil }   // 已在服务端：不重传（重试路径）
            let bytes = disk.stagedBytes(clientRef: clientRef, slot: slot, role: role)
                ?? attachment.data
            let uploaded = try await client.uploadAttachment(
                attachmentId: draft.attachmentId, bytes: bytes, ticketKey: reply?.ticketKey)
            item.state = uploaded.state
            replace(&queue, with: item)
            persist(queue)
            return nil
        } catch let error as FeedbackClientError {
            return .client(error)
        } catch {
            return .client(.network(String(describing: error)))
        }
    }

    // MARK: - 提交阶段

    private func submit(queue: [FeedbackPendingUpload]) async -> FeedbackSendOutcome {
        phase = .submitting
        do {
            if let reply {
                let result = try await client.append(
                    threadId: reply.threadId, ticketKey: reply.ticketKey,
                    text: text, clientRef: clientRef)
                return complete(.init(
                    threadId: result.threadId, messageId: result.messageId, ticketKey: nil,
                    createdAt: result.createdAt, attachmentsBound: result.attachmentsBound),
                    localAttachments: queue.count)
            }
            let ticket = try await client.submit(
                text: text, subject: subject,
                appVersion: technical.appVersion, deviceModel: technical.deviceModel,
                systemVersion: technical.systemVersion, clientRef: clientRef)
            return complete(.init(
                threadId: ticket.threadId, messageId: ticket.messageId ?? "", ticketKey: ticket.ticketKey,
                createdAt: ticket.createdAt, attachmentsBound: ticket.attachmentsBound),
                localAttachments: queue.count)
        } catch let error as FeedbackClientError {
            failure = .client(error)
            return finish(.failed(.client(error)))
        } catch {
            let wrapped = FeedbackClientError.network(String(describing: error))
            failure = .client(wrapped)
            return finish(.failed(.client(wrapped)))
        }
    }

    /// 提交成功但"服务端绑了几个"与本地不一致：落失败，不假装发出去了。
    private func complete(_ receipt: FeedbackSendReceipt, localAttachments: Int) -> FeedbackSendOutcome {
        if localAttachments > 0, receipt.attachmentsBound != localAttachments {
            let mismatch = FeedbackSendFailure.boundMismatch(local: localAttachments,
                                                             bound: receipt.attachmentsBound)
            failure = mismatch
            return finish(.failed(mismatch))
        }
        clearLocalDraft()
        return finish(.sent(receipt))
    }

    private func submitOnly() async -> FeedbackSendOutcome {
        await submit(queue: [])
    }

    // MARK: - 收尾

    /// 取消的收尾：删已传的草稿（尽力），丢本地暂存，结账为 `cancelled`。
    private func cancelNow(queue: [FeedbackPendingUpload]) async -> FeedbackSendOutcome {
        for slot in slotPhases.keys where slotPhases[slot] != .uploaded {
            slotPhases[slot] = .cancelled
        }
        for item in queue {
            guard let attachmentId = item.attachmentId else { continue }
            try? await client.discardAttachment(attachmentId: attachmentId,
                                                clientRef: clientRef,
                                                ticketKey: reply?.ticketKey)
        }
        clearLocalDraft()
        return finish(.cancelled)
    }

    /// 本地草稿一次性清掉（待上传记录 + 暂存字节）；服务端草稿由 discard / TTL 管。
    private func clearLocalDraft() {
        var uploads = pendingStore.load()
        uploads.remove(clientRef: clientRef)
        pendingStore.save(uploads)
        disk.removeStaged(clientRef: clientRef)
    }

    private func finish(_ outcome: FeedbackSendOutcome) -> FeedbackSendOutcome {
        phase = .finished
        self.outcome = outcome
        return outcome
    }
}

public extension FeedbackSendJob {
    /// job 的失败 → 现有那一个 `FeedbackClientError` 分类（界面不必认识第二种错误）。
    ///
    /// 本地校验类失败折成 `.tooLong`（"内容太大/太多"），服务端没有附件能力折成
    /// `.unsupportedType`，绑定数不符折成 `.decoding`（响应不可信）。
    static func clientError(for failure: FeedbackSendFailure) -> FeedbackClientError {
        switch failure {
        case .client(let error):
            return error
        case .attachmentLimit, .fileTooLarge, .totalTooLarge:
            return .tooLong
        case .attachmentsUnavailable:
            return .unsupportedType
        case .boundMismatch(let local, let bound):
            return .decoding("attachments-bound-mismatch local=\(local) bound=\(bound)")
        }
    }
}
