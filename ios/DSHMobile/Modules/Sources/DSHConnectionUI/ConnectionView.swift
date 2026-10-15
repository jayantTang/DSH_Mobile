#if os(iOS)
import DSHConnectionDomain
import DSHCore
import DSHDesign
import DSHFoundation
import DSHKit
import SwiftUI

/// Onboarding and connection management.
///
/// **One way in, and it is the camera.** The QR code the computer shows already
/// carries the relay address and a one-time pairing code, so asking a person to
/// choose a transport or to retype an address was pure friction: nothing they
/// could supply there was not already in the code. What is left on this screen
/// is 扫码配对, the saved connections, and a deliberately quiet manual entry for
/// the case the camera cannot be used at all (spec 010 FR-011/FR-012).
public struct ConnectionView: View {
    /// 配对完成后的回调（由 App 构造时注入；026：替代 025 的全局 static 钩子）。
    private let onPairingChanged: () async -> Void

    public init(onPairingChanged: @escaping () async -> Void = {}) {
        self.onPairingChanged = onPairingChanged
    }
    @Environment(ConnectionStore.self) private var store

    // Relay pairing state
    // Pre-filled from the build's Config.xcconfig — the relay is published as a
    // path prefix on an existing site rather than a dedicated subdomain, so the
    // path matters as much as the host. The repository ships a placeholder
    // (relay.example.com); a local Config.local.xcconfig overrides it. 见
    // Support/AppConfig.swift。
    //
    // 演示模式改用占位符：这个字段会被拍进 App Store 截图，而真值属于部署方。
    // 生产构建永不传 -DSHDemoMode，预填行为不变（见 Support/DemoMode.swift）。
    @State private var relayURL = DemoMode.isOn ? "https://relay.example.com/dsh-link" : AppConfig.relayURL
    @State private var pairCode = ""

