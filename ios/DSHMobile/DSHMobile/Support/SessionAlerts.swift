import Foundation
import UserNotifications
import Observation

/// Tells the user when a run finishes or a session is blocked on them.
///
/// The point of a phone client for a desktop agent is that you can walk away.
/// That only works if the phone speaks up, so this posts a real notification —
/// a banner while the app is open, a lock-screen alert when it is not — for the
/// two things that actually need a person: a run that has ended, and a session
/// that cannot continue until someone answers.
///
/// Delivered as local notifications rather than push: the phone already holds a
/// live connection to the host, so there is nothing a push server would add for
/// a self-hosted setup, and it keeps the app free of any third-party service.
@MainActor
@Observable
final class SessionAlerts: NSObject, UNUserNotificationCenterDelegate {

    /// Whether a finished run is worth a notification.
    var notifyOnTurnEnd: Bool {
        didSet { defaults.set(notifyOnTurnEnd, forKey: Keys.turnEnd) }
    }

    /// Whether a session waiting on an answer is worth a notification.
    var notifyOnAttention: Bool {
        didSet { defaults.set(notifyOnAttention, forKey: Keys.attention) }
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
    }

    override init() {
        // Both default on: someone who installs a remote client for their agent
        // is installing it precisely to be told when something needs them.
        notifyOnTurnEnd = defaults.object(forKey: Keys.turnEnd) as? Bool ?? true
        notifyOnAttention = defaults.object(forKey: Keys.attention) as? Bool ?? true
        super.init()
    }

    /// Registers as the notification delegate and asks for permission once.
    func prepare() async {
        center.delegate = self
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .notDetermined:
            guard defaults.object(forKey: Keys.didAsk) == nil else { return }
            defaults.set(true, forKey: Keys.didAsk)
            isAuthorized = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
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
            title: "运行结束",
            body: title,
            sessionId: sessionId
        )
    }

    /// `session` cannot continue until the user answers something.
    func needsAttention(sessionId: String, title: String, detail: String) {
        guard notifyOnAttention else { return }
        post(
            identifier: "attention-\(sessionId)",
            title: "需要你确认",
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
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// Tapping a notification opens the session it came from.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let sessionId = response.notification.request.content.userInfo["sessionId"] as? String
        guard let sessionId else { return }
        await MainActor.run { self.requestedSessionId = sessionId }
    }
}
