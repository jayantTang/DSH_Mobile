import DSHFoundation
import DSHKit
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
                let fields = [
                    "session": session,
                    "turn": turn.key,
                    "seq": String(turn.startSeq),
                    "rows": String(turn.processIndexes.count),
                ]
                DSHLog.event("anomaly.unfolded", fields)
                // 现场取证只认探针：`DSHLog` 进的是 OTA 诊断通道，实测
                // `probe-relay.log` 里 `fold.*` 一条都没有（验收不能依赖它）。
                ChatProbe.shared.probeNote?("anomaly.unfolded", fields, true)
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
        ChatProbe.shared.probeNote?("fold.summary", payload, true)
    }

    // MARK: - 形态（设计 M8'-1）

    /// 形态词表：**固定六种，只增不改**。
    ///
    /// 判定顺序即优先级：`empty > unknown > running > expanded > folded > mixed`
    ///（ARCH-REVIEW 3 §12.4）。
    public enum Shape: String, Sendable {
        /// 空帧：一行都没有。**不是**一个折叠形态，优先级最高；不得被读成 `folded`。
        case empty
        /// 有占位行：尾轮状态还没确认。
        case unknown
        /// 有运行行：有一轮在跑。
        case running
        /// 至少一轮可折且已展开。
        case expanded
        /// 可折的轮次全部收起（含"整窗没有过程行可折"的形态，见 `shape(rows:plan:state:)`）。
        case folded
        /// **有过程行**，但既不可折也不在跑（例如被切开、又不算尾部的那段历史）。
        case mixed
    }

    /// 纯函数：这一帧的形态。入参只有显示行、计划与折叠态——没有测量值。
    ///
    /// `rows` 是投影交给渲染的显示行数（`displayRowsFor` 的返回值）。视图层把长回答拆行
    /// （`splitLongAssistantRows`）会让它与 `list.reconcile rows=` 形成**恒定正偏置**
    /// （`Δ = list − shape` 等于拆行增量），**不是相等**。
    ///
    /// 因此 D8-1 的"稳定期 Δ=0"只在**未拆行**时成立；有拆行时必须能指名那条长回答，
    /// 并说明该稳定期的 Δ。模型层不得为了对齐去猜视图怎么切行（那会把折叠与显示耦合死）。
    public static func shape(rows: [TimelineItem], plan: TranscriptProcessFold.Plan,
                             state: TranscriptFoldState) -> Shape {
        // 空帧优先：`mixed` 的定义是"有过程行"，用在没有行的时候是词表的洞。
        if rows.isEmpty { return .empty }
        if rows.contains(where: { if case .processPlaceholder = $0.kind { return true }
                                 return false }) {
            return .unknown
        }
        if rows.contains(where: { if case .runningLine = $0.kind { return true }
                                 return false }) {
            return .running
        }
        let foldable = plan.turns.filter(\.isFoldable)
        let expanded = foldable.filter {
            TranscriptProcessFold.isTurnExpanded($0, plan: plan, state: state)
        }
        if !expanded.isEmpty { return .expanded }
        if !foldable.isEmpty { return .folded }
        // 有行但没有可折的轮次：分两种，不能都叫 mixed。
        // - 有过程行（只是不可折）→ `mixed`（词表本义）；
        // - 连过程行都没有（整窗只有讲话与回答）→ `folded`：没有过程区可展开，
        //   收起态就是它唯一的样子（D8-2 的"有形态必有行"此时天然成立）。
        return plan.processRowIDs.isEmpty ? .folded : .mixed
    }

    /// 纯函数：探针字段（唯一实现，单测直接断言）。
    public static func shapeFields(shape: Shape, session: String, rows: Int,
                                   tail: TranscriptTail, turns: Int,
                                   foldable: Int, hold: Int) -> [String: String] {
        [
            "session": session,
            "rows": String(rows),
            "shape": shape.rawValue,
            "tail": TailTrace.name(tail.boundary),
            "reachesTail": tail.showsTail ? "1" : "0",
            "turns": String(turns),
            "foldable": String(foldable),
            "hold": String(hold),
        ]
    }

    @MainActor private static var lastShapeSignature = ""
    @MainActor private static var lastShapeAt: TimeInterval = 0

    /// 形态事件：只在签名变化且距上次 ≥500 ms 时发。
    ///
    /// 节流状态**独立**于 `fold.summary`（共用一份会让同刻的一条 summary 吞掉 shape）。
    /// 它与 `list.reconcile rows=` 取的是同一批显示行，因此两者行数必须相等。
    @MainActor
    public static func noteShape(rows: [TimelineItem], plan: TranscriptProcessFold.Plan,
                                 state: TranscriptFoldState, tail: TranscriptTail,
                                 session: String) {
        let shape = shape(rows: rows, plan: plan, state: state)
        let fields = shapeFields(shape: shape, session: session, rows: rows.count, tail: tail,
                                 turns: plan.turns.count,
                                 foldable: plan.turns.filter(\.isFoldable).count,
                                 hold: state.manualTurn.count)
        let signature = fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        guard signature != lastShapeSignature else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastShapeAt > 0.5 else { return }
        lastShapeSignature = signature
        lastShapeAt = now
        DSHLog.event("fold.shape", fields)
        ChatProbe.shared.probeNote?("fold.shape", fields, true)
    }

    /// 测试钩子：节流状态是静态的，用例之间必须能重置
    ///（与 `MessageStore.tableNamesForTesting` 同一纪律）。
    @MainActor
    public static func resetShapeThrottleForTesting() {
        lastShapeSignature = ""
        lastShapeAt = 0
    }
}

