import DSHConnectionAPI
import DSHFoundation
import DSHKit
import Foundation
import Observation

/// One connection to the host's forwarded event stream, fanned out to screens.
///
/// Opening `$events` more than once would be wasteful and, worse, would mean
/// several `clientId`s racing to answer the same pending waterfall. The hub
/// owns the only stream, so answering stays unambiguous.
@MainActor
@Observable
public final class HostEventHub {
    /// App 注入的可观测探针钩子（默认无操作）。
    public var probeNote: ((_ kind: String, _ fields: [String: String], _ force: Bool) -> Void)? = nil

    public init() {}

    /// A host prompt waiting for a human answer.
    ///
    /// These are the interruptions that block a desktop session: a question
    /// from `ask_user_question`, an approval request. Surfacing them on the
    /// phone is the single most useful thing the mobile client does.
    ///
    /// 形状与集合判定在 DSHKit（`PendingPrompts`，spec 023 的边界收敛）；这里保留 `Pending`
    /// 这个名字，视图侧用法不变。
    public typealias Pending = PendingPrompts.Item

    public private(set) var hostHome: String?
    /// 待答集合：waterfall 推进来、cancelled 拿掉（判定在 DSHKit，可在秒级单测里钉住）。
    public private(set) var pending = PendingPrompts()
    public private(set) var isLive = false

