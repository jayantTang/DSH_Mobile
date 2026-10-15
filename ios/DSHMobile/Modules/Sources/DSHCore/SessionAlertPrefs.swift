import Foundation
import Observation

/// 通知偏好（「跑完了叫我」「等你回应时叫我」+ 授权状态），Core 层共享：
/// 通知行为由 App 侧的 SessionAlerts 执行，偏好本身放在 Core 让设置页
/// （DSHSettingsUI）直接绑定，不需要认识 App 的通知适配器。
///
/// 存储键与 SessionAlerts 历史版本完全一致，迁移零行为变化。
@MainActor
@Observable
public final class SessionAlertPrefs {

    /// Whether a finished run is worth a notification.
    public var notifyOnTurnEnd: Bool {
        didSet {
            defaults.set(notifyOnTurnEnd, forKey: Keys.turnEnd)
            Task { await self.onChange?() }
        }
    }

    /// Whether a session waiting on an answer is worth a notification.
    public var notifyOnAttention: Bool {
        didSet {
            defaults.set(notifyOnAttention, forKey: Keys.attention)
            Task { await self.onChange?() }
        }
    }

    /// 系统通知授权状态，由 SessionAlerts.refreshAuthorization() 写入。
    public var isAuthorized = false

    /// 偏好变化后的同步钩子（App 装配到 APNSRegistrar.switchesChanged）。
    public var onChange: (() async -> Void)? = nil

    private let defaults: UserDefaults

    private enum Keys {
        static let turnEnd = "alerts.notifyOnTurnEnd"
        static let attention = "alerts.notifyOnAttention"
    }

    /// App 全局唯一实例（偏好与授权状态天然是进程级一份）。
    public static let shared = SessionAlertPrefs()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Both default on: someone who installs a remote client for their agent
        // is installing it precisely to be told when something needs them.
        notifyOnTurnEnd = defaults.object(forKey: Keys.turnEnd) as? Bool ?? true
        notifyOnAttention = defaults.object(forKey: Keys.attention) as? Bool ?? true
    }
}
