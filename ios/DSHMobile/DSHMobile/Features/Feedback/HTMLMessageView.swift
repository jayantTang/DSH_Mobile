import SwiftUI
import os
import UIKit
import WebKit

/// 报告类消息（`format == html`）的渲染器：一个**锁死的** WebKit 容器。
///
/// 这是安全边界，不是普通的富文本控件。`body` 是服务端下发的一整页 HTML（日报由
/// `scripts/dev/feedback.mjs report` 生成），App 不能因为"把一封信显示出来"就执行脚本、
/// 发出网络请求或跳到别人的页面上去。为此这里锁了四件事：
///
/// 1. **不执行脚本**：`defaultWebpagePreferences.allowsContentJavaScript = false`（iOS 17 起
///    对每一次导航真正生效的就是它，旧的 `preferences.javaScriptEnabled` 是同一个开关的废弃
///    写法），另把 `javaScriptCanOpenWindowsAutomatically` 关掉，并且**不注册任何
///    `WKScriptMessageHandler`、不注入任何 `WKUserScript`**（`removeAllUserScripts()` 把注入点
///    清空）。内容与原生之间没有桥，页面里也没有任何执行入口。
/// 2. **不跳转**：`WKNavigationDelegate` 只放行最初那一次 `loadHTMLString`（`about:blank`），
///    之后任何 navigation action——点链接、`<meta http-equiv="refresh">`、子框架、表单提交
///    ——一律 `.cancel`；navigation response 同样只放行最初那一次。
/// 3. **不取外部资源**：`loadHTMLString(html, baseURL: nil)`——没有基址，相对地址与 `file://`
///    都无从谈起；页面数据存非持久化 store（关掉即没）。写死的绝对地址（`https://…/x.png`）
///    不是 `baseURL` 拦得住的，由注入的 CSP `default-src 'none'` 挡下（见 ``lockedDocument(_:)``）。
/// 4. **不靠脚本量高度**：`didFinish` 之后读 `webView.scrollView.contentSize.height` 设 frame。
///
/// 报告类消息按附件式呈现，不强行跟随暗色：报告本身就是浅色页面（`background: #f9fafb`
/// 写死在它自己的 CSS 里），硬套暗色只会变成深底深字。这里给它 ``DSHTheme/layer1`` 的圆角
/// 卡片与外框——暗色下它看起来像夹在信里的一张纸，而不是一整页刺眼的白。
struct HTMLMessageView: View {

    let html: String

    @State private var height: CGFloat = 1

    var body: some View {
        LockedHTMLWebView(html: html, height: $height)
            .frame(height: max(height, 1))
            .background(DSHTheme.layer1)
            .overlay {
                RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous)
                    .strokeBorder(DSHTheme.border2)
            }
    }
}

/// 会在每次布局后回调的 `WKWebView`：让协调者有机会在**宽度确定之后**重新量高度。
///
/// `WKWebView` 自己不会因为 view 变宽就再发一次 `didFinish`，而页面高度跟宽度强相关，
/// 所以量高度的第二个时机只能挂在布局上。
private final class ReportingWebView: WKWebView {

    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

/// 上面那个容器的实现。`UIViewRepresentable` 把 `WKWebView` 当作叶子交给 SwiftUI。
private struct LockedHTMLWebView: UIViewRepresentable {

    let html: String
    @Binding var height: CGFloat

    /// 无障碍标识：用例靠它断言"这一页正文走的是 HTML 那条路"（Markdown 那条是
    /// `feedback.body.markdown`）。标在 `WKWebView` 上而不是外层包装上——前者一定在
    /// 无障碍树里，`descendants(matching: .any)` 找得到。
    static let bodyIdentifier = "feedback.body.html"

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()

        // 1) 脚本全关：现代开关、开窗开关，注入点也清空。
        //    旧的 `preferences.javaScriptEnabled`（iOS 14 起废弃、官方指到下面这个开关）不
        //    再单独设置：iOS 17 起对每一次导航真正生效的就是 `allowsContentJavaScript`。
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.removeAllUserScripts()

        // 一次性展示：不留 cookie、缓存与本地存储。
        configuration.websiteDataStore = .nonPersistent()
        // 报告里没有媒体；真有也不许自动播放。
        configuration.allowsInlineMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all

