import Foundation

/// 消息数据层的宿主（spec 009 / 023 的 S4-1：搬进 DSHKit 的门面数据能力）。
///
/// 持有进程级唯一的 `MessageStore`（GRDB 磁盘层）与 `MessagePipeline`（内存层枢纽），
/// 列表冷启动叠加、预取瀑布、进会话首帧都从这一个实例取数。网络面（按页拉取）
/// 通过注入的 client 闭包现取，重连换了 carrier 不用重建管道。
///
/// **搬进 DSHKit 时动了什么**：把三处 App 侧依赖改成注入的 `Probes`——
/// 探针落盘（原来是 `ViewportProbe.note`）、故障注入的开关与配额（原来是
/// `PageFailureInjector` / `ProbeVariants`）。逻辑一行没改；App 侧只剩一个
/// 把这几样接起来的工厂（`MessageLayer.withAppProbes()`）。
@MainActor
public final class MessageLayer {

    /// App 侧接进来的探针与故障注入。
    ///
    /// 全部默认关闭：生产构建下这套东西不产生任何行为，也不需要 App 提供实现。
    public struct Probes: Sendable {
        /// 探针落盘（`await`，因为 App 那侧是 `@MainActor`）。
        public typealias Sink = @Sendable (_ kind: String,
                                           _ fields: [String: String],
                                           _ force: Bool) async -> Void
        /// 这一次用户驱动的取页要不要注入失败。
        public var failPageShouldInject: @Sendable () -> Bool
        /// 空回包注入的剩余配额（`-DSHProbeEmptyPage <n>`）。
        public var emptyPageAttempts: Int
        /// 失败注入是否已进入"驱动开始之后"的窗口（`-DSHProbeFailPageOnDrive`）。
        public var failPageArmed: @Sendable () -> Bool
        public var note: Sink

        public init(failPageShouldInject: @escaping @Sendable () -> Bool = { false },
                    emptyPageAttempts: Int = 0,
                    failPageArmed: @escaping @Sendable () -> Bool = { true },
                    note: @escaping Sink = { _, _, _ in }) {
            self.failPageShouldInject = failPageShouldInject
            self.emptyPageAttempts = emptyPageAttempts
            self.failPageArmed = failPageArmed
            self.note = note
        }
    }

    /// 拉取/发送失败原因。预取路径对失败一律静默（磁盘只是缓存，取用失败即拉取
    /// 兜底），这里只为让调试日志可读。
    public enum FetchFailure: Error {
        /// 链接未建立：预取整体跳过，不刷日志（tasks T011 的硬要求）。
        case notConnected
        /// 该会话没有注册过拉取地址（不在当前列表里）。
        case noAddress
    }

    /// 会话 id → 拉取地址。subagent 会话的地址需要父 id 与 mode，只能从列表行的
    /// `SessionSummary` 推导，所以由列表/会话侧注册。`@Sendable` 的 fetch 闭包不能
    /// 挂 MainActor，地址簿自带锁。
    public final class AddressBook: @unchecked Sendable {
        private var table: [String: SessionAddress] = [:]
        private let lock = NSLock()

        public init() {}

        public func register(_ summaries: [SessionSummary]) {
            lock.lock()
            defer { lock.unlock() }
            for summary in summaries {
                table[summary.sessionId] = summary.address
            }
        }

        public func address(for sessionId: String) -> SessionAddress? {
            lock.lock()
            defer { lock.unlock() }
            return table[sessionId]
        }
    }

    public let addresses = AddressBook()
    public private(set) var store: MessageStore?
    public private(set) var pipeline: MessagePipeline?
    /// attach 时注入的 client 现取闭包，T024 灌库也要用（重连后自动换 carrier）。
    private var clientProvider: (@Sendable () -> DSHClient?)?
    private let probes: Probes
    /// DEBUG 故障注入：前 N 次**往更早方向**的取页回空包（`-DSHProbeEmptyPage <n>`）。
    /// release 恒 0（`Probes.emptyPageAttempts` 默认 0）。
    private let emptyPages: EmptyPageInjector

