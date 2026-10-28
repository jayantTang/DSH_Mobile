import Foundation

/// 连接器的链路与设备生命周期流水（`lib/journal.js`）在 App 侧的对应物。
///
/// 职责（与连接器那份**同构**，上限口径也只有一套）：
///   * 有界事件环（条数上限）——供 App 内查看与增量导出；
///   * JSONL 落盘（单文件上限 × 两代，跨启动先看现有大小再滚动）——App 被系统杀掉后记录还在；
///   * 单调序号 + 增量导出——只把"还没推给连接器"的条目交出去，单批有上限。
///
/// **硬约束**：任何一步失败都不许影响连接与同步。写失败记一次然后闭嘴，调用方永远拿到结果而不是异常。
///
/// 契约：`docs/diagnostics-events.md`、
///       `specs/020-link-diagnostics/contracts/connector-diagnostics-method.md`
public actor LinkDiagnostics {
    /// 环容量（条）。
    static let ringLimit = 200
    /// 单文件上限（字节）。
    public static let maxBytes = 128 * 1024
    /// 单批导出上限（字节），与契约 §1 的 `args.events` 对齐。
    public static let batchBytes = 32 * 1024

    /// 一条诊断事件（信封见契约 §1；`detail` 里的键随 `kind` 定）。
    public struct Event: Codable, Sendable, Equatable {
        public var seq: Int
        public var at: String
        public var ms: Int
        public var kind: String
        public var detail: [String: JSONValue]?

        public init(seq: Int, at: String, ms: Int, kind: String, detail: [String: JSONValue]? = nil) {
            self.seq = seq
            self.at = at
            self.ms = ms
            self.kind = kind
            self.detail = detail
        }
    }

    private struct State: Codable {
        var seq: Int
        var pushedUpTo: Int
        var dropped: Int
    }

    /// 打开日志文件的结果。init 里不能用实例方法（actor 的 init 是 nonisolated），
    /// 所以磁盘那几步都做成不碰实例状态的 static，由 init 把结果装进属性。
    private struct LogFile {
        var handle: FileHandle?
        var bytes: Int
        var disabled: Bool
        var errors: Int
    }

    /// 落盘目录；`nil` 表示只留内存（单测与"不想落盘"的宿主）。
    public let directory: URL?
    private let limit: Int
    private let maxBytes: Int
    private let batchBytes: Int
    private let now: @Sendable () -> Int

    private var ring: [Event] = []
    private var handle: FileHandle?
    private var bytes = 0
    private var fileDisabled = false

    public private(set) var seq = 0
    public private(set) var dropped = 0
    public private(set) var fileErrors = 0
    public private(set) var pushedUpTo = 0

    /// - Parameters:
    ///   - directory: 落盘目录（`nil` = 只留内存）。生产是 App 容器的 `Application Support`。
    ///   - now: 取时刻（测试注入）。
    ///   - limit / maxBytes: 上限，测试注入小值以便覆盖滚动。
    public init(directory: URL? = nil,
                now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970 * 1000) },
                limit: Int = 200,   // = `ringLimit`（内部常量，默认参数只能用字面量）
                maxBytes: Int = LinkDiagnostics.maxBytes,
                batchBytes: Int = LinkDiagnostics.batchBytes) {
        self.directory = directory
        self.now = now
        self.limit = max(1, limit)
        self.maxBytes = max(1024, maxBytes)
        self.batchBytes = max(1, batchBytes)
        guard let directory else { return }
        let state = Self.readState(directory)
        seq = state?.seq ?? 0
        pushedUpTo = state?.pushedUpTo ?? 0
        dropped = state?.dropped ?? 0
        ring = Self.readTail(directory, limit: self.limit)
        let log = Self.openLog(directory)
        handle = log.handle
        bytes = log.bytes
        fileDisabled = log.disabled
        fileErrors = log.errors
    }

    /// 日志文件（供采集侧读取与排查）。
    public var logURL: URL? {
        directory?.appendingPathComponent("link-diagnostics.jsonl")
    }

    /// 记一条。**永不抛**：写失败只记一次 `fileErrors` 并停手。
    @discardableResult
    public func record(kind: String, detail: [String: JSONValue] = [:]) -> Event {
        seq += 1
        let ms = now()
        let event = Event(seq: seq, at: Self.isoString(ms), ms: ms, kind: kind,
                          detail: detail.isEmpty ? nil : detail)
        ring.append(event)
        while ring.count > limit {
            ring.removeFirst()
            dropped += 1
        }
        append(event)
        saveState()
        return event
    }

    /// 环里现有的全部条目（副本，最旧在前）。
    public func entries() -> [Event] { ring }

    /// 还没推给连接器的条目；单批不超过 `batchBytes`。
    public func pending() -> [Event] {
        var batch: [Event] = []
        var size = 0
        for event in ring where event.seq > pushedUpTo {
            let cost = Self.encodedSize(event)
            if !batch.isEmpty, size + cost > batchBytes { break }
            batch.append(event)
            size += cost
        }
        return batch
    }

    // MARK: - 阶段（拨号起点与首个交互）

    /// 拨号起点（epoch 毫秒）。`app.*.elapsedMs` 全部相对它算。
    private var dialAtMs: Int?

    /// 记下这次拨号的起点（由 `LinkCarrier.openSocket` 在 `resume()` 前调用），
    /// 并开启一个新的"首交互/首屏"周期。
    public func markDialStart(_ ms: Int? = nil) {
        dialAtMs = ms ?? now()
        beginDialCycle()
    }

    /// 距拨号起点多少毫秒；还没拨过号就是 `nil`（不编 0）。
    public func elapsedSinceDial() -> Int? {
        guard let dialAtMs else { return nil }
        return now() - dialAtMs
    }

    /// 首个数据交互是否已经发出去过（每个 carrier 生命周期内一次）。
    private var firstInteractionSent = false

    /// 记「首个数据请求发出」。**只有第一次**返回 true 并落一条 `app.first-request`。
    public func beginInteraction(method: String) -> Bool {
        guard !firstInteractionSent else { return false }
        firstInteractionSent = true
        var detail: [String: JSONValue] = ["method": .string(method)]
        if let elapsed = elapsedSinceDial() { detail["elapsedMs"] = .int(elapsed) }
        record(kind: "app.first-request", detail: detail)
        return true
    }

    /// 首个交互是否已经收尾（`app.first-response` 只该有一条）。
    private var firstInteractionCompleted = false

    /// 记一次交互收尾：每次都留一条 `app.request`（环有上限兜底），
    /// 首个交互再补一条 `app.first-response`（阶段阶梯要它）。
    ///
    /// `ok` 是必需的：`bytes: 0` 既可能是"失败"，也可能是"成功但响应为空"，
    /// 不写 `ok` 这两种情况在包内分不开（现场诊断时发现的缺口）。
    public func endInteraction(method: String, elapsedMs: Int, bytes: Int,
                               ok: Bool = true, errorCode: String? = nil) {
        var detail: [String: JSONValue] = [
            "method": .string(method), "elapsedMs": .int(elapsedMs), "bytes": .int(bytes), "ok": .bool(ok),
        ]
        if !ok, let errorCode { detail["error"] = .string(String(errorCode.prefix(120))) }
        record(kind: "app.request", detail: detail)
        guard firstInteractionSent, !firstInteractionCompleted else { return }
        firstInteractionCompleted = true
        record(kind: "app.first-response", detail: detail)
    }

    /// 首个内容**真的画出来**（与"状态机已连接"分开）。一次拨号只记一条。
    ///
    /// `cached` 是关键：列表有本地缓存时，首批内容可能在**拨号后几百毫秒**就画出来了
    /// （实测 410 ms），而此时新数据还没到（同一份包的首个响应在 10 秒后）。
    /// 不标这个字段的话，"首屏 410 ms"会被读成"加载很快"，与事实相反。
    @discardableResult
    public func markFirstRender() -> Bool {
        guard !firstRenderRecorded else { return false }
        firstRenderRecorded = true
        var detail: [String: JSONValue] = ["cached": .bool(!firstInteractionCompleted)]
        if let elapsed = elapsedSinceDial() { detail["elapsedMs"] = .int(elapsed) }
        record(kind: "app.first-render", detail: detail)
        return true
    }

    private var firstRenderRecorded = false

    /// 重置"首屏"相关的标志（每次安装新链路时调用）：
    /// 不重置的话第二次连接就没有 `app.first-response` / `app.first-render` 了。
    func beginDialCycle() {
        firstInteractionSent = false
        firstInteractionCompleted = false
        firstRenderRecorded = false
    }

    /// 连接器确认收到 `upTo` 为止；水位只前进不后退。
    public func markPushed(upTo: Int) {
        if upTo > pushedUpTo {
            pushedUpTo = upTo
            saveState()
        }
    }

    // MARK: - 磁盘

    private static func openLog(_ directory: URL) -> LogFile {
        let logURL = directory.appendingPathComponent("link-diagnostics.jsonl")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int) ?? 0
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            return LogFile(handle: handle, bytes: size, disabled: false, errors: 0)
        } catch {
            return LogFile(handle: nil, bytes: 0, disabled: true, errors: 1)
        }
    }

    private func append(_ event: Event) {
        guard let logURL, !fileDisabled, let data = Self.encodeLine(event) else { return }
        do {
            if bytes > 0, bytes + data.count > maxBytes { try rotate(at: logURL) }
            try handle?.write(contentsOf: data)
            bytes += data.count
        } catch {
            // 只报一次然后闭嘴：诊断设施不能因为自己坏了把调用方拖下水（也不能刷屏）。
            fileDisabled = true
            fileErrors += 1
            try? handle?.close()
            handle = nil
        }
    }

    /// 滚一次：现文件改名成 `.1`（旧的那份丢掉），只保两代。
    private func rotate(at logURL: URL) throws {
        try handle?.close()
        handle = nil
        let archived = URL(fileURLWithPath: logURL.path + ".1")
        try? FileManager.default.removeItem(at: archived)
        try FileManager.default.moveItem(at: logURL, to: archived)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        handle = try FileHandle(forWritingTo: logURL)
        bytes = 0
    }

    /// 跨启动把最近若干条读回环里：崩溃前的现场才是要看的现场。
    private static func readTail(_ directory: URL, limit: Int) -> [Event] {
        let logURL = directory.appendingPathComponent("link-diagnostics.jsonl")
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(limit).compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(Event.self, from: data)
        }
    }

    private static func stateURL(_ directory: URL) -> URL {
        directory.appendingPathComponent("link-diagnostics.state.json")
    }

    private static func readState(_ directory: URL) -> State? {
        guard let data = try? Data(contentsOf: stateURL(directory)) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    private func saveState() {
        guard let directory else { return }
        let state = State(seq: seq, pushedUpTo: pushedUpTo, dropped: dropped)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Self.stateURL(directory), options: .atomic)
    }

    // MARK: - 编码

    /// `Date.ISO8601FormatStyle` 是值类型（Sendable），比共享一个 `ISO8601DateFormatter`
    /// 更省事：后者不是 `Sendable`，放在 static 里在 Swift 6 下过不了编译。
    private static let isoStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)

    static func isoString(_ ms: Int) -> String {
        Date(timeIntervalSince1970: Double(ms) / 1000).formatted(isoStyle)
    }

    private static func encodeLine(_ event: Event) -> Data? {
        guard var data = try? JSONEncoder().encode(event) else { return nil }
        data.append(0x0A)
        return data
    }

    private static func encodedSize(_ event: Event) -> Int {
        (try? JSONEncoder().encode(event).count) ?? 0
    }
}
