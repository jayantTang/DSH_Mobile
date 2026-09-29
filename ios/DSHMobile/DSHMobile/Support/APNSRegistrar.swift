import DSHKit
import Foundation
import RelayKit
import UIKit
import UserNotifications

#if canImport(Security)
import Security
#endif

/// Remote notifications: registration, the token, and reporting it to the relay.
///
/// The app already spoke to the user through **local** notifications
/// (`SessionAlerts`): the phone holds a live link to the host, so a run that
/// ends while the phone is awake is a banner the app posts itself. What that
/// design cannot do is reach a phone that is *away* — the socket dies with the
/// process, and nothing wakes it up. That is what APNs is for, and it needs
/// three things this type provides:
///
/// 1. **Registration.** `UIApplication.registerForRemoteNotifications()` after
///    the user grants permission. Granting permission and registering are two
///    separate steps and neither implies the other: an app can be allowed to
///    show notifications and still never obtain a token, which is precisely the
///    state the acceptance run found (`hasPush=0`).
/// 2. **The token**, from
///    `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`, and the
///    failure path from its `didFail` sibling. Apple reissues tokens without
///    warning, so both callbacks are routed back here rather than handled once.
/// 3. **Reporting it**, with the environment it belongs to, to `POST
///    /devices/push` — the relay's existing endpoint; the device row's
///    `apnsToken`/`apnsEnv` are what a push is aimed at.
///
/// Reporting is deliberately *idempotent and cheap to repeat*: the relay stores
/// one row per phone, so a launch that re-sends an unchanged token costs one
/// request and removes a whole class of "the token changed while the app was
/// closed" bugs. It is skipped only when nothing that the relay cares about has
/// moved — same token, same environment, same switches, same device.
@MainActor
@Observable
final class APNSRegistrar: NSObject, UIApplicationDelegate {
    static let shared = APNSRegistrar()

    /// The hex device token, once Apple has handed one over.
    ///
    /// `private(set)` and observable: the settings screen shows whether this
    /// phone is actually reachable, which is the question "did registration
    /// work?" and cannot be answered from a log nobody reads.
    private(set) var token: String?

    /// Why the last registration attempt failed, if it did.
    ///
    /// Kept rather than logged and forgotten: `didFailToRegister` is silent by
    /// nature, and a missing entitlement turns "push does not work" into a
    /// message with no cause.
    private(set) var registrationError: String?

