import DSHKit
import Foundation
import Observation

/// 会话转写的可见状态：**开的是哪个会话**与**屏幕上那批行**是同一个值。
///
/// 从 `ChatModel` 拆出的核心状态。它只发布一对自洽的 `(summary, timeline)`，
/// 不碰网络、不碰折叠算法；ChatModel 在 open/close 时写入，UI 只读。
@MainActor
@Observable
public final class TranscriptStore {

    /// 一次发布的会话可见状态。
    public struct VisibleSession {
        public var summary: SessionSummary
        public var timeline: ChatTimeline

        public init(summary: SessionSummary, timeline: ChatTimeline) {
            self.summary = summary
            self.timeline = timeline
        }
    }

    /// 唯一被发布的会话可见状态；换会话时只赋值一次。
    public internal(set) var visible: VisibleSession?

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
