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

    /// 跳转诊断：当前**落在视口里**的行 id（按 y 从下到上）。
    ///
    /// 只靠 `topVisibleRow()` 判不出"目标行是渲染了但在视口外，还是根本没渲染"
    /// （2026-10-08 T068 三次加长梯子都没修好，就是因为判不出来）。
    static func visibleRowIds() -> [String] {
        guard viewport.height > 1 else { return [] }
        return rows.filter { $0.value.intersects(viewport) }
            .sorted { $0.value.minY < $1.value.minY }
            .map(\.key)
    }

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

    /// `-DSHProbeNotifyColdTap <sid>`：复现真机**冷启动点通知**的形态（015）。
    ///
    /// 真机冷启动点通知会在两个时刻各写一次同一个意图：
    ///   ① `application(_:didFinishLaunchingWithOptions:)` 的 `launchOptions[.remoteNotification]`
    ///      （`APNSRegistrar`）；
    ///   ② 随后的 `userNotificationCenter(_:didReceive:)`（`SessionAlerts.handleTap`）。
    ///
    /// 现有两个钩子各自只覆盖一半：`-DSHNotifySession` 只有 ①（单消费者），
    /// `-DSHProbeNotifyTap` 有 ②但触发时列表已就绪。缺陷要的是"两处都写到了 +
    /// 被点会话还没进列表"：015 之前那两处写的是**两个不同的位**，视图因此有两个
    /// 消费者，各自停在"等列表到达"里，最后各入栈一次。所以这里：
    /// sid 由启动期那条来源先写（见 `DSHMobileApp.init`），主界面出现后（此刻还没
    /// 拿到 host 的列表）再由下面的方法走 ②。
    ///
    /// 钩子只负责"把这一下点出来"；从 `handleTap` 往下全是产品代码。
    static var notifyColdTapSid: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DSHProbeNotifyColdTap"),
              index + 1 < arguments.count
        else { return nil }
        let value = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
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

    /// `-DSHProbeOlderNoReclaim`：驱动的"滑回被回收行"绕行关掉。
    ///
    /// 那个绕行是给翻页水合用例（用例 57）造的；新消息胶囊（TC-009-US3）只需要
    /// "离开底部并停住"，绕行会把视口带到回收行（往往又贴回底部），reading 前提
    /// 就没了（2026-10-11 复跑实测：distance=6676 → 绕行 → distance=0）。
    static var olderDriveSkipsReclaimed: Bool {
        ProcessInfo.processInfo.arguments.contains("-DSHProbeOlderNoReclaim")
    }

    // MARK: - 自动化入口（转发到调试工具；发布构建里是空实现，见文件末尾的 #else）

    /// 实现搬到了 `Debug/ViewportAutomation.swift`。留在这里的理由有两条：
    /// ① 生产调用点（会话页、主界面、通知回调）只认识基础设施，不必认识调试工具目录；
    /// ② 转发只在 `#if DEBUG` 内——发布构建不存在这条依赖（`npm run arch` 会看到一条
    ///    `Support → Debug` 边，逐行核对过它落在这个条件编译块里）。

    static func runNotifyTapProbe(delegate: SessionAlerts) async {
        await ViewportAutomation.runNotifyTapProbe(
            background: { NotificationProbe.background() },
            deliverTap: { sid in await NotificationProbe.deliverTap(sid: sid, to: delegate) },
            log: ProbeLog(sink: ViewportProbe.note))
    }

    static func runNotifyColdTapProbe(
        delegate: SessionAlerts,
        isListed: @MainActor (String) -> Bool
    ) async {
        await ViewportAutomation.runNotifyColdTapProbe(
            onTap: { sid in await delegate.handleTap(sessionId: sid) },
            isListed: isListed,
            sid: notifyColdTapSid,
            log: ProbeLog(sink: ViewportProbe.note))
    }

    static func runAskProbe(provider: @escaping @MainActor () -> DSHClient?) async {
        // 端口在调用点构造：工具收到的是"能不能发"与"怎么发"，不是连接对象本身。
        await ViewportAutomation.runAskProbe(
            isReady: { provider() != nil },
            prompt: { request in try await provider()?.prompt(request) },
            log: ProbeLog(sink: ViewportProbe.note))
    }

    static func runTyping(into target: TypingTarget, focus: FocusState<Bool>.Binding) async {
        await ViewportAutomation.runTyping(
            isRunning: { target.isRunning() },
            draft: { target.draft() },
            setDraft: { target.setDraft($0) },
            focus: focus,
            log: ProbeLog(sink: ViewportProbe.note))
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

    /// 复现用：假装连接器没有精确窗口能力，逼 App 走旧的 `session/page` 通道
    /// （配合 `pageShortfall` 复现"少给一段要重问"，也就是用例 43）。
    static var noHistoryWindow: Bool {
        ProcessInfo.processInfo.arguments.contains("-DSHProbeNoHistoryWindow")
    }

    /// 故障注入：让前 N 次取页失败，验证"失败不等于到底、重试能恢复"（用例 48）。
    static var failPageAttempts: Int {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DSHProbeFailPage"),
              index + 1 < arguments.count
        else { return 0 }
        return Int(arguments[index + 1]) ?? 0
    }

    /// 故障注入：让前 N 次**往更早方向**的取页回空包（records 空 + hasMore=true），
    /// 设备层验「空页即异常 → 可重试失败 → 点重试仍能拉」（用例 80，T038/T041）。
    ///
    /// 方向判据在 `EmptyPageInjector` 里，与管道判失败用的是同一份
    ///（`SessionPipeline.isNewerDirectionProbe`）：往更新方向探空是正常形态
    ///（adeb3aa 的语义），注入打上去只会把正常路径记成失败。
    static var emptyPageAttempts: Int {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DSHProbeEmptyPage"),
              index + 1 < arguments.count
        else { return 0 }
        return Int(arguments[index + 1]) ?? 0
    }

    /// `-DSHProbeFailPageOnDrive`：故障注入只在翻页驱动开始之后生效（用例 48）。
    ///
    /// 打开会话时的可见取页按竞争拿到 `.userVisible` / `.prefetch` 不一，会提前吃掉
    /// 注入配额——用例 48 四次复跑里打开阶段消耗 0–2 次不等，配额在点重试那一刻
    /// 可能还没用光，恢复结果因此不确定。驱动开始后才武装，注入次数就是确定的：
    /// 驱动送顶 1 次 + 一次性自动补试 1 次。
    static var failPageOnDrive: Bool {
        ProcessInfo.processInfo.arguments.contains("-DSHProbeFailPageOnDrive")
    }
    nonisolated(unsafe) private static var _driveBegan = false
    /// 驱动开始（`-DSHProbeOlderScroll` 第一轮）时由 TranscriptListHost 报到。
    static func noteDriveBegan() { _driveBegan = true }
    /// 注入器此刻是否该生效：没带 OnDrive 旗标时维持旧语义（恒生效）。
    static var failPageArmed: Bool { !failPageOnDrive || _driveBegan }

    /// 复现用：失败后那次自动补试的等待时长（毫秒）。默认 3 秒——对人是"自己就好了"，
    /// 但要让用例稳定看到重试条，就得把这段窗口拉长（`-DSHProbeAutoRetryMs 20000`）。
    static var autoRetryMs: Int {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DSHProbeAutoRetryMs"),
              index + 1 < arguments.count,
              let value = Int(arguments[index + 1]), value > 0
        else { return 3000 }
        return value
    }

    /// 转写列表宿主走哪条实现（spec 008）。
    /// **缺省已是 `uikit`（新宿主）**：008 的全部验收都在它上面取得（见 VERIFY-008）；
    /// `-DSHProbeListHost swiftui` 是**回退开关**（旧 `List` 宿主保留一个版本周期，见 plan 的退场计划）。
    static var listHost: String {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DSHProbeListHost"),
              index + 1 < arguments.count
        else { return "uikit" }
        return arguments[index + 1]
    }

    /// 复现用：把"离视口几屏才回收 / 回到几屏内水合"改掉（spec 008 的 FR-009）。
    /// 默认 5 屏回收、2 屏水合，写进 `specs/008-transcript-list-host/contracts/list-host.md` §4。
    static func screensArg(_ name: String) -> Int? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count,
              let value = Int(arguments[index + 1]), value > 0 else { return nil }
        return value
    }

    static var reclaimScreens: Int { screensArg("-DSHProbeReclaimScreens") ?? 5 }
    // 水合带 2 → 4 屏（owner 2026-10-11 定调：回收/水合不得出现任何过渡性视觉变化，
    // 0.2s 闪白也算缺陷）。量化：回收/水合判定是滚动里 400ms 防抖触发的，仿真器甩动
    // 峰值 ~4000–6000pt/s 时一个防抖窗能走 1600–2400pt（≈2.4–3.6 屏，vp_h≈671），
    // 2 屏（1342pt）兜不住；4 屏（2684pt）可覆盖 ≤6700pt/s 的甩动。仍严格小于
    // 回收保护带 5 屏，乒乓在构造上不可能（ViewportBandPlanner 的口径不变）。
    static var rehydrateScreens: Int { screensArg("-DSHProbeRehydrateScreens") ?? 4 }

    /// 复现用：强制走一次"回收 → 再水合"的真实代码路径（spec 008 的 US3 / SC-004）。
    /// 仿真器里**造不出**"滑回被回收的那一段"（未渲染的行 `scrollTo` 落不下去），
    /// 所以用这个开关直接调用同一条链：`onNeedRehydrate → ChatModel.items(forSeqs:) → host.rehydrate`。
    static var forceRehydrate: Bool {
        ProcessInfo.processInfo.arguments.contains("-DSHProbeForceRehydrate")
    }

    /// 复现用：把行载荷预算压小（KB），这样"按预算丢弃"在用例里能真的发生
    /// （spec 008 的 US1/T013；默认 32MB，真实会话远达不到）。
    static var payloadBudgetKB: Int? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DSHProbePayloadBudgetKB"),
              index + 1 < arguments.count, let value = Int(arguments[index + 1]), value > 0
        else { return nil }
        return value
    }

    /// spike 用：转写页换成"列表宿主 spike 屏"（spec 008 的 Phase 0 A/B）。
    /// 它不读会话，自己造 200 行、每 1.5 秒往上插 50 行并**故意并发**一次定位，
    /// 用来量"插入时的锚点位移"与"插入与滚动并发会不会崩"。
    static var listSpike: Bool {
        ProcessInfo.processInfo.arguments.contains("-DSHProbeListSpike")
    }

    /// 复现用：把 `session-search` 从能力表里摘掉——等价于"连接器版本低于基线、
    /// 不会搜整个会话"，用来验硬门槛提示与本地降级（用例 51）。
    static var noSessionSearch: Bool {
        ProcessInfo.processInfo.arguments.contains("-DSHProbeNoSessionSearch")
    }

    /// 复现用：启动时清空本地转写库。故障注入类用例必须在**干净库**上跑，
    /// 否则"本地读回"会抢在注入的失败/少给一段之前把页补上，用例前提就不成立。
    static var clearTranscriptStore: Bool {
        ProcessInfo.processInfo.arguments.contains("-DSHProbeClearTranscriptStore")
    }

    /// 复现用：把内存窗口行数上限压小（如 `-DSHProbeWindowRows 200`），
    /// 这样"窗口滑出去 → 往回滑读回本地、不联网"在仿真器里可观测（用例 47）。
    static var windowRows: Int? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DSHProbeWindowRows"),
              index + 1 < arguments.count
        else { return nil }
        return Int(arguments[index + 1])
    }

    /// 复现用：把转写换回 `ScrollView + LazyVStack`（产品默认已经是 `List`）。
    static var lazyStack: Bool { all.contains("lazy-stack") }
    static var noRowProbe: Bool { all.contains("no-rows") }
    static var noPixelProbe: Bool { all.contains("no-pixel") }
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
    static var askProbe: (sessionId: String, delay: Double)? { nil }
    static var olderScrollRounds: Int? { nil }
    static var olderDriveSkipsReclaimed: Bool { false }
    static var notifyTapProbe: (sid: String, seconds: [Double])? { nil }
    static func runNotifyTapProbe(delegate: SessionAlerts) async {}
    static var notifyColdTapSid: String? { nil }
    static func runNotifyColdTapProbe(
        delegate: SessionAlerts, isListed: @MainActor (String) -> Bool
    ) async {}
    static var scrollFacts: (offset: CGFloat, content: CGFloat)? { nil }
    static func topVisibleRow() -> String? { nil }
    static func visibleRowIds() -> [String] { [] }
    static func pause() {}
    static func resume() {}
    static func runAskProbe(provider: @escaping @MainActor () -> DSHClient?) async {}
    static func note(_ kind: String, _ fields: [String: String] = [:], force: Bool = false) {}
    static func setViewport(_ rect: CGRect) {}
    static func setContent(items: Int, streaming: Int) {}
    static func markReady() {}
    static func start() {}
    static func runTyping(into target: TypingTarget, focus: FocusState<Bool>.Binding) async {}
}

enum ProbeVariants {
    static var pageShortfall: Int { 0 }
    static var noHistoryWindow: Bool { false }
    static var windowRows: Int? { nil }
    static var autoRetryMs: Int { 3000 }
    static var clearTranscriptStore: Bool { false }
    static var noSessionSearch: Bool { false }
    static var listHost: String { "uikit" }
    static var listSpike: Bool { false }
    static var payloadBudgetKB: Int? { nil }
    static var forceRehydrate: Bool { false }
    static var reclaimScreens: Int { 5 }
    static var rehydrateScreens: Int { 4 }
    static var failPageAttempts: Int { 0 }
    static var emptyPageAttempts: Int { 0 }
    static var failPageOnDrive: Bool { false }
    static func noteDriveBegan() {}
    static var failPageArmed: Bool { false }
    static var lazyStack: Bool { false }
    static var noRowProbe: Bool { false }
    static var noPixelProbe: Bool { false }
}

#endif
