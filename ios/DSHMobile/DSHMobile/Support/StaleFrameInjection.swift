#if DEBUG
import DSHKit
import Foundation

/// 032 用例钩子：造一帧"上一个会话迟到的帧"。
///
/// 只在 `-DSHProbeStaleFollowFrame` 时被装配（见 `RootView`），并且**走 ChatModel 里那条
/// 真实守卫**——所以它既能证明"跨会话的帧不落地"，也能在守卫被删掉时立刻判红。
///
/// 正文用 ASCII 标记，方便 UI 用例断言"屏幕上不该出现它"（中文还要过本地化检查）。
enum StaleFrameInjection {

    static let marker = "STALE-FRAME-INJECTION"

    /// 一帧看起来完全正常的用户消息，唯一特别的是它属于**别的会话**。
    static func make() -> SessionFollowFrame? {
        let json: JSONValue = .object([
            "type": .string("user/message"),
            // seq 取一个很大的值：真实场景里旧会话的 seq 往往比当前会话大，
            // 这才是"脏行永远排在最后、新内容出现在它前面"的原因。
            "seq": .int(9_999_999),
            "time": .double(Date().timeIntervalSince1970 * 1000),
            "data": .object([
                "id": .string("stale-frame-injection"),
                "source": .object(["kind": .string("user")]),
                "content": .array([
                    .object(["type": .string("text"), "text": .string(marker)]),
                ]),
            ]),
        ])
        guard let data = try? JSONEncoder().encode(json),
              let event = try? JSONDecoder().decode(SessionEvent.self, from: data)
        else { return nil }
        return .event(event)
    }
}
#endif
