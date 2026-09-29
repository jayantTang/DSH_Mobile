import Foundation
import UserNotifications
import Observation
import UIKit

/// Tells the user when a run finishes or a session is blocked on them.
///
/// The point of a phone client for a desktop agent is that you can walk away.
/// That only works if the phone speaks up, so this posts a real notification —
/// a banner while the app is open, a lock-screen alert when it is not — for the
/// two things that actually need a person: a run that has ended, and a session
/// that cannot continue until someone answers.
///
/// Delivered as local notifications for everything the phone is awake to see.
/// The case a local notification cannot cover is a phone that is *away*: the
/// socket dies with the app, so nothing here runs at all. That one belongs to
/// the relay, which sends an APNs push containing nothing but a session id — and
/// the app treats a tap on it exactly like a tap on a local one, through
/// `SessionRouter`. Both paths therefore meet in a single place and cannot drift
/// into two different ideas of "open that session".
@MainActor
@Observable
final class SessionAlerts: NSObject, UNUserNotificationCenterDelegate {

    /// Whether a finished run is worth a notification.
    var notifyOnTurnEnd: Bool {
        didSet {
            defaults.set(notifyOnTurnEnd, forKey: Keys.turnEnd)
            // The relay decides *whether* to push while this app is not running,
            // so it keeps its own copy of both switches. A local toggle that never
            // left the phone would mean a user who turned reminders off still got
            // woken up — the one failure mode of this feature nobody forgives.
            Task { await APNSRegistrar.shared.switchesChanged() }
        }
    }

    /// Whether a session waiting on an answer is worth a notification.
    var notifyOnAttention: Bool {
        didSet {
            defaults.set(notifyOnAttention, forKey: Keys.attention)
            Task { await APNSRegistrar.shared.switchesChanged() }
        }
    }

    /// Set when the user taps a notification, so the app can open that session.
    var requestedSessionId: String?

