#if DIAGNOSTICS
import DSHFoundation
import DSHKit
import Foundation
import OSLog

/// OTA 构建专用的诊断：把 App 进程内产生的日志实时推给电脑端连接器。
///
/// 编译门：只有 `OTA` 配置带 `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DIAGNOSTICS`，
/// `Release`（TestFlight / App Store）没有这个条件，于是本文件整段不参与编译，
/// 发布包里连字符串都不存在。可靠性不靠这里的 `if`，靠发布脚本对产物的断言
/// （见 `scripts/release/deploy-ota.sh` 与 `deploy-testflight.sh`）。
///
/// 三条采集源，覆盖"任意日志"而不是"某个模块的日志"：
///   1. 统一日志（`OSLogStore`，进程范围）：`DSHLog`（NSLog）与框架写进本进程的条目；
///   2. stdout/stderr：`print`、C 库、第三方库的输出，不需要改任何调用点；
///   3. 自建环（本文件的 `LogRing`）：有序时间线与崩溃前的落盘兜底。
///
/// **性能约束（2026-10-18 真机反馈"所有 UI 操作都很慢"之后定的）**：
/// 主线程上只做「加锁、判断配额、数组 append」三件事；读统一日志、编码、写盘全部在
/// 专用后台队列上，且写盘按批（每秒一次）而不是每条一次。任何"在采集路径上做 I/O"的
/// 写法都会直接变成输入卡顿，这条约束优先于日志的实时性。
///
/// 通道：`_link/logs` 走已有的 relay 与连接器，不新增端口、不改 relay。
@MainActor
final class AppDiagnostics {
    static let shared = AppDiagnostics()

    /// 产物哨兵：发布脚本 `strings` 查它。OTA 必中，TestFlight 必不中。
    nonisolated static let sentinel = "DSHDIAG-OTA-2026-10-18"

    /// 一次推送的载荷；字段名与连接器 `lib/logs.js` 的 `normalizeEntry` 对应。
    struct Batch: Encodable, Sendable {
        let sentAt: Int
        /// 整段重推（冷启动回填或 `dsh://diag export`）：连接器不按水位去重。
        let full: Bool
        let entries: [Entry]
    }
    struct Entry: Codable, Sendable {
        let seq: Int
        let ms: Int
        let at: String
        let level: String
        let source: String
        let text: String
    }
    struct Ack: Decodable, Sendable {
        let accepted: Int
        let lastSeq: Int
    }

    private let ring = LogRing(capacity: 20_000)
    private let oslogReader = OSLogReader()
    private var started = false
    /// OTA 包默认开启；`-DSHDiagCommand off` 或 `dsh://diag/off` 可现场关闭。
    private var enabled = true
    private var captureInstalled = false
    private var pushTask: Task<Void, Never>?
    private var attachedCarrier: ObjectIdentifier?
    private var backfill = true
    /// `dsh://diag/export` 或冷启动回填剩下的批次；每批 200 条逐次推完。
    private var exportQueue: [AppDiagnostics.Entry] = []

    // MARK: - 生命周期

    /// 启动即采集（OTA 包默认开启，真机安装没有启动参数可用）。
    func start() {
        guard !started else { return }
        started = true
        ring.loadFromDisk()
        // 模块层的结构化事件（折叠、取页）从这里进环：`DSHLog.event` 只判一次空，
        // TestFlight 里 sink 为 nil，事件零成本。
        DSHLog.sink = { [ring] line in ring.append(level: "info", source: "app", text: line) }
        // 协议层的逐页耗时：系统日志在真机上没有稳定到达，直接接进环。
        SessionPipeline.traceSink = { [ring] line in ring.append(level: "info", source: "app", text: line) }
        // 真机验证入口：`xcrun devicectl device process launch … -DSHDiagCommand on`
        // 带参数拉起即可打开采集，不必在手机上点开链接、再点系统「是否打开」。
        if let command = Self.launchCommand() { perform(command: command) }
        if enabled { installCaptureIfNeeded() }
        record(level: "info", source: "diag",
               text: "\(Self.sentinel) started build=\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?") enabled=\(enabled)")
    }

