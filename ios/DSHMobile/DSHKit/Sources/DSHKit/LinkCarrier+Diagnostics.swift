import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `LinkCarrier` 的诊断半边：把连接过程的关键时刻写成 `app.*` 事件。
///
/// 存在的理由（spec 020 的 D1）：手机侧"拨号卡在握手之前"与"连上了又掉"在中转与连接器两侧
/// **看到的完全一样**（都没有事件）——2026-10-13 00:59–01:05 那个 5 分 50 秒的空窗就是这么卡住的。
/// 要区分二者，只有系统层的 WebSocket 建立/关闭回调能给答案。
///
/// 契约：`specs/020-link-diagnostics/contracts/diagnostics-events.md` §3
extension LinkCarrier {
    /// 这条 carrier 的 session 上有没有挂观察者（单测用：漏挂就等于拿不到"传输建立"）。
    var socketObserverInstalled: Bool {
        session.delegate is LinkSocketObserver
    }

    /// 记录一次拨号开始（在 `resume()` 之前调用）。同时把拨号起点交给流水——
    /// 之后所有 `app.*.elapsedMs` 都相对它算，所以**不能**等握手完再补。
    func diagnosticsDialStarted() async {
        await diagnostics.markDialStart()
        await diagnostics.record(kind: "app.dial", detail: ["phase": .string("start")])
    }

    /// 一次数据交互收尾（由 `performUnary` 调用）：每次都记 `app.request`，
    /// 首个交互另外补 `app.first-request` / `app.first-response`。
    func diagnosticsNoteInteraction(method: String, elapsedMs: Int, bytes: Int) async {
        await diagnostics.endInteraction(method: method, elapsedMs: elapsedMs, bytes: bytes)
    }

    /// 记一条阶段事件。`since` 给了就附上"距它多少毫秒"。
    ///
    /// 字段叫 `elapsedMs` **不叫 `ms`**：`ms` 是信封上的时刻，同名会把时刻冲掉
    /// （2026-10-13 真机运行踩到过：时间线上那条会跑到 1970 年）。见 journal.js 的 PROTECTED_KEYS。
    ///
    /// `public`：App 目标要靠它写 `app.hello` / `app.first-screen` / `app.scene` —— 这几个
    /// 时刻只有 App 的状态机知道（DSHKit 看不到"首屏就绪"）。
    public func diagnosticsNote(_ kind: String, since: Date? = nil, detail: [String: JSONValue] = [:]) async {
        var payload = detail
        if let since {
            payload["elapsedMs"] = .int(Int(Date().timeIntervalSince(since) * 1000))
        }
        await diagnostics.record(kind: kind, detail: payload)
    }
}

/// 系统层的 WebSocket 回调 → `app.dial` 的 `transport-up` / `transport-closed`。
///
/// 为什么必须由系统回调给：`URLSessionWebSocketTask.resume()` 立刻返回，握手成功与否
/// 在这之前没有任何可观察点；而"握手没成功"正是要诊断的那一类。
///
/// 回调在 URLSession 自己的队列上，只做一件事：把事件交给 `LinkDiagnostics`（actor）。
/// 它不碰 `LinkCarrier` 的状态，所以不会与 carrier 的 actor 隔离打架。
final class LinkSocketObserver: NSObject, URLSessionWebSocketDelegate {
    private let diagnostics: LinkDiagnostics

    init(diagnostics: LinkDiagnostics) {
        self.diagnostics = diagnostics
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        let diagnostics = diagnostics
        Task {
            await diagnostics.record(kind: "app.dial", detail: [
                "phase": .string("transport-up"),
                "protocol": .string(`protocol` ?? ""),
            ])
        }
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        let diagnostics = diagnostics
        let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        Task {
            await diagnostics.record(kind: "app.dial", detail: [
                "phase": .string("transport-closed"),
                "code": .int(closeCode.rawValue),
                "reason": .string(String(text.prefix(200))),
            ])
        }
    }
}
