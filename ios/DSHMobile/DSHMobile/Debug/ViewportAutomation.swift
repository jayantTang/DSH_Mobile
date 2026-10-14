import DSHKit
import Foundation
import SwiftUI
import UIKit

#if DEBUG
/// 探针的**自动化驱动**（spec 024：从 `Support/ViewportProbe.swift` 拆出来）。
///
/// 这些入口（`runTyping` / `runAskProbe` / 两个通知探针）只在"带启动参数 + 仿真器跑测试"时生效，
/// 属于调试工具，不该与基础设施同层。落盘口（`ViewportProbe.note` 与周期采样）留在 `Support/`，
/// 因为生产代码到处在调它。生产调用点仍走 `ViewportProbe` 上的四个转发器，所以
/// `Support → Debug` 只有一条边，且落在 `#if DEBUG` 内。
/// 落盘口的形状：由基础设施（`Support/ViewportProbe.swift`）注入，工具不认识它。
///
/// 用 `callAsFunction` 包一层是为了保住调用点的可读性：`log("kind", [...], force: true)`
/// 与原来直接调 `note` 一模一样，字段与 `force` 都还能省略。
struct ProbeLog {
    var sink: @MainActor (String, [String: String], Bool) -> Void

    @MainActor
    func callAsFunction(_ kind: String, _ fields: [String: String] = [:], force: Bool = false) {
        sink(kind, fields, force)
    }
}

@MainActor
enum ViewportAutomation {

    /// `-DSHProbeAsk <sessionId>[@<延迟秒>]`：连上之后由**这个 App** 给指定会话发一条
    /// "立刻调用提问工具"的提示词，让它进入待答状态。
    ///
    /// 可选的 `@<秒>`：提问在连接建立后第 N 秒才发出。新消息胶囊场景（TC-009-US3）
    /// 需要"上滑进入 reading 之后才有新行到达"：提问若随连接立即发出，回复脉冲会
    /// 抢在上滑驱动（~6–11s）之前落完，胶囊永远没有前提。
    ///
    /// 为什么非要从 App 发：2026-09-22 实测，从 host 侧用 RPC（`session/prompt`）发起时，
    /// 会话日志里 `tool/call` 有提问、turn 也没结束，但提问**不会送到手机**，
    /// 列表里就永远看不到待答行。从 App 自己发则走产品那条路（waterfall 回到本设备），
    /// 几秒内就能看到——这也是用户真实遇到的路径。
    static var askProbeSession: String? { askProbe?.sessionId }

