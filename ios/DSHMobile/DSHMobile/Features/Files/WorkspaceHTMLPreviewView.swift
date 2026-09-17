import DSHKit
import SwiftUI
import WebKit

/// A web page from the workspace, rendered the way a browser renders it.
///
/// The point is that a document written for a browser — a test report with its
/// screenshots — should be readable on the phone as the document it is, not as
/// its own source. What the web view shows is the same file Safari shows on
/// macOS, so a report that reads correctly there reads correctly here.
///
/// Nothing in the page is allowed to run or to reach out: the content is static
/// by construction, so JavaScript stays off and every attempt to leave the local
/// files is cancelled.
struct WorkspaceHTMLPreviewView: View {
    let model: WorkspaceFilesModel
    let path: String
    let title: String

    @State private var page: WorkspaceWebPage?
    @State private var phase: WorkspaceWebPage.Phase = .idle
    @State private var missing: [String] = []
    @State private var showsMissing = false

    var body: some View {
        content
            .task {
            guard page == nil, let client = model.client else {
                if model.client == nil { phase = .failed("尚未连接") }
                return
            }
            let loader = WorkspaceWebPage(client: client, scopeId: model.scope.sessionId, path: path)
            page = loader
            await loader.load()
            phase = loader.phase
            if case .ready(_, let absent) = loader.phase { missing = absent }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle, .loading:
            VStack(spacing: DSHTheme.Spacing.standard) {
                ProgressView()
                Text("正在读取…")
                    .font(DSHTheme.Typography.caption)
                    .foregroundStyle(DSHTheme.labelSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ErrorStateView(message: message) {
                Task {
                    await page?.reload()
                    if let page { phase = page.phase }
                }
            }

        case .ready(let url, _):
            ZStack(alignment: .top) {
                WebSurface(url: url)
                if !missing.isEmpty { missingBanner }
            }
        }
    }

    /// Says so when a picture did not come back, rather than leaving a quiet gap
    /// where evidence should be.
    private var missingBanner: some View {
        Button {
            showsMissing = true
        } label: {
            HStack(spacing: DSHTheme.Spacing.hairline) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("有 \(missing.count) 个附件没取到")
                    .font(DSHTheme.Typography.caption)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, DSHTheme.Spacing.standard)
            .padding(.vertical, DSHTheme.Spacing.tight)
            .background(DSHTheme.layer3)
            .foregroundStyle(DSHTheme.attention)
        }
        .buttonStyle(.plain)
        .alert("没有取到的附件", isPresented: $showsMissing) {
            Button("好", role: .cancel) {}
        } message: {
            Text(missing.joined(separator: "\n"))
        }
    }
}

/// The web view itself, wrapped so SwiftUI treats it as a leaf.
private struct WebSurface: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The report is static markup. Nothing needs to run, and switching
        // script off removes a whole class of risk from rendering a file that
        // describes the machine it was produced on.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.suppressesIncrementalRendering = false

        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        web.isOpaque = true
        web.backgroundColor = .clear
        // The page lays itself out with its own viewport meta and CSS; the web
        // view must not add anything on top. An automatic inset would double the
        // safe area and shift the page relative to a browser.
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.bounces = false
        web.allowsLinkPreview = false
        web.isMultipleTouchEnabled = false
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.host = web
        guard web.url != url else { return }
        // The page is read from the directory it was written into, and only that
        // directory: its pictures live beside it, nothing else is reachable.
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Keeps a document from navigating away from itself.
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var host: WKWebView?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let target = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            // A link inside the workspace opens in place; anything pointing at
            // the network is refused rather than followed, so a document can
            // never turn into a request to somewhere else.
            if target.isFileURL {
                if target.pathExtension.lowercased() == "html" {
                    webView.loadFileURL(target, allowingReadAccessTo: target.deletingLastPathComponent())
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.cancel)
        }
    }
}
