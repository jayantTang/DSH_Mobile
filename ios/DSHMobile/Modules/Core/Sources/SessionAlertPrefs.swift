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
            // 远端合并期间两个钩子都由 `applyRemote` 在末尾统一触发一次（见那里的理由）。
            guard !isApplyingRemote else { return }
            Task { await self.onChange?() }
            Task { await self.onLocalChange?() }
        }
    }

    /// Whether a session waiting on an answer is worth a notification.
    public var notifyOnAttention: Bool {
        didSet {
            defaults.set(notifyOnAttention, forKey: Keys.attention)
            guard !isApplyingRemote else { return }
            Task { await self.onChange?() }
            Task { await self.onLocalChange?() }
        }
    }

    /// 系统通知授权状态，由 SessionAlerts.refreshAuthorization() 写入。
    public var isAuthorized = false

    // MARK: - 账户级同步（032）

    /// 当前两个开关（上传账户状态用）。
    public var accountSnapshot: (turnEnd: Bool, attention: Bool) {
        (notifyOnTurnEnd, notifyOnAttention)
    }

    /// 把远端（账户级）的开关并进来。
    ///
    /// 与本地改动走**同一**条 `onChange`（本机要把新的开关重新登记到中转的设备级 push 字段），
    /// 但**不**触发 `onLocalChange`——那是"用户在本机改的"。少了 `isApplyingRemote` 这道闸，
    /// 两台设备会把对方的写入再推回去，来回打。
    public func applyRemote(turnEnd: Bool, attention: Bool) {
        // 值没变就什么都不做：每次拉取都触发一次推送登记是无谓的。
        guard notifyOnTurnEnd != turnEnd || notifyOnAttention != attention else { return }
        isApplyingRemote = true
        notifyOnTurnEnd = turnEnd
        notifyOnAttention = attention
        isApplyingRemote = false
        // 两个开关一起并进来时只登记一次（`onChange` 会去中转重写设备级推送字段，
        // 触发两次没有意义）。`onLocalChange` 刻意不触发：这不是用户在本机改的。
        Task { await self.onChange?() }
    }

    /// 正在把远端值并进来（`didSet` 据此不再回推）。
    private var isApplyingRemote = false

    /// 偏好变化后的同步钩子（App 装配到 APNSRegistrar.switchesChanged）。
    ///
    /// **本地与远端变化都会触发**：远端改的也要让本机重新登记推送开关（设备级的 push* 字段）。
    public var onChange: (() async -> Void)? = nil

    /// 只由**用户在本机**改动时触发（032）：App 用它把新的开关推到账户级状态。
    /// 与 `onChange` 分开是有意的——远端并进来的值不该再被推回去，否则两台设备会互相回推。
    public var onLocalChange: (() async -> Void)? = nil

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