    private(set) var isAuthorized = false

    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let turnEnd = "alerts.notifyOnTurnEnd"
        static let attention = "alerts.notifyOnAttention"
        static let didAsk = "alerts.didAsk"
        /// 记录 `didAsk` 的语义版本，用于修掉旧版本留下的坏状态。
        ///
        /// 旧版本从没写过这个键，所以它缺失（= 0）就代表「`didAsk` 不可信」。
        static let askVersion = "alerts.didAskVersion"
        /// 修好之后的版本号：只有弹窗真的被回答过才写这个版本。
        static let askVersionTrusted = 1
    }

    override init() {
        // Both default on: someone who installs a remote client for their agent
        // is installing it precisely to be told when something needs them.
        notifyOnTurnEnd = defaults.object(forKey: Keys.turnEnd) as? Bool ?? true
        notifyOnAttention = defaults.object(forKey: Keys.attention) as? Bool ?? true
        super.init()
        // 一次性迁移：清掉旧版本不可信的 `didAsk`。
        //
        // 1854 及更早的版本在**弹窗之前**就写了 `didAsk`，这个值可能是「从没真正问过」
        // 留下的。覆盖安装不清 UserDefaults，所以真机上这个坏值会一路带进修好的版本，
        // 让 `prepare()` 继续在 `.notDetermined` 上 return、永远不弹窗 —— 也就是修复
        // 看起来完全没生效。带上版本号才认，避免把用户真实的「拒绝过」也擦掉
        // （那种情况状态是 `.denied`，压根不看 `didAsk`）。
        if defaults.integer(forKey: Keys.askVersion) < Keys.askVersionTrusted {
            defaults.removeObject(forKey: Keys.didAsk)
            defaults.set(Keys.askVersionTrusted, forKey: Keys.askVersion)
        }
    }

    /// Registers as the notification delegate and asks for permission once.
    ///
    /// The permission prompt is the app's **only** one, and it is deliberately
    /// the single place `.notDetermined` is resolved: `APNSRegistrar` reads the
    /// resulting status rather than asking again, so the user is never shown the
    /// dialog twice — which is also why registering with APNs happens after this
    /// returns, not beside it.
    func prepare() async {
        center.delegate = self
        let settings = await center.notificationSettings()
        // 权限状态是这条链路唯一无法从别处推断的输入，也是「通知到底给没给」的答案本身；
        // 留下来，排查时才不必靠猜。
        DSHLog.push("prepare: authorizationStatus=\(settings.authorizationStatus.rawValue) "
            + "alertSetting=\(settings.alertSetting.rawValue)")

        switch settings.authorizationStatus {
        case .notDetermined:
            // 只在**弹窗前**用 `didAsk` 去重，并且用 `requestAuthorization` 的返回值
            // 作为「这次真的问过」的凭据：
            //
            // 这里原本是「先 set(true) 再 await 弹窗」。那个顺序有个致命的窗口——
            // 只要这一行执行了、弹窗却没真的落地（比如 App 在弹窗出现前就被切到后台/
            // 被系统回收，或用户根本没看到），`didAsk` 已经落盘，之后**每一次**启动都会
            // 在 `.notDetermined` 上直接 return，永远不再弹窗。状态于是卡死在
            // `.notDetermined`：`registerIfAuthorized()` 只对 `.authorized` 注册，
            // App 永远拿不到 APNs 令牌 —— 正是真机上看到的
            // 「已点允许、apnsToken 仍为空」。OTA 覆盖安装不会清 UserDefaults，
            // 所以旧的 `didAsk` 会一路带进新版本，让修复看起来没生效。
            //
            // 现在改成：只有弹窗**真的问过**才记 `didAsk`；`requestAuthorization`
            // 抛错（没见过、但可能）时不记，让它下次重试。用户已经明确拒绝
            // （`.denied`）时状态不再是 `.notDetermined`，由下面的 default 分支处理，
            // 不依赖 `didAsk`，所以这里的放宽不会变成反复骚扰。
            let didAsk = defaults.integer(forKey: Keys.askVersion) >= Keys.askVersionTrusted
                && defaults.bool(forKey: Keys.didAsk)
            // 已经问过就不再弹 —— 但**不 return**：这个函数末尾的
            // `registerIfAuthorized()` 必须照跑。它在 `.notDetermined` 下会自己
            // 早退（不注册），而在权限已经是 `.authorized` 的情况下这是唯一的注册点；
            // 原来这里直接 `return`，等于把「权限已给但还没注册」这条自愈路径掐掉了。
            if !didAsk {
                do {
                    isAuthorized = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                    defaults.set(true, forKey: Keys.didAsk)
                    defaults.set(Keys.askVersionTrusted, forKey: Keys.askVersion)
                    DSHLog.push("permission prompt answered: granted=\(isAuthorized)")
                } catch {
                    // 弹窗没能展示：不记 `didAsk`，下一次启动再问一次。
                    DSHLog.push("permission prompt failed: \(error.localizedDescription)")
                }
            }
        case .authorized, .provisional, .ephemeral:
            isAuthorized = true
        default:
            isAuthorized = false
        }
        // Permission is settled by now, so this is the moment a token can be
        // asked for. Doing it here rather than at `didFinishLaunching` is what
        // makes the grant and the registration one flow instead of two races.
        await APNSRegistrar.shared.registerIfAuthorized()
    }

    /// Re-reads the system's permission state without ever prompting.
    ///
    /// The settings footer tells the user what to do about a denied permission,
    /// and that sentence is wrong the moment they come back from iOS Settings
    /// having allowed it. `requestAuthorization` is deliberately not called here:
    /// a prompt can only be shown once and `prepare()` owns it.
    func refreshAuthorization() async {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            isAuthorized = true
        default:
            isAuthorized = false
        }
    }

    // MARK: - Posting

    /// A run in `session` has ended.
    func turnFinished(sessionId: String, title: String) {
        guard notifyOnTurnEnd else { return }
        post(
            identifier: "turn-end-\(sessionId)",
            title: String(localized: "运行结束"),
            body: title,
            sessionId: sessionId
        )
    }

    /// `session` cannot continue until the user answers something.
    func needsAttention(sessionId: String, title: String, detail: String) {
        guard notifyOnAttention else { return }
        post(
            identifier: "attention-\(sessionId)",
            title: String(localized: "需要你确认"),
            body: detail.isEmpty ? title : "\(title)：\(detail)",
            sessionId: sessionId
        )
    }

    private func post(
        identifier: String,
        title: String,
        body: String,
        sessionId: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // `.defaultCritical` was used here for prompts, which is silent without
        // Apple's Critical Alerts entitlement — an alert nobody hears is worse
        // than an ordinary one, so the sound is the ordinary one.
        content.sound = .default
        content.userInfo = ["sessionId": sessionId]
        // Grouping by session keeps a busy workspace from flooding the lock
        // screen with one alert per turn.
        content.threadIdentifier = sessionId

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            // A second of delay is enough for the system to treat it as a
            // delivered notification rather than a same-instant replacement.
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        center.add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Shown even while the app is in front.
    ///
    /// Without this the system swallows notifications for the foreground app,
    /// which is exactly when a user watching a different session needs them.
    ///
    /// A **remote** notification is the one case that is suppressed, and only
    /// while the app is actually in front. A push is sent because the phone was
    /// away; if the user has since picked it up, the banner is describing
    /// something the app is already showing live — and on a phone whose local
    /// path produced the same alert, it would appear twice for one event. The
    /// two reminders are told apart by their payload: a push carries `sid`
    /// (the relay's field name) and a local notification carries `sessionId`.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let userInfo = notification.request.content.userInfo
        let isRemote = notification.request.trigger is UNPushNotificationTrigger
        if isRemote, await MainActor.run(body: { Self.isInForeground }) {
            // 前台且是推送：本地那条（如果该弹）已经由 `$events` 这条路发出来了。
            let sessionId = SessionRouter.sessionId(in: userInfo) ?? ""
            await MainActor.run {
                DSHLog.push("suppressed a foreground push for \(sessionId.isEmpty ? "unknown" : sessionId)")
            }
            return []
        }
        return [.banner, .sound, .list]
    }

    /// Tapping a notification opens the session it came from.
    ///
    /// The request is handed to `SessionRouter` as well as kept here: this
    /// callback also fires for a tap that **launched** the app, at a moment when
    /// no view exists to observe `requestedSessionId`. The router holds it until
    /// there is something that can open it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // 回调本身只做一件事：从载荷里取出会话 id 交给下面那个方法。
        // 拆开是为了让「点通知」这条路的**后半段**可被直接驱动——仿真器里点不到真实
        // 横幅（通知权限装不上），而 `UNNotificationResponse` 也无法被忠实地构造出来
        // （它的 `userInfo` 走私有归档格式，解档回来是空的）。
        // `SessionRouter.sessionId(in:)` 认 `sid`（relay 的字段名）与 `sessionId`
        // （本地通知的字段名），两种载荷在这里被归一到同一个值。
        //
        // 这里**只做解档**，不碰任何 UI：`didReceive` 是 nonisolated 的，系统在
        // 后台线程上调用它（真机崩溃日志里崩的就是这条栈）。`handleTap` 是
        // `@MainActor`，`await` 它会把执行体切到主线程 —— App 在后台时点通知，
        // UIKit 正处在状态恢复/快照事务里，任何非主线程的 UIKit 触碰都会让
        // `_performBlockAfterCATransactionCommitSynchronizes:` 断言中止进程。
        let userInfo = response.notification.request.content.userInfo
        await handleTap(sessionId: SessionRouter.sessionId(in: userInfo))
    }

    /// 处理一次「通知被点按」——真机回调与仿真器复现走的都是这里。
    ///
    /// 拿到会话 id 之后把它放进进程级 `SessionRouter`（视图还不存在时也接得住），
    /// 同时留在 `requestedSessionId` 上给正在观察它的视图。
    ///
    /// **必须在主线程**：方法体读 `UIApplication.shared.applicationState` /
    /// `connectedScenes`，并写 `@Observable` 的 `requestedSessionId`（驱动 SwiftUI 刷新）。
    /// `didReceive` 从后台线程 await 进来，所以这里显式钉在 `@MainActor`；
    /// 调用点（`NotificationProbe` / `ViewportProbe` 的仿真器复现）同样在主线程 await 它。
    @MainActor
    func handleTap(sessionId resolved: String?) async {
        ViewportProbe.note("notifytap.didReceive", [
            "sid": resolved ?? "nil",
            "appState": String(UIApplication.shared.applicationState.rawValue),
            "inForeground": Self.isInForeground ? "1" : "0",
        ], force: true)
        guard let sessionId = resolved else { return }
        DSHLog.push("notification tapped → session \(sessionId)")
        SessionRouter.shared.request(sessionId: sessionId)
        self.requestedSessionId = sessionId
    }

    /// Whether the app is currently in front.
    ///
    /// Read from the scene rather than tracked by hand: the app is `@main`
    /// SwiftUI, so scene activation is the authority and there is no
    /// `applicationDidBecomeActive` to hang a flag on.
    private static var isInForeground: Bool {
        // 仿真器复现「后台点通知」时，探针把状态钉成后台：`simctl` 的 home 键改不了
        // `connectedScenes` 的 `activationState`，而这条路正是要靠它区分。
        // 探针没开时是 nil，产品判断逐字未变（见 `NotificationProbe`，DEBUG-only）。
        if let simulated = NotificationProbe.simulatedBackground { return !simulated }
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .contains { $0.activationState == .foregroundActive }
    }
}