    /// 连接器换了一条链路就换一个推送目标；同一个 carrier 不重启任务。
    /// 只接 carrier，不接 `DSHClient`：分层规则不允许白名单之外的文件引用实现层类型
    /// （`scripts/dev/check-layers.mjs` 的 R3），而推送只需要一次 unary 调用。
    func attachIfNeeded(_ carrier: (any DSHCarrier)?) {
        guard enabled, let carrier else { return }
        let identity = ObjectIdentifier(carrier as AnyObject)
        guard identity != attachedCarrier else { return }
        attachedCarrier = identity
        pushTask?.cancel()
        pushTask = Task { [ring] in
            var delay: UInt64 = 2
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                guard !Task.isCancelled else { return }
                // 冷启动的第一批带上一段尾部上下文（崩溃前进程留下的那些行），
                // 之后只推未确认的新增。
                let next = await MainActor.run { self.nextBatch() }
                guard !next.entries.isEmpty else { delay = 2; continue }
                let batch = Batch(sentAt: Int(Date().timeIntervalSince1970 * 1000),
                                  full: next.full, entries: next.entries)
                do {
                    let ack = try await carrier.unary(
                        method: "_link/logs", args: batch, as: Ack.self)
                    ring.markPushed(upTo: ack.lastSeq)
                    delay = 2
                } catch {
                    // 旧连接器会回 `link/unsupported`：当作无事，只放慢重试。
                    // 回填/导出的批次没确认就放回队列，别让导出被一次断网吞掉。
                    if next.full { await MainActor.run { self.requeue(next.entries) } }
                    delay = min(delay * 2, 30)
                }
            }
        }
    }

    /// 下一批要发什么：
    ///   * 导出队列没排空就继续（`full: true`，连接器不按水位去重）；
    ///   * 冷启动第一次发送带 2000 条尾部上下文，覆盖"上一个进程崩溃前"的那一段；
    ///   * 其余时间只发未确认的新增。
    private func nextBatch() -> (entries: [AppDiagnostics.Entry], full: Bool) {
        if !exportQueue.isEmpty {
            let slice = Array(exportQueue.prefix(200))
            exportQueue.removeFirst(slice.count)
            return (slice, true)
        }
        if backfill {
            backfill = false
            return (ring.pendingTail(limit: 2000), true)
        }
        return (ring.pending(limit: 200), false)
    }

    private func requeue(_ entries: [AppDiagnostics.Entry]) {
        guard exportQueue.count < 20_000 else { return }
        exportQueue.insert(contentsOf: entries, at: 0)
    }

    // MARK: - 开关与导出（`dsh://diag/...`）

    /// 返回 true 表示这个 URL 属于诊断命令，调用方不再按连接链接处理。
    func handle(url: URL) -> Bool {
        record(level: "debug", source: "diag", text: "url \(url.absoluteString)")
        guard url.scheme?.lowercased() == "dsh", url.host?.lowercased() == "diag" else { return false }
        perform(command: url.pathComponents.dropFirst().first?.lowercased() ?? "status")
        return true
    }

    /// 启动参数里的同一条命令：`-DSHDiagCommand <off|on|export|status>`。
    static func launchCommand() -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-DSHDiagCommand"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    /// 采集设施只装一次：关闭再打开时不重复 dup2 管道。
    private func installCaptureIfNeeded() {
        guard !captureInstalled else { return }
        captureInstalled = true
        installStdioCapture()
        oslogReader.start(ring: ring)
    }

    private func perform(command: String) {
        switch command {
        case "off":
            enabled = false
            pushTask?.cancel()
            pushTask = nil
            attachedCarrier = nil
            oslogReader.stop()
            DSHLog.sink = nil
            record(level: "warn", source: "diag", text: "disabled by dsh://diag/off")
        case "on":
            enabled = true
            backfill = true
            installCaptureIfNeeded()
            DSHLog.sink = { [ring] line in ring.append(level: "info", source: "app", text: line) }
        // 协议层的逐页耗时：系统日志在真机上没有稳定到达，直接接进环。
        SessionPipeline.traceSink = { [ring] line in ring.append(level: "info", source: "app", text: line) }
            record(level: "info", source: "diag", text: "enabled by dsh://diag/on")
        case "export":
            enabled = true
            exportQueue = ring.all()
            record(level: "info", source: "diag",
                   text: "export requested: \(ring.count) lines in ring")
        default:
            record(level: "info", source: "diag",
                   text: "status enabled=\(enabled) ring=\(ring.count) pending=\(ring.pendingCount) dropped=\(ring.dropped)")
        }
    }

    // MARK: - 采集

    /// 把 stdout/stderr 接到管道：任何模块的 `print` 与 C 库输出都进得来。
    /// 读管道在后台线程，写环只做加锁 append（不碰磁盘）。
    private func installStdioCapture() {
        for fd: Int32 in [STDOUT_FILENO, STDERR_FILENO] {
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { continue }
            _ = dup2(fds[1], fd)
            close(fds[1])
            // 管道不是 TTY，stdio 默认会整块缓冲：不关掉的话 `print` 要等缓冲区满才出现。
            setvbuf(fd == STDOUT_FILENO ? stdout : stderr, nil, _IONBF, 0)
            let readFD = fds[0]
            DispatchQueue.global(qos: .utility).async { [ring] in
                var buffer = [UInt8](repeating: 0, count: 4096)
                var carry = Data()
                while true {
                    let count = read(readFD, &buffer, buffer.count)
                    guard count > 0 else { return }
                    carry.append(contentsOf: buffer[0..<count])
                    while let newline = carry.firstIndex(of: 0x0A) {
                        let line = String(decoding: carry[carry.startIndex..<newline], as: UTF8.self)
                        carry.removeSubrange(carry.startIndex...newline)
                        guard !line.isEmpty else { continue }
                        // NSLog 同时写 stderr 与统一日志；这里丢掉 stderr 那份，避免每条两遍。
                        if line.contains(" DSHMobile[") && line.contains("[DSHMobile/") { continue }
                        ring.append(level: "info", source: "stdio", text: line)
                    }
                }
            }
        }
    }

    // MARK: - 写入环

    private func record(level: String, source: String, text: String, ms: Date = Date()) {
        ring.append(level: level, source: source, text: text, ms: ms)
    }
}

