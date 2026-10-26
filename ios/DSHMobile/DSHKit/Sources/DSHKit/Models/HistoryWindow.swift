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
    /// 折叠感知下发（能力 `history-fold-summary` / `history-fold-summary-v2`）。
    ///
    /// v1（`fold: true`）只把过程段换成一条摘要，原始事件基本照旧；
    /// v2（`fold: "summary"`）整段过程都不下发，只给概要（讲话 + 回答 + 分组/步骤
    /// 元数据），此时 `limit` 是**轮数**、`maxBytes` 是主约束。
    public let fold: HistoryWindowFold?
    /// Optional response encoding, connector capability `history-compression`.
    /// Only `"deflate-raw"` is defined; omit it and the connector returns plain JSON,
    /// which is what every client before this capability does.
    public let encoding: String?
    /// 覆盖信息（能力 `history-coverage`）：请求随回包带回"这些号确认没有内容"。
    public let coverage: Bool?

    /// 「从最新开始」的线上安全值。连接器用 JS `Number.isSafeInteger` 校验
    /// `before`；Swift 的 `Int.max`（2^63−1）过 JSON.parse 会变成 2^63，
    /// 不是安全整数，连接器一律回 `gateway/bad-request`（T036 慢闸抓出：
    /// 灌库首拉全挂、账本永远为空）。2^53−1 是能过校验的最大整数。
    public static let safeMaxBefore = 9_007_199_254_740_991

    public init(address: SessionAddress, before: Int, through: Int? = nil,
                limit: Int? = nil, maxBytes: Int? = nil, roles: [String]? = nil,
                encoding: String? = nil, fold: HistoryWindowFold? = nil,
                coverage: Bool? = nil) {
        self.address = address
        self.before = before
        self.through = through
        self.limit = limit
        self.maxBytes = maxBytes
        self.roles = roles
        self.encoding = encoding
        self.fold = fold
        self.coverage = coverage
    }

    /// The one encoding this build asks for, when the connector advertises it.
    public static let deflateRaw = "deflate-raw"
}

/// `fold` 的三种取值：不折、v1 摘要、v2 概要。
///
/// 为什么不用 `Bool?`：v2 是**另一种取数模式**（过程正文不下发、`limit` 按轮数），
/// 与"要不要摘要"不是同一个量。编码保持向后兼容：`.v1` 仍写 `true`、`.none` 写
/// `false`、`.summary` 写字符串 `"summary"`（连接器 `fold: "summary"`），
/// 这样老连接器、老测试与逐字节黄金夹具都不受影响。
public enum HistoryWindowFold: Sendable, Equatable, Codable, ExpressibleByBooleanLiteral {
    /// 明确不折（要原事件）。
    case none
    /// v1：过程段换成一条摘要（能力 `history-fold-summary`）。
    case v1
    /// v2：整轮只回讲话 + 概要 + 回答（能力 `history-fold-summary-v2`）。
    case summary

    public init(booleanLiteral value: Bool) {
        self = value ? .v1 : .none
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            self = flag ? .v1 : .none
            return
        }
        let text = try container.decode(String.self)
        switch text {
        case "summary": self = .summary
        default:
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unknown fold mode \(text)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .none: try container.encode(false)
        case .v1: try container.encode(true)
        case .summary: try container.encode("summary")
        }
    }
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
    /// 本窗口内确认无内容的号段（能力 `history-coverage`）。没有 = 老连接器。
    public let knownEmpty: [[Int]]?
    /// 覆盖版本；与客户端当前版本不一致时整段丢弃。
    public let revision: String?

    public init(records: [SessionRecord], startSeq: Int?, endSeq: Int?, hasMore: Bool,
                truncatedBy: String? = nil, clamped: Bool? = nil, scanBoundary: Int? = nil,
                folds: [HistoryFoldSummary]? = nil,
                knownEmpty: [[Int]]? = nil, revision: String? = nil) {
        self.records = records
        self.startSeq = startSeq
        self.endSeq = endSeq
        self.hasMore = hasMore
        self.truncatedBy = truncatedBy
        self.clamped = clamped
        self.scanBoundary = scanBoundary
        self.folds = folds
        self.knownEmpty = knownEmpty
        self.revision = revision
    }

    /// The page as the transcript expects it.
    public func page() -> TranscriptPage {
        TranscriptPage(
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
