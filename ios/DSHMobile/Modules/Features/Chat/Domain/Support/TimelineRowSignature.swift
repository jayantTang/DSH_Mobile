import DSHKit
import Foundation

/// 一行的**内容签名**：列表宿主用它判断"同一个 id 的行内容有没有变"。
///
/// 为什么放在领域层：签名必须覆盖每一类行的可见内容，漏一个字段就是一种
/// "内容变了但行不重载"的缺陷（TC-112 之前的分组行就是这样：`isRunning`/
/// `endReason` 没进签名，轮次结束后分组行还写着「正在分析请求」）。
/// 放在这里才能用纯函数单测钉住每一类行，而 UI 目标在 `swift test` 里不参与。
public enum TimelineRowSignature {

    public static func of(_ item: TimelineItem) -> String {
        let base = "\(item.id)#\(TranscriptRowPayload(item: item).payloadBytes)"
        switch item.kind {
        case .gap(_, _, let status):
            return "\(item.id)|gap:\(status)"
        case .userMessage(_, _, let isSteering, let isPending, _):
            // pending→sent 原地替换不改字节数，状态位必须进签名，否则徽标永远停在"等待开始"。
            // 失败/未确认两个标记同理：都只翻状态位，不改载荷字节数。
            return "\(base)|u:\(isSteering):\(isPending):\(item.sendFailed):\(item.sendUnconfirmed)"
        case .toolCall(let invocation):
            return "\(base)|t:\(invocation.isRunning):\(invocation.isError)"
        case .processHeader(let header):
            // 轮次行与分组行都走这里：运行态/结束原因/用时/失败标记都会改文案，
            // 缺一个就会停在旧字上（「正在分析请求」不消失就是这么来的）。
            var prefetch = "none"
            switch header.prefetchStatus {
            case .loading(let loaded): prefetch = "loading:\(loaded)"
            case .failed: prefetch = "failed"
            case nil: break
            }
            return "\(base)|ph:\(header.isExpanded):\(header.toolCount):\(header.reasoningCount)"
                + ":\(header.messageCount):\(header.isRunning):\(header.endReason ?? "-")"
                + ":\(header.duration ?? -1):\(header.hasFailure):\(header.isPrefetched):\(prefetch)"
        case .processStep(let step):
            // 步骤行没有正文载荷：状态（running→ok/error）、字节数与**按需取回来的
            // 正文三态**都是它的内容——任一变化都要重载，否则卡片停在旧状态
            //（刚刚取回正文却还显示「点开查看」）。
            let body: String
            switch step.body {
            case .loading: body = "loading"
            case .failed: body = "failed"
            case .loaded(let text, _): body = "loaded:\(text.utf8.count)"
            case .tooLarge: body = "tooLarge"
            case nil: body = "none"
            }
            return "\(base)|ps:\(step.status.rawValue):\(step.bytes ?? -1):\(step.resultSeq ?? -1):\(body):\(step.isExpanded)"
        case .processPlaceholder(let placeholder):
            // 占位行的三态就是它的全部内容（44pt 固定高度，没有正文载荷）：
            // 状态不进签名，`.unresolved → resolving → failed` 就不会重载。
            return "\(item.id)|pp:\(placeholder.state)"
        case .runningLine(let line):
            // 文案由行视图按开始时刻自己走表；开始时刻变了（新的一轮）要重载。
            return "\(item.id)|run:\(line.since?.timeIntervalSince1970 ?? -1)"
        default:
            return base
        }
    }
}
