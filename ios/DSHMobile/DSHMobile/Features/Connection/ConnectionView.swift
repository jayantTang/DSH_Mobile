import DSHKit
import SwiftUI

/// Onboarding and connection management.
///
/// Two paths are offered because they answer different situations: pairing
/// through the relay works anywhere, while a direct LAN connection is faster
/// and keeps traffic off the server. The copy states that trade-off plainly
/// rather than hiding it behind "自动".
struct ConnectionView: View {
    @Environment(ConnectionStore.self) private var store

    /// One way in.
    ///
    /// There used to be a second: dialling the computer directly over the local
    /// network. It is gone because both ends need the internet anyway, running
    /// two connection paths meant two sets of failure modes and two capability
    /// sets — files, for instance, worked over the relay and not over the local
    /// path. The direct transport still exists for the DEBUG launch hook the
    /// simulator suite uses; it is not offered to anyone.
    enum Method: String, CaseIterable, Identifiable {
        case relay
        var id: String { rawValue }
        var title: String { "扫码配对" }
    }

    @State private var method: Method = .relay

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

    // Direct state
    @State private var host = ""
    @State private var port = "54499"
    @State private var launchToken = ""

    @State private var isWorking = false
    @State private var error: String?
    @State private var isScanning = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSHTheme.Spacing.section) {
                    banner
                    if !store.profiles.isEmpty { savedConnections }
                    methodPicker
                    form
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
        PanelSection("已保存的连接") {
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
                            Button("连接") {
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

    private var methodPicker: some View {
        Picker("连接方式", selection: $method) {
            ForEach(Method.allCases) { method in
                Text(method.title).tag(method)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: method) { error = nil }
    }

    @ViewBuilder
    private var form: some View {
        switch method {
        case .relay:
            PanelSection("中转配对") {
                VStack(alignment: .leading, spacing: DSHTheme.Spacing.tight) {
                    scanButton
                    field("中转服务器", text: $relayURL, keyboard: .URL)
                    field("配对码", text: $pairCode, keyboard: .asciiCapable, autocapitalization: .characters)
                    Text("在电脑端打开 /mobile-link/qr（或 DSH 的移动端连接页）显示二维码，用上面的「扫码配对」扫它；也可以手动输入配对码。")
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    primaryButton("配对并连接") { Task { await pair() } }
                }
                .padding(.horizontal, DSHTheme.Spacing.tight)
            }

        }
    }

    private var hint: some View {
        PanelSection("提示") {
            VStack(alignment: .leading, spacing: DSHTheme.Spacing.hairline) {
                Label("中转连接需要电脑侧连接器在线，DSH 重启后会自动重连。", systemImage: "cloud")
                Label("电脑与手机都需联网；对话内容经中转服务转发，不在服务器落盘。", systemImage: "lock.shield")
            }
            .font(DSHTheme.Typography.micro)
            .foregroundStyle(DSHTheme.labelTertiary)
            .padding(.horizontal, DSHTheme.Spacing.tight)
        }
    }

    // MARK: - Controls

    private func field(
        _ title: String,
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

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
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

    /// The one-tap path: point the camera at the code the computer shows.
    ///
    /// It fills the same fields the manual path uses, so a scan that fails to
    /// claim a code leaves the user somewhere they can retype it rather than at
    /// a dead end.
    private var scanButton: some View {
        Button {
            error = nil
            isScanning = true
        } label: {
            HStack(spacing: DSHTheme.Spacing.tight) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 17, weight: .medium))
                VStack(alignment: .leading, spacing: 1) {
                    Text("扫码配对")
                        .font(DSHTheme.Typography.bodyStrong)
                        .foregroundStyle(DSHTheme.labelPrimary)
                    Text("扫描电脑上显示的二维码，地址和配对码自动填入")
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelTertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DSHTheme.labelDimmed)
            }
            .padding(DSHTheme.Spacing.tight)
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

    // MARK: - Actions

    /// Connects from a scanned payload.
    ///
    /// A full `dsh://pair?…` link goes through the same path as the launch hook
    /// (profile de-duplication included); a bare code is filled into the field
    /// and claimed against the relay currently typed in.
    private func handleScanned(_ payload: String) async {
        switch PairPayload.parse(payload) {
        case .link(let link):
            isWorking = true
            defer { isWorking = false }
            if let failure = await store.connect(link: link) { error = failure }
        case .code(let code):
            pairCode = code
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
                deviceName: ConnectionStore.deviceName
            )
            let profile = ConnectionProfile(
                name: pairing.agentName,
                transport: .relay(relayURL: pairing.relayURL, agentId: pairing.agentId)
            )
            store.addProfile(profile, secret: pairing.deviceToken)
            pairCode = ""
            await store.connect(to: profile)
            if case .failed(let message) = store.state { error = message }
        } catch {
            self.error = ConnectionStore.describe(error)
        }
    }

    private func connectDirect() async {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedToken = launchToken.trimmingCharacters(in: .whitespaces)
        guard !trimmedHost.isEmpty, !trimmedToken.isEmpty else {
            error = "请填写电脑地址和启动令牌。"
            return
        }
        guard let url = URL(string: "http://\(trimmedHost):\(port)") else {
            error = "电脑地址无效。"
            return
        }

        isWorking = true
        error = nil
        defer { isWorking = false }

        // A direct connection has no pairing step, so the launch token is
        // exchanged for a cookie immediately: that is also the only way to tell
        // the user their token is wrong before saving the profile.
        let carrier = HTTPCarrier(baseURL: url, credential: .launchToken(trimmedToken), timeout: 30)
        do {
            try await carrier.authenticate()
            let cookie = await carrier.cookie
            await carrier.close()

            guard let cookie else {
                error = "无法从启动令牌换取会话凭据。"
                return
            }
            let profile = ConnectionProfile(
                name: trimmedHost,
                transport: .direct(baseURL: url, cookieName: cookie.name)
            )
            store.addProfile(profile, secret: cookie.value)
            launchToken = ""
            await store.connect(to: profile)
            if case .failed(let message) = store.state { error = message }
        } catch {
            await carrier.close()
            self.error = ConnectionStore.describe(error)
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
