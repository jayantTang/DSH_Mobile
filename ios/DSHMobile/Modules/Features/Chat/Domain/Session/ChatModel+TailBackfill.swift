import DSHFoundation
import DSHKit
import Foundation

/// 首帧窗口按轮次切齐（设计 `20261027-折叠抖动-方案A.md` M5'）。
///
/// 为什么必须有它：窗口是按**条数**切的（`restoreRecordLimit` / 补读预算），被切开的
/// 尾轮里既没有 `turn/start` 也没有 `turn/end`，边界于是只能猜。补读的职责就是
/// "从窗口最老一条往下读到最近的轮次边界"，**全部在本地库完成（0 网络）**，
/// 并把每种结局都落到可见状态：边界已知 → 占位行消失；否则占位行停在一个可重试的终态。
extension ChatModel {

    /// 磁盘层能交回来的那段尾部（`loadStoredTail` 的返回形状，三条路共用）。
    struct StoredTail {
        public let records: [SessionRecord]
        public let oldest: Int?
        public let newest: Int?
        public let hasOlder: Bool
        /// 按轮次切齐的结局（M5'-4）。前缀单独传，不塞进 `records`：
        /// "读出来的窗口"与"补出来的窗口"不混成一个字段。
        public var backfill: BackfillOutcome = .notNeeded
    }

    /// 补读结局（M5'-1）。每一种都有映射到界面的出口，没有"静默当成没事"的分支。
    enum BackfillOutcome: Equatable, Sendable {
        /// 原窗口里已经有轮次边界行。
        case notNeeded
        /// 补读到边界行（含该条）。
        case aligned(added: Int)
        /// 读到库最老一条仍没有边界行。
        case earliest
        /// 达到补读上限。
        case capped(limit: Int)
        /// 本地区间集在下方有洞：不猜。
        case hole
        /// 读库抛错（`"read"`）或超时（`"timeout"`）。
        case failed(String)
    }

    /// 补读预算（M5'-2）。**不是**设计原写的 500 / 5000：管道热窗口是 500，补超过
    /// 500 会被 `evictIfNeeded` 淘汰，第二帧反而删掉首帧的行。一页与总量是同一个数
    /// （读一页就够），所以只留一个常量。不够用时按设计 §8.5 第 4 条调它并写理由。
    static let tailBackfillMaxRecords = 200

    /// 结局 → 占位行状态（纯函数，M5'-1）。
    ///
    /// `earliest` / `capped` **不**映射到 `.failed`：那两种结局没有"读失败/超时"的事实，
    /// 写成失败就是撒谎。它们的诚实表达是"未确认 + 可重试"（`.unresolved` 也必须可点，
    /// 见 M7'-1）。
    static func placeholderState(for outcome: BackfillOutcome)
        -> TimelineProcessPlaceholder.State {
        switch outcome {
        case .notNeeded, .aligned, .earliest, .capped: return .unresolved
        case .hole: return .failed(.hole)
        case .failed(let reason): return reason == "timeout" ? .failed(.timeout) : .failed(.read)
        }
    }

    /// 结局 → 探针词（`transcript.backfill` 的 `outcome`）。
    static func backfillName(_ outcome: BackfillOutcome) -> String {
        switch outcome {
        case .notNeeded: return "notNeeded"
        case .aligned: return "aligned"
        case .earliest: return "earliest"
        case .capped: return "capped"
        case .hole: return "hole"
        case .failed(let reason): return "failed:\(reason)"
        }
    }

    /// 探针字段的唯一实现（单测直接断言，防下一轮改列）。
    static func backfillFields(_ outcome: BackfillOutcome, phase: String, added: Int,
                               oldest: Int?, hole: Bool) -> [String: String] {
        var out: [String: String] = [
            "phase": phase,
            "outcome": backfillName(outcome),
            "added": String(added),
            "hole": hole ? "1" : "0",
        ]
        if let oldest { out["oldest"] = String(oldest) }
        return out
    }

    // MARK: - 边界行判定

    /// 边界行判定走**同一个解码入口**（不按 `event.type` 字符串自判）。
    static func isTailBoundaryRow(_ record: SessionRecord) -> Bool {
        switch ChatEventDecoder.decode(record.event) {
        case .turnStart, .turnEnd: return true
        default: return false
        }
    }

    /// 这段记录里最新的那条边界事实（从后往前取第一条）。没有就是 `nil`。
    static func tailBoundary(in records: [SessionRecord]) -> TranscriptTail.Boundary? {
        for record in records.reversed() {
            switch ChatEventDecoder.decode(record.event) {
            case .turnStart(let turn):
                return .open(turn: turn, startedAt: record.event.date)
            case .turnEnd(let turn, let reason):
                return .closed(turn: turn, reason: reason)
            default:
                continue
            }
        }
        return nil
    }

    // MARK: - 补读