// MARK: - 统一日志读取（全程后台）

/// `OSLogStore` 的读取单独一个队列：它一次可以跑几百毫秒，绝不能放在主线程。
/// 每 5 秒增量读一次，最多取 300 条，避免一次接入把 CPU 占满。
final class OSLogReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dsh.diagnostics.oslog", qos: .utility)
    private var cursor = Date()
    private var failures = 0
    private var generation = 0
    private var running = false

    func start(ring: LogRing) {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.cursor = Date()
            self.generation += 1
            let generation = self.generation
            self.schedule(ring: ring, generation: generation)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.running = false
            self?.generation += 1
        }
    }

    private func schedule(ring: LogRing, generation: Int) {
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.running, self.generation == generation else { return }
            self.drain(ring: ring)
            self.schedule(ring: ring, generation: generation)
        }
    }

    private func drain(ring: LogRing) {
        guard failures < 5 else { return }
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = try store.position(date: cursor)
            var newest = cursor
            var taken = 0
            for entry in try store.getEntries(at: position) {
                guard taken < 300 else { break }
                guard let log = entry as? OSLogEntryLog else { continue }
                let text = log.composedMessage
                guard !text.isEmpty else { continue }
                taken += 1
                if log.date > newest { newest = log.date }
                ring.append(level: Self.level(for: log.level),
                            source: log.subsystem.isEmpty ? "oslog" : log.subsystem,
                            text: text, ms: log.date)
            }
            cursor = newest.addingTimeInterval(0.001)
        } catch {
            failures += 1
        }
    }

    private static func level(for type: OSLogEntryLog.Level) -> String {
        switch type {
        case .error, .fault: return "error"
        case .debug: return "debug"
        default: return "info"
        }
    }
}

// MARK: - 环与落盘

/// 有上限的内存环 + 一份滚动 JSONL。线程安全，文件写失败不抛（诊断设施不许带崩 App）。
///
/// **调用方（主线程）只做加锁与数组操作**；编码、写盘、轮转、24 小时清理都在
/// `ioQueue` 上，而且写盘按批（每秒最多一次）。`persist` 曾经是每条一次 open/write/close，
/// 真机上直接把输入卡成了幻灯片，这条教训写在这里防止回退。
final class LogRing: @unchecked Sendable {
    private let capacity: Int
    private let lock = NSLock()
    private var entries: [AppDiagnostics.Entry] = []
    private var nextSeq = 1
    private var pushed = 0
    // 限流：日志量必须被总量约束，否则一次 UIKit 的调试风暴就能把推送链路占满。
    private var sourceBudget: [String: (second: Int, count: Int)] = [:]
    private var globalSecond = 0
    private var globalCount = 0
    private(set) var droppedByBudget = 0
    private static let perSourcePerSecond = 10
    private static let globalPerSecond = 60

