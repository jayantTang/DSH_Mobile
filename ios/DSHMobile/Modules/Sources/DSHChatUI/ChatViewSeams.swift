#if os(iOS)
import DSHChatDomain
import DSHFoundation
import SwiftUI

/// 界面层自己的探针端口（025 阶段4b）。
///
/// 与 `ChatProbe` 同一套做法，分开的理由只有一条：这里要过的类型（`FocusState`）
/// 是 SwiftUI 的，而 `DSHChatDomain` 不许 import SwiftUI（边界契约 C2）。
/// 接线同样在 `DSHMobileApp.init`。
public enum ChatViewSeams {
    /// `-DSHTypingProbe <文字>@<秒数>`：按字符把文字追加进草稿，模拟人连续打字
    /// （原 `ViewportProbe.runTyping`）。带上 `@MainActor` 是因为 `FocusState.Binding`
    /// 不是 Sendable、只能在主线程上过。
    nonisolated(unsafe) public static var runTyping: (@MainActor (_ target: TypingTarget, _ focus: FocusState<Bool>.Binding) async -> Void)?
}
#endif
