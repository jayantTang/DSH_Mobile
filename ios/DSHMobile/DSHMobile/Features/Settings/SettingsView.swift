import DSHKit
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
        HStack(alignment: .top, spacing: DSHTheme.Spacing.tight) {
            Image(systemName: device.isCurrent ? "iphone.gen3" : "iphone")
                .font(.system(size: 15))
                .foregroundStyle(device.isCurrent ? DSHTheme.brand : DSHTheme.labelTertiary)
                .frame(width: 20)
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
            Spacer(minLength: 0)
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
            LabeledContent("状态") {
                HStack(spacing: DSHTheme.Spacing.hairline) {
                    StatusDot(level: connectionLevel, size: 7)
                    Text(connectionLabel)
                }
            }
            LabeledContent("连接方式", value: model.about.transport.label)
            if let endpoint = model.about.endpoint {
                LabeledContent("主机地址") {
                    Text(masked(endpoint))
                        .font(DSHTheme.Typography.caption)
                        .foregroundStyle(DSHTheme.labelSecondary)
                        .textSelection(.enabled)
                }
            }
            if let home = model.about.hostHome {
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
        case .connected: return "已连接"
        case .connecting: return "连接中"
        case .failed: return "连接失败"
        case .disconnected: return "未连接"
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
                    HStack(alignment: .top, spacing: DSHTheme.Spacing.tight) {
                        Image(systemName: currentPreset == preset.value ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 15))
                            .foregroundStyle(currentPreset == preset.value ? DSHTheme.brand : DSHTheme.labelDimmed)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                                .font(DSHTheme.Typography.body)
                                .foregroundStyle(DSHTheme.labelPrimary)
                            Text(preset.detail)
                                .font(DSHTheme.Typography.micro)
                                .foregroundStyle(DSHTheme.labelTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
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

    private static let permissionPresets: [(value: String, name: String, detail: String)] = [
        ("read-only", "只读", "可以查看文件，但不能做任何修改。"),
        ("workspace-write", "仅工作区可写", "可在项目目录内创建和修改文件，工作区之外只读。"),
        ("danger-full-access", "完全访问", "可以执行任意命令，读写整台电脑。"),
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
                        LabeledContent(row.ref) {
                            HStack(spacing: DSHTheme.Spacing.hairline) {
                                if let source = row.source, !source.isEmpty {
                                    Text(source)
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
                }
            }
            .accessibilityIdentifier("settings.alert.turnEnd")

            Toggle(isOn: $alerts.notifyOnAttention) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("需要确认时提醒")
                    Text("会话等待授权或等待你回答时收到通知")
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelSecondary)
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
                SessionListSnapshotStore().clear()
                cacheClearedAt = Date()
            } label: {
                HStack {
                    Text("清除会话列表缓存")
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
            Text("会话列表会留一份「上次看到的样子」在本机，冷启动先显示它再更新；只存标题、时间、用量这类元数据，不存对话内容，30 天后自动失效。")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("App 版本", value: model.about.appVersion)
            LabeledContent("DSH 主机版本") {
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
                LabeledContent("连接器", value: name)
            }
            if let port = model.about.connectorPort {
                LabeledContent("连接器端口", value: String(port))
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
                }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text("在电脑端配置")
                        .font(DSHTheme.Typography.body)
                        .foregroundStyle(DSHTheme.labelPrimary)
                    Text("\(model.namespaces.count - Self.mobileNamespaces.count) 项")
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelTertiary)
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
        case "agent-default-model": return "新会话使用的默认模型"
        case "subagent-model-selection": return "子代理使用的模型"
        case "llm-deepseek": return "DeepSeek 接口地址、上下文窗口与图片限制"
        case "llm-pi-ai": return "其他模型提供方"
        case "web-search-deepseek": return "联网搜索"
        case "agent-loop": return "Agent 循环、步数上限与超时"
        case "agent-presets": return "Agent 预设"
        case "shell": return "Shell 环境与超时"
        case "ui-theme": return "电脑端主题与字号"
        case "locale": return "电脑端语言"
        case "ui-chat": return "电脑端聊天界面"
        case "ui-conversation": return "电脑端会话界面"
        case "ui-onboarding": return "电脑端引导状态"
        default: return "电脑端配置"
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