    @State private var isWorking = false
    @State private var error: String?
    @State private var isScanning = false
    /// 手输配对码默认收起来：扫码是主路径，打字是兜底。
    @State private var showsManualInput = false

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSHTheme.Spacing.section) {
                    banner
                    if !store.profiles.isEmpty { savedConnections }
                    scanButton
                    manualEntry
                    if let error {
                        Text(error)
                            .font(DSHTheme.Typography.caption)
                            .foregroundStyle(DSHTheme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    hint
                }
                .padding(DSHTheme.Spacing.loose)
            }
            .background(DSHTheme.background)
            .navigationTitle("连接 DSH")
            .sheet(isPresented: $isScanning) {
                PairScannerView { payload in
                    Task { await handleScanned(payload) }
                }
            }
        }
    }

    // MARK: - Sections

    private var banner: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.tight) {
            HStack(spacing: DSHTheme.Spacing.tight) {
                // 与桌面图标同一个形状：图由 `scripts/dev/make-app-icon.py` 出，
                // 模板图跟着 `foregroundStyle` 染色，界面里和桌面上永远一致。
                Image("TailMark")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .foregroundStyle(DSHTheme.brand)
                    .accessibilityHidden(true)
                Text("DSH Mobile")
                    .font(DSHTheme.Typography.largeTitle)
                    .foregroundStyle(DSHTheme.labelPrimary)
            }
            Text("连接你电脑上的 DSH，随时随地查看进度、回应提问、继续会话。")
                .font(DSHTheme.Typography.caption)
                .foregroundStyle(DSHTheme.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var savedConnections: some View {
        PanelSection(String(localized: "已保存的连接")) {
            VStack(spacing: DSHTheme.Spacing.hairline) {
                // Relay connections only: a direct profile saved by an older
                // build is legacy and has no UI to create a new one.
                ForEach(store.profiles.filter { if case .relay = $0.transport { return true }; return false }) { profile in
                    HStack(spacing: DSHTheme.Spacing.tight) {
                        Image(systemName: profile.isDirect ? "wifi" : "cloud")
                            .font(.system(size: 13))
                            .foregroundStyle(profile.isDirect ? DSHTheme.success : DSHTheme.brand)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            // 演示模式下换成占位符：这一页会被拍进 App Store 截图，
                            // 而电脑名与中转地址都是"对外信息"，不能出现在商店页里。
                            Text(DemoMode.maskedHostName(profile.name))
                                .font(DSHTheme.Typography.bodyStrong)
                                .foregroundStyle(DSHTheme.labelPrimary)
                            Text(DemoMode.maskedEndpoint(profile.subtitle))
                                .font(DSHTheme.Typography.micro)
                                .foregroundStyle(DSHTheme.labelTertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if isWorking {
                            ProgressView().controlSize(.mini)
                        } else {
                            // 动词「连接设备」：名词「连接」（设置页章节标题）与它共用过一个键，
                            // 英文下按钮因此显示成 "Connection"（见 check-localization 的 duplicate-key）。
                            Button("连接设备") {
                                Task { await connect(profile) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(DSHTheme.brand)
                        }
                        Button {
                            store.removeProfile(profile)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                                .foregroundStyle(DSHTheme.labelTertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("删除连接")
                    }
                    .padding(DSHTheme.Spacing.tight)
                    .background(DSHTheme.layer1)
                    .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous))
                }
            }
            .padding(.horizontal, DSHTheme.Spacing.tight)
        }
    }

    /// The one-tap path, and the only one that is visible by default: point the
    /// camera at the code the computer's 「移动端连接」 panel shows.
    private var scanButton: some View {
        Button {
            error = nil
            isScanning = true
        } label: {
            HStack(spacing: DSHTheme.Spacing.tight) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 22, weight: .medium))
                VStack(alignment: .leading, spacing: 2) {
                    Text("扫码配对")
                        .font(DSHTheme.Typography.bodyStrong)
                        .foregroundStyle(DSHTheme.labelPrimary)
                    Text("扫描电脑端「移动端连接」里的二维码")
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelTertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DSHTheme.labelDimmed)
            }
            .padding(DSHTheme.Spacing.loose)
            .background(DSHTheme.layer2)
            .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous)
                    .stroke(DSHTheme.border2, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("connection.scan")
    }

    /// The way in when the camera cannot be used. Kept deliberately quiet — a
    /// line of small print with a plain-text toggle — because a second, equally
    /// loud entry point is what made the old screen hard to read. The relay
    /// address is pre-filled, so nobody has to know it.
    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.tight) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showsManualInput.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "keyboard")
                    Text(showsManualInput ? "收起手动输入" : "扫不了码？手动输入配对码")
                    Spacer(minLength: 0)
                }
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("connection.manual.toggle")

            if showsManualInput {
                PanelSection(String(localized: "手动输入配对码")) {
                    VStack(alignment: .leading, spacing: DSHTheme.Spacing.tight) {
                        field("中转服务器", text: $relayURL, keyboard: .URL)
                        field("配对码", text: $pairCode, keyboard: .asciiCapable, autocapitalization: .characters)
                        Text("配对码在电脑端 DSH 界面的「移动端连接」里。")
                            .font(DSHTheme.Typography.micro)
                            .foregroundStyle(DSHTheme.labelTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        primaryButton("配对并连接") { Task { await pair() } }
                    }
                    .padding(.horizontal, DSHTheme.Spacing.tight)
                }
            }
        }
    }

    private var hint: some View {
        PanelSection(String(localized: "提示")) {
            VStack(alignment: .leading, spacing: DSHTheme.Spacing.hairline) {
                Label("在电脑端 DSH 界面的「移动端连接」里打开二维码。", systemImage: "qrcode")
                Label("中转连接需要电脑侧连接器在线，DSH 重启后会自动重连。", systemImage: "cloud")
                Label("电脑与手机都需联网；对话内容经中转服务转发，不在服务器落盘。", systemImage: "lock.shield")
            }
            .font(DSHTheme.Typography.micro)
            .foregroundStyle(DSHTheme.labelTertiary)
            .padding(.horizontal, DSHTheme.Spacing.tight)
        }
    }

    // MARK: - Controls

    /// `LocalizedStringKey`, not `String`: the field labels are the page's
    /// source-language identities, and taking them as a plain `String` made
    /// `Text(_:)` use its verbatim initializer — an English phone showed
    /// 「中转服务器」「配对码」 verbatim. (The old blanket exemption for this file in
    /// `localization-exemptions.json` was that wart; it is gone now.)
    private func field(
        _ title: LocalizedStringKey,
        text: Binding<String>,
        keyboard: UIKeyboardType,
        autocapitalization: TextInputAutocapitalization = .sentences
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelTertiary)
            TextField(title, text: text)
                .font(DSHTheme.Typography.body)
                .textInputAutocapitalization(autocapitalization)
                .autocorrectionDisabled()
                .keyboardType(keyboard)
                .textFieldStyle(.plain)
                .padding(.horizontal, DSHTheme.Spacing.tight)
                .padding(.vertical, DSHTheme.Spacing.tight)
                .background(DSHTheme.layer2)
                .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous)
                        .stroke(DSHTheme.border2, lineWidth: 1)
                )
        }
    }

    /// `LocalizedStringKey` for the same reason as `field`: a plain `String`
    /// turns `Text` into its verbatim initializer.
    private func primaryButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DSHTheme.Spacing.hairline) {
                if isWorking { ProgressView().controlSize(.mini).tint(.white) }
                Text(isWorking ? "连接中…" : title)
                    .font(DSHTheme.Typography.bodyStrong)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(DSHTheme.brand)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .padding(.top, DSHTheme.Spacing.hairline)
    }

    // MARK: - Actions

    /// Connects from a scanned payload.
    ///
    /// A full `dsh://pair?…` link goes through the same path as the launch hook
    /// (profile de-duplication included); a bare code is filled into the manual
    /// field — and the manual field is revealed, so the code does not vanish
    /// into a control the person cannot see.
    private func handleScanned(_ payload: String) async {
        switch PairPayload.parse(payload) {
        case .link(let link):
            isWorking = true
            defer { isWorking = false }
            if let failure = await store.connect(link: link) { error = failure }
        case .code(let code):
            pairCode = code
            showsManualInput = true
        case nil:
            error = "这个二维码不是 DSH 配对码。"
        }
    }

    private func pair() async {
        guard let url = URL(string: relayURL.trimmingCharacters(in: .whitespaces)) else {
            error = "中转地址无效。"
            return
        }
        let code = pairCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            error = "请输入配对码。"
            return
        }

        isWorking = true
        error = nil
        defer { isWorking = false }

        do {
            let pairing = try await ConnectionStore.claimPairingCode(
                relayURL: url,
                code: code,
                deviceName: DeviceInfo.deviceName
            )
            let profile = ConnectionProfile(
                name: pairing.agentName,
                transport: .relay(relayURL: pairing.relayURL, agentId: pairing.agentId)
            )
            store.addProfile(profile, secret: pairing.deviceToken)
            pairCode = ""
            // 刚配上的这台电脑在中转上是一条全新的设备记录，`apnsToken` 必然是空的：
            // 立刻把本机令牌报过去，否则用户要等到下一次启动才收得到推送。
            await onPairingChanged()
            await store.connect(to: profile)
            if case .failed(let message) = store.state { error = message }
        } catch {
            self.error = LinkErrors.describe(error)
        }
    }

    private func connect(_ profile: ConnectionProfile) async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        await store.connect(to: profile)
        if case .failed(let message) = store.state { error = message }
    }
}
#endif