    // 落盘：串行队列 + 批缓冲。
    private let ioQueue = DispatchQueue(label: "dsh.diagnostics.io", qos: .utility)
    private var buffered: [Data] = []
    private var flushScheduled = false

    private let directory: URL
    private let currentFile: URL
    private let previousFile: URL
    private let maxBytes = 8 * 1024 * 1024
    /// 落盘与内存环只留最近 24 小时；清理在写入路径上，不靠定时任务。
    private let retentionMs = 24 * 60 * 60 * 1000
    private var lastCompactionAt: Date = .distantPast

    init(capacity: Int) {
        self.capacity = capacity
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("DSHDiagnostics", isDirectory: true)
        currentFile = directory.appendingPathComponent("current.jsonl")
        previousFile = directory.appendingPathComponent("previous.jsonl")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var count: Int { lock.withLock { entries.count } }
    var dropped: Int { lock.withLock { droppedByBudget } }
    var pendingCount: Int { lock.withLock { entries.count(where: { $0.seq > pushed }) } }

    /// 全部条目（最多 `capacity` 条）：`dsh://diag/export` 用。
    func all() -> [AppDiagnostics.Entry] {
        lock.withLock { entries }
    }

    /// 环里最近若干条，不论是否推过：冷启动回填用。
    func pendingTail(limit: Int) -> [AppDiagnostics.Entry] {
        lock.withLock { Array(entries.suffix(limit)) }
    }

    private static let isoFormat = Date.ISO8601FormatStyle()

    func append(level: String, source: String, text: String, ms: Date = Date()) {
        let stamp = Int(ms.timeIntervalSince1970 * 1000)
        lock.lock()
        let second = stamp / 1000
        // 自有来源（诊断通道、App 事件、协议层 page.fetch）不受全局配额约束：
        // 全局配额是给系统框架的日志风暴用的，不能把必须留痕的行一起丢掉。
        // 2026-10-18 实测：全局 60 行/秒被 UIKit/xpc 占满，`page.fetch` 一条都没留下来。
        let isOwnSource = source == "diag" || source == "app" || source.hasPrefix("com.jayanttang.")
        if !isOwnSource {
            if second == globalSecond {
                if globalCount >= Self.globalPerSecond { droppedByBudget += 1; lock.unlock(); return }
                globalCount += 1
            } else {
                globalSecond = second
                globalCount = 1
            }
        }
        if var budget = sourceBudget[source], budget.second == second {
            if budget.count >= Self.perSourcePerSecond { droppedByBudget += 1; lock.unlock(); return }
            budget.count += 1
            sourceBudget[source] = budget
        } else {
            sourceBudget[source] = (second, 1)
            if sourceBudget.count > 64 {
                sourceBudget = sourceBudget.filter { $0.value.second >= second - 1 }
            }
        }
        let entry = AppDiagnostics.Entry(
            seq: nextSeq, ms: stamp,
            at: ms.formatted(Self.isoFormat),
            level: level, source: source, text: text)
        nextSeq += 1
        entries.append(entry)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        let compacted = takeExpiredLocked(nowMs: stamp)
        lock.unlock()
        enqueue(entry)
        if let compacted { rewrite(compacted) }
    }

    func pending(limit: Int) -> [AppDiagnostics.Entry] {
        lock.withLock {
            entries.filter { $0.seq > pushed }.prefix(limit).map { $0 }
        }
    }

    func markPushed(upTo seq: Int) {
        lock.withLock { pushed = max(pushed, seq) }
    }

    /// 冷启动把上一次进程留下的尾部读回来：崩溃现场的最后一屏就在这里。
    func loadFromDisk() {
        var loaded: [AppDiagnostics.Entry] = []
        for file in [previousFile, currentFile] {
            guard let data = try? Data(contentsOf: file) else { continue }
            // 只读尾部 2MB：全读会在日志很大时把启动拖慢。
            let slice = data.count > 2 * 1024 * 1024 ? data.suffix(2 * 1024 * 1024) : data
            for line in slice.split(separator: 0x0A) {
                if let entry = try? JSONDecoder().decode(AppDiagnostics.Entry.self, from: Data(line)) {
                    loaded.append(entry)
                }
            }
        }
        let cutoff = Int(Date().timeIntervalSince1970 * 1000) - retentionMs
        let fresh = loaded.filter { $0.ms >= cutoff }
        lock.lock()
        entries = Array(fresh.suffix(capacity))
        // 序号取「文件里的下一条」与「当前毫秒」的较大者：删掉日志文件、换设备恢复
        // 备份这类情况下序号不会倒退，连接器的水位也就不会把新日志当重复丢掉。
        nextSeq = max((entries.last?.seq ?? 0) + 1, Int(Date().timeIntervalSince1970 * 1000))
        // 冷启动把「已推」清零，让尾部上下文重新过一遍连接器；连接器按序号去重，
        // 重复的那部分不会落两遍（`full` 只在回填批次里为 true）。
        pushed = 0
        lock.unlock()
        // 文件里可能还留着 24 小时以前的旧行（进程被杀时没来得及清）：启动时重写一遍。
        if fresh.count != loaded.count { rewrite(fresh) }
    }

    /// 在锁内挑出过期条目并移除；返回需要重写的快照（没有过期就是 nil）。
    /// 10 分钟内最多重写一次：重写是整文件替换，不能跟着每条日志做。
    private func takeExpiredLocked(nowMs: Int) -> [AppDiagnostics.Entry]? {
        guard let oldest = entries.first, oldest.ms < nowMs - retentionMs else { return nil }
        let now = Date(timeIntervalSince1970: Double(nowMs) / 1000)
        guard now.timeIntervalSince(lastCompactionAt) > 600 else { return nil }
        lastCompactionAt = now
        entries.removeAll { $0.ms < nowMs - retentionMs }
        return entries
    }

    // MARK: - 落盘（全部在 ioQueue 上）

    /// 入队一行并安排一次合并写盘；主线程只做一次数组 append。
    private func enqueue(_ entry: AppDiagnostics.Entry) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        var line = data
        line.append(0x0A)
        lock.lock()
        buffered.append(line)
        let schedule = !flushScheduled
        flushScheduled = true
        lock.unlock()
        guard schedule else { return }
        ioQueue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.flush() }
    }

    /// 把缓冲区攒下的行一次写进文件；轮转与 24 小时清理也在这里做。
    private func flush() {
        lock.lock()
        let lines = buffered
        buffered.removeAll(keepingCapacity: true)
        flushScheduled = false
        lock.unlock()
        guard !lines.isEmpty else { return }
        let manager = FileManager.default
        if let size = try? manager.attributesOfItem(atPath: currentFile.path)[.size] as? Int,
           size > maxBytes {
            try? manager.removeItem(at: previousFile)
            try? manager.moveItem(at: currentFile, to: previousFile)
        }
        let data = lines.reduce(into: Data()) { $0.append($1) }
        if let handle = try? FileHandle(forWritingTo: currentFile) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: currentFile)
        }
        purgePreviousIfExpired()
    }

    /// 上一次进程留下的 `previous.jsonl` 也可能是 24 小时以前的：写盘时顺手清掉。
    private func purgePreviousIfExpired() {
        guard let info = try? FileManager.default.attributesOfItem(atPath: previousFile.path),
              let modified = info[.modificationDate] as? Date else { return }
        if Date().timeIntervalSince(modified) > 24 * 60 * 60 { try? FileManager.default.removeItem(at: previousFile) }
    }

    /// 用快照整体替换当前文件（24 小时清理用）。先清缓冲，避免重写后旧行再被追加一次。
    private func rewrite(_ snapshot: [AppDiagnostics.Entry]) {
        lock.lock()
        buffered.removeAll(keepingCapacity: true)
        lock.unlock()
        ioQueue.async { [directory = directory, currentFile = currentFile, previousFile = previousFile] in
            var data = Data()
            let encoder = JSONEncoder()
            for entry in snapshot {
                guard let line = try? encoder.encode(entry) else { continue }
                data.append(line)
                data.append(0x0A)
            }
            let manager = FileManager.default
            try? manager.removeItem(at: previousFile)
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: currentFile, options: .atomic)
        }
    }
}
#endif
