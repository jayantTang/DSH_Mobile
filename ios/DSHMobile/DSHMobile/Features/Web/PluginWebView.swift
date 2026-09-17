import DSHKit
import Observation
import SwiftUI
import WebKit

// MARK: - Surface

/// A cookie-shaped credential injected before the first load.
///
/// DSH authenticates a browser with a `dsh-auth-*` cookie minted by the launch
/// token exchange; the same cookie is what makes this web view act as the signed
/// in user. Only name, value and scope are kept — the value is never rendered.
struct WebCredential: Sendable, Hashable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let isSecure: Bool

    init?(cookie: HTTPCookie) {
        guard !cookie.domain.isEmpty, !cookie.value.isEmpty else { return nil }
        self.name = cookie.name
        self.value = cookie.value
        self.domain = cookie.domain
        self.path = cookie.path.isEmpty ? "/" : cookie.path
        self.isSecure = cookie.isSecure
    }

    init?(name: String, value: String, for url: URL) {
        guard let host = url.host(), !name.isEmpty, !value.isEmpty else { return nil }
        self.name = name
        self.value = value
        self.domain = host
        self.path = "/"
        self.isSecure = url.scheme == "https"
    }

    /// Mirrors `HTTPCarrier`'s own cookie construction so the web view and the
    /// RPC carrier authenticate identically.
    func makeCookie() -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: domain,
            .path: path,
            .name: name,
            .value: value,
        ]
        if isSecure { properties[.secure] = "TRUE" }
        return HTTPCookie(properties: properties)
    }
}

/// The page a `PluginWebView` loads.
///
/// Two shapes exist because the phone can reach a DSH host two ways: a LAN base
/// URL (the host's own pages, authenticated by cookie) or the relay origin (which
/// serves the pairing and status console rather than the host's page tree).
struct PluginWebSurface: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case lan
        case relay

        var label: String {
            switch self {
            case .lan: return "局域网主机"
            case .relay: return "中转控制台"
            }
        }
    }

    let url: URL
    let kind: Kind
    let title: String
    let credential: WebCredential?

    var id: String { url.absoluteString + kind.rawValue }

    init(url: URL, kind: Kind, title: String, credential: WebCredential? = nil) {
        self.url = url
        self.kind = kind
        self.title = title
        self.credential = credential
    }

    /// Builds the surface a saved connection profile implies.
    ///
    /// A direct profile carries the base URL and the cookie name, and its secret
    /// lives in the keychain, so the credential can be injected without asking
    /// the user again. A relay profile can only reach the relay origin: DLP
    /// tunnels the RPC protocol, not the host's HTTP page tree, so the console is
    /// all that is reachable through it.
    /// Builds the surface from the store's active connection.
    ///
    /// A direct connection yields the host's own origin, which is what actually
    /// serves the plugin pages; a relay connection yields the relay origin, which
    /// serves the pairing console instead. `nil` means there is nothing to open.
    @MainActor
    init?(store: ConnectionStore) {
        guard let profile = store.activeProfile else { return nil }
        self.init(profile: profile)
    }

    init?(profile: ConnectionProfile) {
        switch profile.transport {
        case .direct(let baseURL, let cookieName):
            let secret = Keychain.get(profile.secretAccount)
            self.init(
                url: baseURL,
                kind: .lan,
                title: profile.name,
                credential: secret.flatMap { WebCredential(name: cookieName, value: $0, for: baseURL) }
            )
        case .relay(let relayURL, _):
            self.init(url: relayURL, kind: .relay, title: profile.name, credential: nil)
        }
    }
}

// MARK: - Model

@MainActor
@Observable
final class PluginWebModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    let surface: PluginWebSurface
    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0
    private(set) var title: String?
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    /// The live web view, handed over by the representable.
    @ObservationIgnored weak var webView: WKWebView?
    /// Bumped to ask the representable to load again.
    private(set) var reloadToken = UUID()

    init(surface: PluginWebSurface) {
        self.surface = surface
    }

    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    /// Injects the credential, then loads. Nothing is requested before the cookie
    /// is stored, which is what makes the first paint already authenticated.
    func start() async {
        guard let webView else { return }
        phase = .loading
        progress = 0
        if let credential = surface.credential, let cookie = credential.makeCookie() {
            await Self.store(cookie, in: webView.configuration.websiteDataStore.httpCookieStore)
        }
        webView.load(URLRequest(url: surface.url, timeoutInterval: 30))
    }

    func reload() {
        reloadToken = UUID()
    }

    func goBack() {
        guard webView?.canGoBack == true else { return }
        webView?.goBack()
    }

    func goForward() {
        guard webView?.canGoForward == true else { return }
        webView?.goForward()
    }

    func stop() {
        webView?.stopLoading()
    }

    /// Writes one cookie and waits for the store to acknowledge it.
    private static func store(_ cookie: HTTPCookie, in store: WKHTTPCookieStore) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.setCookie(cookie) { continuation.resume() }
        }
    }

    // MARK: Delegate callbacks

    fileprivate func didStart() {
        phase = .loading
        progress = 0
        refreshNavigationState()
    }

    fileprivate func didFinish() {
        phase = .loaded
        progress = 1
        title = webView?.title
        refreshNavigationState()
    }

    fileprivate func didFail(_ message: String) {
        phase = .failed(message)
        refreshNavigationState()
    }

    fileprivate func update(progress value: Double) {
        progress = min(1, max(0, value))
    }

    fileprivate func refreshNavigationState() {
        canGoBack = webView?.canGoBack ?? false
        canGoForward = webView?.canGoForward ?? false
    }
}

