import DSHChatDomain
import DSHChatUI
import DSHConnectionDomain
import DSHConnectionUI
import DSHFeedbackDomain
import DSHFeedbackUI
import DSHDesign
import DSHSessionsUI
import DSHCore
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
        // 探针接线（025）：模块层的 Core/Domain 不认识 App 的调试仪器 ViewportProbe，
        // 由装配层把 note 注入它们的 probeNote 钩子，行为与搬迁前一致。
        let note: (String, [String: String], Bool) -> Void = { kind, fields, force in
            ViewportProbe.note(kind, fields, force: force)
        }
        KeyboardProbe.shared.isOn = { ViewportProbe.isOn }
        SessionAlertPrefs.shared.onChange = { await APNSRegistrar.shared.switchesChanged() }
        KeyboardProbe.shared.note = { kind, fields in ViewportProbe.note(kind, fields) }
        // 025：会话单元的信箱钩子（信箱单元尚未迁入模块前由 App 提供实现）。
        // FIXME(025-阶段4b)：信箱单元迁入 DSHFeedbackDomain 后改为注入其模型。
        // 025 阶段4b：聊天单元的探针端口。`DSHChatDomain` / `DSHChatUI` 不认识
        // App 的 `ViewportProbe`（调试仪器）与 `ProbeVariants`（读启动参数），
        // 所以日志、视口几何与变体开关逐项注入；每一项都直接转发给原实现，
        // 带 `-DSHViewportProbe` / `-DSHProbe*` 启动时的行为与搬迁前逐字一致。
        // 崩溃诊断：MetricKit 在**下次启动**把它交回来，这里只负责收进本地存档，
        // 投递交给 FeedbackCenter.flushCrashReports()（前台时跑）。单测宿主不注册——
        // 那个进程不起界面、也没有中转凭据，收下来只会留在沙箱里。
        if !Self.isUnitTestHost {
            MetricKitCrashObserver.shared.start { report in
                ViewportProbe.note("crash.captured", ["id": report.id, "exception": report.exceptionType], force: false)
                Task { await FeedbackCenter.shared.flushCrashReports() }
            }
        }
        ChatProbe.shared.probeNote = note
        ChatProbe.shared.setContent = { items, streaming in
            ViewportProbe.setContent(items: items, streaming: streaming)
        }
        ChatProbe.shared.setViewport = { rect in ViewportProbe.setViewport(rect) }
        ChatProbe.shared.markReady = { ViewportProbe.markReady() }
        ChatProbe.shared.start = { ViewportProbe.start() }
        ChatProbe.shared.pause = { ViewportProbe.pause() }
        ChatProbe.shared.resume = { ViewportProbe.resume() }
        ChatProbe.shared.scrollFacts = { ViewportProbe.scrollFacts }
        ChatProbe.shared.topVisibleRow = { ViewportProbe.topVisibleRow() }
        ChatProbe.shared.visibleRowIds = { ViewportProbe.visibleRowIds() }
        ChatProbe.shared.enterRow = { id, rect in ViewportProbe.enter(id, rect) }
        ChatProbe.shared.updateRow = { id, rect in ViewportProbe.update(id, rect) }
        ChatProbe.shared.leaveRow = { id in ViewportProbe.leave(id) }
        ChatProbe.shared.setScroll = { offset, content in ViewportProbe.lastScroll = (offset, content) }
        ChatProbe.shared.olderScrollRounds = ViewportProbe.olderScrollRounds
        ChatProbe.shared.olderDriveSkipsReclaimed = ViewportProbe.olderDriveSkipsReclaimed
        ChatProbe.shared.listHost = ProbeVariants.listHost
        ChatProbe.shared.listSpike = ProbeVariants.listSpike
        ChatProbe.shared.lazyStack = ProbeVariants.lazyStack
        ChatProbe.shared.windowRows = ProbeVariants.windowRows
        ChatProbe.shared.payloadBudgetKB = ProbeVariants.payloadBudgetKB
        ChatProbe.shared.failPageAttempts = ProbeVariants.failPageAttempts
        ChatProbe.shared.pageShortfall = ProbeVariants.pageShortfall
        ChatProbe.shared.autoRetryMs = ProbeVariants.autoRetryMs
        ChatProbe.shared.noHistoryWindow = ProbeVariants.noHistoryWindow
        ChatProbe.shared.noSessionSearch = ProbeVariants.noSessionSearch
        ChatProbe.shared.reclaimScreens = ProbeVariants.reclaimScreens
        ChatProbe.shared.rehydrateScreens = ProbeVariants.rehydrateScreens
        ChatProbe.shared.forceRehydrate = ProbeVariants.forceRehydrate
        ChatProbe.shared.noteDriveBegan = { ProbeVariants.noteDriveBegan() }
        ChatViewSeams.shared.runTyping = { target, focus in
            await ViewportProbe.runTyping(into: target, focus: focus)
        }
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
        // 015：冷启动点通知的**第一条**来源，等价真机
        // `launchOptions[.remoteNotification]` 那条（`APNSRegistrar` 里同一句话）。
        // 第二条来源由主界面出现后触发（`ViewportProbe.runNotifyColdTapProbe`）：
        // 两条同时存在、且被点会话还没进列表，才是真机冷启动的形态。
        if let sid = ViewportProbe.notifyColdTapSid {
            SessionRouter.shared.request(sessionId: sid)
        }
        #endif
    }

    /// 是不是被 `xcodebuild test` 注入的单元测试宿主。
    ///
    /// 为什么需要它：单元测试包必须靠 App 宿主进程才能 `@testable` 到 App 内部的类型（推送注册、
    /// 通知路由、钥匙串这些平台适配都在 App target 里），但那些用例一点都不关心界面。见到这个
    /// 环境变量就不建 `RootView`——这就是 spec 023 说的"零截图"口径：不启动主界面、不截图、
    /// 不做手势。
    ///
    /// 注意它**不是**"零模拟器"：`xcodebuild test` 仍会拉起模拟器进程。界面回归照旧走
    /// `scripts/dev/verify-simulator.sh` 与 `test/run.sh` 的逐屏核对。
    static let isUnitTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    var body: some Scene {
        WindowGroup {
            if Self.isUnitTestHost {
                // 单元测试宿主：不起界面。用例只用 App 里的非 UI 代码。
                Color.clear
            } else {
                RootView()
            }
        }
    }
}
