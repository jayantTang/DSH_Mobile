import DSHConnectionAPI
import DSHFoundation
import DSHKit
import Foundation
import Observation

/// The one place a "open this session" request can be parked.
///
/// Two very different situations produce the same request, and both happen
/// **before** the view that can honour it exists:
///
/// - A tap on a notification while the app is running; the transcript is on
///   screen within a frame, so the request is taken almost immediately.
/// - A tap on a notification that **launches** the app. `didReceive` fires
///   during `application(_:didFinishLaunchingWithOptions:)`, long before
///   `RootView` has a session list — or even a connection. Setting a flag on a
///   view that does not exist yet loses the request, which is exactly the
///   defect this type removes.
///
/// So the request lives in a process-wide object the delegate can always reach,
/// and the view takes it when it is ready. It is deliberately *not* the
/// notification centre's `didReceive` alone: a launch happens once, and a
/// request that has nowhere to land has no second chance.
///
/// **取走即拥有（015）**：请求本体住在 ``SessionRequestBox`` 里，那里"读"与"清空"
/// 是同一个调用。以前这里有两个可读可写的位（`SessionRouter` 与
/// `SessionAlerts.requestedSessionId`），视图也有两个消费者，于是同一次点按能被处理
/// 两遍——第一个消费者入栈后用户左划返回、第二个消费者随后又入栈一次，用户就得返回
/// 两次。现在只有一处可写（``request(sessionId:)``）、一处可取（``take()``），
/// 上面两个属性只是给视图观察用的镜像。
@MainActor
@Observable
public final class SessionRouter {
    /// App 注入的可观测探针钩子（默认无操作）。
    public var probeNote: ((_ kind: String, _ fields: [String: String], _ force: Bool) -> Void)? = nil
    /// App-wide instance. A notification response is delivered to the delegate,
    /// which has no reference to any view, so this cannot be per-view.
    public static let shared = SessionRouter()

    /// The session a tap asked for, until someone takes it — **read-only**.
    ///
    /// Nothing may decide to act on this value: that is the shape that produced
    /// the double push. Take the request with ``take()`` instead.
    private(set) var requestedSessionId: String?

    /// Changes on every new request; the view drives its handler on it.
    ///
    /// An id rather than the session id itself: two taps on the same session are
    /// still two events, and `.task(id:)` must re-run for the second one.
    public private(set) var routingToken = "0"

    /// The take-once rule lives here, where it can be unit tested (015).
    private let box = SessionRequestBox()

    /// The relay's push payload calls the session id `sid`; everything else in
    /// the app calls it `sessionId`. Both are accepted so a change of transport
    /// (local notification today, push tomorrow) cannot silently stop routing.
    nonisolated static let sessionKeys = ["sessionId", "sid"]

    /// Reads a session id out of a notification or launch payload.
    public nonisolated static func sessionId(in userInfo: [AnyHashable: Any]) -> String? {
        for key in sessionKeys {
            if let value = userInfo[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// Notes that the user asked for `sessionId`.
    ///
    /// The only writer there is: the notification delegate, the launch payload
    /// and the automation hooks all come through here (FR-007).
    public func request(sessionId: String) {
        let request = box.put(sessionId: sessionId)
        requestedSessionId = request.sessionId
        routingToken = "\(request.generation)"
        probeNote?("route.request", [
            "sid": request.sessionId,
            "generation": "\(request.generation)",
        ], true)
    }

    /// Takes the pending request, clearing it in the same call (015).
    ///
    /// `nil` means "someone else owns it, or nothing is pending". A caller that
    /// gets `nil` does nothing at all — it must not look for the same intent in
    /// another property, which is how one tap used to become two pushes.
    public func take() -> SessionRequest? {
        guard let request = box.take() else { return nil }
        requestedSessionId = nil
        probeNote?("route.take", [
            "sid": request.sessionId,
            "generation": "\(request.generation)",
        ], true)
        return request
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
    public nonisolated static func automationRequestedSession() -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-DSHNotifySession"),
              index + 1 < arguments.count
        else { return nil }
        let value = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
    #endif

    /// 兼容保留：老调用点按"取走会话 id"的语义用它（用例台与诊断）。
    ///
    /// 与 ``take()`` 是同一个动作，只是丢掉代次。
    public func consume() -> String? {
        take()?.sessionId
    }
}
