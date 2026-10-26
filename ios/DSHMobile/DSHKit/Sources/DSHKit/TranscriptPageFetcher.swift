import Foundation

/// Turns "give me the page before seq N" into one `TranscriptPage`, over
/// whichever channel the connector actually offers (spec 007 FR-002/FR-027).
///
/// Why this lives in the protocol package and not in the chat model: choosing a
/// channel and normalising two different answers into one shape is the part that
/// can be tested without a UI, and it is where the old code went wrong — the
/// legacy channel's shortfall was "corrected" by arithmetic in the middle of the
/// view model, and when the arithmetic ran out the session was marked finished.
///
/// **Exact channel** (`history-window` capability): the connector returns a page
/// that abuts the window by construction, and `clamped` tells the phone when the
/// log was trimmed instead.
///
/// **Legacy channel**: the Host's `session/page` with the published workaround —
/// ask again with the measured shortfall, at most `maxAttempts` times. This
/// channel *cannot promise* abutment even after correcting (that is the defect
/// 007 exists for), so its pages are marked `clamped` as well. The pager then
/// accepts the gap and the app tells the reader the connector should be upgraded
/// (FR-041) instead of refusing to page forever.
public struct TranscriptPageFetcher: Sendable {

    public enum Channel: Sendable, Equatable {
        case exactWindow
        case legacyPage
    }

    public enum Failure: Error, CustomStringConvertible {
        case emptyPage
        case noProgress

        public var description: String {
            switch self {
            case .emptyPage: return "the host returned an empty history page"
            case .noProgress: return "history paging stopped making progress"
            }
        }
    }

    /// Picks the channel from the link handshake's capability list.
    public static func channel(capabilities: Set<String>) -> Channel {
        capabilities.contains("history-window") ? .exactWindow : .legacyPage
    }

    public let channel: Channel
    private let client: any ChatHosting
    private let address: SessionAddress
    private let throughSeq: Int
    private let pageSize: Int
    private let maxBytes: Int
    private let encoding: String?
    private let fold: HistoryWindowFold?
    /// Test seam: rewrites a legacy page before the shortfall correction runs.
    /// The app passes this only under the DEBUG probe flag that reproduces "the
    /// host gave back a short page" (test case 43); production passes nothing.
    private let pageFilter: (@Sendable (TranscriptPage) -> TranscriptPage)?

    public init(
        client: any ChatHosting,
        address: SessionAddress,
        throughSeq: Int,
        capabilities: Set<String>,
        pageSize: Int = 60,
        maxBytes: Int = 256 * 1024,
        pageFilter: (@Sendable (TranscriptPage) -> TranscriptPage)? = nil
    ) {
        self.client = client
        self.address = address
        self.throughSeq = throughSeq
        self.pageSize = pageSize
        self.maxBytes = maxBytes
        self.encoding = capabilities.contains(HistoryWindowWire.compressionCapability)
            ? HistoryWindowRequest.deflateRaw : nil
        self.fold = capabilities.contains(HistoryWindowWire.foldCapability) ? .v1 : nil
        self.pageFilter = pageFilter
        self.channel = Self.channel(capabilities: capabilities)
    }

    /// One page strictly older than `before`.
    public func page(before: Int) async throws -> TranscriptPage {
        switch channel {
        case .exactWindow: return try await exactPage(before: before)
        case .legacyPage: return try await legacyPage(before: before)
        }
    }

    private func exactPage(before: Int) async throws -> TranscriptPage {
        let value = try await client.historyWindow(
            HistoryWindowRequest(address: address, before: before,
                                 through: throughSeq, limit: pageSize, maxBytes: maxBytes,
                                 encoding: encoding, fold: fold)
        )
        return value.page()
    }

    /// The published workaround for `session/page`'s offset/seq mismatch: ask
    /// again with the measured shortfall. Never guesses past `maxAttempts`.
    /// 旧通道一页要得**比精确窗口小**。
    ///
    /// 旧通道的 `maxMessages` 数的是"消息条数"，实际会回 ~300 条记录（~150 行）——一次性插进
    /// 时间线时行高要过一秒才折完，"按行 id 事后锚回"追不上，读者位置会被顶走
    /// （2026-10-08 用例 50 实测：6 轮里 1–2 轮 `kept=0`）。要小一点（20 条消息 ≈ 50 行），
    /// 代价是旧通道多几次往返——它本来就是降级路径，位置不跳比省一次往返重要。
    private static let legacyMessages = 20

    private func legacyPage(before: Int) async throws -> TranscriptPage {
        var requested = before
        var lastShortfall: Int?
        for attempt in 1...TranscriptPageBoundary.maxAttempts {
            let page = try await client.sessionPage(
                SessionPageRequest(address: address, throughSeq: throughSeq,
                                   beforeSeq: requested, maxMessages: Self.legacyMessages)
            )
            guard let first = page.records.first?.event.seq, let last = page.records.last?.event.seq else {
                throw Failure.emptyPage
            }
            let raw = TranscriptPage(records: page.records, startSeq: first, endSeq: last,
                                           hasMore: page.hasMore, clamped: true)
            // The seam runs **before** the correction, so a short page injected here
            // makes the correction fire exactly as a real short page would.
            let returned = pageFilter?(raw) ?? raw
            if let next = TranscriptPageBoundary.corrected(requested: requested, returnedLast: returned.endSeq,
                                                          wanted: before),
               attempt < TranscriptPageBoundary.maxAttempts {
                lastShortfall = next - requested
                requested = next
                continue
            }
            return returned
        }
        // Only reachable when every attempt produced a correction.
        _ = lastShortfall
        throw Failure.noProgress
    }
}
