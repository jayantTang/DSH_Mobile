import Foundation

/// One request for an exact backward window, answered by the **connector**
/// (spec 007, `_link/sessionWindow`).
///
/// Unlike the Host's own `session/page`, the connector's method takes the
/// position it should end before and nothing else: no `throughSeq`, no guessing
/// whether a number means a seq or a log offset. `before` is exclusive — the page
/// must end at `before - 1`, which is how the phone knows a page abuts the window
/// it already holds.
///
/// Args are flat (`{address, before, …}`), matching the connector's other local
/// methods (`_link/git*`); the Host's `{request: …}` envelope is for Host
/// endpoints only.
public struct HistoryWindowRequest: Sendable, Codable {
    public let address: SessionAddress
    /// Exclusive upper bound: the oldest seq the phone already holds.
    public let before: Int
    /// Optional hard ceiling (the follow snapshot's cursor).
    public let through: Int?
    /// How many records the phone would like.
    public let limit: Int?
    /// Byte budget for the page; the connector trims the oldest end to fit.
    public let maxBytes: Int?
    /// Optional role filter (`["me"]`…), connector capability `history-role-filter`
    /// (spec 009 T031/T033). Filtering affects only which records come back;
    /// the `before` cursor semantics are unchanged. Since T039 such a page also
    /// carries `scanBoundary` — the boundary a filtered pull advances by.
    public let roles: [String]?
    /// 折叠感知下发（能力 `history-fold-summary`）：`true` 时连接器把本页内已完成
    /// 的轮次折成一条 `+link/fold` 摘要记录。展开某轮时用 `false`（默认）取回原事件。
    public let fold: Bool?
    /// Optional response encoding, connector capability `history-compression`.
    /// Only `"deflate-raw"` is defined; omit it and the connector returns plain JSON,
    /// which is what every client before this capability does.
    public let encoding: String?

    /// 「从最新开始」的线上安全值。连接器用 JS `Number.isSafeInteger` 校验
    /// `before`；Swift 的 `Int.max`（2^63−1）过 JSON.parse 会变成 2^63，
    /// 不是安全整数，连接器一律回 `gateway/bad-request`（T036 慢闸抓出：
    /// 灌库首拉全挂、账本永远为空）。2^53−1 是能过校验的最大整数。
    public static let safeMaxBefore = 9_007_199_254_740_991

    public init(address: SessionAddress, before: Int, through: Int? = nil,
                limit: Int? = nil, maxBytes: Int? = nil, roles: [String]? = nil,
                encoding: String? = nil, fold: Bool? = nil) {
        self.address = address
        self.before = before
        self.through = through
        self.limit = limit
        self.maxBytes = maxBytes
        self.roles = roles
        self.encoding = encoding
        self.fold = fold
    }

    /// The one encoding this build asks for, when the connector advertises it.
    public static let deflateRaw = "deflate-raw"
}

/// What the connector hands back.
public struct HistoryWindowValue: Sendable, Codable {
    public let records: [SessionRecord]
    public let startSeq: Int?
    public let endSeq: Int?
    /// Host-authoritative "there is older history".
    public let hasMore: Bool
    /// Which budget cut the page: `count`, `bytes`, or nothing.
    public let truncatedBy: String?
    /// The requested position no longer exists (the session was trimmed), so this
    /// page starts from the log's newest event. The phone must treat a page that
    /// does not abut its window as "the log got shorter" rather than as a hole.
    public let clamped: Bool?
    /// How far the scan actually got: the oldest seq the connector examined for
    /// this page, usable directly as the next request's `before` (exclusive).
    ///
    /// Added by spec 009 T039 (`history-scan-boundary`). Why it is needed: a
    /// `roles`-filtered page can be returned empty while the scan moved hundreds
    /// of seqs, and the old cursor rule (the oldest **returned** record) then
    /// stands still — the backfill re-reads the same stretch on every cold start.
    /// `nil` means the connector predates the field; readers fall back to
    /// `startSeq` (the old rule) and behave exactly as before.
    public let scanBoundary: Int?
    /// 本页被折掉的轮次摘要（能力 `history-fold-summary`）。没有这个字段 = 连接器
    /// 没折（老连接器，或本页没有可折的完成轮次）。
    public let folds: [HistoryFoldSummary]?

    public init(records: [SessionRecord], startSeq: Int?, endSeq: Int?, hasMore: Bool,
                truncatedBy: String? = nil, clamped: Bool? = nil, scanBoundary: Int? = nil,
                folds: [HistoryFoldSummary]? = nil) {
        self.records = records
        self.startSeq = startSeq
        self.endSeq = endSeq
        self.hasMore = hasMore
        self.truncatedBy = truncatedBy
        self.clamped = clamped
        self.scanBoundary = scanBoundary
        self.folds = folds
    }

    /// The page as the pager wants it.
    public func page() -> TranscriptPager.Page {
        TranscriptPager.Page(
            records: records,
            startSeq: startSeq ?? records.first?.event.seq ?? 0,
            endSeq: endSeq ?? records.last?.event.seq ?? 0,
            hasMore: hasMore,
            clamped: clamped ?? false
        )
    }
}


/// 连接器折好的一条轮次摘要（`+link/fold` 的 `data`，也是 `folds` 的元素）。
///
/// 字段与 `TimelineProcessHeader` 一一对应；客户端收到后直接插一行过程节点，
/// 点开时按 `startSeq...endSeq` 回取详情。`isPartial` 恒为 false：连接器只折
/// 完整落在本页里的轮次。
public struct HistoryFoldSummary: Sendable, Codable, Equatable {
    public let turn: Int
    public let startSeq: Int
    public let endSeq: Int
    public let finalSeq: Int?
    public let dividerSeq: Int?
    public let toolCount: Int
    public let reasoningCount: Int
    public let messageCount: Int
    public let subagentCount: Int
    public let endReason: String?
    public let durationMs: Double?
    public let foldedCount: Int

    /// 展开这一轮时要发的那一次请求：精确覆盖摘要的 seq 段，**不带 fold**
    /// （要的就是被折掉的原事件），压缩按当前连接能力带。
    public func detailRequest(address: SessionAddress, encoding: String? = nil) -> HistoryWindowRequest {
        HistoryWindowRequest(
            address: address,
            before: endSeq + 1,
            through: nil,
            limit: max(1, endSeq - startSeq + 1),
            maxBytes: 512 * 1024,
            encoding: encoding
        )
    }
}
