import DSHKit
import Foundation

/// 只统计当前流式尝试产出的字数（正文 + 思考），供运行中折叠行右侧显示。
/// 与时间线折叠解耦：摘要模式下正文不下发时，也能从 `assistantStream` 增量得到字数。
public struct LiveStreamCharCounter: Equatable, Sendable {
    public private(set) var attemptId: String?
    public private(set) var chars: Int = 0

    public init() {}

    public mutating func apply(_ frame: AssistantStreamFrame) {
        switch frame {
        case .start(let attemptId, _, _, _, _):
            self.attemptId = attemptId
            chars = 0
        case .chunk(let attemptId, _, _, _, let chunk):
            guard attemptId == self.attemptId else { return }
            switch chunk {
            case .textDelta(let text), .reasoningDelta(let text):
                chars += text.count
            case .toolCallDelta, .other:
                break
            }
        case .end(let attemptId, _, _, _):
            guard attemptId == self.attemptId else { return }
            self.attemptId = nil
            chars = 0
        case .unknown:
            break
        }
    }
}