    private var clientId: String?
    private var task: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<HostEvent>.Continuation] = [:]
    private var link: LinkGateway?
    /// Where the feed gets its client, asked fresh on every reopen.
    private var linkProvider: (@MainActor () -> LinkGateway?)?

    /// Subscribes to the raw event feed.
    public func events() -> AsyncStream<HostEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<HostEvent>.makeStream(bufferingPolicy: .bufferingNewest(512))
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.observers[id] = nil }
        }
        return stream
    }

    /// Points the feed at whatever client the store currently holds.
    ///
    /// A repair replaces the carrier underneath the app, so the feed cannot keep
    /// a client of its own: it has to ask again each time it reopens.
    public func attach(provider: @escaping @MainActor () -> LinkGateway?) {
        linkProvider = provider
    }

    /// Consumes the host feed, reopening it whenever the socket drops.
    ///
    /// This stream is the app's only source of "a run ended" and "a question is
    /// waiting", so it has to outlive a dropped socket. It used to end for good
    /// the first time the socket failed: the task returned, `isLive` went false,
    /// and nothing reopened it until the app was foregrounded — which is exactly
    /// the moment a background notification should already have been sent.
    public func start(link: LinkGateway?) {
        guard task == nil else {
            // Already feeding: only the client it should use may have changed.
            self.link = linkProvider?() ?? link ?? self.link
            return
        }
        stop()
        self.link = link
        task = Task { [weak self] in
            // The handle is what `start` checks, so a loop that ends — because
            // the store has no client at all — has to clear it, or the feed
            // could never be started again after the link came back. A cancelled
            // loop leaves the handle alone: `stop()` already replaced it.
            defer { if !Task.isCancelled { self?.task = nil } }
            var attempt = 0
            while !Task.isCancelled {
                guard let self, let link = self.linkProvider?() ?? self.link else { return }
                self.link = link
                do {
                    for try await event in await link.hostEvents() {
                        if Task.isCancelled { return }
                        self.handle(event)
                    }
                } catch {
                    // The socket went away; the loop below puts it back.
                }
                self.isLive = false
                if Task.isCancelled { return }
                attempt += 1
                // 节奏在 DSHKit（`EventStreamRetry`）：这条重试不拨号、只是重新订阅，所以比连接退避密。
                try? await Task.sleep(for: .seconds(EventStreamRetry.delay(afterAttempt: attempt)))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        link = nil
        clientId = nil
        isLive = false
        pending.removeAll()
        for observer in observers.values { observer.finish() }
        observers.removeAll()
    }

    private func handle(_ event: HostEvent) {
        switch event {
        case .ready(let clientId, let home):
            // 每次重连都会拿到新的 clientId——补投是否发生，就看 ready 之后有没有
            // hub.waterfall。
            probeNote?("hub.ready", ["client": String(clientId.prefix(8))], true)
            self.clientId = clientId
            if !home.isEmpty { hostHome = home }
            isLive = true

        case .waterfall(let waterfall):
            // 待答状态是"手机看不看得出 agent 在等你"的唯一来源，所以这里留一行
            // 诊断日志（只在 -DSHViewportProbe 时写文件）：排查"host 明明挂着提问、
            // 手机却没反应"时，第一件事就是看这行有没有出现。
            probeNote?("hub.waterfall", [
                "event": waterfall.event,
                "agent": waterfall.agentId,
                "pending": String(pending.count + 1),
            ], true)
            // A waterfall blocks the host until answered, so it is promoted
            // into the pending list rather than merely forwarded.
            pending.apply(event)

        case .cancelled(let eventId):
            probeNote?("hub.cancelled", ["id": eventId], true)
            pending.apply(event)

        case .emit, .unknown:
            break
        }

        for observer in observers.values {
            observer.yield(event)
        }
    }

    /// 应答侧的错误。
    public enum HostEventHubError: Error, Equatable {
        /// 这条提问已不在待答集（已被答过/已被宿主撤回）。
        case promptAlreadyAnswered
    }

    // MARK: - Answering

    /// Answers one pending prompt and clears it locally.
    public func answer(_ item: Pending, with outcome: EventAnswer.Outcome) async throws {
        guard let link, let clientId else {
            throw DSHTransportError.carrierClosed
        }
        // 029 缺陷10：先本地认领再发。不发就重复应答照发第二帧——宿主端 waterfall
        // 已经有人答过时，这边再发一帧只会让 host 的日志多一份费解的重复。
        // 认领先于网络：失败也宁可留下"这个 prompt 没了"（重新来一条 feed 会再出现），
        // 也不能让两次 tap 变成两个结果帧。
        guard pending.contains(where: { $0.id == item.id }) else {
            throw HostEventHubError.promptAlreadyAnswered
        }
        pending.remove(id: item.id)
        let answer = EventAnswer(clientId: clientId, eventId: item.id, outcome: outcome)
        try await link.answer(answer)
        // 032：答过之后告诉账户级状态（同账户其他设备要把这条从待回应里去掉）。
        await onPromptAnswered?(item.id)
    }

    /// 一条提示被本机答掉之后的通知（App 装配到账户级同步）。
    public var onPromptAnswered: ((String) async -> Void)?

    /// 别的设备答掉了这些提示：从本机待回应里去掉。
    ///
    /// 为什么不能只等宿主撤回：宿主只把结果发给**提问到达过**的客户端，另一台设备
    /// 可能压根没收到过这条，也可能收到后一直挂着——这正是 owner 说的"用户选择点击"
    /// 要跨设备一致的那一类。返回是否有变化（调用方据此决定要不要刷新界面）。
    @discardableResult
    public func applyRemoteAnswers(_ ids: Set<String>) -> Bool {
        guard !ids.isEmpty else { return false }
        let before = pending.count
        pending.remove(ids: ids)
        return pending.count != before
    }

    /// Declines to handle a prompt, letting the host continue to other clients.
    ///
    /// Used when the desktop client is the better place to answer.
    public func pass(_ item: Pending) async {
        try? await answer(item, with: .next)
    }

    /// The pending prompts addressed to one session.
    public func pendingPrompts(for sessionId: String) -> [Pending] {
        pending.forSession(sessionId)
    }
}

public extension HostEventHub.Pending {
    /// Decodes this prompt as a multiple-choice question, when it is one.
    public var userQuestions: UserQuestionsRequest? {
        guard event == "user-questions/request" else { return nil }
        guard let data = try? JSONEncoder().encode(request) else { return nil }
        return try? JSONDecoder().decode(UserQuestionsRequest.self, from: data)
    }

    /// A human label for the prompt kind.
    public var title: String {
        switch event {
        case "user-questions/request": return "需要你确认"
        case "approval/asked", "approval/request": return "请求授权"
        default: return "需要你回应"
        }
    }
}
