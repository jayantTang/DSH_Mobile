import DSHKit
import RelayKit
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
        // 启动清扫：删掉 `Caches/outgoing-files/` 下 24 小时以上的残留。
        // 正常一次发送由 `ChatModel.sendFile` 自己删拷贝，这里兜的是「上传中途被
        // 杀」那一种 —— 否则暂存区只增不减（P-3）。放在 App 的初始化里、不放进
        // `connectToBestAvailableProfile` 的关键路径：它是一次目录扫描，与连接无关，
        // 也不该拖慢或挡住连接。
        OutgoingFiles.sweep()
        // 同一类清扫，对象是中断下载留下的 resume data（P-13c）：一次下载走完就
        // 会自己删掉它那份 blob，这里兜的是「下载被放弃、再也没人回来续」那一种。
        // 同样是目录扫描，同样不在连接关键路径上。
        RelayResumeStore.sweep()

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
