import Foundation

/// 前后台切换的计划：把"哪个 phase 该做什么"从 SwiftUI 修饰符里拿出来。
///
/// 这里只产出布尔计划，不执行副作用；执行在 `ScenePhaseCoordinator`。
/// 计划可以单测，副作用顺序不再藏在 `.onChange` 的 if-else 里。
enum AppLifecyclePhase: Equatable {
    case active
    case inactive
    case background
}

struct AppLifecycleInput: Equatable {
    let phase: AppLifecyclePhase
    let isConnected: Bool
    let hasWorkInFlight: Bool
}

struct AppLifecyclePlan: Equatable {
    var flushTranscripts = false
    var noteBackground = false
    var noteForeground = false
    var refreshAccountState = false
    var refreshUpdates = false
    var refreshFeedback = false
    var refreshPushRegistration = false
    var startFeedAndRefreshList = false
    var syncTail = false
    var reconnect = false
    var holdAwake = false

    static func make(_ input: AppLifecycleInput) -> AppLifecyclePlan {
        var plan = AppLifecyclePlan()
        if input.phase != .active {
            plan.flushTranscripts = true
        }
        switch input.phase {
        case .background:
            plan.noteBackground = true
        case .active:
            plan.noteForeground = true
            plan.refreshAccountState = true
            plan.refreshUpdates = true
            plan.refreshFeedback = true
            plan.refreshPushRegistration = true
            if input.isConnected {
                plan.startFeedAndRefreshList = true
                plan.syncTail = true
            } else {
                plan.reconnect = true
            }
        case .inactive:
            break
        }
        plan.holdAwake = input.phase == .background && input.hasWorkInFlight
        return plan
    }
}
