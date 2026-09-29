#if DEBUG
import Foundation
import UserNotifications
import UIKit

/// 模拟「App 在后台时用户点了一条通知」——只用于仿真器复现，Release 里不存在。
///
/// 真机上这条路的时序是：
///
/// ```
/// App 在后台（进程活着，socket 大概率已被 iOS 收走、keep-alive 还开着）
///   → 用户点横幅
///   → iOS 把 App 拉回前台
///   → userNotificationCenter(_:didReceive:) 回调
///   → SessionRouter.request → MainView.openRequestedSession → chatModel.open + paths.append
/// ```
///
/// 仿真器点不到真实横幅（通知权限装不上），但 `didReceive` **可以**被构造出来：
/// `UNNotificationResponse` 不是抽象类，`UNNotification` / `UNNotificationRequest` /
/// `UNMutableNotificationContent` 都是可实例化的。构造出的对象里 `userInfo` 与真机
/// 推送逐字段相同（`sid` 是 relay `push.py` 的字段名），所以从 delegate 往下走的
/// **全部是产品自己的代码**——探针只负责"把这一下点出来"，不替产品做任何决定。
///
/// 关键点：`NotificationProbe.background()` 让 delegate 读到的"前台/后台"与真机一致。
/// 产品代码里有一处依赖它 (`SessionAlerts.isInForeground` 走 `connectedScenes` 的
/// `activationState`)，用 `simctl` 的 home 键做不到这个状态，所以在进程内模拟。
@MainActor
enum NotificationProbe {

    /// 当前是否处于"后台态"。真机上由 iOS 维护，这里由探针维护。
    ///
    /// `SessionAlerts.isInForeground` 会先读它——**只在探针开启时**才被读，
    /// 平时这个值是 nil，产品走原来那条 `connectedScenes` 判断（见 SessionAlerts）。
    private(set) static var simulatedBackground: Bool?

    static func background() {
        simulatedBackground = true
        ViewportProbe.note("notifytap.state", ["simulated": "background"], force: true)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    static func foreground() {
        simulatedBackground = false
        ViewportProbe.note("notifytap.state", ["simulated": "active"], force: true)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    /// 触发一次「用户点了通知」，交给产品自己的入口处理。
    static func deliverTap(sid: String, remote: Bool = true, to delegate: SessionAlerts) async {
        ViewportProbe.note("notifytap.didReceive.begin", [
            "sid": sid,
            "remote": remote ? "1" : "0",
            "appState": String(UIApplication.shared.applicationState.rawValue),
        ], force: true)
        // 产品自己的入口，逐字调用：sid -> SessionRouter -> MainView。
        // 传的是 `sid`（relay `push.py:_payload` 的字段名），与真推送一致；
        // 本地通知那条路传 `sessionId`，由回调里同一个 `sessionId(in:)` 归一。
        await delegate.handleTap(sessionId: sid)
        ViewportProbe.note("notifytap.didReceive.end", ["sid": sid], force: true)
        // 真机上 iOS 紧接着把 App 拉回前台。
        try? await Task.sleep(for: .milliseconds(300))
        foreground()
    }
}

#else
import Foundation

/// Release 构建里没有这种钩子。
@MainActor
enum NotificationProbe {
    static var simulatedBackground: Bool? { nil }
    static func background() {}
    static func foreground() {}
}
#endif
