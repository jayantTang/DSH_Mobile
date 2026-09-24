#if DEBUG
import DSHKit
import SwiftUI
import UIKit

/// 「打字时跳白」的现场记录仪。
///
/// 为什么需要它：白屏是**概率性**的、由滚动几何与懒加载窗口的相对位置决定；
/// 外部录像每秒只有几十帧、截图只有某一刻，容易错过那一瞬，也说不清"当时内部是什么状态"。
/// 这里同时用两条独立的证据盯着转写区：
///
///   * **结构**（每 100ms）：转写区的可见矩形里，有没有已渲染的行盖住它。
///   * **像素**（每 500ms）：把转写区真的画一遍，数里面的墨迹占比。
///     会话有内容却几乎没有墨迹 = 用户看到的那片白（这条不依赖任何关于成因的假设）。
///
/// 另外记录触发源（键盘帧变化、输入框高度、内容信号、跟随状态、滚动几何），
/// 异常时把整屏与转写区各存一张 PNG。只在带 `-DSHViewportProbe` 启动时工作（DEBUG-only）。
@MainActor
enum ViewportProbe {

    // MARK: - 开关与落盘

    static let isOn = ProcessInfo.processInfo.arguments.contains("-DSHViewportProbe")

    private static let started = Date()
    private static var lines: [String] = []
    private static var lastFlush = Date.distantPast
    private static var anomalyCount = 0
    private static var ticker: Timer?
    /// 上一次"不在前台"的时刻：回前台后的头两秒不采样（第一帧还没画完）。
    private static var suspendedAt: Date?
    private static var ticks = 0