    public init(probes: Probes = Probes()) {
        self.probes = probes
        self.emptyPages = EmptyPageInjector(remaining: probes.emptyPageAttempts)
    }

    /// 注册一批会话的拉取地址（列表刷新后、进会话前各喂一次）。
    public func registerAddresses(_ summaries: [SessionSummary]) {
        addresses.register(summaries)
    }

    /// 懒建磁盘层与内存层（各一次，进程级复用）。`client` 每次调用现取：
    /// 未连接时 fetch 抛 `notConnected`，预取方按"跳过"处理。
    public func attach(client: @escaping @Sendable () -> DSHClient?) {
        clientProvider = client
        if store == nil {
            // 磁盘层建不起来（如存储被拒）时整套 009 叠加自动缺位，
            // 列表/会话都回退到现有行为——不劣于现状。
            store = try? MessageStore()
        }
        guard let store, pipeline == nil else { return }
        let addresses = self.addresses
        // T028：`-DSHProbeFailPage` 重接到 009 链路——包在 PageFetch 外层，
        // 前 N 次取页直接抛错，驱动慢闸场景③（断网缺口失败重试）。
        let emptyPages = self.emptyPages
        let probes = self.probes
        // T026：热窗口按 spec 裁决的 500 条裁剪（US2 期间为避免淘汰后回看
        // 静默丢行临时放宽到 5000；空白带根因——磁盘水合不发 diff——已在
        // SessionPipeline 修复，这里调回预算值）。
        pipeline = MessagePipeline(
            store: store,
            fetchFactory: { ref in
                { range, priority in
                    // T041：空回包注入（`-DSHProbeEmptyPage`）。方向只认热窗口：
                    // 请求区间落在最新 seq 之下（更早方向）才吃配额；往更新方向
                    // 探空是产品语义里的正常形态，不许被打成失败。
                    if await emptyPages.shouldEmpty(page: range,
                                                    hotNewest: emptyPages.hotNewest(for: ref),
                                                    priority: priority) {
                        await probes.note("pager.empty.injected", [
                            "start": String(range.lowerBound), "end": String(range.upperBound),
                        ], true)
                        return SessionPipeline.FetchPage(records: [], hasMore: true, clamped: false)
                    }
                    // 只对用户驱动的取页注入失败：预取/冷启动吃配额会让慢闸
                    // 场景③永远等不到可见失败（007 的 PageFailureInjector 头注）。
                    // failPageArmed：带 -DSHProbeFailPageOnDrive 时再等驱动开始，
                    // 打开阶段的可见取页按竞争拿优先级，会随机吃掉配额（用例 48）。
                    if priority == .userVisible, probes.failPageArmed(),
                       probes.failPageShouldInject() {
                        throw PageFailureInjected()
                    }
                    guard let client = client() else { throw FetchFailure.notConnected }
                    guard let address = addresses.address(for: ref.sessionId) else {
                        throw FetchFailure.noAddress
                    }
                    // 017：每一页都留一条可核诊断——是预取还是读者触发、这次网络花了多久。
                    // SC-001（读者到达前本地已有内容）与 SC-003（预取有界）都靠它判。
                    let started = Date()
                    do {
                        // `before` 是开区间上界：页必须结束在 before-1，正好盖住 range。
                        let value = try await client.historyWindow(HistoryWindowRequest(
                            address: address, before: range.upperBound + 1, through: nil,
                            limit: range.count, maxBytes: 256 * 1024))
                        await Self.noteFetch(probes, priority: priority, range: range,
                                             started: started, records: value.records.count)
                        return SessionPipeline.FetchPage(
                            records: value.records, hasMore: value.hasMore,
                            clamped: value.clamped ?? false)
                    } catch {
                        await Self.noteFetch(probes, priority: priority, range: range,
                                             started: started, records: nil, failure: error)
                        throw error
                    }
                }
            },
            // T022 上行：requestId 就是管道给的 clientId（同一套稳定 UUID，
            // 不并存第二套身份）——host 把它落在 durable 消息的 source.rpcId 上，
            // 确认走下行回流（follow → SessionPipeline → rpcId 命中原地替换），
            // 所以这里受理即返回 nil，不伪造回包。附件发送不走这里（见 ChatModel）。
            sender: { ref, text, clientId, steer in
                guard let client = client() else { throw FetchFailure.notConnected }
                try await client.prompt(SessionPromptRequest(
                    requestId: clientId.uuidString,
                    sessionId: ref.sessionId,
                    mode: steer ? .steer : .queue,
                    content: [.text(text)]))
                return nil
            },
            // T022 重发去重：崩溃前可能确认了没落库。重发前按 clientId 对服务端
            // 最新页查一次（safeMaxBefore 即最新；Int.max 过不了连接器的 JS 安全整数校验，T036），已有则只替换不重发。
            confirmationLookup: { ref, clientId in
                guard let client = client(),
                      let address = addresses.address(for: ref.sessionId) else { return nil }
                let value = try? await client.historyWindow(HistoryWindowRequest(
                    address: address, before: HistoryWindowRequest.safeMaxBefore, limit: 50, maxBytes: 256 * 1024))
                return value?.records.first { record in
                    guard case .userMessage(let message) = ChatEventDecoder.decode(record.event)
                    else { return false }
                    return message.isFromHuman && message.rpcId == clientId.uuidString
                }
            },
            hotLimit: 500
        )
        // 注入器要现读热窗口判方向，而管道是它自己创建之后才存在的：这里补一次绑定
        //（弱引用，不把 MessageLayer 挂在自身管道的闭包上）。
        if let pipeline { emptyPages.bind(pipeline: pipeline) }
    }


