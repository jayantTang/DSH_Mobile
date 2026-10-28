#if DEBUG
import Foundation

/// 过程折叠的**取数探针**（仅 DEBUG，默认关闭）。
///
/// 用仿真器验证"按需取数"的请求次数与首屏耗时：启动参数 `-DSHFoldPerfProbe`
/// 打开后，每次 `_link/sessionWindow` 按调用点打标累加，并把耗时样本以
/// JSON 覆盖写到 `Library/Caches/dsh-fold-probe.json`。
///
/// 关闭时：`isEnabled == false`，所有入口第一行就 return，不建文件、不分配报告。
/// 发布构建里整份文件被 `#if DEBUG` 编译掉，调用点也都在 `#if DEBUG` 里。
public enum FoldPerfProbe {

    /// 五个调用点。字符串就是落盘 JSON 里的 `kind`。
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// 首屏概要页（`fold: "summary"`，12 轮）。
        case summaryFirst = "summary.first"
        /// 旧页概要（`fold: "summary"`，6 轮）。
        case summaryOlder = "summary.older"
        /// 单条正文（`limit: 1`，不带 fold）。
        case stepBody = "step.body"
        /// 管道路径/搜索缓冲的**概要**页（v2 能力下的通用取页）。
        case summaryPage = "summary.page"
        /// 管道路径的 v1 折叠（仅在连接器没有 v2 能力时出现）。
        case legacyV1 = "legacy.v1"
        /// 普通窗口（不带 fold；补拉详情、查重等）。
        case historyNone = "history.none"
    }

    /// 一次请求/回包/落帧的耗时与体积。
    public struct Sample: Codable, Equatable {
        public var kind: Kind
        /// 请求带的 fold 模式：`"summary"` / `"v1"` / nil（不折）。
        public var fold: String?
        public var limit: Int?
        public var maxBytes: Int?
        /// 回包之后 decode + adopt 的纯耗时（不含网络）；"解析 ≤30ms"用它。
        public var parseMs: Double?
        /// t1 - t0：请求发出 → 回包并采纳（单条正文是"请求 → 落行"）。
        public var requestMs: Double?
        /// t2 - t0：采纳后主队列下一轮（首帧机会）。
        public var frameMs: Double?
        /// t3 - t0：视口可见（能拿就拿；当前没有视口回调时为 nil）。
        public var visibleMs: Double?
        public var records: Int?
        public var bytes: Int?

        public init(kind: Kind, fold: String? = nil, limit: Int? = nil,
                    maxBytes: Int? = nil, parseMs: Double? = nil,
                    requestMs: Double? = nil,
                    frameMs: Double? = nil, visibleMs: Double? = nil,
                    records: Int? = nil, bytes: Int? = nil) {
            self.kind = kind
            self.fold = fold
            self.limit = limit
            self.maxBytes = maxBytes
            self.parseMs = parseMs
            self.requestMs = requestMs
            self.frameMs = frameMs
            self.visibleMs = visibleMs
            self.records = records
            self.bytes = bytes
        }
    }

    /// 落盘的完整报告（纯数据，编码可单测）。
    public struct Report: Codable, Equatable {
        public var launchId: String
        /// 进程启动时刻（epoch 秒，`Date().timeIntervalSince1970`）。
        public var startedAt: Double
        /// kind → 请求次数。
        public var counts: [String: Int]
        public var samples: [Sample]
        public var lastError: String?

        public init(launchId: String, startedAt: Double,
                    counts: [String: Int] = [:], samples: [Sample] = [],
                    lastError: String? = nil) {
            self.launchId = launchId
            self.startedAt = startedAt
            self.counts = counts
            self.samples = samples
            self.lastError = lastError
        }

        public func count(_ kind: Kind) -> Int { counts[kind.rawValue] ?? 0 }

        public mutating func recordRequest(_ kind: Kind) {
            counts[kind.rawValue, default: 0] += 1
        }

        /// 追加一条样本（同一 kind 的后续帧只更新最近一条）。
        @discardableResult
        public mutating func append(_ sample: Sample) -> Int {
            samples.append(sample)
            return samples.count - 1
        }

        public mutating func updateSample(at index: Int, frameMs: Double? = nil,
                                          visibleMs: Double? = nil) {
            guard samples.indices.contains(index) else { return }
            if let frameMs { samples[index].frameMs = frameMs }
            if let visibleMs { samples[index].visibleMs = visibleMs }
        }

        public mutating func recordFailure(_ message: String) {
            lastError = message
        }

        /// 编码并保证体积（超出预算从最老的样本开始丢；计数与错误保留）。
        public func encoded(maxBytes: Int = FoldPerfProbe.maxFileBytes) -> Data {
            var trimmed = self
            var data = (try? JSONEncoder().encode(trimmed)) ?? Data("{}".utf8)
            while data.count > maxBytes, !trimmed.samples.isEmpty {
                trimmed.samples.removeFirst(max(1, trimmed.samples.count / 4))
                data = (try? JSONEncoder().encode(trimmed)) ?? data
            }
            return data
        }

        public static func decode(_ data: Data) throws -> Report {
            try JSONDecoder().decode(Report.self, from: data)
        }
    }

    /// 落盘文件上限：超过就从最老的样本开始丢（schema 固定，计数不丢）。
    /// `nonisolated(unsafe)`：读写都在 `lock` 里；单测会临时压小它。
    public nonisolated(unsafe) static var maxFileBytes = 64 * 1024

    /// 启动参数开关。
    public nonisolated(unsafe) static var isEnabled: Bool = ProcessInfo.processInfo
        .arguments.contains("-DSHFoldPerfProbe")

    /// 一次进程一个 id：二次打开（冷启动）会换一个，便于区分。
    public static let launchId = UUID().uuidString
    public static let startedAt = Date().timeIntervalSince1970

    private static let lock = NSLock()
    // 下面三个都在 `lock` 内读写（`nonisolated(unsafe)` 只是告诉编译器这点）。
    private nonisolated(unsafe) static var report = Report(launchId: launchId, startedAt: startedAt)
    /// kind → 请求发出时刻（CFAbsoluteTime，秒）与请求参数。
    private nonisolated(unsafe) static var requestStart: [Kind: CFAbsoluteTime] = [:]
    private nonisolated(unsafe) static var requestMeta:
        [Kind: (fold: String?, limit: Int?, maxBytes: Int?)] = [:]
    /// 客户端解码回包的耗时（`DSHClient.historyWindow` 里量，按 kind 记）。
    private nonisolated(unsafe) static var decodeMsByKind: [Kind: Double] = [:]
    /// 当前请求的 kind：解码发生在 `DSHClient` 里，用 TaskLocal 把 kind 带过去。
    @TaskLocal static var activeKind: Kind?
    /// kind → 最近一条样本下标（帧/可见回填用）。
    private nonisolated(unsafe) static var sampleIndex: [Kind: Int] = [:]

    /// 一次回包的字节量（编码后大小；探针关闭时不编码、返回 nil）。
    public static func payloadBytes(_ records: [SessionRecord]) -> Int? {
        guard isEnabled else { return nil }
        return (try? JSONEncoder().encode(records))?.count
    }

    /// 探针文件：`Library/Caches/dsh-fold-probe.json`。
    public static var fileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dsh-fold-probe.json")
    }

    // MARK: - 解码耗时（TaskLocal 把 kind 带进 client）

    /// 包住一次 `client.historyWindow`：让 `DSHClient` 的解码耗时归到这个 kind。
    public static func withActiveKind<T: Sendable>(
        _ kind: Kind,
        _ body: @Sendable () async throws -> T) async rethrows -> T {
        guard isEnabled else { return try await body() }
        return try await $activeKind.withValue(kind) { try await body() }
    }

    /// `DSHClient.historyWindow` 解码完成后调用。
    static func noteDecodeMs(_ ms: Double) {
        guard isEnabled, let kind = activeKind else { return }
        withLock { decodeMsByKind[kind] = ms }
    }

    /// 回包之后 decode + adopt 的纯耗时；`adoptionMs` 由调用方量采纳那一段。
    public static func parseMs(_ kind: Kind, adoptionMs: Double = 0) -> Double? {
        guard isEnabled else { return nil }
        return withLock { (decodeMsByKind[kind] ?? 0) + adoptionMs }
    }

    // MARK: - 事件

    /// 发出请求前调用（计入 counts，并记下 fold/limit/maxBytes）。
    public static func begin(_ kind: Kind, fold: String? = nil,
                             limit: Int? = nil, maxBytes: Int? = nil) {
        guard isEnabled else { return }
        let now = CFAbsoluteTimeGetCurrent()
        withLock {
            report.recordRequest(kind)
            requestStart[kind] = now
            requestMeta[kind] = (fold, limit, maxBytes)
        }
    }

    /// 回包并采纳（或单条正文落行）时调用：t1，`parseMs` 是 decode+adopt 的纯耗时。
    public static func finished(_ kind: Kind, records: Int? = nil, bytes: Int? = nil,
                                parseMs: Double? = nil) {
        guard isEnabled else { return }
        let now = CFAbsoluteTimeGetCurrent()
        withLock {
            guard let started = requestStart[kind] else { return }
            let meta = requestMeta[kind] ?? (nil, nil, nil)
            let measuredParse = parseMs ?? decodeMsByKind[kind]
            let index = report.append(Sample(
                kind: kind, fold: meta.fold, limit: meta.limit, maxBytes: meta.maxBytes,
                parseMs: measuredParse,
                requestMs: (now - started) * 1000,
                records: records, bytes: bytes))
            sampleIndex[kind] = index
            decodeMsByKind[kind] = nil
        }
        flush()
    }

    /// 采纳后的主队列下一轮（t2）；拿不到就跳过。
    public static func firstFrame(_ kind: Kind) {
        guard isEnabled else { return }
        let now = CFAbsoluteTimeGetCurrent()
        withLock {
            guard let started = requestStart[kind], let index = sampleIndex[kind] else { return }
            report.updateSample(at: index, frameMs: (now - started) * 1000)
        }
        flush()
    }

    /// 视口真正可见（t3）；当前没有视口回调时不会调用。
    static func firstVisible(_ kind: Kind) {
        guard isEnabled else { return }
        let now = CFAbsoluteTimeGetCurrent()
        withLock {
            guard let started = requestStart[kind], let index = sampleIndex[kind] else { return }
            report.updateSample(at: index, visibleMs: (now - started) * 1000)
        }
        flush()
    }

    /// 失败：只记最后一条错误（样本不追加）。
    public static func failed(_ kind: Kind, error: any Error) {
        guard isEnabled else { return }
        withLock { report.recordFailure("\(kind.rawValue): \(String(describing: error))") }
        flush()
    }

    // MARK: - 落盘（原子覆盖写）

    /// 覆盖写一份报告（原子：先写临时文件再 replace，读方不会看到半个 JSON）。
    public static func write(_ report: Report, to url: URL) throws {
        let data = report.encoded(maxBytes: maxFileBytes)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    /// 读回（测试与人工排查共用）。
    public static func read(from url: URL) throws -> Report {
        try Report.decode(Data(contentsOf: url))
    }

    private static func flush() {
        guard isEnabled else { return }
        let snapshot: Report = withLock { report }
        try? write(snapshot, to: fileURL)
    }

    private static func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
#endif