    /// The environment the current token belongs to.
    ///
    /// Figured out from the embedded provisioning profile when there is one, and
    /// from the build configuration otherwise. Getting this wrong is not a
    /// visible error: Apple answers `BadDeviceToken` and the phone simply never
    /// hears anything.
    private(set) var environment: RelayPushEnvironment = .sandbox

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let token = "push.apnsToken"
        static let environment = "push.apnsEnvironment"
        static let reportedToken = "push.reportedToken"
        static let reportedEnvironment = "push.reportedEnvironment"
        static let reportedTurnEnd = "push.reportedTurnEnd"
        static let reportedAttention = "push.reportedAttention"
        static let reportedDevice = "push.reportedDevice"
    }

    override init() {
        super.init()
        // 令牌落盘：Apple 只在注册时给一次，重启后不重新申请也能接着上报。
        token = defaults.string(forKey: Keys.token)
        environment = Self.detectEnvironment()
    }

    // MARK: - UIApplicationDelegate

    /// Adopted as *this* type rather than a separate `AppDelegate`: the two
    /// callbacks that matter carry the token and are useless anywhere else, and
    /// the SwiftUI app already needs exactly one delegate.
    ///
    /// The app is built on `UIApplicationSceneManifest` (`INFOPLIST_KEY_...`
    /// generates one), so `application(_:didFinishLaunchingWithOptions:)` still
    /// arrives and is where a launch-time notification tap is first visible.
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // A tap that launched the app: the payload is in `launchOptions`, not in
        // a delegate callback (the system only delivers `didReceive` for a tap
        // while the app is already running), so it has to be picked up here or
        // the cold-start deep link is lost.
        if let payload = launchOptions?[.remoteNotification] as? [AnyHashable: Any],
           let sessionId = SessionRouter.sessionId(in: payload) {
            SessionRouter.shared.request(sessionId: sessionId)
        }
        return true
    }

    /// Apple's answer to `registerForRemoteNotifications()`: the device token.
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let hex = Self.hexString(from: deviceToken)
        registrationError = nil
        let changed = hex != token
        token = hex
        defaults.set(hex, forKey: Keys.token)
        // 环境每次注册都重新判别：OTA 装的是 ad-hoc 描述文件，TestFlight 装的是
        // App Store 描述文件，同一台手机换一种装法，环境就变了。
        environment = Self.detectEnvironment()
        DSHLog.push("registered token len=\(deviceToken.count) env=\(environment.rawValue) changed=\(changed)")
        // A changed token invalidates what the relay holds, so the "already
        // reported" memo is cleared rather than trusted.
        if changed { forgetReport() }
        Task { await self.reportToRelayIfNeeded(force: changed) }
    }

    /// Registration failed — no token is coming this time.
    ///
    /// Never fatal: the common causes are transient (no network at launch, the
    /// simulator, a provisioning profile without the Push Notifications
    /// capability), and the next foreground is a free retry.
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        let message = error.localizedDescription
        registrationError = message
        DSHLog.push("registration failed: \(message)")
        // A device that never registers must not leave a stale token on the
        // relay: the old row would be pushed to forever, and Apple would answer
        // `BadDeviceToken` for it. The token is kept locally (Apple may still
        // have handed one over in an earlier launch) but not re-reported.
    }

    // MARK: - Permission and registration

    /// Asks for permission (once) and registers with APNs.
    ///
    /// Permission first, registration second, and the second is skipped when the
    /// first is refused: registering without permission yields a token that can
    /// never be shown, which is worse than no token because the relay would
    /// believe this phone is reachable.
    ///
    /// Called on launch and on every return to the foreground — the latter is not
    /// redundant, because the user may have just allowed notifications in iOS
    /// Settings, which is the one path that produces a first token after a
    /// previous refusal.
    func registerIfAuthorized() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            // 回到前台时也重新注册：iOS 不保证进程活着就一定有令牌回调。
            UIApplication.shared.registerForRemoteNotifications()
            // 这一步是整条链路最容易「静默失败」的地方：注册是异步的，令牌要靠回调
            // 送回来，而 Apple 可能只回一个 error。日志里留下「确实发起过」与当前的
            // 注册态，才能把「没注册」和「注册了但 Apple 没给令牌」分开。
            DSHLog.push("registerForRemoteNotifications sent; "
                + "alreadyRegistered=\(await UIApplication.shared.isRegisteredForRemoteNotifications)")
        case .notDetermined:
            // `SessionAlerts.prepare()` owns the one and only permission prompt;
            // asking here as well would race it and show the dialog twice.
            break
        default:
            // 用户拒绝了（或在设置里关了）通知：把 relay 上的登记清掉，否则
            // 推送会一直发往一个没人看的手机。
            let hadToken = token != nil
            token = nil
            defaults.removeObject(forKey: Keys.token)
            forgetReport()
            if hadToken { await reportToRelayIfNeeded(force: true) }
        }
    }

    // MARK: - Reporting to the relay

    /// What the relay should currently know about this phone.
    private struct Registration: Equatable {
        var token: String
        var env: RelayPushEnvironment
        var turnEnd: Bool
        var attention: Bool
        /// Which pairing this was reported for.
        ///
        /// Profiles are separate rows on the relay, and the same phone paired to
        /// two computers has two device records; a memo that ignored this would
        /// register the second computer only by accident.
        var device: String
    }

    /// The registration the relay is believed to hold, so an unchanged one is not
    /// re-sent on every foreground.
    private var reported: Registration? {
        get {
            guard let token = defaults.string(forKey: Keys.reportedToken),
                  let raw = defaults.string(forKey: Keys.reportedEnvironment),
                  let env = RelayPushEnvironment(rawValue: raw),
                  let device = defaults.string(forKey: Keys.reportedDevice)
            else { return nil }
            return Registration(
                token: token,
                env: env,
                turnEnd: defaults.bool(forKey: Keys.reportedTurnEnd),
                attention: defaults.bool(forKey: Keys.reportedAttention),
                device: device
            )
        }
        set {
            guard let newValue else { return forgetReport() }
            defaults.set(newValue.token, forKey: Keys.reportedToken)
            defaults.set(newValue.env.rawValue, forKey: Keys.reportedEnvironment)
            defaults.set(newValue.turnEnd, forKey: Keys.reportedTurnEnd)
            defaults.set(newValue.attention, forKey: Keys.reportedAttention)
            defaults.set(newValue.device, forKey: Keys.reportedDevice)
        }
    }

    private func forgetReport() {
        for key in [Keys.reportedToken, Keys.reportedEnvironment,
                    Keys.reportedTurnEnd, Keys.reportedAttention, Keys.reportedDevice] {
            defaults.removeObject(forKey: key)
        }
    }

    /// Sends the current registration to `POST /devices/push`.
    ///
    /// - Parameter force: report even when the memo says nothing changed. Set
    ///   when the *relay* may have lost the row (a fresh pairing, a revocation)
    ///   or when the token itself just moved.
    ///
    /// A no-op in two cases that are not errors: no usable pairing yet (the app
    /// is on the pairing screen — the report happens once one exists), and no
    /// token yet (permission not granted, or Apple has not answered).
    func reportToRelayIfNeeded(force: Bool = false) async {
        guard let relay = Self.currentRelay() else {
            DSHLog.push("report skipped: no relay pairing yet")
            return
        }
        // No token means "clear the registration"; that is a legitimate report,
        // so it is not skipped — but only when there is something to clear.
        let cleared = token == nil
        if cleared, reported == nil, !force {
            // 有配对、却没有令牌，而且 relay 那边也没有可清的东西时，这里原本是**静默**
            // 返回的。真机排查「已允许通知但 hasPush=0」时，这条静默路径正好把最可能的
            // 状态藏了起来，所以现在把它说出来（并带上权限状态，一眼能分清是权限没给
            // 还是 Apple 没回令牌）。
            let status = await UNUserNotificationCenter.current().notificationSettings()
            DSHLog.push("report skipped: no APNs token yet "
                + "(authorizationStatus=\(status.authorizationStatus.rawValue)); "
                + "a token arrives only after registerForRemoteNotifications succeeds")
            return
        }
        let desired = Registration(
            token: token ?? "",
            env: environment,
            turnEnd: defaults.object(forKey: "alerts.notifyOnTurnEnd") as? Bool ?? true,
            attention: defaults.object(forKey: "alerts.notifyOnAttention") as? Bool ?? true,
            device: relay.deviceToken
        )
        if !force, desired == reported {
            return
        }

        let admin = RelayDeviceAdmin(relayURL: relay.url, deviceToken: relay.deviceToken)
        do {
            try await admin.registerPush(
                token: desired.token,
                env: desired.env,
                turnEnd: desired.turnEnd,
                attention: desired.attention
            )
            reported = desired
            DSHLog.push(cleared
                ? "push cleared on relay"
                : "push registered: env=\(desired.env.rawValue) tokenLen=\(desired.token.count) "
                    + "turnEnd=\(desired.turnEnd) attention=\(desired.attention)")
        } catch {
            // Not fatal and not retried in a tight loop: the next foreground, the
            // next token change and the next switch flip all call back in.
            DSHLog.push("push report failed: \(ConnectionStore.describe(error))")
        }
    }

    /// The relay pairing to report against.
    ///
    /// Read straight from the keychain and the saved profiles rather than from
    /// the live connection: a phone that is away — the exact case push exists
    /// for — has no live connection, and a token that can only be reported while
    /// online would never be reported at all.
    ///
    /// The most recently used relay profile wins, matching which host the app
    /// reconnects to on launch (`RootView.connectToBestAvailableProfile`).
    private static func currentRelay() -> (url: URL, deviceToken: String)? {
        ConnectionStore.persistedProfiles()
            .compactMap { profile -> (URL, String, ConnectionProfile)? in
                guard case .relay(let relayURL, _) = profile.transport,
                      let secret = Keychain.get(profile.secretAccount),
                      !secret.isEmpty
                else { return nil }
                return (relayURL, secret, profile)
            }
            .sorted { ($0.2.lastConnectedAt ?? .distantPast) > ($1.2.lastConnectedAt ?? .distantPast) }
            .first
            .map { (url: $0.0, deviceToken: $0.1) }
    }

    /// Pull-to-refresh / switch flip: mirror the two settings toggles to the relay.
    ///
    /// The relay keeps its own `pushTurnEnd`/`pushAttention` because *it* decides
    /// whether to send, at a moment when this app is not running to be asked.
    func switchesChanged() async {
        await reportToRelayIfNeeded(force: true)
    }

    /// Called once the app has a pairing again (a fresh pairing, or a reconnect
    /// after being revoked): whatever the relay holds for this device is now
    /// unknown, so the memo goes and the next report is unconditional.
    func pairingChanged() async {
        forgetReport()
        await reportToRelayIfNeeded(force: true)
    }

    // MARK: - Token formatting

    /// `Data` → lowercase hex, which is what the relay stores and what APNs
    /// expects in the `:path` of a delivery. Apple documents the token as
    /// opaque bytes; hex is the representation that survives JSON, logs and a
    /// database column without a byte-order question.
    static func hexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Environment

    /// Which APNs host this build's tokens belong to.
    ///
    /// The truthful answer is the `aps-environment` entitlement, which is written
    /// into the code signature by whichever provisioning profile signed the
    /// build. iOS offers no public API to read an app's own entitlements
    /// (`SecTaskCopyValueForEntitlement` is macOS-only), but the *profile* is
    /// inside the bundle and carries the same word in `Entitlements`. That is
    /// what this reads.
    ///
    /// Reading it beats a `#if DEBUG` check, which is wrong for exactly the
    /// builds this project ships most often: an OTA build is a **Release** build
    /// signed with a **development** profile, so it gets a sandbox token.
    ///
    /// Falls back to the build's own `APS_ENVIRONMENT` value, then to a
    /// configuration guess. The fallback is not silent for long — `report
    /// skipped`/`push registered` lines name the environment they sent.
    private static func detectEnvironment() -> RelayPushEnvironment {
        if let raw = profileEntitlement(key: "aps-environment") {
            return raw == "production" ? .production : .sandbox
        }
        if let raw = Bundle.main.object(forInfoDictionaryKey: "APSEnvironment") as? String,
           !raw.isEmpty {
            // xcconfig 注入的值（`$(APS_ENVIRONMENT)`），构建时即确定。
            return raw == "production" ? .production : .sandbox
        }
        DSHLog.push("no aps-environment found; falling back to a build-configuration guess")
        #if DEBUG
        return .sandbox
        #else
        return .production
        #endif
    }

    /// One value out of the `Entitlements` dictionary of the embedded profile.
    ///
    /// The profile is a CMS blob with the plist in the middle, so the outer
    /// signature is stripped before parsing. Everything here is best-effort: a
    /// build with no profile (a simulator run) returns nil, which the caller
    /// treats as "ask the next source".
    private static func profileEntitlement(key: String) -> String? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return nil }
        let plist = data[start.lowerBound..<end.upperBound]
        guard let parsed = try? PropertyListSerialization.propertyList(
            from: plist, options: [], format: nil
        ) as? [String: Any],
            let entitlements = parsed["Entitlements"] as? [String: Any]
        else { return nil }
        return entitlements[key] as? String
    }
}

/// The push-related lines of the app's log.
///
/// A tiny wrapper rather than `print` scattered at the call sites: registration
/// is the one flow whose failures are *silent* (no token, no banner, no error
/// shown to anyone), so every step says what it saw, and one filter turns the
/// whole story up.
enum DSHLog {
    static func push(_ message: String) {
        NSLog("[DSHMobile/push] %@", message)
    }
}
