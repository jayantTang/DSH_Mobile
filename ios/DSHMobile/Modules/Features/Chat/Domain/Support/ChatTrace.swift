import DSHFoundation
import Foundation

/// 会话界面的状态摘要（折叠与取页）。
///
/// 为什么要有它：字符串/折叠/取页这三类现场只在真机出现，靠人复述"哪一屏、
/// 当时几行、为什么没折叠"既慢又不准。这里把**状态变化**压成一行事件，
/// 经 `DSHLog.sink` 进 OTA 诊断通道；TestFlight 里 sink 为 nil，`event` 只判一次空。
///
/// 约束：只在状态变化时发（不逐帧、不逐条消息），并有 500ms 的最小间隔；
/// 计算成本必须低于它要诊断的那条路径，否则就是在制造问题。
public enum FoldTrace {
    /// 纯函数：计数压成字段。单测直接断言它（排序、空 reason、缺省）。
    public static func fields(turns: Int, foldable: Int, running: Int,
                              openCompleted: Int, reasons: [String: Int]) -> [String: String] {
        var out: [String: String] = [
            "turns": String(turns),
            "foldable": String(foldable),
            "running": String(running),
            "open": String(openCompleted),
        ]
        if !reasons.isEmpty {
            let text = reasons.keys.sorted()
                .map { "\($0):\(reasons[$0] ?? 0)" }
                .joined(separator: ",")
            out["why"] = text
        }
        return out
    }

    /// 从折叠计划里数一遍：可折叠、进行中、以及"已结束却没能折叠"的原因。
    /// 原因词表只增：`noProcess`、`partial`、`gap`、`interleaved`、`failed`、`other`。
    public static func counts(_ plan: TranscriptProcessFold.Plan)
        -> (turns: Int, foldable: Int, running: Int, openCompleted: Int, reasons: [String: Int]) {
        var foldable = 0
        var running = 0
        var openCompleted = 0
        var reasons: [String: Int] = [:]
        for turn in plan.turns {
            if turn.isRunning { running += 1; continue }
            if turn.isFoldable { foldable += 1; continue }
            openCompleted += 1
            let reason: String
            let prefetched = turn.processIndexes.contains { index in
                if case .processHeader(let header) = plan.rows[index].kind { return header.isPrefetched }
                return false
            }
            if turn.processIndexes.isEmpty { reason = "noProcess" }
            else if prefetched { reason = "prefetched" }
            else if turn.isPartial { reason = "partial" }
            else if turn.hasGap { reason = "gap" }
            else if turn.hasInterleavedInput { reason = "interleaved" }
            else if turn.hasFailure { reason = "failed" }
            else { reason = "other" }
            reasons[reason, default: 0] += 1
        }
        return (plan.turns.count, foldable, running, openCompleted, reasons)
    }

    // MARK: - 发送（低频、变化驱动）

    @MainActor private static var lastSignature = ""
    @MainActor private static var lastAt: TimeInterval = 0

    /// 只在摘要变化时发一条；与上一次相同则直接返回（一次比较，代价可忽略）。
    @MainActor
    public static func note(plan: TranscriptProcessFold.Plan, session: String) {
        let summary = counts(plan)
        let fields = fields(turns: summary.turns, foldable: summary.foldable,
                            running: summary.running, openCompleted: summary.openCompleted,
                            reasons: summary.reasons)
        // 会话必须参与签名：两个会话的计数相同不代表同一个现场，
        // 不带它会把"另一个会话没折叠"的事件吞掉。
        // 异常：这一轮已结束、有过程行，却既不可折也不是预折摘要。按设计不该出现；
        // 出现就是读者看到"整轮铺开"的那一类。
        for turn in plan.turns where !turn.isRunning && !turn.isFoldable && !turn.isPartial {
            let prefetched = turn.processIndexes.contains { index in
                if case .processHeader(let header) = plan.rows[index].kind { return header.isPrefetched }
                return false
            }
            if !prefetched && !turn.processIndexes.isEmpty {
                DSHLog.event("anomaly.unfolded", [
                    "session": session,
                    "turn": turn.key,
                    "seq": String(turn.startSeq),
                    "rows": String(turn.processIndexes.count),
                ])
            }
        }
        let signature = session + "|" + fields.keys.sorted()
            .map { "\($0)=\(fields[$0] ?? "")" }.joined(separator: " ")
        guard signature != lastSignature else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastAt > 0.5 else { return }
        lastSignature = signature
        lastAt = now
        var payload = fields
        payload["session"] = session
        DSHLog.event("fold.summary", payload)
    }
}

/// 取页的起止与失败：一条 `page.older.start` 没有配对的 `end`，就是"一直转圈"。
public enum PageTrace {
    /// 纯函数：一行事件字段（单测断言排序与缺省）。
    public static func fields(direction: String, from: Int, to: Int, pages: Int,
                              records: Int? = nil, elapsedMs: Int? = nil) -> [String: String] {
        var out: [String: String] = [
            "dir": direction,
            "from": String(from),
            "pages": String(pages),
        ]
        if to > 0 { out["to"] = String(to) }
        if let records { out["records"] = String(records) }
        if let elapsedMs { out["ms"] = String(elapsedMs) }
        return out
    }
}