        // 为什么不是裸 `WKWebView`：高度只能在**拿到真实宽度之后**量得准。`makeUIView`
        // 里这个 view 还是 0 宽，而此时 `loadHTMLString` 已经开跑，页面按 0 宽排版，`didFinish`
        // 里读到的 `contentSize.height` 会小得离谱（实测报告页量到 0，卡片里只剩 1pt 高的一条，
        // 页面内容整块不见）。所以用一个会在 `layoutSubviews` 里回调的子类，宽度定下来之后再量；
        // 旋转、动态字号变化也走同一条路。
        let webView = ReportingWebView(frame: .zero, configuration: configuration)
        webView.onLayout = { [weak coordinator = context.coordinator, weak webView] in
            guard let coordinator, let webView else { return }
            coordinator.measure(webView)
        }
        webView.navigationDelegate = context.coordinator
        webView.accessibilityIdentifier = Self.bodyIdentifier
        // 报告是浅色"纸"：web view 自己不画底色，圆角与四周露出外层卡片的 layer1。
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.underPageBackgroundColor = UIColor(DSHTheme.layer1)
        // 外层详情页是 ScrollView：里面这层不该自己滚。但**不能**用 `isScrollEnabled = false`
        // 来达到这个目的：滚动一关，`UIScrollView.contentSize` 就退化成 frame 尺寸，
        // 而这里正是靠 `contentSize` 量页面高度的——实测页面因此永远只有 1pt 高（内容整块不见）。
        // 正确做法是把高度量准（量准了它本来就没有可滚动的余量），其余只关回弹与安全区。
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false
        webView.isMultipleTouchEnabled = false
        webView.layer.cornerRadius = DSHTheme.Radius.medium
        webView.layer.masksToBounds = true