// MARK: - Navigation delegate

/// Keeps off-origin links out of the fallback surface.
///
/// The surface exists to reach the host's own pages; anything pointing elsewhere
/// belongs in Safari, where the user can see the address bar.
@MainActor
final class PluginWebNavigationDelegate: NSObject, WKNavigationDelegate {
    weak var model: PluginWebModel?
    /// Opens a link this surface refused, in the user's browser.
    var onExternalURL: (@MainActor (URL) -> Void)?
    /// KVO subscriptions, kept alive for the web view's lifetime.
    var observations: [NSKeyValueObservation] = []
    /// The last reload token this delegate acted on.
    var lastReloadToken = UUID()

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        model?.didStart()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        model?.didFinish()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        model?.didFail(Self.describe(error))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        model?.didFail(Self.describe(error))
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        model?.refreshNavigationState()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }
        let scheme = url.scheme?.lowercased() ?? ""

        // Sub-frames belong to the page itself.
        if navigationAction.targetFrame?.isMainFrame == false {
            return .allow
        }
        if scheme == "about" || scheme == "data" || scheme == "blob" || scheme == "javascript" {
            return .allow
        }
        guard scheme == "http" || scheme == "https" else {
            // mailto:, tel:, and app links: hand them to the system.
            onExternalURL?(url)
            return .cancel
        }
        let surfaceHost = model?.surface.url.host()
        if let host = url.host(), host == surfaceHost {
            return .allow
        }
        if let host = url.host(), let surfaceHost, host.hasSuffix(".\(surfaceHost)") {
            return .allow
        }
        // A link out of the host's own pages belongs in Safari, where the address
        // bar tells the user where they landed.
        onExternalURL?(url)
        return .cancel
    }

    private static func describe(_ error: any Error) -> String {
        let failure = error as NSError
        switch failure.code {
        case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
            return "无法连接主机：请确认电脑端 DSH 仍在运行，并且手机与电脑在同一网络。"
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "网络不可用，请检查手机的网络连接。"
        case NSURLErrorTimedOut:
            return "加载超时，主机没有在预期时间内响应。"
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return "系统拦截了这次连接：DSH 需要 HTTPS 或本机地址才能加载。"
        case NSURLErrorCancelled:
            return "加载已取消。"
        default:
            return "插件页面加载失败：\(failure.localizedDescription)"
        }
    }
}

// MARK: - Web view

/// The `WKWebView` bridge.
struct PluginWebContainer: UIViewRepresentable {
    let surface: PluginWebSurface
    let model: PluginWebModel
    let reloadToken: UUID

    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> PluginWebNavigationDelegate {
        let delegate = PluginWebNavigationDelegate()
        delegate.model = model
        // The model already starts the load from `.task`, so seed the token to
        // avoid a second load on the first update pass.
        delegate.lastReloadToken = model.reloadToken
        delegate.onExternalURL = { url in
            guard !url.isFileURL else { return }
            openURL(url)
        }
        return delegate
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The default (persistent) store is what makes the injected cookie
        // survive a reload inside the same session.
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        context.coordinator.observe(webView, model: model)
        model.attach(webView)

        // No load here: `model.start()` stores the credential first, so the very
        // first request already carries it.
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastReloadToken != reloadToken else { return }
        context.coordinator.lastReloadToken = reloadToken
        Task { await model.start() }
    }
}

extension PluginWebNavigationDelegate {
    /// Publishes `estimatedProgress` onto the observable model.
    func observe(_ webView: WKWebView, model: PluginWebModel) {
        observations.append(
            webView.observe(\.estimatedProgress, options: [.new]) { _, change in
                guard let value = change.newValue else { return }
                Task { @MainActor in model.update(progress: value) }
            }
        )
        observations.append(
            webView.observe(\.title, options: [.new]) { _, change in
                // `newValue` is doubly optional: the observed property is itself
                // optional, and KVO wraps it once more.
                let value = change.newValue ?? nil
                Task { @MainActor in model.didUpdate(title: value) }
            }
        )
    }
}

extension PluginWebModel {
    fileprivate func didUpdate(title value: String?) {
        guard let value, !value.isEmpty else { return }
        title = value
    }
}

// MARK: - The screen

/// A fallback surface: an in-app browser for the rare plugin-provided interface
/// the native client does not implement.
///
/// It is deliberately presented as an escape hatch rather than primary UI — the
/// header says so — and it always offers the Safari hand-off, because a page
/// built for a desktop browser behaves better there when it misbehaves here.
struct PluginWebView: View {
    let surface: PluginWebSurface

