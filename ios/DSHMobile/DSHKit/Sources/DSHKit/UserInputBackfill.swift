import Foundation
import GRDB

/// T033：用户输入全量灌库（三表终局，spec 009 data-model v3）。
///
/// 冷启动后的低优先级后台任务：逐会话走 `_link/sessionWindow` 的
/// `roles:['me']` 过滤分页（连接器能力 `history-role-filter`），把**完整
/// SessionRecord** 经 `applyWrites` 同一幂等路径写进 `record` 表——不再写
/// 独立的 user_inputs 摘要表（摘要没有 source，是三表模型的脏数据来源）。
///
/// 降级语义：连接器没有 `history-role-filter` 时**跳过整个回填**（不回退到
/// 浏览模式写摘要——那会污染新模型），由调用方在探针里留痕，等连接器升级。
///
/// 账本（`meta` 键值表，key=`uinput.sync.<scope>/<sid>`，
/// value=`游标:lastSeq:时间戳`）：
/// - 距上次灌库 < `freshWindow`（24h）且会话 lastSeq 没有变大 → 整会话跳过；
/// - lastSeq 变大了 → 增量补拉：从最新一页开始，页里出现已入库的 seq 即停；
/// - 拉到 `hasMore=false`（日志最老）才算灌全，置
///   `session_state.user_inputs_synced_at` 完整性标记（data-model v3）。
///
/// 游标推进（T039）：优先用连接器的 `scanBoundary`（这次扫到哪就推到哪）——
/// roles 过滤会把整页滤空，按"最老返回记录"推进会在原地卡死；老连接器缺这个
/// 字段时退回旧口径（最老返回记录的 seq）。
public struct UserInputBackfiller: Sendable {
    /// 单页取数的最长等待（秒）。回包丢失/链路挂起时回填不能永远挂着——
    /// 挂住的会话会永远标不上「灌全」，「我问过的」就一直缺（OTA 实测类）。
    let pageTimeout: TimeInterval

    /// 一页窗口拉取：`before == nil` 表示从最新开始（开区间上界 .max）。
    public typealias PageFetch = @Sendable (_ before: Int?) async throws -> HistoryWindowValue

    /// 某会话的灌库账本（meta 键值的投影）。`resumeCursor` 是上次没灌完时的
    /// 续拉锚点（下一页的 before），灌全了为 nil。
    public struct State: Sendable, Equatable {
        public let pulledAt: Date
        public let lastSeq: Int
        public let resumeCursor: Int?

        public init(pulledAt: Date, lastSeq: Int, resumeCursor: Int? = nil) {
            self.pulledAt = pulledAt
            self.lastSeq = lastSeq
            self.resumeCursor = resumeCursor
        }
    }

    /// 一页取数超时（回包丢失/链路挂起的兜底）。
    enum BackfillError: Error { case pageTimeout }

    public enum Outcome: Sendable, Equatable {
        /// 24h 内灌过且 lastSeq 没变，整会话跳过。
        case skippedFresh
        /// 连接器没有 `history-role-filter`：跳过（不写任何东西），等升级。
        case unsupported
        /// 拉了 `pages` 页，入库 `rows` 条（含幂等 replace）。
        case pulled(pages: Int, rows: Int)
    }

    /// 一次灌库扫描的收束状态（`pull` 的返回值）。
    private struct Pull: Sendable {
        var pages = 0
        var rows = 0
        /// 没灌全时的续拉锚点（下一页的 before）。
        var resume: Int?
        /// 本轮没有更多要拉（增量已接上上次的地盘）。
        var done = false
        /// 真的扫到日志开头（`hasMore == false`）。
        var reachedStart = false
    }

    let store: MessageStore
    let now: @Sendable () -> Date
    /// 连接器是否支持 `_link/sessionWindow` 的 roles 过滤。
    let roleFilterSupported: Bool
    /// 距上次灌库多久内算「新鲜」。默认 24h，测试可注入。
    let freshWindow: TimeInterval
    /// 单会话最多拉多少页（防失控）。
    let maxPages: Int

