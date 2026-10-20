import DSHChatDomain
import DSHConnectionDomain
import DSHCore
import DSHFeedbackDomain
import DSHFoundation
import DSHSessionsDomain
import SwiftUI

/// 前后台切换的执行器：计划来自 `AppLifecyclePlan`，这里只按计划发起动作。
///
/// 它替代的是 `RootView.stageTwo` 里那段 50 行的 `.onChange(of: scenePhase)`。
/// 依赖由 RootView 在首次 phase 变化时注入；不持有全局单例的写入权。
@MainActor
final class ScenePhaseCoordinator {

    private let store: ConnectionStore
    private let hub: HostEventHub
    private let listModel: SessionListModel
    private let chatModel: ChatModel
    private let updates: UpdateChecker
    private let alerts: SessionAlerts
    private let keepAlive: RunKeepAlive

    init(store: ConnectionStore, hub: HostEventHub, listModel: SessionListModel,
         chatModel: ChatModel, updates: UpdateChecker, alerts: SessionAlerts,
         keepAlive: RunKeepAlive) {
        self.store = store
        self.hub = hub
        self.listModel = listModel
        self.chatModel = chatModel
        self.updates = updates
        self.alerts = alerts
        self.keepAlive = keepAlive
    }

    func handle(_ phase: AppLifecyclePhase) {
        let input = AppLifecycleInput(
            phase: phase,
            isConnected: store.state.isConnected,
            hasWorkInFlight: hasWorkInFlight
        )
        apply(AppLifecyclePlan.make(input), phase: phase)
    }

    /// 运行中的任务数或待答集合变化时，只重算保活这一项。
    func syncHoldAwake(phase: AppLifecyclePhase) {
        keepAlive.sync(
            isBackground: phase == .background,
            hasWorkInFlight: hasWorkInFlight
        )
    }

    private var hasWorkInFlight: Bool {
        listModel.runningCount > 0 || !hub.pending.isEmpty
    }

    private func apply(_ plan: AppLifecyclePlan, phase: AppLifecyclePhase) {
        if plan.flushTranscripts {
            // 此刻之后进程可能就没了；两条写链都要冲。
            chatModel.persistTranscriptNow()
            Task { await chatModel.flushTranscript() }
            Task { await chatModel.flushPipelineWrites() }
        }
        if plan.noteBackground {
            Task { await store.noteScene(.background) }
        }
        if plan.noteForeground {
            Task { await store.noteScene(.foreground) }
            if plan.refreshAccountState {
                Task { await AccountStateSync.shared.refresh() }
            }
        }
        if plan.refreshUpdates {
            Task { await updates.refresh() }
        }
        if plan.refreshFeedback {
            Task { await FeedbackCenter.shared.applicationBecameActive() }
        }
        if plan.refreshPushRegistration {
            Task {
                await alerts.refreshAuthorization()
                await APNSRegistrar.shared.registerIfAuthorized()
                await APNSRegistrar.shared.reportToRelayIfNeeded()
            }
        }
        if plan.startFeedAndRefreshList {
            hub.startIfNeeded(link: store.link)
            Task { await listModel.refresh() }
            Task { await chatModel.syncTailWithHost(reason: "foreground") }
        }
        if plan.reconnect {
            Task { await store.reconnectIfNeeded() }
        }
        keepAlive.sync(
            isBackground: phase == .background,
            hasWorkInFlight: hasWorkInFlight
        )
    }
}

extension ScenePhase {
    var lifecyclePhase: AppLifecyclePhase {
        switch self {
        case .active: return .active
        case .inactive: return .inactive
        case .background: return .background
        @unknown default: return .inactive
        }
    }
}