    static var logURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("probe.log")
    }

    static func note(_ kind: String, _ fields: [String: String] = [:], force: Bool = false) {
        guard isOn else { return }
        let stamp = String(format: "%.3f", Date().timeIntervalSince(started))
        var text = "\(stamp) \(kind)"
        for key in fields.keys.sorted() {
            text += " \(key)=\(fields[key] ?? "")"
        }
        lines.append(text)
        let due = force || Date().timeIntervalSince(lastFlush) > 0.5
        guard due else { return }
        lastFlush = Date()
        let batch = lines
        lines.removeAll(keepingCapacity: true)
        append(batch)
    }

    private static func append(_ batch: [String]) {
        let body = batch.joined(separator: "\n") + "\n"
        guard let data = body.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }

    private static func documents() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static func save(_ image: UIImage, name: String) {
        guard let data = image.pngData() else { return }
        let url = documents().appendingPathComponent(name)
        try? data.write(to: url)
        note("snapshot", ["file": name, "bytes": String(data.count)], force: true)
    }

    private static var window: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
    }

    // MARK: - 行与视口的实测矩形

    /// 已渲染的行（含尾部气泡）；键是行 id，值是它在屏幕坐标里的矩形。
    private static var rows: [String: CGRect] = [:]
    /// 最近一次 `scroll` 记录，供 `scrollFacts` 读。
    static var lastScroll: (offset: CGFloat, content: CGFloat)?
    /// 转写区的可见矩形（屏幕坐标）。
    private static var viewport: CGRect = .zero
    private static var lastUncovered: CGFloat = -1
    private static var lastSample = Date.distantPast
    /// 连续几拍都"没被盖住"——单拍的瞬态不算。
    private static var gapTicks = 0
    /// 会话里到底有没有东西可显示；没有的时候"白"是正常的空态。
    private static var hasContent = false
    private static var isReady = false

    static func setContent(items: Int, streaming: Int) {
        guard isOn else { return }
        hasContent = items > 0 || streaming > 0
        note("content", ["items": String(items), "streaming": String(streaming)])
        evaluate(force: true)
    }

    static func enter(_ id: String, _ rect: CGRect) {
        guard isOn else { return }
        rows[id] = rect
    }

    static func update(_ id: String, _ rect: CGRect) {
        guard isOn else { return }
        rows[id] = rect
    }

    static func leave(_ id: String) {
        guard isOn else { return }
        rows.removeValue(forKey: id)
    }

    /// 转写区自己的矩形。它和已渲染行的矩形之差就是"没被盖住的带"。
    static func setViewport(_ rect: CGRect) {
        guard isOn else { return }
        viewport = rect
        evaluate(force: false)
    }

    /// 最近一次滚动几何（偏移 / 内容高）。
    ///
    /// 判"补页之后位置有没有跳"就靠它：往视口上方插进 Δ 的内容而**可见内容不变**时，
    /// 偏移必须同时增加 Δ——`|Δoffset - Δcontent| < 4` 就是"读者原地不动"。
    /// 行矩形（`topVisibleRow`）在 `List` 里滚动时不刷新，不能拿来当判据。
    static var scrollFacts: (offset: CGFloat, content: CGFloat)? {
        guard isOn, let facts = lastScroll else { return nil }
        return (facts.offset, facts.content)
    }

    /// 视口里**最上面**那一行的 id，以及它离视口顶还有多远。
    ///
    /// 用来机器判定"补页之后读者看到的第一行有没有变"：补更早的一页时，如果位置没被
    /// 锚回来，`List` 会把视口顶到新插入内容的中段，这一行的 id 立刻换人。
    static func topVisibleRow() -> String? {
        guard isOn, viewport.height > 1 else { return nil }
        let visible = rows.filter { $0.value.maxY > viewport.minY + 1 && $0.value.minY < viewport.maxY - 1 }
        return visible.min { $0.value.minY < $1.value.minY }?.key
    }

    static func markReady() {
        guard isOn else { return }
        isReady = true
    }

    // MARK: - 两条证据

    private static func evaluate(force: Bool) {
        guard viewport.height > 1, isReady else { return }
        let band = viewport
        let inside = rows.values.filter { $0.intersects(band) }
        let covered = inside.reduce(CGFloat.zero) { $0 + $1.intersection(band).height }
        let top = inside.map(\.minY).min() ?? band.maxY
        let uncovered = max(max(0, top - band.minY), band.height - min(covered, band.height))
        let moved = abs(uncovered - lastUncovered) > 8
        let due = Date().timeIntervalSince(lastSample) > 1
        guard force || moved || due else { return }
        lastUncovered = uncovered
        lastSample = Date()
        // 最高的那一行是谁、多高：懒加载在重新估算未渲染行时用的是已渲染行的尺寸，
        // 一行超高的（长回答）能把整份内容高度抬到十几倍——这是根因的指纹。
        let tallest = rows.max { $0.value.height < $1.value.height }
        let renderedSum = rows.values.reduce(CGFloat.zero) { $0 + $1.height }
        note("cover", [
            "rendered": String(rows.count),
            "vp_h": String(format: "%.0f", band.height),
            "uncovered": String(format: "%.0f", uncovered),
            "top_row_y": String(format: "%.0f", top),
            "content": hasContent ? "1" : "0",
            "tallest": String(format: "%.0f", tallest?.value.height ?? 0),
            "tallest_id": String((tallest?.key ?? "-").prefix(18)),
            "rows_sum": String(format: "%.0f", renderedSum),
        ])
        // 空会话（没有内容可显示）不算异常；有内容却没行盖住可见带才是。
        // 还要**连续几拍都在**才算：布局切换的那一两帧里行会先消失再回来。
        if hasContent, uncovered > 24, rows.count > 0 {
            gapTicks += 1
            if gapTicks == 3 { fullSnapshot("gap") }
        } else {
            gapTicks = 0
        }
    }

    /// 每 100ms 一次：结构覆盖 + 每 5 次做一次像素核对。
    private static func tick() {
        guard isOn, isReady, !isPaused else { return }
        // App 不在前台、以及刚回前台的头两秒不采样：那段时间转写区本来就还没画，
        // 采出来的"空白"是假阳性（2026-09-22 用例里"切到后台 3 秒"误报了两段）。
        guard UIApplication.shared.applicationState == .active else {
            suspendedAt = Date()
            return
        }
        if let suspendedAt {
            if Date().timeIntervalSince(suspendedAt) < 2 { return }
            self.suspendedAt = nil
        }
        ticks += 1
        evaluate(force: true)
        if ticks % 5 == 0, !ProbeVariants.noPixelProbe { pixelCheck() }
    }

    /// 转写区的墨迹占比：把这块真的画一遍，数"与背景不同的像素"。
    ///
    /// 判据必须是**对比**而不是"暗"：深色模式会话区本来就是暗的，按暗像素数会把
    /// 整块背景算成内容（第一版就是这样，80% 的"墨迹"其实是底色）。
    private static func pixelCheck() {
        guard let window, viewport.height > 40, viewport.width > 40 else { return }
        let rect = viewport.intersection(window.bounds)
        guard rect.height > 40 else { return }
        // 缩到 1/4 再数，省时间也不影响"有没有内容"的判断。
        let scale: CGFloat = 0.25
        let size = CGSize(width: max(1, rect.width * scale), height: max(1, rect.height * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let small = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.saveGState()
            context.cgContext.scaleBy(x: scale, y: scale)
            context.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            context.cgContext.restoreGState()
        }
        guard let cg = small.cgImage, let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data)
        else { return }
        let bytesPerRow = cg.bytesPerRow
        let bytesPerPixel = cg.bitsPerPixel / 8
        var histogram = [Int](repeating: 0, count: 256)
        var total = 0
        for y in 0..<cg.height {
            for x in 0..<cg.width {
                histogram[Int(bytes[y * bytesPerRow + x * bytesPerPixel])] += 1
                total += 1
            }
        }
        guard total > 0 else { return }
        // 中位数就是"背景色"；离它足够远的像素才算内容。
        var seen = 0
        var background = 0
        for value in 0..<256 {
            seen += histogram[value]
            if seen * 2 >= total { background = value; break }
        }
        var ink = 0
        for value in 0..<256 where abs(value - background) > 40 {
            ink += histogram[value]
        }
        let fraction = Double(ink) / Double(total)
        note("pixel", ["ink": String(format: "%.4f", fraction), "bg": String(background),
                       "h": String(format: "%.0f", rect.height)])
        if hasContent, fraction < 0.004 {
            save(small, name: String(format: "probe-%02d-blank-crop.png", anomalyCount + 1))
            fullSnapshot("blank")
        }
    }

    private static func fullSnapshot(_ tag: String) {
        guard isOn, let window else { return }
        anomalyCount += 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        save(image, name: String(format: "probe-%02d-%@.png", anomalyCount, tag))
    }

    // MARK: - 生命周期

    /// 转写页不在屏幕上时暂停采样：退回列表后"转写区"本来就什么都没有，
    /// 继续采就是纯误报（2026-09-22 用例里"返回列表"那几秒被记成空白）。
    private static var isPaused = false

    static func pause() { isPaused = true }
    static func resume() { isPaused = false }

    static func start() {
        guard isOn, ticker == nil else { return }
        note("probe.begin", ["log": logURL.lastPathComponent], force: true)
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    // MARK: - 提问夹具（"让某个会话进入待答"这件事只能由 App 自己发起）

    /// `-DSHProbeAsk <sessionId>`：连上之后由**这个 App** 给指定会话发一条
    /// "立刻调用提问工具"的提示词，让它进入待答状态。
    ///
    /// 为什么非要从 App 发：2026-09-22 实测，从 host 侧用 RPC（`session/prompt`）发起时，
    /// 会话日志里 `tool/call` 有提问、turn 也没结束，但提问**不会送到手机**，
    /// 列表里就永远看不到待答行。从 App 自己发则走产品那条路（waterfall 回到本设备），
    /// 几秒内就能看到——这也是用户真实遇到的路径。
    static var askProbeSession: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DSHProbeAsk"),
              index + 1 < arguments.count
        else { return nil }
        return arguments[index + 1]
    }

    /// `-DSHProbeOlderScroll <n>`：由 App 自己把转写视口送到顶部 n 次。
    ///
    /// 为什么要这个钩子：XCUITest 对转写页做手势会抛 "Pointer events are not
    /// supported for this device"（进程级异常，整轮直接 ERROR），所以"一直往上滑"
    /// 这件事在仿真器里没法由手指完成。钩子只负责**把视口送上去**；送上去之后的
    /// 一切——哨兵露出来、自动补页、把读者那一行锚回顶部——都还是产品代码。
    static var olderScrollRounds: Int? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DSHProbeOlderScroll"),
              index + 1 < arguments.count
        else { return nil }
        return Int(arguments[index + 1])
    }

    @MainActor
    static func runAskProbe(provider: @MainActor () -> DSHClient?) async {
        guard let sessionId = askProbeSession else { return }
        note("askprobe.begin", ["session": sessionId], force: true)
        // 冷启动时 client 还没有：等它出现（连接建立后 store 才装上）。
        var client: DSHClient?
        for _ in 0..<120 {
            client = provider()
            if client != nil { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard let client else {
            note("askprobe.failed", ["error": "no client after 60s"], force: true)
            return
        }
        do {
            try await client.prompt(SessionPromptRequest(
                requestId: "probe-ask-\(UUID().uuidString)",
                sessionId: sessionId,
                mode: .queue,
                content: [.text("现在立刻调用 ask_user_question 工具问我一个问题（给 2 个选项），"
                                + "不要做任何其它事情也不要解释。")]))
            note("askprobe.sent", ["session": sessionId], force: true)
        } catch {
            note("askprobe.failed", ["error": String(describing: error)], force: true)
        }
    }

    // MARK: - 打字驱动（复现"一边流式一边打字"，不经过 XCUITest）

    /// `-DSHTypingProbe <文字>@<秒数>[@旗标]`：按字符把文字追加进草稿，模拟人连续打字。
    ///
    /// 旗标（`+` 连接）：
    ///   * `oscillate`——敲满一段就退格，输入框高度反复变化；
    ///   * `now`——不等这一轮开始就打字（对照组：只有键盘与打字、没有流式内容）；
    ///   * `kbcycles`——每 6 秒收起再弹出键盘，把"视口高度变化"从 1 次变成 7–8 次。
    ///
    /// 为什么不用 XCUITest 的 `typeText`：流式输出期间 App 一直在更新，XCUITest 查元素
    /// 会因为"等不到静止"而超时，把整轮跑废（2026-09-20 实测 `type_loop` 就这样）。
    /// 这里驱动的是与真实打字同一个状态（`ChatModel.draft`），输入框的高度变化一致。
    static var typingProbe: (text: String, seconds: Double, oscillate: Bool, immediately: Bool,
                             keyboardCycles: Bool)? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DSHTypingProbe"),
              index + 1 < arguments.count
        else { return nil }
        let parts = arguments[index + 1].split(separator: "@")
        guard let text = parts.first, !text.isEmpty else { return nil }
        let seconds = parts.count > 1 ? Double(parts[1]) ?? 30 : 30
        let flags = parts.count > 2 ? Set(parts[2].split(separator: "+").map(String.init)) : []
        return (String(text), seconds, flags.contains("oscillate"), flags.contains("now"),
                flags.contains("kbcycles"))
    }

    static func runTyping(into model: ChatModel, focus: FocusState<Bool>.Binding) async {
        guard let probe = typingProbe else { return }
        // 先等这一轮真的开始：要复现的是"一边流式流入一边打字"，
        // 打字跑在流式之前就等于没测到那条组合。`now` 旗标跳过这一步。
        if !probe.immediately {
            let waitUntil = Date().addingTimeInterval(90)
            while !model.isRunning, Date() < waitUntil {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        note("typing.begin", ["seconds": String(probe.seconds), "chars": String(probe.text.count),
                              "running": model.isRunning ? "1" : "0",
                              "oscillate": probe.oscillate ? "1" : "0"], force: true)
        focus.wrappedValue = true
        try? await Task.sleep(for: .milliseconds(500))
        let characters = Array(probe.text)
        let deadline = Date().addingTimeInterval(probe.seconds)
        var index = 0
        var typed = 0
        var sinceSwing = 0
        var cycleTimer = Date()
        while Date() < deadline {
            if probe.keyboardCycles, Date().timeIntervalSince(cycleTimer) > 6 {
                cycleTimer = Date()
                focus.wrappedValue = false
                try? await Task.sleep(for: .milliseconds(900))
                focus.wrappedValue = true
                try? await Task.sleep(for: .milliseconds(300))
            }
            model.draft.append(characters[index % characters.count])
            index += 1
            typed += 1
            sinceSwing += 1
            if probe.oscillate, sinceSwing >= 45 {
                sinceSwing = 0
                for _ in 0..<38 where !model.draft.isEmpty {
                    model.draft.removeLast()
                    try? await Task.sleep(for: .milliseconds(25))
                }
            }
            if typed % 20 == 0 {
                note("typing", ["chars": String(typed), "draft": String(model.draft.count),
                                "running": model.isRunning ? "1" : "0"])
            }
            try? await Task.sleep(for: .milliseconds(90))
        }
        note("typing.end", ["chars": String(typed), "draft": String(model.draft.count)], force: true)
    }
}

// MARK: - 诊断开关

/// 诊断用的开关（DEBUG-only，`-DSHProbeVariants a,b`）。
///
/// 只留两件在这一轮里真正用到的事：
///   * `lazy-stack`——把转写换回 `LazyVStack`，用来复现"跳白"（产品默认已是普通 `VStack`）；
///   * `no-rows` / `no-pixel`——关掉探针自己的两处开销，用来证明观测没有改变被测行为。
///
/// 这一轮试过、被数据否掉的候选（滚到真实行、视口变化后暂停跟随、只让尾部非懒加载、
/// 去掉 `scrollTargetLayout`、去掉底部锚定）都删了，结论写在用例
/// `test/cases/current/32-长会话里边流式边打字不跳白.md`。
enum ProbeVariants {
    static let all: Set<String> = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DSHProbeVariants"),
              index + 1 < arguments.count
        else { return [] }
        return Set(arguments[index + 1].split(separator: ",").map(String.init))
    }()

    /// 复现用：模拟"host 把 `beforeSeq` 当日志偏移用"——每页少给最新的 N 条记录。
    ///
    /// 2026-09-24 实测真 host 已经按 seq 收边界（四个真实会话整段历史翻下来一条不漏），
    /// 所以正常的仿真器用例碰不到 `TranscriptPageBoundary` 那条校正重试。
    /// `-DSHProbePageShortfall <n>` 注入这个"少给一段"的故障，让校正路径能被端到端验证：
    /// 少了就必须重问，重问之后时间线里不许留洞。
    static var pageShortfall: Int {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DSHProbePageShortfall"),
              index + 1 < arguments.count
        else { return 0 }
        return Int(arguments[index + 1]) ?? 0
    }

    /// 复现用：把转写换回 `ScrollView + LazyVStack`（产品默认已经是 `List`）。
    static var lazyStack: Bool { all.contains("lazy-stack") }
    static var noRowProbe: Bool { all.contains("no-rows") }
    static var noPixelProbe: Bool { all.contains("no-pixel") }
}

// MARK: - 把一块视图的屏幕坐标报给探针

/// 把一行的屏幕矩形报给探针；`no-rows` 变体下不挂，用来控制"这些 background
/// 会不会自己改变布局"。
struct ProbedRow: ViewModifier {
    let id: String

    func body(content: Content) -> some View {
        if ProbeVariants.noRowProbe {
            content
        } else {
            content.background(ViewportProbeReporter(id: id))
        }
    }
}

/// 挂在每一行（以及尾部气泡、输入框）上，把它的屏幕矩形报给探针。
struct ViewportProbeReporter: View {
    let id: String

    var body: some View {
        GeometryReader { proxy in
            let rect = proxy.frame(in: .global)
            Color.clear
                .onAppear { ViewportProbe.enter(id, rect) }
                .onChange(of: rect) { _, next in ViewportProbe.update(id, next) }
                .onDisappear { ViewportProbe.leave(id) }
        }
    }
}

extension View {
    /// 让这一行出现在探针的覆盖核对里。
    func probed(_ id: String) -> some View {
        modifier(ProbedRow(id: id))
    }
}

/// 滚动几何的记录：偏移、内容高、容器高。
///
/// 只在 iOS 18 以上可用（`onScrollGeometryChange`），系统更低时什么都不做——
/// 探针是诊断工具，不值得为它提高部署目标。
struct ScrollGeometryProbe: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: ScrollFacts.self) { geometry in
                ScrollFacts(offset: geometry.contentOffset.y,
                            content: geometry.contentSize.height,
                            container: geometry.containerSize.height)
            } action: { _, facts in
                ViewportProbe.lastScroll = (facts.offset, facts.content)
                ViewportProbe.note("scroll", [
                    "offset": String(format: "%.0f", facts.offset),
                    "content": String(format: "%.0f", facts.content),
                    "container": String(format: "%.0f", facts.container),
                    "beyond": String(format: "%.0f", facts.offset + facts.container - facts.content),
                ])
            }
        } else {
            content
        }
    }

    /// 只带三个数，避免为了记录把整个 `ScrollGeometry` 拖进依赖里。
    struct ScrollFacts: Equatable {
        var offset: CGFloat
        var content: CGFloat
        var container: CGFloat
    }
}