    public init(store: MessageStore, now: @escaping @Sendable () -> Date = Date.init,
                roleFilterSupported: Bool = true,
                freshWindow: TimeInterval = 24 * 3600, maxPages: Int = 100,
                pageTimeout: TimeInterval = 45) {
        self.store = store
        self.now = now
        self.roleFilterSupported = roleFilterSupported
        self.freshWindow = freshWindow
        self.maxPages = maxPages
        self.pageTimeout = pageTimeout
    }

    /// 灌一个会话。`lastSeq` 是列表已知的最新游标（host asOfSeq 或磁盘 newestSeq）。
    public func backfill(
        scope: String, sessionId: String, lastSeq: Int, fetch: @escaping PageFetch
    ) async throws -> Outcome {
        // 降级：老连接器给不出归类过的完整记录，浏览模式的摘要写进 record 就是
        // 脏数据（没有 source）。宁可不灌，等连接器升级。
        guard roleFilterSupported else { return .unsupported }
        let previous = try await store.userInputSyncState(scope: scope, sessionId: sessionId)
        if let previous,
           now().timeIntervalSince(previous.pulledAt) < freshWindow,
           previous.lastSeq >= lastSeq {
            return .skippedFresh
        }
        let pull = try await collect(scope: scope, sessionId: sessionId,
                                     from: previous?.resumeCursor, fetch: fetch)
        try await store.saveUserInputSyncState(
            scope: scope, sessionId: sessionId,
            state: State(pulledAt: now(), lastSeq: max(lastSeq, previous?.lastSeq ?? 0),
                         resumeCursor: pull.done ? nil : pull.resume))
        // 完整性标记只在真的扫到日志开头时置（T039）：碰到已入库 seq 只是「接上了
        // 上次的地盘」，没灌全的会话（浏览路径可能先写过半截记录）不许就此宣布完整。
        if pull.reachedStart {
            try await store.setUserInputsSyncedAt(scope: scope, sessionId: sessionId, at: now())
        }
        return .pulled(pages: pull.pages, rows: pull.rows)
    }

    /// 一页一页往回拉，直到灌全、页数打满或游标推不动。
    /// 给一页取数加最长等待：超时抛错，回填器按「失败不记账、下次重试」的
    /// 既有语义处理（页挂起不再把整会话灌库拖死）。取数本体是外部注入的闭包，
    /// 这里统一包，调用点不用再各自处理。
    private func withPageTimeout<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(pageTimeout * 1_000_000_000))
                throw BackfillError.pageTimeout
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw BackfillError.pageTimeout }
            return value
        }
    }

    private func collect(
        scope: String, sessionId: String, from anchor: Int?, fetch: @escaping PageFetch
    ) async throws -> Pull {
        // 增量锚点：此前灌过的最大 seq（record 表里的 me 子集）。全新会话为 0。
        let knownMax = try await store.maxUserInputSeq(scope: scope, sessionId: sessionId) ?? 0
        // 「碰到已入库的 seq 即停」只对**已灌全过**的会话成立；没灌全时 record 表里
        // 可能只有浏览路径顺手写下的半截记录，碰到它们就收工等于把不完整的子集
        // 当成完整的（T039），所以那种情况继续往下扫到日志开头。
        let alreadySynced = try await store.userInputsSyncedAt(scope: scope, sessionId: sessionId) != nil
        var pull = Pull(resume: anchor)
        var before = anchor
        while true {
            let cursor = before
            let value = try await withPageTimeout { try await fetch(cursor) }
            pull.pages += 1
            if !value.records.isEmpty {
                pull.rows += value.records.count
                try await store.applyWrites([
                    .upsertRecords(scope: scope, sessionId: sessionId, records: value.records),
                ])
                if alreadySynced, value.records.contains(where: { $0.event.seq <= knownMax }) {
                    pull.done = true
                    break
                }
            }
            // 下一页的 before：连接器的扫描边界优先（整页被滤空也照样前进），
            // 缺字段时退回「最老返回记录的 seq」；两者都没有就停在原锚点重拉。
            let next = value.scanBoundary ?? value.startSeq ?? before
            if !value.hasMore {
                pull.resume = next
                pull.done = true
                pull.reachedStart = true
                break
            }
            guard pull.pages < maxPages, let advanced = next, advanced < (before ?? Int.max) else {
                pull.resume = next
                break
            }
            pull.resume = advanced
            before = advanced
        }
        return pull
    }
}

extension MessageStore {

