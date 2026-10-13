import Foundation

/// `LinkCarrier` 的诊断半边：把连接过程的关键时刻写成 `app.*` 事件。
///
/// 存在的理由（spec 020 的 D1）：手机侧"拨号卡在握手之前"与"连上了又掉"在中转与连接器两侧
/// **看到的完全一样**（都没有事件）——2026-10-13 00:59–01:05 那个 5 分 50 秒的空窗就是这么卡住的。
/// 要区分二者，只有系统层的 WebSocket 建立/关闭回调能给答案：
///   * `app.dial{phase:start}`          拨号开始（进 `openSocket` 之前）
///   * `app.dial{phase:transport-up}`   `URLSessionWebSocketDelegate` 的 `didOpenWithProtocol`
///   * `app.dial{phase:transport-closed}` 的 `didCloseWith:reason:`（带 close code）
///   * `app.scene{phase:background|foreground}` 前后台切换
///
/// 契约：`specs/020-link-diagnostics/contracts/diagnostics-events.md` §3
extension LinkCarrier {
    /// 记录一次拨号开始。`attempt` 是本次重连的序号（0 起）。
    public func diagnosticsDialStarted(attempt: Int) async {
        await diagnostics.record(kind: "app.dial", detail: ["phase": .string("start"), "attempt": .int(attempt)])
    }
}