    static var askProbe: (sessionId: String, delay: Double)? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DSHProbeAsk"),
              index + 1 < arguments.count
        else { return nil }
        let parts = arguments[index + 1].split(separator: "@")
        guard let sessionId = parts.first, !sessionId.isEmpty else { return nil }
        let delay = parts.count > 1 ? Double(parts[1]) ?? 0 : 0
        return (String(sessionId), delay)
    }


    /// `-DSHProbeNotifyTap <sid>@<秒>[+<秒>…]`：模拟「App 在后台时用户点了通知」。
    ///
    /// 为什么必须用钩子而不是 XCUITest：真机那条路是 iOS 把 App 拉回前台并回调
    /// `userNotificationCenter(_:didReceive:)`。仿真器里点不到真实横幅（通知权限
    /// 装不上：`simctl privacy grant notifications` 返回 `Operation not permitted`），
    /// 但**回调本身**可以构造——`UNNotificationResponse` 是可实例化的，把一个
    /// `UNNotification` 塞进 `request.content.userInfo` 就得到与真机逐字段相同的对象。
    ///
    /// 时序是这条路的关键，也是它与 `-DSHNotifySession`（冷启动）唯一的不同：
    /// 先等 <秒>（此刻 App 在前台、已连上、列表已在），再由 App 自己按 home 键退到后台，
    /// 再等 2 秒（等 iOS 真的挂起/停掉 socket），然后触发 didReceive。
    ///
    /// `@<秒>+<秒>` 可以给多个时刻（分隔符用 `+`：用例台的 `args=` 是按逗号切参数的）（015 的 FR-006 要"已经在该会话里，再点它的同一条
    /// 通知"）：每个时刻各点一次，点与点之间仍是"退后台 → 挂起窗口 → 收回前台"那一套。
    static var notifyTapProbe: (sid: String, seconds: [Double])? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DSHProbeNotifyTap"),
              index + 1 < arguments.count
        else { return nil }
        let parts = arguments[index + 1].split(separator: "@")
        guard let sid = parts.first, !sid.isEmpty else { return nil }
        let times = parts.count > 1
            ? parts[1].split(whereSeparator: { $0 == "," || $0 == "+" })
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            : []
        return (String(sid), times.isEmpty ? [6] : times.sorted())
    }


    /// 跑上面那个钩子：前台等 → 退后台 → 挂起窗口 → 触发点按回调；多个时刻就重复一遍。
    static func runNotifyTapProbe(
        background: @MainActor () -> Void,
        deliverTap: @MainActor (String) async -> Void,
        log: ProbeLog
    ) async {
        guard let probe = notifyTapProbe else { return }
        log("notifytap.wait", [
            "sid": probe.sid,
            "seconds": probe.seconds.map { String($0) }.joined(separator: ","),
        ], force: true)
        var clock: Double = 0
        for target in probe.seconds {
            if target > clock { try? await Task.sleep(for: .seconds(target - clock)) }
            clock = target
            guard UIApplication.shared.applicationState == .active else {
                log("notifytap.abort", ["why": "not active before backgrounding", "at": String(target)],
                     force: true)
                return
            }
            // 退到后台 = 真机上"用户把手机放下"的那一刻。
            UIApplication.shared.perform(#selector(UIApplication.resignFirstResponder))
            log("notifytap.backgrounding", ["sid": probe.sid, "at": String(target)], force: true)
            // 这里刻意**不**调 suspend：保持进程活着，正是 owner 说的
            // 「App 在后台（未被划掉）」那种状态。
            background()
            try? await Task.sleep(for: .seconds(2))
            clock = target + 2
            await deliverTap(probe.sid)
            // `deliverTap` 末尾会把模拟态收回前台，并再等 0.3 秒。
            clock += 0.3
        }
    }


    /// 主界面出现后触发 ②。目标会话必须**还没进列表**，否则窗口不成立——
    /// 那时如实记一条 `notifyctap.abort` 并放弃，让这一轮呈现为"没复现"而不是
    /// "莫名其妙绿了"。
    static func runNotifyColdTapProbe(
        onTap: @MainActor (String) async -> Void,
        isListed: @MainActor (String) -> Bool,
        sid: String?,
        log: ProbeLog
    ) async {
        guard let sid else { return }
        // 让主界面这一帧先落地：请求的消费者（`.task(id: routingToken)`）由这次
        // 出现启动，②要写在它已经跑起来之后。
        try? await Task.sleep(for: .milliseconds(300))
        guard !isListed(sid) else {
            log("notifyctap.abort", ["sid": sid, "why": "session already listed"], force: true)
            return
        }
        log("notifyctap.fire", ["sid": sid, "listed": "0"], force: true)
        await onTap(sid)
    }


    @MainActor
    static func runAskProbe(
        isReady: @MainActor () -> Bool,
        prompt: @escaping @MainActor (SessionPromptRequest) async throws -> Void,
        log: ProbeLog
    ) async {
        guard let probe = askProbe else { return }
        let sessionId = probe.sessionId
        log("askprobe.begin", ["session": sessionId, "delay": String(probe.delay)], force: true)
        // 冷启动时还连不上：等它就绪（连接建立后 store 才装上）。
        var ready = isReady()
        for _ in 0..<120 {
            if ready { break }
            try? await Task.sleep(for: .milliseconds(500))
            ready = isReady()
        }
        guard ready else {
            log("askprobe.failed", ["error": "no client after 60s"], force: true)
            return
        }
        // 可选延迟：让回复脉冲落在"上滑驱动完成之后"（见 askProbe 头注）。
        if probe.delay > 0 {
            try? await Task.sleep(for: .seconds(probe.delay))
        }
        do {
            try await prompt(SessionPromptRequest(
                requestId: "probe-ask-\(UUID().uuidString)",
                sessionId: sessionId,
                mode: .queue,
                content: [.text("现在立刻调用 ask_user_question 工具问我一个问题（给 2 个选项），"
                                + "不要做任何其它事情也不要解释。")]))
            log("askprobe.sent", ["session": sessionId], force: true)
        } catch {
            log("askprobe.failed", ["error": String(describing: error)], force: true)
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

    /// 驱动一段"边流式流入边打字"的自动化（spec 024：收端口，不收业务类型）。
    ///
    /// 唯一调用点是会话页；它把输入框的三个动作作为闭包传进来，所以基础设施与调试工具
    /// 都不认识 `ChatModel`，工具也不需要认识基础设施的类型。
    static func runTyping(
        isRunning: @MainActor () -> Bool,
        draft: @MainActor () -> String,
        setDraft: @MainActor (String) -> Void,
        focus: FocusState<Bool>.Binding,
        log: ProbeLog
    ) async {
        guard let probe = typingProbe else { return }
        // 先等这一轮真的开始：要复现的是"一边流式流入一边打字"，
        // 打字跑在流式之前就等于没测到那条组合。`now` 旗标跳过这一步。
        if !probe.immediately {
            let waitUntil = Date().addingTimeInterval(90)
            while !isRunning(), Date() < waitUntil {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        log("typing.begin", ["seconds": String(probe.seconds), "chars": String(probe.text.count),
                              "running": isRunning() ? "1" : "0",
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
            setDraft(draft() + String(characters[index % characters.count]))
            index += 1
            typed += 1
            sinceSwing += 1
            if probe.oscillate, sinceSwing >= 45 {
                sinceSwing = 0
                for _ in 0..<38 {
                    var current = draft()
                    guard !current.isEmpty else { break }
                    current.removeLast()
                    setDraft(current)
                    try? await Task.sleep(for: .milliseconds(25))
                }
            }
            if typed % 20 == 0 {
                log("typing", ["chars": String(typed), "draft": String(draft().count),
                                "running": isRunning() ? "1" : "0"])
            }
            try? await Task.sleep(for: .milliseconds(90))
        }
        log("typing.end", ["chars": String(typed), "draft": String(draft().count)], force: true)
    }
}
#endif