#else
import DSHKit
import SwiftUI

/// Release 构建里这些钩子都不存在，产品行为与探针无关。
enum ViewportProbe {
    static let isOn = false
    static var typingProbe: (text: String, seconds: Double, oscillate: Bool, immediately: Bool,
                             keyboardCycles: Bool)? { nil }
    static var askProbeSession: String? { nil }
    static var olderScrollRounds: Int? { nil }
    static var scrollFacts: (offset: CGFloat, content: CGFloat)? { nil }
    static func topVisibleRow() -> String? { nil }
    static func pause() {}
    static func resume() {}
    static func runAskProbe(provider: @MainActor () -> DSHClient?) async {}
    static func note(_ kind: String, _ fields: [String: String] = [:], force: Bool = false) {}
    static func setViewport(_ rect: CGRect) {}
    static func setContent(items: Int, streaming: Int) {}
    static func markReady() {}
    static func start() {}
    static func runTyping(into model: ChatModel, focus: FocusState<Bool>.Binding) async {}
}

enum ProbeVariants {
    static var pageShortfall: Int { 0 }
    static var lazyStack: Bool { false }
    static var noRowProbe: Bool { false }
    static var noPixelProbe: Bool { false }
}

struct ScrollGeometryProbe: ViewModifier {
    func body(content: Content) -> some View { content }
}

extension View {
    func probed(_ id: String) -> some View { self }
}
#endif

/// 转写行在 `List` 模式下需要的装饰。
///
/// `List` 默认给每行内边距、分隔线和系统底色；聊天转写要的是"行就是自己画的那块"，
/// 所以全部去掉，行距与左右留白改由行自己给（与 `LazyVStack` 那两个 padding 对齐）。
struct TranscriptRowChrome: ViewModifier {
    let inList: Bool

    func body(content: Content) -> some View {
        if inList {
            content
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .padding(.horizontal, DSHTheme.Spacing.loose)
                .padding(.bottom, DSHTheme.Spacing.standard)
        } else {
            content
        }
    }
}
