import DSHKit
import Foundation
import Observation

/// 会话转写的可见状态：**开的是哪个会话**与**屏幕上那批行**是同一个值。
///
/// 从 `ChatModel` 拆出的核心状态。它只发布一对自洽的 `(summary, timeline)`，
/// 不碰网络、不碰折叠算法；ChatModel 在 open/close 时写入，UI 只读。
/// 一次发布的会话可见状态。
public struct VisibleSession {
    public var summary: SessionSummary
    public var timeline: ChatTimeline

    public init(summary: SessionSummary, timeline: ChatTimeline) {
        self.summary = summary
        self.timeline = timeline
    }
}

@MainActor
@Observable
final class TranscriptStore {

    /// 唯一被发布的会话可见状态；换会话时只赋值一次。
    public internal(set) var visible: VisibleSession?

    /// 读者顶部可见行：列表宿主回传的**测量值**，不是折叠输入。它只在"轮次关闭"
    /// 那一刻被读一次（`ChatModel.noteTailTransition`），此后不再参与任何判定。
    /// 与 `visible` 同属会话级状态：换会话/重开时由 `ChatModel.clearTailScope()` 清空。
    var readerTopRowID: String?

    /// 过程区「边界未确认」的三态：占位行显示什么只由模型写，投影只搬运。
    var tailBoundaryAttempt: TimelineProcessPlaceholder.State = .unresolved

    public init() {}

    public var session: SessionSummary? { visible?.summary }

    public var timeline: ChatTimeline {
        get { visible?.timeline ?? ChatTimeline() }
        set { visible?.timeline = newValue }
    }

    public func clear() {
        visible = nil
    }
}
