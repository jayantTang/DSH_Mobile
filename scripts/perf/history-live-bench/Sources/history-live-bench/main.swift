import Foundation
import DSHKit
import DSHChatDomain

// 历史加载端到端基准（程序化，无 UI）：
//   连接器(经中转) → _link/sessionWindow → DSHKit 解码 → ChatTimeline 折叠 → 过程折叠投影
// 只走产品同一条链路与同一份数据层代码，不含 UIKit/SwiftUI。

struct Options {
    var relay = ""
    var agent = ""
    var token = ""
    var session = ""
    var rounds = 8
    var pageSize = 50
    var pagesPerFetch = 3
    var readPauseMs = 0
    var maxBytes = 256 * 1024
    var label = "default"
    var out = ""

    static func parse(_ argv: [String]) -> Options {
        var o = Options()
        var i = 1
        while i < argv.count {
            let key = argv[i]
            let value = i + 1 < argv.count ? argv[i + 1] : ""
            switch key {
            case "--relay": o.relay = value; i += 2
            case "--agent": o.agent = value; i += 2
            case "--token": o.token = value; i += 2
            case "--session": o.session = value; i += 2
            case "--rounds": o.rounds = Int(value) ?? 8; i += 2
            case "--page-size": o.pageSize = Int(value) ?? 50; i += 2
            case "--pages-per-fetch": o.pagesPerFetch = Int(value) ?? 3; i += 2
            case "--read-pause-ms": o.readPauseMs = Int(value) ?? 0; i += 2
            case "--max-bytes": o.maxBytes = Int(value) ?? 256 * 1024; i += 2
            case "--label": o.label = value; i += 2
            case "--out": o.out = value; i += 2
            default:
                FileHandle.standardError.write(Data("unknown argument \(key)\n".utf8))
                exit(2)
            }
        }
        return o
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var fetches: [[String: Any]] = []
    private var folds: [[String: Any]] = []
    func add(_ entry: [String: Any]) { lock.lock(); fetches.append(entry); lock.unlock() }
    func addFolds(_ entries: [[String: Any]]) {
        lock.lock(); folds.append(contentsOf: entries); lock.unlock()
    }
    func snapshot() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return fetches }
    func foldSnapshot() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return folds }
}

func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let idx = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
    return sorted[idx]
}

let opts = Options.parse(CommandLine.arguments)
guard let relayURL = URL(string: opts.relay) else {
    FileHandle.standardError.write(Data("bad --relay\n".utf8)); exit(2)
}
guard !opts.agent.isEmpty, !opts.token.isEmpty else {
    FileHandle.standardError.write(Data("--agent/--token required\n".utf8)); exit(2)
}

let result: [String: Any] = try await runBench(opts, relayURL)
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
if !opts.out.isEmpty {
    try data.write(to: URL(fileURLWithPath: opts.out))
}
print(String(decoding: data, as: UTF8.self))