    /// 把窗口向下切到最近的轮次边界（M5'-2）。本地读，0 网络。
    ///
    /// 顺序是刻意的：先看原窗口有没有边界行（有就 0 次读盘），再判下方有没有洞
    ///（区间集不是 `.full` 就不猜），最后才读一页。命中边界行就连它一起取回。
    func alignTail(_ stored: StoredTail, scope: String, sessionId: String)
        async -> (prefix: [SessionRecord], outcome: BackfillOutcome) {
        if Self.tailBoundary(in: stored.records) != nil { return ([], .notNeeded) }
        guard let layer = messageBacking else { return ([], .failed("read")) }
        guard let state = try? await layer.sessionState(scope: scope, sessionId: sessionId)
        else { return ([], .failed("read")) }
        let windowFirst = stored.records.first?.event.seq ?? (stored.oldest ?? 1)
        // 下方有洞：不猜、不联网，落 `.hole`（可见的失败态，可重试）。
        //
        // 只在区间集**有内容**时才这么判：空区间集的意思是"这台设备从没记录过覆盖"，
        // 不是"已知有洞"。把它当成洞会让"记录都在、只是没记区间"的会话永远停在
        // 「过程区缺一段记录」——那是不许出现的死路（设计 §6 第 8 条自己点过这个风险）。
        // 空区间集继续往下读：读到库最老仍无边界就是 `.earliest`，同样可重试。
        if let storeOldest = state.oldestSeq, storeOldest < windowFirst,
           !state.ranges.spans.isEmpty,
           state.ranges.coverage(of: storeOldest...(windowFirst - 1)) != .full {
            return ([], .hole)
        }
        let page: [SessionRecord]
        do {
            page = try await layer.windowBefore(scope: scope, sessionId: sessionId,
                                                seq: windowFirst,
                                                limit: Self.tailBackfillMaxRecords)
        } catch {
            return ([], .failed("read"))
        }
        if let index = page.lastIndex(where: Self.isTailBoundaryRow) {
            let prefix = Array(page[...index])
            return (prefix, .aligned(added: prefix.count))
        }
        if page.count < Self.tailBackfillMaxRecords { return (page, .earliest) }
        return (page, .capped(limit: Self.tailBackfillMaxRecords))
    }

    // MARK: - 首帧接入（M5'-3）

    /// 冷启动窗口落地：补读 → 首帧 reset → 占位状态 → 探针。
    ///
    /// 抽成一个方法是为了让 `ChatModel.swift` 的 `open()` 只多一行调用（那个文件
    /// 已超 500 行，只许持平）。
    ///
    /// - Returns: 需要 `absorb` 进管道的前缀。`reset` 已经画好首帧，前缀也必须让
    ///   管道的下一次 refold 包含它，否则第二帧会把首帧的行抹掉。
    func openStoredTail(_ stored: StoredTail, scope: String, sessionId: String,
                        syncPlan: TranscriptSyncPlan, seeding boundary: TranscriptTail.Boundary,
                        hostSeq: Int) async -> [SessionRecord] {
        var stored = stored
        let backfill: (prefix: [SessionRecord], outcome: BackfillOutcome)
        if syncPlan.reBase {
            // 窗口会被整段替换：此刻补读出来的前缀马上要被丢掉，不读。
            backfill = ([], .notNeeded)
        } else {
            backfill = await alignTail(stored, scope: scope, sessionId: sessionId)
        }
        stored.backfill = backfill.outcome
        let records = backfill.prefix + stored.records
        timeline.reset(with: records, seeding: boundary)
        // 边界已知时不留旧的失败态：否则它会在以后某次变 unknown 时冒出来。
        tailBoundaryAttempt = timeline.tail.boundary.isUnknown
            ? Self.placeholderState(for: backfill.outcome) : .unresolved
        TailTrace.noteBackfill(session: sessionId,
                               fields: Self.backfillFields(backfill.outcome, phase: "open",
                                                           added: backfill.prefix.count,
                                                           oldest: records.first?.event.seq,
                                                           hole: backfill.outcome == .hole))
        recentRecords = stored.records
        throughSeq = max(stored.newest ?? 0, hostSeq)
        noteWindow(oldest: backfill.prefix.first?.event.seq ?? stored.oldest,
                   hasMore: stored.hasOlder)
        phase = .ready
        scrollSignal += 1
        // `turn` / `boundaryRow`：D5 硬档据此判——`boundaryRow=0` + `turn>0`
        // 证明边界来自播种而不是回放。
        ChatProbe.shared.probeNote?("transcript.loaded", [
            "session": sessionId,
            "records": String(records.count),
            "oldest": String(records.first?.event.seq ?? -1),
            "turn": String(timeline.tail.boundary.turn),
            "boundaryRow": Self.tailBoundary(in: records) == nil ? "0" : "1",
        ], true)
        return backfill.prefix
    }
}
