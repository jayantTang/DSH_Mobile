import Foundation

/// One "open this session" request, and the generation that produced it.
///
/// The generation is what makes a request **once-only**: the view drives its
/// handler with the generation as the identity, so a request that has been taken
/// can never be taken again, and a *new* request for the same session is still a
/// new event.
public struct SessionRequest: Equatable, Sendable {
    /// The session the user asked for.
    public let sessionId: String
    /// Monotonic counter, bumped by every ``SessionRequestBox/put(sessionId:)``.
    public let generation: Int

    public init(sessionId: String, generation: Int) {
        self.sessionId = sessionId
        self.generation = generation
    }
}

/// The one place a pending "open this session" request can be parked — and the
/// only way to read it is to **take** it (015).
///
/// Two very different situations produce the same request: a tap on a
/// notification while the app runs (the transcript is on screen a frame later),
/// and a tap that launched the app (the callback fires before any view exists).
/// The request therefore has to outlive the view that will honour it.
///
/// What the previous shape got wrong: the reader *read* the pending value and
/// cleared it later, so two triggers could both hold the same request and both
/// open the session — the user saw the same transcript pushed onto the
/// navigation stack twice and had to go back twice. Here the value is cleared
/// **inside** the same call that returns it, so the second reader gets `nil`.
///
/// It is `@MainActor` for the same reason ``TranscriptPager`` is: every caller
/// is (notifications arrive on the main actor, and the view reads this while
/// building a body), and the take-once guarantee is only a guarantee if the
/// check and the clear cannot interleave.
@MainActor
public final class SessionRequestBox {

    /// The request nobody has taken yet — exposed for diagnostics only.
    ///
    /// Reading it must never be how a caller decides to act: that is what
    /// brought the double push back. Use ``take()``.
    public private(set) var pending: SessionRequest?

    /// How many requests have been parked so far. Monotonic; never reset.
    public private(set) var generation = 0

    public init() {}

    /// Parks a request for `sessionId` and returns it.
    ///
    /// The newest request wins: a second tap replaces whatever was pending.
    @discardableResult
    public func put(sessionId: String) -> SessionRequest {
        generation += 1
        let request = SessionRequest(sessionId: sessionId, generation: generation)
        pending = request
        return request
    }

    /// Takes the pending request, clearing it in the same call.
    ///
    /// `nil` means "someone else owns it, or there is nothing to open" — a
    /// caller that gets `nil` must do nothing at all, not look for another
    /// source of the same intent.
    public func take() -> SessionRequest? {
        defer { pending = nil }
        return pending
    }
}
