import DSHChatDomain
import DSHChatUI
import DSHConnectionDomain
import DSHCore
import DSHFoundation
import DSHKit
import DSHSessionsDomain
import SwiftUI

/// 启动装配：把 RootView 里"先绑谁、再连谁"的次序收进一处。
///
/// 只做接线，不持有界面状态：连接失败通过闭包交回 RootView 的 `connectionError`。
/// 次序是产品不变量：账户状态 → 冷启动记录 → 消息层 → 列表/附件/聊天/事件中枢
/// → 活动名单 → 连接。写在 `start()` 里之后，RootView 只剩"什么时候调用它"。
@MainActor
final class AppStartupCoordinator {

    private let store: ConnectionStore
    private let hub: HostEventHub
    private let listModel: SessionListModel
    private let chatModel: ChatModel
    private let messageLayer: MessageLayer
    private let attachmentImages: AttachmentImages
    private let activity: ActivityModel
    private let viewLog: SessionViewLog
    private let answerLog: PromptAnswerLog
    private let alertPrefs: SessionAlertPrefs
    private let onConnectionFailure: (String) -> Void

    init(store: ConnectionStore, hub: HostEventHub, listModel: SessionListModel,
         chatModel: ChatModel, messageLayer: MessageLayer,
         attachmentImages: AttachmentImages, activity: ActivityModel,
         viewLog: SessionViewLog, answerLog: PromptAnswerLog,
         alertPrefs: SessionAlertPrefs,
         onConnectionFailure: @escaping (String) -> Void) {
        self.store = store
        self.hub = hub
        self.listModel = listModel
        self.chatModel = chatModel
        self.messageLayer = messageLayer
        self.attachmentImages = attachmentImages
        self.activity = activity
        self.viewLog = viewLog
        self.answerLog = answerLog
        self.alertPrefs = alertPrefs
        self.onConnectionFailure = onConnectionFailure
    }

    func start() async {
        // 032：账户级状态只依赖中转，与主机是否在线无关，所以先装配。
        AccountStateSync.shared.attach(
            viewLog: viewLog, alertPrefs: alertPrefs, answerLog: answerLog,
            hub: hub, link: { [weak store] in store })
        await AccountStateSync.shared.refresh()
        await store.noteColdLaunch()

        messageLayer.attach(link: store.link)
        listModel.attach(to: store, hub: hub, viewLog: viewLog, messageLayer: messageLayer)
        attachmentImages.attach(store: store)
        chatModel.attach(store: store, hub: hub)
        chatModel.attach(messageLayer: messageLayer)
        // 宿主标题事件按会话归属转给列表：占位行据此显示真实标题。
        chatModel.onSessionTitle = { [listModel] id, title in
            listModel.noteSessionTitle(id: id, title: title)
        }
        #if DEBUG
        // 032 用例钩子：`-DSHProbeStaleFollowFrame` 时注入一帧上一个会话的迟到帧。
        if ProbeVariants.staleFollowFrame {
            chatModel.staleFrameInjector = { StaleFrameInjection.make() }
        }
        #endif
        // 事件流每次重开都重新问 client，修链路换 carrier 后自动跟上。
        hub.attach { [store] in store.link }
        // 018：活动名单跟着连接走：建连即订阅 + 取名单，断线冻结本地推断。
        activity.attach(service: store, hub: hub)
        listModel.activityModel = activity

        // 自动化优先：脚本给了明确目标，不能再回退到记住的档案。
        if let link = RootView.automationLink() {
            if let failure = await store.connect(link: link) {
                onConnectionFailure(failure)
            }
            return
        }

        // 静默重连：打开 App 应落在会话列表，而不是配对页。
        guard !RootView.automationShowsOnboarding() else { return }
        forgetDirectProfilesIfAsked()
        await connectToBestAvailableProfile()
    }

    /// 连第一台有凭据、最近用过的电脑；失败就换下一台。
    private func connectToBestAvailableProfile() async {
        let ordered = store.profiles
            .filter { store.hasSecret(for: $0) }
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
        for profile in ordered {
            await store.connect(to: profile)
            if store.state.isConnected { return }
        }
    }

    /// `-DSHForgetDirect`：当次运行要求走产品通道时，删掉遗留的调试直连档案。
    private func forgetDirectProfilesIfAsked() {
        #if DEBUG
        guard CommandLine.arguments.contains("-DSHForgetDirect") else { return }
        for profile in store.profiles {
            if case .direct = profile.transport { store.removeProfile(profile) }
        }
        #endif
    }
}
