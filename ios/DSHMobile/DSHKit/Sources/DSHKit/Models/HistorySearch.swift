import Foundation

/// One request for in-session search, answered by the **connector**
/// (`_link/sessionFind`, spec 007 FR-010…FR-012).
///
/// Flat args, like every `_link/*` method: the Host's `{request: …}` envelope is
/// for Host endpoints only.
public struct HistorySearchRequest: Sendable, Codable {
    public let address: SessionAddress
    public let query: String
    /// Which roles to keep: `me` / `agent` / `tool`. Omitted means all three.
    public let roles: [String]?
    public let limit: Int?
    /// Opaque continuation from the previous page.
    public let cursor: String?
    /// Advanced: how many seqs one scan chunk covers (bounded by the connector).
    public let chunk: Int?

    public init(address: SessionAddress, query: String, roles: [String]? = nil,
                limit: Int? = nil, cursor: String? = nil, chunk: Int? = nil) {
        self.address = address
        self.query = query
        self.roles = roles
        self.limit = limit
        self.cursor = cursor
        self.chunk = chunk
    }
}

/// One hit: where it is, what role it has, and the snippet to show.
public struct HistorySearchHit: Sendable, Codable {
    public let seq: Int
    public let role: String
    public let snippet: String
    public let highlightStart: Int
    public let highlightLength: Int

    public init(seq: Int, role: String, snippet: String, highlightStart: Int, highlightLength: Int) {
        self.seq = seq
        self.role = role
        self.snippet = snippet
        self.highlightStart = highlightStart
        self.highlightLength = highlightLength
    }
}

public struct HistorySearchValue: Sendable, Codable {
    public let hits: [HistorySearchHit]
    public let cursor: String?
    public let hasMore: Bool
    /// `index` when the deployment's full-text index answered, `scan` otherwise.
    public let source: String?
    /// 扫描式搜索的进度（连接器能力 `search-progress`）：一共要扫多少片、还剩多少片。
    ///
    /// **片**是扫描单位（`chunk` 个 seq 一段，从新往旧），不是命中页数。`totalChunks` 由日志
    /// 最新 seq 算出，所以第一页就精确；命中**条数**要扫到最老那一片才定稿。
    /// 走索引的部署不发这两个字段，此时两者为 nil——界面按"进度未知"处理，不许假装知道。
    public let totalChunks: Int?
    public let remainingChunks: Int?

    public init(hits: [HistorySearchHit], cursor: String?, hasMore: Bool, source: String? = nil,
                totalChunks: Int? = nil, remainingChunks: Int? = nil) {
        self.hits = hits
        self.cursor = cursor
        self.hasMore = hasMore
        self.source = source
        self.totalChunks = totalChunks
        self.remainingChunks = remainingChunks
    }
}

/// Where a hit lands in the transcript the reader is looking at.
///
/// A hit carries a journal `seq`; the transcript is a list of *rows*, and a row
/// owns the seq that produced it (an assistant row can be produced by a seq well
/// below a later tool result that belongs to it). The row a hit belongs to is
/// therefore the last row whose own seq is at or below the hit's; if the hit
/// precedes everything loaded, the first row is the closest thing to it.
public enum TranscriptHitLocator {
    public static func row(forSeq seq: Int, in items: [TimelineItem]) -> TimelineItem? {
        guard !items.isEmpty else { return nil }
        var candidate: TimelineItem?
        for item in items {
            if item.seq <= seq { candidate = item } else { break }
        }
        return candidate ?? items.first
    }

    /// Membership variant of `row(forSeq:in:)`: returns a row **only** when `seq`
    /// is inside the loaded window (owned by some row); `nil` when the hit lies
    /// outside. `row(forSeq:in:)` deliberately clamps out-of-window hits to the
    /// nearest edge row (its original callers wanted a landing spot, not a
    /// verdict) — using it as a membership test makes every off-window seq a
    /// false hit (009 场景⑥：搜索跳转到窗口外命中被判成"本地命中"，
    /// 换窗口拉取整段被跳过，跳转成为空操作）。
    public static func row(exactlyForSeq seq: Int, in items: [TimelineItem]) -> TimelineItem? {
        // 边界只认数据行：缺口行（含顶部合成行 `gap:0-0`，seq=0）不是内容，
        // 拿它当窗口边界会让"比窗口还旧"的判定永远成立（假命中复发）。
        let dataRows = items.filter { $0.kind.isContentRow }
        guard let first = dataRows.first, let last = dataRows.last,
              seq >= first.seq, seq <= last.seq else { return nil }
        // 归属同样只认数据行：旧实现在全量行上解析，缺口行的排序键（gap.start）
        // ≤ 命中 seq，命中落在缺口里时会解析到缺口占位行本身——跳转梯子先把
        // 视口滚到加载占位条，等真数据折叠进来再纠正，中间晃到错误位置
        //（007 用例 49 链路回归）。缺口里返回 nil，调用方（梯子 / rebase
        // waiter）按既有重试继续等，真行出现才落地。
        var candidate: TimelineItem?
        for row in dataRows {
            if row.seq <= seq { candidate = row } else { break }
        }
        guard let candidate else { return nil }
        // 同一 seq 上既有数据行又有缺口行时归数据行（数据行的拥有权优先）；
        // 否则命中落在缺口覆盖区间里 = 数据还没到，不算命中。
        if candidate.seq != seq,
           items.contains(where: { $0.kind.covers(seq: seq) }) {
            return nil
        }
        return candidate
    }

    /// Fills the phone-side row id on each hit, dropping the ones that have no row
    /// to point at (the reader has not loaded that stretch yet).
    public static func attach(hits: [HistorySearchHit], to items: [TimelineItem]) -> [TranscriptSearchHit] {
        // 同一条记录可能落进同一行（命中映射是按 seq → 行），去重后每行只留一条：
        // 列表用行 id 当身份，重复 id 会让 SwiftUI 的 `ForEach` 出现未定义渲染（少行/错行）。
        var seen = Set<String>()
        return hits.compactMap { hit in
            let role: TranscriptSearchHit.Role = switch hit.role {
            case "me": .me
            case "tool": .tool
            default: .agent
            }
            // 没有可落地的**数据行**（命中在窗口之外——浏览"我的提问"时几乎全是这样，
            // 或落在缺口里、数据还没到）：钳制版 `row(forSeq:)` 会退化成"窗口第一行"，
            // 全都会被去重成一条——那正是"列表里只剩几条"的原因；旧实现还可能把缺口
            // 占位行的 id 填给命中，点它就跳到加载占位条上。这类命中用合成身份
            //（`seq-<n>`）：列表直接显示连接器给的 snippet，点它时由
            // `ChatView.jumpToHit` 按 seq 换窗口再跳（那条路已经验过）。
            guard let row = row(exactlyForSeq: hit.seq, in: items) else {
                let synthetic = "seq-\(hit.seq)"
                guard seen.insert(synthetic).inserted else { return nil }
                return TranscriptSearchHit(id: synthetic, role: role, snippet: hit.snippet,
                                           highlightStart: hit.highlightStart,
                                           highlightLength: hit.highlightLength, seq: hit.seq)
            }
            guard seen.insert(row.id).inserted else { return nil }
            return TranscriptSearchHit(id: row.id, role: role, snippet: hit.snippet,
                                       highlightStart: hit.highlightStart,
                                       highlightLength: hit.highlightLength, seq: hit.seq)
        }
    }
}