        context.coordinator.attach(webView)
        context.coordinator.load(Self.lockedDocument(html), into: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // 量到高度会再走一次 `updateUIView`：只有文档真的变了才重新加载，否则每次回填
        // 高度都重载一次，页面永远定不下来。
        context.coordinator.load(Self.lockedDocument(html), into: webView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    /// 给页面补一条 CSP。
    ///
    /// `baseURL: nil` 管不住内容里写死的绝对地址（`https://…/x.png`、`<link href="https://…">`、
    /// 子框架），这条 meta 才管得住：子资源请求——脚本、样式表、字体、媒体、fetch/XHR、
    /// 表单提交、子框架——全部关掉，只留报告真正需要的两样：`data:` 内嵌图片与内联样式
    /// （日报的手写 CSS 与内联 SVG 都算内联样式）。内容拿不掉这条策略：多条 CSP 是交集，
    /// 它自己再写一条只会更严。
    private static func lockedDocument(_ html: String) -> String {
        let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\""
            + "default-src 'none'; script-src 'none'; connect-src 'none'; frame-src 'none'; "
            + "media-src 'none'; form-action 'none'; base-uri 'none'; "
            + "img-src data:; style-src 'unsafe-inline'\">"
        guard let head = html.range(of: "<head", options: .caseInsensitive) else {
            // 片段（没有 `<head>`）：自己补一个，浏览器会把 meta 当头部内容。
            return "<head>\(meta)</head>\(html)"
        }
        let insertAt = html.range(of: ">", range: head.upperBound..<html.endIndex)?.upperBound
            ?? head.upperBound
        return html.replacingCharacters(in: insertAt..<insertAt, with: meta)
    }

    /// 只放行最初那一次加载，并把量到的高度回填给 SwiftUI。
    ///
    /// `@MainActor` 与两个 `decisionHandler` 上那串注解**不是风格问题**：iOS 26 SDK 里
    /// `WKNavigationDelegate` 的这两个要求声明为
    /// `@MainActor optional func …(…, decisionHandler: @escaping @MainActor @Sendable (…) -> Void)`，
    /// 类型对不上时编译器只给一句 "nearly matches optional requirement" —— 方法不再满足要求，
    /// Swift 也不会把它暴露成那个 ObjC 选择器，于是 WebKit 从不回调它，"只放行最初那一次"
    /// 这道锁就形同不存在（编译还能过）。签名照 SDK 写全，警告消失才算真的挂上了代理。
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {

        private let height: Binding<CGFloat>
        private var contentSizeObservation: NSKeyValueObservation?
        /// 已经交给 web view 的那份文档；没变就不重复加载。
        private var loadedDocument: String?

        init(height: Binding<CGFloat>) {
            self.height = height
        }

        /// 盯住 `scrollView.contentSize`：它一变就说明页面真的排出高度了。
        ///
        /// 这是比"`didFinish` 之后轮询几次"更可靠的信号——32 KB 的日报带三张内联 SVG，
        /// 排完可能要几百毫秒，轮询窗口短了就刚好错过（实测同一份内容一次量到 3000+pt、
        /// 另一次停在 1pt，卡片里一片空白）。
        func attach(_ webView: WKWebView) {
            contentSizeObservation = webView.scrollView.observe(\.contentSize, options: [.new]) { [weak self, weak webView] _, _ in
                guard let self, let webView else { return }
                Task { @MainActor in self.measure(webView) }
            }
        }

        func load(_ document: String, into webView: WKWebView) {
            guard loadedDocument != document else { return }
            loadedDocument = document
            webView.loadHTMLString(document, baseURL: nil)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            // 判据只有一条：**地址指不指向网络**。`about:blank`/`data:`/没有 URL 的放行，
            // 其余一律 `.cancel`——点链接、meta refresh、子框架、表单提交都落在后者。
            //
            // 早先这里还带一个"只放行第一次"的闸门（配一个 `didAllowInitialNavigation` 标记），
            // 结果是页面永远空白：`loadHTMLString` 的导航回调顺序不保证先 action 后 response，
            // 而 response 那道闸门依赖 action 先设过标记——顺序一反，初始加载被自己取消，
            // 编译期一点提示都没有（2026-10-12 实测：日报在卡片里只剩 1pt 高的一条）。
            // 去掉状态之后，两条回调各自凭地址判断，谁先谁后都成立。
            decisionHandler(Self.isInert(navigationAction.request.url) ? .allow : .cancel)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
        ) {
            decisionHandler(Self.isInert(navigationResponse.response.url) ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // `didFinish` 这一刻 `contentSize` 还是 0：WebKit 在文档解析完之后才更新它，
            // 而那时我们的 view 帧没变、不会再走 `layoutSubviews`。实测（2026-10-12）无论
            // 32 KB 的日报还是 148 字节的 `<h1>`，这里读到的都是 0，于是卡片只有 1pt 高、
            // 内容整块不见。所以量不到就在主线程上按小间隔重试几次，量到即止。
            measure(webView)
            retryMeasure(webView, attempts: 40)
        }

        /// `didFinish` 之后的补偿测量：每 100 ms 试一次，最多 40 次（4 秒），量到就停。
        /// KVO 是主路，这里是它没触发时的兜底。
        private func retryMeasure(_ webView: WKWebView, attempts: Int) {
            guard attempts > 0, height.wrappedValue <= 1 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.measure(webView)
                self.retryMeasure(webView, attempts: attempts - 1)
            }
        }

        // 加载失败只进系统日志（不弹、不打断）：报告页加载不出来时，卡片会保持 1pt 高，
        // 界面上一片空白——真正的原因只有这里知道。日志里只写错误描述，不写正文。
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Self.logger.error("feedback html failed: \(error.localizedDescription, privacy: .public)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            Self.logger.error("feedback html provisional failed: \(error.localizedDescription, privacy: .public)")
        }

        private static let logger = Logger(subsystem: "com.jayanttang.dsh", category: "feedback-html")

        /// 高度不用脚本量：`scrollView.contentSize` 就是页面自己的高度。
        ///
        /// 两个调用点：`didFinish`（文档解析完）与 `layoutSubviews`（宽度定下来 / 变化）。
        /// 只靠前者会在 0 宽时量到 0（见 `makeUIView` 里的注释）。
        func measure(_ webView: WKWebView) {
            let measured = webView.scrollView.contentSize.height.rounded(.up)
            guard measured > 1, abs(height.wrappedValue - measured) > 0.5 else { return }
            height.wrappedValue = measured
        }

        /// `about:blank` / `data:` 这类不指向网络的地址；`nil` 也算（初始请求在部分系统上
        /// 没有 URL）。`http`/`https`/`file` 一律不算。
        private static func isInert(_ url: URL?) -> Bool {
            guard let url else { return true }
            switch url.scheme?.lowercased() {
            case nil, "about", "data": return true
            default: return false
            }
        }
    }
}
