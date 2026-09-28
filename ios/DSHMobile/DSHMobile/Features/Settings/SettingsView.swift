import DSHKit
import RelayKit
import SwiftUI

/// Settings, scoped to what a phone should actually change.
///
/// The host exposes fourteen configuration namespaces and the desktop client
/// edits all of them. Almost none of that belongs here: theme, locale, chat
/// layout, model wiring, shell and agent-loop tuning are decisions about the
/// machine doing the work, and changing them from a phone is at best awkward
/// and at worst a way to break a running session.
///
/// So this screen answers a different question — what does someone holding a
/// phone genuinely need? — with four things: whether the link is healthy, how
/// much freedom the agent has on the machine, whether the host's credentials
/// are present, and which build is on each end. Everything else is named and
/// pointed at the desktop rather than hidden, so a search for a setting ends in
/// an answer instead of a dead end.
struct SettingsView: View {
    let store: ConnectionStore

    @State private var model = SettingsModel()
    @State private var isShowingPCOnly = false
    @State private var isShowingRawDocument = false
    /// The device a confirmation sheet is asking about, if any.
    @State private var pendingRevoke: RelayDevice?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(SessionAlerts.self) private var alerts

    var body: some View {
        List {
            statusSection
            devicesSection
            permissionSection
            credentialsSection
            alertsSection
            cacheSection
            aboutSection
            desktopOnlySection
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("settings.root")
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    if model.isRefreshing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("刷新")
                    }
                }
                .disabled(model.isRefreshing)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
        .task {
            model.attach(to: store)
            await model.start()
        }
        .onChange(of: store.state.isConnected) { _, isConnected in
            // 设置页可以在握手完成前打开（启动即直达设置页，或慢网下先点了齿轮），
            // 那时 `start()` 读不到 client。`load()` 自己会等一段，但等待有上限：
            // 握手比上限还慢、或先失败后被 store 的看护循环重连成功时，靠这里补读一次，
            // 页面自己长齐，而不是让用户去点「刷新」。`readScreen()` 会合并在飞的那次，
            // 所以这里不会重复取。
            guard isConnected else { return }
            Task { await model.start() }
        }
        .onDisappear {
            Task { await model.flushPendingSaves() }
        }
        .confirmationDialog(
            pendingRevoke?.isCurrent == true ? "撤销这台手机？" : "撤销这台设备？",
            isPresented: Binding(
                get: { pendingRevoke != nil },
                set: { if !$0 { pendingRevoke = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("撤销", role: .destructive) {
                guard let device = pendingRevoke else { return }
                pendingRevoke = nil
                Task { await model.revoke(device) }
            }
            Button("取消", role: .cancel) { pendingRevoke = nil }
        } message: {
            Text(pendingRevoke?.isCurrent == true
                 ? "撤销的是你正在使用的这台手机。撤销后这台手机将立即断开，需要重新配对才能再连。"
                 : "撤销后该设备需要重新配对才能连接这台电脑。")
        }
    }

    // MARK: - Paired devices

    /// The pairings the relay holds for this computer.
    ///
    /// This is the one piece of security-relevant state a phone genuinely needs
    /// to manage: if a device is lost, someone holding it should be able to cut
    /// it off without walking to the computer. The list comes from the relay
    /// (the only party that knows about pairings), which is why it is absent on
    /// a direct connection rather than shown empty.
    @ViewBuilder
    private var devicesSection: some View {
        if model.devicesAvailable {
            Section {
                switch model.devicesPhase {
                case .loading where model.devices.isEmpty:
                    HStack(spacing: DSHTheme.Spacing.hairline) {
                        ProgressView().controlSize(.mini)
                        Text("读取中…").foregroundStyle(DSHTheme.labelTertiary)
                    }
                default:
                    if model.devices.isEmpty {
                        Text("还没有其他设备配对到这台电脑。")
                            .font(DSHTheme.Typography.caption)
                            .foregroundStyle(DSHTheme.labelTertiary)
                    } else {
                        ForEach(model.devices) { device in
                            deviceRow(device)
                        }
                    }
                    if let failure = model.devicesError {
                        Text(failure)
                            .font(DSHTheme.Typography.caption)
                            .foregroundStyle(DSHTheme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                HStack {
                    Text("已配对的设备")
                    Spacer()
                    if model.revokingDeviceId != nil {
                        ProgressView().controlSize(.mini)
                    }
                }
            } footer: {
                Text("这些是能通过中转到这台电脑的手机。撤销一台设备后，它需要重新配对。")
            }
            .accessibilityIdentifier("settings.devices")
        }
    }

    private func deviceRow(_ device: RelayDevice) -> some View {
        AdaptiveRow {
            // 图标列的固定宽度保留：它装的是 `Image(systemName:)` 而不是文本，
            // 与语言无关（方案「不做什么」1）。
            Image(systemName: device.isCurrent ? "iphone.gen3" : "iphone")
                .font(.system(size: 15))
                .foregroundStyle(device.isCurrent ? DSHTheme.brand : DSHTheme.labelTertiary)
                .frame(width: 20)
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DSHTheme.Spacing.hairline) {
                    Text(device.displayName)
                        .font(DSHTheme.Typography.body)
                        .foregroundStyle(DSHTheme.labelPrimary)
                    if device.isCurrent {
                        Badge(text: "本机", tone: .brand)
                            .accessibilityIdentifier("settings.device.current.\(device.deviceId)")
                    }
                }
                if let hardware = device.model, !hardware.isEmpty {
                    Text(hardware)
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelTertiary)
                }
                Text(model.lastSeenLabel(for: device))
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.labelTertiary)
            }
            .fixedSize(horizontal: false, vertical: true)
        } trailing: {
            if model.revokingDeviceId == device.deviceId {
                ProgressView().controlSize(.mini)
            } else {
                Button("撤销") { pendingRevoke = device }
                    .buttonStyle(.borderless)
                    .font(DSHTheme.Typography.caption)
                    .foregroundStyle(DSHTheme.danger)
                    .disabled(model.revokingDeviceId != nil)
                    .accessibilityIdentifier("settings.device.revoke.\(device.deviceId)")
            }
        }
        .padding(.vertical, 2)
        // A `List` row is a single accessibility element, so an identifier on the
        // outer container is dropped and the row becomes unfindable from a UI
        // test. Marking the row's content instead (without merging children, so
        // the badge and the revoke button stay individually addressable) keeps
        // the whole row addressable by device id.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.device.row.\(device.deviceId)")
    }

    // MARK: - Connection

    /// Whether the deployment's own addresses are replaced by placeholders.
    ///
    /// Set by `-DSHDemoMode`, which only the screenshot run passes. A picture of
    /// this screen travels: the README, a blog post, an issue. A real relay
    /// hostname in it publishes where the relay is — and the screenshot is the
    /// one place `relay.example.com` cannot be substituted at build time,
    /// because it is the *host's* address, painted by the running app.
    private var isDemoMode: Bool { DemoMode.isOn }

    /// The address as it should appear: the real one, or a placeholder.
    ///
    /// Whatever the shape of the real value, the placeholder is fixed: the point
    /// of the picture is that this is a relay rather than a LAN address, and
    /// that part is not secret.
    private func masked(_ endpoint: String) -> String { DemoMode.maskedEndpoint(endpoint) }

    private var statusSection: some View {
        Section {
            AdaptivePair {
                Text("状态")
            } value: {
                HStack(spacing: DSHTheme.Spacing.hairline) {
                    StatusDot(level: connectionLevel, size: 7)
                    Text(connectionLabel)
                }
            }
            AdaptivePair {
                Text("连接方式")
            } value: {
                Text(model.about.transport.label)
            }
            if let endpoint = model.about.endpoint {
                AdaptivePair {
                    Text("主机地址")
                } value: {
                    Text(masked(endpoint))
                        .font(DSHTheme.Typography.caption)
                        .foregroundStyle(DSHTheme.labelSecondary)
                        .textSelection(.enabled)
                }
            }
            if let home = model.about.hostHome {
                // 这一处**刻意**保留 `.lineLimit(1) + .truncationMode(.head)`：
                // 路径首部省略是设计（长路径从中间省略读不出是什么目录），
                // 行高恒定，且路径长度与语言无关。不要换成 AdaptivePair。
                LabeledContent("主机主目录") {
                    Text(isDemoMode ? DemoMode.homePlaceholder : home)
                        .font(DSHTheme.Typography.caption)
                        .foregroundStyle(DSHTheme.labelSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("连接")
        } footer: {
            Text("新增或切换连接在会话列表左上角的状态按钮里。")
        }
    }

    private var connectionLevel: StatusDot.Level {
        switch store.state {
        case .connected: return .ok
        case .connecting: return .busy
        case .failed: return .error
        case .disconnected: return .idle
        }
    }

    private var connectionLabel: String {
        switch store.state {
        case .connected: return String(localized: "已连接")
        case .connecting: return String(localized: "连接中")
        case .failed: return String(localized: "连接失败")
        case .disconnected: return String(localized: "未连接")
        }
    }

    // MARK: - Permission

    /// The one setting genuinely worth changing from a phone.
    ///
    /// It answers "how much may the agent do to my computer", which is exactly
    /// the question you want to be able to answer while away from it.
    private var permissionSection: some View {
        Section {
            ForEach(Self.permissionPresets, id: \.value) { preset in
                Button {
                    selectPreset(preset.value)
                } label: {
                    AdaptiveRow {
                        Image(systemName: currentPreset == preset.value ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 15))
                            .foregroundStyle(currentPreset == preset.value ? DSHTheme.brand : DSHTheme.labelDimmed)
                    } content: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                                .font(DSHTheme.Typography.body)
                                .foregroundStyle(DSHTheme.labelPrimary)
                            Text(preset.detail)
                                .font(DSHTheme.Typography.micro)
                                .foregroundStyle(DSHTheme.labelTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } trailing: {
                        if let label = model.saveState(for: "permission").label {
                            Text(label)
                                .font(DSHTheme.Typography.micro)
                                .foregroundStyle(DSHTheme.labelTertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.isReadOnly)
                .accessibilityIdentifier("settings.permission.\(preset.value)")
            }
        } header: {
            Text("权限")
        } footer: {
            Text(currentPreset == "danger-full-access"
                 ? "当前为完全访问：Agent 可以执行任意命令并读写整台电脑。只在信任当前任务时使用。"
                 : "这是新建会话的默认权限；已存在的会话保持它们各自的设置。")
        }
    }

    /// 名字与说明都过一遍本地化：表里存中文是为了跟电脑端文案一致，
    /// 英文用户看到的应当是英文。
    private static let permissionPresets: [(value: String, name: String, detail: String)] = [
        ("read-only", String(localized: "只读"), String(localized: "可以查看文件，但不能做任何修改。")),
        ("workspace-write", String(localized: "仅工作区可写"),
         String(localized: "可在项目目录内创建和修改文件，工作区之外只读。")),
        ("danger-full-access", String(localized: "完全访问"),
         String(localized: "可以执行任意命令，读写整台电脑。")),
    ]

    private var currentPreset: String {
        model.value(namespace: "permission", path: ["defaultPreset"])?.stringValue ?? ""
    }

    private func selectPreset(_ value: String) {
        guard value != currentPreset else { return }
        model.setValue(namespace: "permission", path: ["defaultPreset"], value: .string(value))
    }

    // MARK: - Credentials

    /// Read-only by design: a secret typed on a phone keyboard is a worse idea
    /// than walking to the machine, and all the phone needs to know is whether
    /// the host can authenticate at all.
    private var credentialsSection: some View {
        Section {
            switch model.credentialsPhase {
            case .loading:
                HStack(spacing: DSHTheme.Spacing.hairline) {
                    ProgressView().controlSize(.mini)
                    Text("读取中…").foregroundStyle(DSHTheme.labelTertiary)
                }
            case .failed(let message):
                Text(message)
                    .font(DSHTheme.Typography.caption)
                    .foregroundStyle(DSHTheme.danger)
            default:
                if model.credentialRows.isEmpty {
                    Text("主机没有声明任何凭据。")
                        .font(DSHTheme.Typography.caption)
                        .foregroundStyle(DSHTheme.labelTertiary)
                } else {
                    ForEach(model.credentialRows) { row in
                        AdaptivePair {
                            Text(row.ref)
                        } value: {
                            HStack(spacing: DSHTheme.Spacing.hairline) {
                                if let source = row.source, !source.isEmpty {
                                    // 宿主下发的文案：认识的词条翻，不认识的按原样显示。
                                    Text(String(localized: String.LocalizationValue(source)))
                                        .font(DSHTheme.Typography.micro)
                                        .foregroundStyle(DSHTheme.labelTertiary)
                                }
                                Badge(
                                    text: row.configured ? "已配置" : "缺失",
                                    tone: row.configured ? .success : .danger
                                )
                            }
                        }
                    }
                }
            }
        } header: {
            Text("凭据")
        } footer: {
            Text("密钥只写入主机，客户端无法读回；这里只显示是否已配置。修改请在电脑端 DSH 设置中进行。")
        }
    }

    // MARK: - About

    /// The two things worth interrupting someone for.
    private var alertsSection: some View {
        @Bindable var alerts = alerts
        return Section {
            Toggle(isOn: $alerts.notifyOnTurnEnd) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("运行结束时提醒")
                    Text("某个会话跑完一轮后收到通知")
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityIdentifier("settings.alert.turnEnd")

            Toggle(isOn: $alerts.notifyOnAttention) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("需要确认时提醒")
                    Text("会话等待授权或等待你回答时收到通知")
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityIdentifier("settings.alert.attention")
        } header: {
            Text("提醒")
        } footer: {
            Text(
                alerts.isAuthorized
                    ? "通知会在这台手机上弹出；点一下直接打开对应会话。"
                    : "尚未获得通知权限，请到 iOS 设置里允许 DSH 发送通知。"
            )
        }
    }

    /// 缓存：会话列表的本地快照（只有元数据，30 天后自动失效）。
    ///
    /// 放在设置里是为了让"手机上留了什么"可见、可清——用户不该需要相信我们没存东西。
    @State private var cacheClearedAt: Date?

    private var cacheSection: some View {
        Section {
            Button(role: .destructive) {
                SessionListSnapshotStore().clearAll()
                SessionTranscriptCache().clearAll()
                AttachmentDiskCache().clearAll()
                // 内存里那一份也要放掉，否则下一次落盘会把刚清掉的文件写回来。
                NotificationCenter.default.post(name: .localCachesCleared, object: nil)
                cacheClearedAt = Date()
            } label: {
                HStack {
                    Text("清除本地缓存")
                    Spacer(minLength: 0)
                    if cacheClearedAt != nil {
                        Text("已清除")
                            .foregroundStyle(DSHTheme.labelTertiary)
                    }
                }
            }
            .accessibilityIdentifier("settings.clear-cache")
        } header: {
            Text("缓存")
        } footer: {
            Text("本机留两份缓存：会话列表（标题、时间、用量这类元数据）和每个会话的对话尾部（最近 200 条，用来冷启动先显示再增量更新）。都在 Caches 里、不进备份，30 天后自动失效，总占用有上限（转写 40 MB、图片 100 MB），这里可以随时一键清掉。")
        }
    }

    private var aboutSection: some View {
        Section {
            AdaptivePair {
                Text("App 版本")
            } value: {
                Text(model.about.appVersion)
            }
            AdaptivePair {
                Text("DSH 主机版本")
            } value: {
                if let version = model.about.hostVersion {
                    Text(version)
                } else {
                    // The host does not publish its version over the client
                    // protocol, so say so rather than showing a placeholder key.
                    Text("主机未上报")
                        .foregroundStyle(DSHTheme.labelTertiary)
                }
            }
            if let name = model.about.connectorName {
                AdaptivePair {
                    Text("连接器")
                } value: {
                    Text(name)
                }
            }
            if let port = model.about.connectorPort {
                AdaptivePair {
                    Text("连接器端口")
                } value: {
                    Text(String(port))
                }
            }
        } header: {
            Text("关于")
        }
    }

    // MARK: - Desktop-only configuration

    /// Everything else the host can configure: named, explained, not editable.
    private var desktopOnlySection: some View {
        Section {
            DisclosureGroup(isExpanded: $isShowingPCOnly) {
                ForEach(model.namespaces.filter { !Self.mobileNamespaces.contains($0.ns) }) { namespace in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(namespace.title)
                            .font(DSHTheme.Typography.caption)
                            .foregroundStyle(DSHTheme.labelPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(Self.desktopOnlyReason(namespace.ns))
                            .font(DSHTheme.Typography.micro)
                            .foregroundStyle(DSHTheme.labelTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 1)
                }

                DisclosureGroup(isExpanded: $isShowingRawDocument) {
                    Text(SettingsValueText.pretty(model.document?.raw ?? .null))
                        .font(DSHTheme.Typography.code)
                        .foregroundStyle(DSHTheme.labelSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("原始设置文档")
                        .font(DSHTheme.Typography.caption)
                        .foregroundStyle(DSHTheme.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text("在电脑端配置")
                        .font(DSHTheme.Typography.body)
                        .foregroundStyle(DSHTheme.labelPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(model.namespaces.count - Self.mobileNamespaces.count) 项")
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            Text("手机端负责接入并操作电脑上的 DSH；主题、语言、模型接口、Shell 等配置请在电脑端修改。")
        }
    }

    /// Namespaces this screen owns.
    private static let mobileNamespaces: Set<String> = ["permission"]

    private static func desktopOnlyReason(_ ns: String) -> String {
        switch ns {
        case "agent-default-model": return String(localized: "新会话使用的默认模型")
        case "subagent-model-selection": return String(localized: "子代理使用的模型")
        case "llm-deepseek": return String(localized: "DeepSeek 接口地址、上下文窗口与图片限制")
        case "llm-pi-ai": return String(localized: "其他模型提供方")
        case "web-search-deepseek": return String(localized: "联网搜索")
        case "agent-loop": return String(localized: "Agent 循环、步数上限与超时")
        case "agent-presets": return String(localized: "Agent 预设")
        case "shell": return String(localized: "Shell 环境与超时")
        case "ui-theme": return String(localized: "电脑端主题与字号")
        case "locale": return String(localized: "电脑端语言")
        case "ui-chat": return String(localized: "电脑端聊天界面")
        case "ui-conversation": return String(localized: "电脑端会话界面")
        case "ui-onboarding": return String(localized: "电脑端引导状态")
        default: return String(localized: "电脑端配置")
        }
    }
}

/// Sheet presentation for `SettingsView`.
struct SettingsSheet: View {
    let store: ConnectionStore

    var body: some View {
        NavigationStack {
            SettingsView(store: store)
        }
    }
}
