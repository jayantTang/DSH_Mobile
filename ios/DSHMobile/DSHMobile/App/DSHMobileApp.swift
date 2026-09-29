import DSHKit
import SwiftUI

@main
struct DSHMobileApp: App {
    /// The one `UIApplicationDelegate` this app has.
    ///
    /// SwiftUI's `@main` owns the process, but the APNs callbacks — the device
    /// token, its failure path, and the launch-time notification payload — exist
    /// only as `UIApplicationDelegate` methods. `@UIApplicationDelegateAdaptor`
    /// is how they are reached without a second delegate object beside the app;
    /// all three live in `APNSRegistrar`.
    @UIApplicationDelegateAdaptor(APNSRegistrar.self) private var appDelegate

    init() {
        #if DEBUG
        // 通知点击的冷启动路径在仿真器里没法用真推送触发（需要 Apple 签名与真机令牌），
        // 但**会崩的那一段**可以复现：冷启动时先有 sid、后有列表。这个入口把 sid 交给
        // 与推送完全相同的 `SessionRouter`，往下的代码全部是产品自己的路径。
        // 见 `SessionRouter.automationRequestedSession()`。
        if let sid = SessionRouter.automationRequestedSession() {
            SessionRouter.shared.request(sessionId: sid)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
