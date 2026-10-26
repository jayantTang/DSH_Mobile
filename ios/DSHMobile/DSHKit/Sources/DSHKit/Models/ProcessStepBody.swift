import Foundation

/// 从**一条记录**里取出步骤正文（按需单条取数的解析半边）。
///
/// 概要 v2 只下发步骤元数据；读者点开某一条时，客户端按 `resultSeq`（工具）
/// 或自身 `seq`（思考）取回那一条记录，这里把它还原成卡片要显示的正文。
/// 纯函数：找不到对应正文就返回 nil，调用方落到可见的失败态，不编内容。
public enum ProcessStepBodyReader {

    /// - Parameters:
    ///   - kind: 步骤类型（工具正文在 `tool/result`，思考正文在 `assistant/message`）。
    ///   - record: 取回来的那一条记录（调用方已按 seq 校验过，这里再校验一次）。
    ///   - seq: 期望的正文 seq（`TimelineProcessStep.bodySeq`）。
    public static func text(for kind: FoldSummaryV2.StepKind,
                            in record: SessionRecord,
                            seq: Int) -> String? {
        guard record.event.seq == seq else { return nil }
        switch ChatEventDecoder.decode(record.event) {
        case .toolResult(let result):
            guard kind == .tools else { return nil }
            return joined(result.content)
        case .assistantMessage(let message):
            guard kind == .reasoning else { return nil }
            // 思考正文只取思考块；同一条消息里的正文属于「讲话」，不塞进步骤卡。
            let reasoning = message.content.compactMap { block -> String? in
                if case .reasoning(let text) = block { return text }
                return nil
            }
            return joined(reasoning.map(ContentBlock.text))
        default:
            return nil
        }
    }

    private static func joined(_ blocks: [ContentBlock]) -> String? {
        let text = blocks.compactMap { block -> String? in
            switch block {
            case .text(let value): return value
            case .unknown(_, let raw): return raw["text"]?.stringValue
            default: return nil
            }
        }.joined()
        return text.isEmpty ? nil : text
    }
}
