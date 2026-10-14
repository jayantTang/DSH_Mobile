import Foundation

// 门面交给 App 的**只读模型**（spec 023 边界收敛：按能力的窄对象）。
//
// 为什么需要这一层名字：这些模型原本是**嵌套在实现层类型里**的
// （`MessagePipeline.SessionRef`、`SessionPipeline.GapRow`、`MessageStore.UserInputEntry`……），
// 于是 App 每写一次 `MessagePipeline.SessionRef(scope:sessionId:)` 就把实现层的名字带进了产品路径。
// 模型本身是 App 该拿的东西（会话引用、缺口行、快照差异、待发送状态），问题只是名字挂错了地方。
//
// 这里是**纯别名**：类型、成员、初始化器完全同一份，不存在两套实现；改实现层的嵌套名字会立刻
// 编译不过，所以不会漂移。App 侧改用这些名字之后，"实现层标识符出现在产品路径"这条就只剩真正
// 需要能力对象的地方（见 `half-two-evidence.md` 的下一批）。

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