    /// 一页取回的诊断（成功与失败共用一份字段格式）。
    ///
    /// 原来这两条 `note` 各写一遍字段，漏一个就会让"预取有界"的判读少一列；
    /// 合并成一处之后字段只有一份。
    private static func noteFetch(_ probes: Probes,
                                  priority: SessionPipeline.FetchPriority,
                                  range: ClosedRange<Int>,
                                  started: Date,
                                  records: Int?,
                                  failure: (any Error)? = nil) async {
        var fields: [String: String] = [
            "source": priority.name,
            "start": String(range.lowerBound),
            "end": String(range.upperBound),
            "ms": String(Int(Date().timeIntervalSince(started) * 1000)),
        ]
        if let records {
            fields["records"] = String(records)
            fields["ok"] = "1"
        } else {
            fields["ok"] = "0"
            if let failure { fields["reason"] = String(describing: failure) }
        }
        await probes.note("pager.fetch", fields, true)
    }

    // MARK: - T033 用户输入灌库（三表终局，spec 009 data-model v3）

    /// 冷启动预取瀑布之后的低优先级任务：逐会话走 `_link/sessionWindow` 的
    /// `roles:['me']` 过滤分页，把**完整记录**灌进 `record` 表（与浏览落库同一
    /// 幂等路径，不再写独立摘要表）。
    ///
    /// 连接器没有 `history-role-filter` 能力时整体跳过（降级回浏览模式会拿到
    /// 没有 source 的摘要，写进 record 就是脏数据——宁可不灌，等连接器升级）。
    /// 刻意**串行**：灌库是缓存行为，不许和读者正在用的拉取抢隧道（连接器对
    /// 同会话并发窗口读也直接回 `link/busy`）。未连接、磁盘层缺位、地址未注册
    /// 都静默跳过；去重与增量判定全在 `UserInputBackfiller`。
    /// 一次冷启动最多花多少页 / 多少秒在后台灌库上。
    ///
    /// 为什么要有预算：以前这里是"按列表顺序遍历**全部**会话"，重装后账本为空就是 437 个会话
    /// 一路扫下去（实测后台要跑几十秒到几十分钟）。改成"只预热活跃的十来个 + 每轮有硬上限"：
    /// 常用会话照旧"点开即完整"，其余交给按需灌（`backfillUserInput`，见下），
    /// 后台流量不再无上限。
    public static let warmupPageBudget = 200
    public static let warmupTimeBudget: TimeInterval = 60