func runBench(_ opts: Options, _ relayURL: URL) async throws -> [String: Any] {
    let carrier = LinkCarrier(
        configuration: LinkConfiguration(relayURL: relayURL, agentId: opts.agent, deviceToken: opts.token),
        timeout: .seconds(90)
    )
    let hello = try await DSHClient(carrier: carrier).linkHandshake()
    let client = DSHClient(carrier: carrier, capabilities: Set(hello.capabilities))

    // 链路 RTT：同一条连接上的最小请求（_link/hello），只反映往返，不含读页。
    var pings: [Double] = []
    for _ in 0..<5 {
        let t0 = nowMs()
        _ = try await client.linkHandshake()
        pings.append(nowMs() - t0)
    }

    let sessions = try await client.sessions()
    let candidates = sessions.items
        .filter { !$0.blank && $0.origin != "subagent" }
        .sorted { $0.asOfSeq > $1.asOfSeq }
    guard !candidates.isEmpty else {
        throw NSError(domain: "bench", code: 2, userInfo: [NSLocalizedDescriptionKey: "empty session list"])
    }
    // 先挑会话再做一次"探针读"：列表里可能有宿主自己读不动的老格式会话
    //（v0 迁移被拒），拿它当样本会让整轮基准在开屏就失败。跳过的会话如实打印。
    var summary: SessionSummary?
    let pool: [SessionSummary]
    if !opts.session.isEmpty {
        guard let hit = candidates.first(where: { $0.sessionId.contains(opts.session) }) else {
            throw NSError(domain: "bench", code: 1, userInfo: [NSLocalizedDescriptionKey: "session not in list: \(opts.session)"])
        }
        pool = [hit]
    } else {
        pool = Array(candidates.prefix(8))
    }
    for candidate in pool {
        do {
            _ = try await client.historyWindow(HistoryWindowRequest(
                address: candidate.address, before: max(1, candidate.asOfSeq + 1),
                through: nil, limit: 1, maxBytes: 64 * 1024,
                encoding: client.historyWindowEncoding))
            summary = candidate
            break
        } catch {
            FileHandle.standardError.write(Data("skip \(candidate.sessionId): \(error)\n".utf8))
        }
    }
    guard let summary else {
        throw NSError(domain: "bench", code: 3, userInfo: [NSLocalizedDescriptionKey: "no readable session in the first 8 candidates"])
    }

    let address = summary.address
    let asOf = summary.asOfSeq
    let counter = Counter()
    let maxBytes = opts.maxBytes
    let pageSize = opts.pageSize

    let fetch: SessionPipeline.PageFetch = { range, priority in
        let t0 = nowMs()
        do {
            let value = try await client.historyWindow(HistoryWindowRequest(
                address: address, before: range.upperBound + 1, through: nil,
                limit: range.count, maxBytes: maxBytes,
                encoding: client.historyWindowEncoding,
                fold: client.historyFoldEnabled ? true : nil))
            let bytes = (try? JSONEncoder().encode(value).count) ?? 0
            var byType: [String: Int] = [:]
            for record in value.records {
                byType[record.event.type, default: 0] += (try? JSONEncoder().encode(record).count) ?? 0
            }
            if let folds = value.folds, !folds.isEmpty {
                counter.addFolds(folds.map { fold in
                    ["turn": fold.turn, "start": fold.startSeq, "end": fold.endSeq,
                     "toolCount": fold.toolCount, "foldedCount": fold.foldedCount]
                })
            }
            counter.add(["start": range.lowerBound, "end": range.upperBound,
                         "priority": String(describing: priority),
                         "ms": nowMs() - t0, "payloadBytes": bytes,
                         "records": value.records.count, "ok": true, "byType": byType])
            return SessionPipeline.FetchPage(records: value.records,
                                             hasMore: value.hasMore,
                                             clamped: value.clamped ?? false)
        } catch {
            counter.add(["start": range.lowerBound, "end": range.upperBound,
                         "priority": String(describing: priority),
                         "ms": nowMs() - t0, "payloadBytes": 0,
                         "records": 0, "ok": false, "error": String(describing: error)])
            throw error
        }
    }

    let pipeline = SessionPipeline(scope: "perf", sessionId: summary.sessionId, store: nil,
                                   fetch: fetch, pageSize: pageSize, hotLimit: 100_000)

    // 打开会话：产品取最新页（.jump），随后 UI 折一次时间线。
    var timeline = ChatTimeline()
    let openLower = max(1, asOf - pageSize + 1)
    let openStart = nowMs()
    let openRecords = try await pipeline.records(in: openLower...asOf, priority: .jump)
    let openNetMs = nowMs() - openStart
    let openResetStart = nowMs()
    timeline.reset(with: openRecords)
    let openResetMs = nowMs() - openResetStart
    let openPlanStart = nowMs()
    let openPlan = TranscriptProcessFold.plan(items: timeline.items,
                                              isTurnOpen: timeline.isTurnOpen,
                                              currentTurn: timeline.currentTurn)
    let openPlanMs = nowMs() - openPlanStart
    let openVisible = TranscriptProcessFold.displayRows(openPlan, state: TranscriptFoldState())
    let openRawRows = timeline.items.count

    var rounds: [[String: Any]] = []
    var prevVisible = openVisible.count
    var prevRaw = timeline.items.count
    var totalStallMs: Double = 0

    for index in 0..<opts.rounds {
        if opts.readPauseMs > 0 {
            try? await Task.sleep(for: .milliseconds(opts.readPauseMs))
        }
        let snap = await pipeline.snapshot()
        let oldest = snap.records.map(\.event.seq).min() ?? timeline.firstSeq ?? 1
        if oldest <= 1 { break }
        let lower = max(1, oldest - pageSize * opts.pagesPerFetch)
        let t0 = nowMs()
        let records: [SessionRecord]
        do {
            records = try await pipeline.records(in: lower...(oldest - 1), priority: .userVisible)
        } catch {
            rounds.append(["index": index, "lower": lower, "oldest": oldest,
                           "error": String(describing: error), "waitMs": nowMs() - t0])
            break
        }
        let t1 = nowMs()
        let fresh = records.filter { $0.event.seq < oldest }
        let prependStart = nowMs()
        _ = timeline.prepend(older: fresh)
        let prependMs = nowMs() - prependStart
        let planStart = nowMs()
        let plan = TranscriptProcessFold.plan(items: timeline.items,
                                              isTurnOpen: timeline.isTurnOpen,
                                              currentTurn: timeline.currentTurn)
        let planMs = nowMs() - planStart
        let displayStart = nowMs()
        let visible = TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())
        let displayMs = nowMs() - displayStart
        // 折叠后的可见行：真正画在屏幕上的数据行。收起的过程节点本身不占这些字节
        // （它的成员被隐藏），展开时成员才各自出现在 visible 里。
        var visibleSeqs = Set<Int>()
        for item in visible {
            if case .processHeader = item.kind { continue }
            visibleSeqs.insert(item.seq)
        }
        var visibleBytes = 0
        var hiddenBytes = 0
        for record in fresh {
            let size = (try? JSONEncoder().encode(record).count) ?? 0
            let seq = record.event.seq
            if visibleSeqs.contains(seq) {
                visibleBytes += size
            } else {
                hiddenBytes += size
            }
        }
        let wait = t1 - t0
        let total = wait + prependMs + planMs + displayMs
        totalStallMs += total
        let rawRows = timeline.items.count
        rounds.append([
            "index": index,
            "lower": lower,
            "oldest": oldest,
            "newOldest": fresh.first?.event.seq ?? oldest,
            "records": fresh.count,
            "waitMs": wait,
            "prependMs": prependMs,
            "planMs": planMs,
            "displayMs": displayMs,
            "totalMs": total,
            "rawRows": rawRows,
            "rawDelta": rawRows - prevRaw,
            "visibleRows": visible.count,
            "visibleDelta": visible.count - prevVisible,
            "visibleBytes": visibleBytes,
            "hiddenBytes": hiddenBytes,
        ])
        prevRaw = rawRows
        prevVisible = visible.count
        if fresh.isEmpty { break }
    }

    // 同一页连续重问三次：把「网络/带宽」与「宿主+连接器读页」分开。
    var repeatMs: [Double] = []
    var repeatBytes = 0
    do {
        for _ in 0..<3 {
            let t = nowMs()
            let v = try await client.historyWindow(HistoryWindowRequest(
                address: address, before: asOf + 1, through: nil,
                limit: pageSize, maxBytes: maxBytes,
                encoding: client.historyWindowEncoding,
                fold: client.historyFoldEnabled ? true : nil))
            repeatMs.append(nowMs() - t)
            repeatBytes = (try? JSONEncoder().encode(v).count) ?? repeatBytes
        }
    } catch {
        repeatMs = []
    }

    // 展开探针：拿一条真实摘要，按 detail 请求（不带 fold）取回原事件，
    // 证明"展开"这条路径在真实链路上确实能拿回被折掉的过程行。
    var expandProbe: [String: Any] = ["available": false]
    if let fold = counter.foldSnapshot().first {
        let start = fold["start"] as? Int ?? 0
        let end = fold["end"] as? Int ?? 0
        do {
            let t = nowMs()
            let detail = try await client.historyWindow(HistoryWindowRequest(
                address: address, before: end + 1, through: nil,
                limit: max(1, end - start + 1), maxBytes: 512 * 1024,
                encoding: client.historyWindowEncoding, fold: nil))
            let inRange = detail.records.filter { $0.event.seq >= start && $0.event.seq <= end }
            expandProbe = ["available": true, "start": start, "end": end,
                           "ms": nowMs() - t,
                           "records": inRange.count,
                           "types": Array(Set(inRange.map(\.event.type))).sorted()]
        } catch {
            expandProbe = ["available": true, "start": start, "end": end,
                           "error": String(describing: error)]
        }
    }

    let fetches = counter.snapshot()
    let waits = rounds.compactMap { $0["waitMs"] as? Double }
    let totals = rounds.compactMap { $0["totalMs"] as? Double }
    let visibleDeltas = rounds.compactMap { $0["visibleDelta"] as? Int }
    let payloads = fetches.compactMap { $0["payloadBytes"] as? Int }

    return [
        "label": opts.label,
        "relay": opts.relay,
        "sessionId": summary.sessionId,
        "sessionTitle": summary.displayTitle,
        "asOfSeq": asOf,
        "capabilities": hello.capabilities,
        "connectorVersion": hello.serverVersion ?? "",
        "hostVersion": hello.hostVersion ?? "",
        "pageSize": pageSize,
        "pagesPerFetch": opts.pagesPerFetch,
        "maxBytes": maxBytes,
        "readPauseMs": opts.readPauseMs,
        "pingMs": pings,
        "pingMedianMs": percentile(pings, 0.5),
        "open": [
            "netMs": openNetMs,
            "resetMs": openResetMs,
            "planMs": openPlanMs,
            "records": openRecords.count,
            "rawRows": openRawRows,
            "visibleRows": openVisible.count,
        ],
        "rounds": rounds,
        "roundsCompleted": rounds.count,
        "waitMedianMs": percentile(waits, 0.5),
        "waitP95Ms": percentile(waits, 0.95),
        "totalMedianMs": percentile(totals, 0.5),
        "visiblePerRoundMedian": percentile(visibleDeltas.map(Double.init), 0.5),
        "fetches": fetches,
        "fetchCount": fetches.count,
        "payloadBytesMedian": percentile(payloads.map(Double.init), 0.5),
        "payloadBytesTotal": payloads.reduce(0, +),
        "totalStallMs": totalStallMs,
        "repeatPageMs": repeatMs,
        "repeatPageBytes": repeatBytes,
        "foldCount": counter.foldSnapshot().count,
        "expandProbe": expandProbe,
    ]
}
