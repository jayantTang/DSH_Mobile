import Foundation

// App 与 DSHKit 之间的**只读模型别名**。
//
// 这些模型原本嵌套在实现层类型里（`MessagePipeline.SessionRef`、`SessionPipeline.GapRow`、
// `MessageStore.UserInputEntry`……），App 每写一次就把实现层的名字带进产品路径。别名让
// App 用稳定的名字，实现层改内部命名时只在这里跟随一次。
//
// 纯别名：类型、成员、初始化器完全同一份，不存在两套实现，也不会漂移。
// **它们不是“单一入口”**：DSHKit 的数据能力仍由 `MessageLayer` / `SessionHandle` /
// `LinkGateway` 三个窄对象构成。2026-10-21 删除了未落地的 `SessionRuntime` 骨架
// （协议只有 `transport` 一个成员且 App 从未使用），避免再出现“名义门面”。

/// 一个会话的地址（scope + sessionId）。
public typealias MessageSessionRef = MessagePipeline.SessionRef

/// 预取目标：某个会话要预取到哪一条。
public typealias MessagePrefetchTarget = MessagePipeline.PrefetchTarget

/// 快照之间的差异（内存层广播给渲染侧）。
public typealias MessageSnapshotDiff = MessagePipeline.SnapshotDiff

/// 一条待发送/已发送消息的状态。
public typealias MessageSendStatus = MessagePipeline.RenderedMessage.Status

/// 时间线上的缺口行（失败的取页区间）。
public typealias TranscriptGapRow = SessionPipeline.GapRow

/// 「我问过的」一条记录。
public typealias UserInputEntry = MessageStore.UserInputEntry