    /// meta 键：某会话的灌库账本（internal：MessageStore+Maintenance 的 clear 也用）。
    static func syncKey(scope: String, sessionId: String) -> String {
        "uinput.sync.\(scope)/\(sessionId)"
    }

    /// 读某会话的灌库账本；nil = 从没灌过。value 形如 `游标:lastSeq:时间戳`
    /// （游标为 `-` 表示已灌全）。
    public func userInputSyncState(
        scope: String, sessionId: String
    ) async throws -> UserInputBackfiller.State? {
        try await pool.read { db in
            guard let value = try String.fetchOne(
                db, sql: "SELECT value FROM meta WHERE key = ?",
                arguments: [Self.syncKey(scope: scope, sessionId: sessionId)])
            else { return nil }
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3,
                  let lastSeq = Int(parts[1]),
                  let timestamp = Double(parts[2])
            else { return nil }  // 账本损坏当作没灌过（缓存语义，重灌即可）
            return UserInputBackfiller.State(
                pulledAt: Date(timeIntervalSince1970: timestamp),
                lastSeq: lastSeq,
                resumeCursor: Int(parts[0]))
        }
    }

    /// 写灌库账本（整会话灌完或增量补拉完成后各记一次）。
    public func saveUserInputSyncState(
        scope: String, sessionId: String, state: UserInputBackfiller.State
    ) async throws {
        let cursor = state.resumeCursor.map(String.init) ?? "-"
        try await pool.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
                arguments: [Self.syncKey(scope: scope, sessionId: sessionId),
                            "\(cursor):\(state.lastSeq):\(state.pulledAt.timeIntervalSince1970)"])
        }
    }

    /// 本地已灌的最大 seq（增量补拉的锚点），归类口径与 `userInputRecords` 一致；
    /// nil = 空库。
    ///
    /// 排除 pending：未确认的上行消息带的是本机合成键（`Int.max` 起递减），算进
    /// MAX 会把锚点顶到天花板，`collect` 的「碰到已入库 seq 即停」对第一页恒成立，
    /// 增量补拉因此只拉一页就收工（`MessageStore.sessionContent()` 的注释）。
    func maxUserInputSeq(scope: String, sessionId: String) async throws -> Int? {
        try await pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT MAX(seq) FROM record
                WHERE scope = ? AND session_id = ?
                  AND \(MessageStore.sessionContent()) AND role = 'me'
                  AND COALESCE(source_kind, 'user') = 'user'
                  AND (source_id IS NULL OR source_id NOT LIKE 'agent-%')
                """, arguments: [scope, sessionId])
        }
    }

    /// 完整性标记：该会话的用户输入子集已灌全（data-model v3，
    /// 「子集是否灌全看这个标记，不能从表内容推断」）。
    public func setUserInputsSyncedAt(scope: String, sessionId: String, at date: Date) async throws {
        try await pool.write { db in
            // upsert 而非裸 UPDATE：零提问、磁盘一条记录都没有的会话没有
            // session_state 行（2026-10-11 实测：那种会话标记永远写不上，
            // 面板就一直显示「同步中…」）。新建的行只有标记有值，其余列为
            // NULL/默认——列表摘要读 last_snippet（NULL 不加行）、预取读
            // newest_seq（NULL 时回退 host 的 asOfSeq），都不会被这行影响。
            try db.execute(sql: """
                INSERT INTO session_state
                  (scope, session_id, last_opened, has_more, unread_count,
                   ranges_json, user_inputs_synced_at)
                VALUES (?, ?, ?, 1, 0, '[]', ?)
                ON CONFLICT(scope, session_id) DO UPDATE SET
                  user_inputs_synced_at = excluded.user_inputs_synced_at
                """, arguments: [scope, sessionId, date.timeIntervalSince1970,
                                 date.timeIntervalSince1970])
        }
    }

    /// 读完整性标记（测试与读侧用）；nil = 未灌全/没灌过。
    public func userInputsSyncedAt(scope: String, sessionId: String) async throws -> Date? {
        try await pool.read { db in
            try Double.fetchOne(db, sql: """
                SELECT user_inputs_synced_at FROM session_state
                WHERE scope = ? AND session_id = ?
                """, arguments: [scope, sessionId]).map { Date(timeIntervalSince1970: $0) }
        }
    }
}
