import Foundation
import Observation

/// The one place a "open this session" request can be parked.
///
/// Two very different situations produce the same request, and both happen
/// **before** the view that can honour it exists:
///
/// - A tap on a notification while the app is running; the transcript is on
///   screen within a frame, so the request is consumed almost immediately.
/// - A tap on a notification that **launches** the app. `didReceive` fires
///   during `application(_:didFinishLaunchingWithOptions:)`, long before
///   `RootView` has a session list — or even a connection. Setting a flag on a
///   view that does not exist yet loses the request, which is exactly the
///   defect this type removes.
///
/// So the request lives in a process-wide object the delegate can always reach,
/// and the view consumes it when it is ready. It is deliberately *not* the
/// notification centre's `didReceive` alone: a launch happens once, and a
/// request that has nowhere to land has no second chance.
///
/// `SessionAlerts.requestedSessionId` keeps existing and keeps working — the
/// foreground path writes both, so nothing that already observed it changes
/// behaviour.
@MainActor
@Observable
final class SessionRouter {
    /// App-wide instance. A notification response is delivered to the delegate,
    /// which has no reference to any view, so this cannot be per-view.
    static let shared = SessionRouter()

    /// The session a tap asked for, until someone opens it.
    ///
    /// Held as `String?` rather than a `Bool` + payload so "nothing pending" has
    /// one spelling. Consuming it is an explicit step — see ``consume()``.
    private(set) var requestedSessionId: String?

    /// The relay's push payload calls the session id `sid`; everything else in
    /// the app calls it `sessionId`. Both are accepted so a change of transport
    /// (local notification today, push tomorrow) cannot silently stop routing.
    nonisolated static let sessionKeys = ["sessionId", "sid"]

    /// Reads a session id out of a notification or launch payload.
    nonisolated static func sessionId(in userInfo: [AnyHashable: Any]) -> String? {
        for key in sessionKeys {
            if let value = userInfo[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// Notes that the user asked for `sessionId`.
    func request(sessionId: String) {
        requestedSessionId = sessionId
    }

    #if DEBUG
    /// A notification tap injected on the command line, for an unattended run.
    ///
    /// The real trigger is an APNs tap, which cannot be produced from
    /// `simctl launch` — a remote notification needs a signed payload from
    /// Apple and a registered device token, and the simulator gets neither.
    /// What *can* be reproduced is the part that crashed: the app being launched
    /// cold with a `sid` in `launchOptions`, before any session exists. This
    /// reads that id and hands it to the same router the delegate writes to, so
    /// everything downstream of the payload is the product's own code.
    ///
    /// `-DSHNotifySession <id>` mirrors `-DSHOpenSession`; the difference is the
    /// path, not the destination. Debug only.
    nonisolated static func automationRequestedSession() -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-DSHNotifySession"),
              index + 1 < arguments.count
        else { return nil }
        let value = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
    #endif

    /// Takes the pending request, if any, and clears it.
    ///
    /// Called by whoever actually opens the session: leaving it set would make
    /// every later re-render try to open the same session again, which is how a
    /// user who navigated away gets dragged back.
    func consume() -> String? {
        defer { requestedSessionId = nil }
        return requestedSessionId
    }
}
