import Foundation
import Observation

/// 运行中过程的实时指标。由 `ChatModel` 唯一持有，视图直接观察它，
/// 不依赖列表重建的时机；否则流式字数只能跟着步数一起刷新。
@Observable
public final class LiveProcessMetrics {
    public var chars: Int = 0
    public var frames: Int = 0
    public init() {}
}
