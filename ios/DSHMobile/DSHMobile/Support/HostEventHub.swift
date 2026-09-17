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
final class HostEventHub {

    /// A host prompt waiting for a human answer.
    ///
    /// These are the interruptions that block a desktop session: a question
    /// from `ask_user_question`, an approval request. Surfacing them on the
    /// phone is the single most useful thing the mobile client does.
    struct Pending: Identifiable {
        let id: String
        let event: String
        let agentId: String
        let request: JSONValue
        let arrivedAt: Date

        /// The session this prompt belongs to.
        var sessionId: String { agentId }
    }

    private(set) var hostHome: String?
    private(set) var pending: [Pending] = []
    private(set) var isLive = false

    private var clientId: String?
    private var task: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<HostEvent>.Continuation] = [:]
    private var client: DSHClient?
    /// Where the feed gets its client, asked fresh on every reopen.
    private var clientProvider: (@MainActor () -> DSHClient?)?

    /// Subscribes to the raw event feed.
    func events() -> AsyncStream<HostEvent> {
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
    func attach(provider: @escaping @MainActor () -> DSHClient?) {
        clientProvider = provider
    }

    /// Consumes the host feed, reopening it whenever the socket drops.
    ///
    /// This stream is the app's only source of "a run ended" and "a question is
    /// waiting", so it has to outlive a dropped socket. It used to end for good
    /// the first time the socket failed: the task returned, `isLive` went false,
    /// and nothing reopened it until the app was foregrounded — which is exactly
    /// the moment a background notification should already have been sent.
    func start(client: DSHClient?) {
        guard task == nil else {
            // Already feeding: only the client it should use may have changed.
            self.client = clientProvider?() ?? client ?? self.client
            return
        }
        stop()
        self.client = client
        task = Task { [weak self] in
            // The handle is what `start` checks, so a loop that ends — because
            // the store has no client at all — has to clear it, or the feed
            // could never be started again after the link came back. A cancelled
            // loop leaves the handle alone: `stop()` already replaced it.
            defer { if !Task.isCancelled { self?.task = nil } }
            var attempt = 0
            while !Task.isCancelled {
                guard let self, let client = self.clientProvider?() ?? self.client else { return }
                self.client = client
                do {
                    for try await event in await client.hostEvents() {
                        if Task.isCancelled { return }
                        self.handle(event)
                    }
                } catch {
                    // The socket went away; the loop below puts it back.
                }
                self.isLive = false
                if Task.isCancelled { return }
                attempt += 1
                try? await Task.sleep(for: .seconds(min(8, 0.5 * Double(attempt))))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        client = nil
        clientId = nil
        isLive = false
        pending.removeAll()
        for observer in observers.values { observer.finish() }
        observers.removeAll()
    }

    private func handle(_ event: HostEvent) {
        switch event {
        case .ready(let clientId, let home):
            self.clientId = clientId
            if !home.isEmpty { hostHome = home }
            isLive = true

        case .waterfall(let waterfall):
            // A waterfall blocks the host until answered, so it is promoted
            // into the pending list rather than merely forwarded.
            if !pending.contains(where: { $0.id == waterfall.eventId }) {
                pending.append(
                    Pending(
                        id: waterfall.eventId,
                        event: waterfall.event,
                        agentId: waterfall.agentId,
                        request: waterfall.request,
                        arrivedAt: Date()
                    )
                )
            }

        case .cancelled(let eventId):
            pending.removeAll { $0.id == eventId }

        case .emit, .unknown:
            break
        }

        for observer in observers.values {
            observer.yield(event)
        }
    }

    // MARK: - Answering

    /// Answers one pending prompt and clears it locally.
    func answer(_ item: Pending, with outcome: EventAnswer.Outcome) async throws {
        guard let client, let clientId else {
            throw DSHTransportError.carrierClosed
        }
        let answer = EventAnswer(clientId: clientId, eventId: item.id, outcome: outcome)
        try await client.answer(answer)
        pending.removeAll { $0.id == item.id }
    }

    /// Declines to handle a prompt, letting the host continue to other clients.
    ///
    /// Used when the desktop client is the better place to answer.
    func pass(_ item: Pending) async {
        try? await answer(item, with: .next)
    }

    /// The pending prompts addressed to one session.
    func pending(for sessionId: String) -> [Pending] {
        pending.filter { $0.agentId == sessionId }
    }
}

extension HostEventHub.Pending {
    /// Decodes this prompt as a multiple-choice question, when it is one.
    var userQuestions: UserQuestionsRequest? {
        guard event == "user-questions/request" else { return nil }
        guard let data = try? JSONEncoder().encode(request) else { return nil }
        return try? JSONDecoder().decode(UserQuestionsRequest.self, from: data)
    }

    /// A human label for the prompt kind.
    var title: String {
        switch event {
        case "user-questions/request": return "需要你确认"
        case "approval/asked", "approval/request": return "请求授权"
        default: return "需要你回应"
        }
    }
}