    @State private var model: PluginWebModel
    @State private var delegate = PluginWebNavigationDelegate()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    init(surface: PluginWebSurface) {
        self.surface = surface
        _model = State(initialValue: PluginWebModel(surface: surface))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                fallbackBanner
                Hairline()
                if model.phase == .loading {
                    ProgressView(value: model.progress, total: 1)
                        .progressViewStyle(.linear)
                        .tint(DSHTheme.brand)
                }
                content
                Hairline()
                navigationBar
            }
            .background(DSHTheme.background)
            .navigationTitle(model.title ?? surface.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        openURL(surface.url)
                    } label: {
                        Label("在浏览器中打开", systemImage: "safari")
                    }
                    .accessibilityHint("用系统浏览器打开同一个地址")
                }
            }
            .task {
                delegate.model = model
                await model.start()
            }
            .onDisappear { model.stop() }
        }
    }

    /// Whether the page failed; a pattern check because `Phase.failed` carries a
    /// message and so has no bare case to compare against.
    private var isFailed: Bool {
        if case .failed = model.phase { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            PluginWebContainer(
                surface: surface,
                model: model,
                reloadToken: model.reloadToken
            )
            .opacity(isFailed ? 0 : 1)

            switch model.phase {
            case .failed(let message):
                ErrorStateView(message: message) { model.reload() }
                    .background(DSHTheme.background)
            case .idle, .loading, .loaded:
                EmptyView()
            }
        }
    }

    /// Says plainly that this is the fallback, and why it exists.
    private var fallbackBanner: some View {
        HStack(alignment: .top, spacing: DSHTheme.Spacing.tight) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 13))
                .foregroundStyle(DSHTheme.brand)
            VStack(alignment: .leading, spacing: 1) {
                Text("备用界面 · \(surface.kind.label)")
                    .font(DSHTheme.Typography.caption)
                    .foregroundStyle(DSHTheme.labelPrimary)
                Text("原生界面还没有实现的插件功能可以在这里使用。页面由主机提供，行为与桌面浏览器一致。")
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.labelSecondary)
                Text(surface.url.absoluteString)
                    .font(DSHTheme.Typography.code)
                    .foregroundStyle(DSHTheme.labelTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DSHTheme.Spacing.standard)
        .padding(.vertical, DSHTheme.Spacing.tight)
        .background(DSHTheme.layer2)
    }

    private var navigationBar: some View {
        HStack(spacing: DSHTheme.Spacing.loose) {
            Button {
                model.goBack()
            } label: {
                Image(systemName: "chevron.backward")
                    .frame(width: 44, height: 44)
            }
            .disabled(!model.canGoBack)
            .accessibilityLabel("后退")

            Button {
                model.goForward()
            } label: {
                Image(systemName: "chevron.forward")
                    .frame(width: 44, height: 44)
            }
            .disabled(!model.canGoForward)
            .accessibilityLabel("前进")

            Spacer(minLength: 0)

            Button {
                model.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("重新加载")
        }
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(DSHTheme.brand)
        .padding(.horizontal, DSHTheme.Spacing.tight)
        .background(DSHTheme.layer1)
    }
}

/// The honest disabled state for a connection that cannot host a plugin page.
///
/// A relay connection is the common case: DLP tunnels DSH's RPC protocol, not the
/// host's HTTP page tree, so the native client simply has no URL to load until the
/// phone is back on the same network.
struct PluginWebUnavailableView: View {
    let reason: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            EmptyStateView(
                icon: "wifi.exclamationmark",
                title: "这个连接没有插件页面",
                message: reason
            )
            .background(DSHTheme.background)
            .navigationTitle("插件页面")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

/// Picks the fallback surface or its disabled state, so a caller can present the
/// escape hatch unconditionally.
struct PluginWebFallback: View {
    let surface: PluginWebSurface?
    let unavailableReason: String

    init(surface: PluginWebSurface?, unavailableReason: String) {
        self.surface = surface
        self.unavailableReason = unavailableReason
    }

    /// The store-driven form: the surface comes from the active connection, and
    /// the reason explains exactly why there is none.
    init(store: ConnectionStore) {
        self.surface = PluginWebSurface(store: store)
        self.unavailableReason = Self.reason(for: store)
    }

    private static func reason(for store: ConnectionStore) -> String {
        guard let profile = store.activeProfile else {
            return "还没有连接到 DSH 主机，插件页面需要一条可用的连接。"
        }
        switch profile.transport {
        case .relay:
            return "中转连接只转发 DSH 的协议帧，不转发主机上的网页；回到与电脑同一局域网后即可打开插件页面。"
        case .direct:
            return "这条连接没有可打开的插件页面地址。"
        }
    }

    var body: some View {
        if let surface {
            PluginWebView(surface: surface)
        } else {
            PluginWebUnavailableView(reason: unavailableReason)
        }
    }
}