    public func backfillUserInputs(scope: String, summaries: [SessionSummary],
                                   roleFilterSupported: Bool,
                                   pageBudget: Int = MessageLayer.warmupPageBudget,
                                   timeBudget: TimeInterval = MessageLayer.warmupTimeBudget) async {
        guard let store, let client = clientProvider?() else { return }
        guard roleFilterSupported else {
            await probes.note("userinputs.backfill.degraded", [
                "reason": "connector-missing-history-role-filter",
            ], true)
            return
        }
        let backfiller = UserInputBackfiller(store: store)
        let startedAt = Date()
        var pagesUsed = 0
        var sessionsDone = 0
        for summary in summaries {
            // 预算用尽就收工：剩下的等下一次冷启动，或由用户打开面板时按需补。
            guard pagesUsed < pageBudget, Date().timeIntervalSince(startedAt) < timeBudget else {
                await probes.note("userinputs.backfill.budget", [
                    "sessions": String(sessionsDone), "pages": String(pagesUsed),
                    "remaining": String(summaries.count - sessionsDone),
                    "seconds": String(format: "%.1f", Date().timeIntervalSince(startedAt)),
                ], true)
                return
            }
            guard let address = addresses.address(for: summary.sessionId) else { continue }
            let lastSeq = summary.asOfSeq
            guard lastSeq > 0 else { continue }
            do {
                let outcome = try await backfiller.backfill(
                    scope: scope, sessionId: summary.sessionId, lastSeq: lastSeq) { before in
                        try await client.historyWindow(HistoryWindowRequest(
                            address: address, before: before ?? HistoryWindowRequest.safeMaxBefore,
                            limit: 200, maxBytes: 256 * 1024, roles: ["me"]))
                    }
                if case .pulled(let pages, let rows) = outcome {
                    pagesUsed += pages
                    sessionsDone += 1
                    await probes.note("userinputs.backfill", [
                        "session": summary.sessionId,
                        "pages": String(pages), "rows": String(rows),
                    ], true)
                } else {
                    sessionsDone += 1
                }
            } catch {
                // 失败不记账（backfiller 语义），下次冷启动重试；不刷错误，
                // 但留探针——「灌库静默全挂」曾经只有加临时埋点才看得见（T036）。
                await probes.note("userinputs.backfill.error", [
                    "session": summary.sessionId,
                    "error": String(describing: error),
                ], true)
                continue
            }
        }
    }

    /// 灌**一个**会话（按需路径，(a)）。
    ///
    /// 触发点是会话内搜索面板切到「只看我的提问」：那里已经有"同步中…"一等状态与 1.5 秒轮询，
    /// 所以这里只要把这一会话的灌库跑起来，面板会自己从"同步中"翻到完整。不做预算——用户此刻
    /// 就在等这一个会话，而 A2 之后单会话实测 0.3–1.1 秒（连接器 `readSession` 快照一次读完）。
    @discardableResult
    public func backfillUserInput(scope: String, sessionId: String, lastSeq: Int,
                                  roleFilterSupported: Bool) async -> Bool {
        guard let store, let client = clientProvider?() else { return false }
        guard roleFilterSupported else {
            await probes.note("userinputs.backfill.degraded", [
                "reason": "connector-missing-history-role-filter", "onDemand": "1",
            ], true)
            return false
        }
        guard lastSeq > 0, let address = addresses.address(for: sessionId) else { return false }
        let backfiller = UserInputBackfiller(store: store)
        do {
            let outcome = try await backfiller.backfill(scope: scope, sessionId: sessionId, lastSeq: lastSeq) { before in
                try await client.historyWindow(HistoryWindowRequest(
                    address: address, before: before ?? HistoryWindowRequest.safeMaxBefore,
                    limit: 200, maxBytes: 256 * 1024, roles: ["me"]))
            }
            if case .pulled(let pages, let rows) = outcome {
                await probes.note("userinputs.backfill", [
                    "session": sessionId, "pages": String(pages), "rows": String(rows), "onDemand": "1",
                ], true)
            }
            return true
        } catch {
            await probes.note("userinputs.backfill.error", [
                "session": sessionId, "error": String(describing: error), "onDemand": "1",
            ], true)
            return false
        }
    }
}