/// 尾轮边界事件（设计 M8 的 `tail.boundary`）。
///
/// 为什么独立一个类型：边界的迁移点只有一个（`ChatModel.noteTailTransition`），
/// 而现场判定要同时看到"从什么变成什么""保位有没有发生""落库了没有"。
/// 这三样合成一条事件，比事后拼三条日志可靠。
///
/// 探针语义（M8'-3，与代码逐字一致）：
/// - `tail.boundary` 的 `persisted=1` = **已交给写链**（不保证已落盘）；落盘失败另发
///   `tail.persist.failed`（`session`/`turn`/`to`/`reason`）；
/// - `tail.persist.readFailed`：播种读盘失败（落 unknown 是有意的，占位行可重试）；
/// - `transcript.backfill` 的 `phase=open|retry`：首帧补读与点击重试；
/// - `tail.conflict`：宿主重放旧 `turn/start`（只记录，合并表已经拒绝）。
public enum TailTrace {

    /// 纯函数：字段压成一行。单测直接断言（不依赖探针接线）。
    public static func fields(from: TranscriptTail.Boundary, to: TranscriptTail.Boundary,
                              hold: String, persisted: Bool) -> [String: String] {
        [
            "from": name(from),
            "to": name(to),
            "turn": String(to.turn),
            "hold": hold,
            "persisted": persisted ? "1" : "0",
        ]
    }

    /// 边界的三个取值（探针字段口径，不含轮次号）。
    public static func name(_ boundary: TranscriptTail.Boundary) -> String {
        switch boundary {
        case .unknown: return "unknown"
        case .open: return "open"
        case .closed: return "closed"
        }
    }

    /// 占位行状态 → 探针词。`resolving` 不是终态，出现在终态位置就是缺陷。
    public static func placeholderStateName(_ state: TimelineProcessPlaceholder.State) -> String {
        switch state {
        case .unresolved: return "unresolved"
        case .resolving: return "resolving"
        case .failed(.read): return "failed:read"
        case .failed(.hole): return "failed:hole"
        case .failed(.timeout): return "failed:timeout"
        }
    }

    /// 一条边界事件：日志与探针**同时**发（只发日志等于现场拿不到）。
    public static func note(from: TranscriptTail.Boundary, to: TranscriptTail.Boundary,
                            hold: String, persisted: Bool) {
        let fields = fields(from: from, to: to, hold: hold, persisted: persisted)
        DSHLog.event("tail.boundary", fields)
        ChatProbe.shared.probeNote?("tail.boundary", fields, true)
    }

    /// `tail.persist.failed`：写盘失败。`persisted=1` 只代表"进了写链"，
    /// 这一条才是"没写下去"。
    public static func persistFailedFields(session: String, turn: Int,
                                          to: String, reason: String) -> [String: String] {
        ["session": session, "turn": String(turn), "to": to, "reason": reason]
    }

    public static func notePersistFailed(session: String, turn: Int,
                                        to: String, reason: String) {
        let fields = persistFailedFields(session: session, turn: turn, to: to, reason: reason)
        DSHLog.event("tail.persist.failed", fields)
        ChatProbe.shared.probeNote?("tail.persist.failed", fields, true)
    }

    /// `tail.persist.readFailed`：播种时读盘失败。
    public static func notePersistReadFailed(session: String, reason: String) {
        let fields = ["session": session, "reason": reason]
        DSHLog.event("tail.persist.readFailed", fields)
        ChatProbe.shared.probeNote?("tail.persist.readFailed", fields, true)
    }

    /// `tail.conflict`：宿主重放旧 `turn/start`。字段 `session`/`turn`/`closed`。
    public static func conflictFields(session: String, turn: Int, closed: Int) -> [String: String] {
        ["session": session, "turn": String(turn), "closed": String(closed)]
    }

    public static func noteConflict(session: String, turn: Int, closed: Int) {
        let fields = conflictFields(session: session, turn: turn, closed: closed)
        DSHLog.event("tail.conflict", fields)
        ChatProbe.shared.probeNote?("tail.conflict", fields, true)
    }

    /// `transcript.backfill`：补读结局。字段由 `BackfillOutcome` 的唯一实现生成
    ///（`ChatModel.backfillFields`），这里只负责加会话与阶段。
    public static func noteBackfill(session: String, fields: [String: String]) {
        var payload = fields
        payload["session"] = session
        DSHLog.event("transcript.backfill", payload)
        ChatProbe.shared.probeNote?("transcript.backfill", payload, true)
    }

    /// `process.unknown.retry`：占位行被点之后**终态**一条（`state` 不是 `resolving`）。
    public static func noteRetry(session: String, state: String, outcome: String) {
        let fields = ["session": session, "state": state, "outcome": outcome]
        DSHLog.event("process.unknown.retry", fields)
        ChatProbe.shared.probeNote?("process.unknown.retry", fields, true)
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
