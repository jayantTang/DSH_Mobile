import Foundation

/// One crash the phone saw, in the shape the team inbox can read.
///
/// Why this exists at all: a crash on a user's phone is invisible from here.
/// The app had no crash reporting and no MetricKit subscriber, so the only
/// signal was a user writing in ("用移动数据容易崩溃", 2026-10-15) — with no build,
/// no exception type and no frame stack to act on. `MXCrashDiagnostic` gives all
/// three on the *next* launch, which is the earliest iOS offers.
///
/// What is deliberately **not** here: any session id, message text, file path or
/// account identifier. A crash report is a technical fact about our own code —
/// see `docs/PRIVACY.md`. The frames are symbol names only; the payload is
/// assembled by ``CrashReportDigest``.
public struct CrashReport: Codable, Sendable, Equatable, Identifiable {

    /// Stable identity: the same crash on the same build is one report, not one
    /// per launch. Built by ``signature(build:exceptionType:topFrame:)``.
    public let id: String
    /// `EXC_BAD_ACCESS`, `EXC_CRASH`, … as MetricKit reports it.
    public let exceptionType: String
    /// The Mach signal name when there is one (`SIGSEGV`, `SIGABRT`, …).
    public let signal: String?
    /// Whether the crash happened while the app was in the foreground.
    public let scene: Scene
    /// Symbol names, most recent call first, capped by the caller.
    public var frames: [String]
    public let appVersion: String
    public let buildVersion: String
    public let systemVersion: String
    public let deviceModel: String
    public var occurredAt: Date
    /// When this report was successfully handed to the relay; nil = still queued.
    public var sentAt: Date?

    public enum Scene: String, Codable, Sendable {
        case foreground
        case background
        case unknown
    }

    public init(id: String, exceptionType: String, signal: String?, scene: Scene,
                frames: [String], appVersion: String, buildVersion: String,
                systemVersion: String, deviceModel: String, occurredAt: Date,
                sentAt: Date? = nil) {
        self.id = id
        self.exceptionType = exceptionType
        self.signal = signal
        self.scene = scene
        self.frames = frames
        self.appVersion = appVersion
        self.buildVersion = buildVersion
        self.systemVersion = systemVersion
        self.deviceModel = deviceModel
        self.occurredAt = occurredAt
        self.sentAt = sentAt
    }

    /// The dedupe key. Crash counts are interesting, but a queue that grows by
    /// one identical report per launch is not: same build + same exception +
    /// same top frame is the same bug.
    public static func signature(build: String, exceptionType: String, topFrame: String?) -> String {
        let head = topFrame.map { Self.normalize(frame: $0) } ?? "no-frame"
        return "\(build)|\(exceptionType)|\(head)"
    }

    /// Symbol names carry addresses and offsets that differ per crash of the
    /// same bug; keep the symbol and drop the rest.
    static func normalize(frame: String) -> String {
        var text = frame.trimmingCharacters(in: .whitespacesAndNewlines)
        if let plus = text.lastIndex(of: "+") {
            text = String(text[text.startIndex..<plus])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The letter one crash turns into: a subject a human can scan in the inbox and
/// a body that answers "which build, what crashed, where".
///
/// Pure formatting on purpose — no I/O, no localisation lookup — so the exact
/// text is pinned by a unit test. The inbox row is read on the phone and in the
/// admin CLI, where a missing symbol would cost another round trip with the user.
public enum CrashReportDigest {

    public static func subject(for report: CrashReport) -> String {
        "崩溃报告：\(report.exceptionType)\(report.signal.map { " (\($0))" } ?? "")"
    }

    public static func body(for report: CrashReport, frameLimit: Int = 12) -> String {
        var lines: [String] = []
        lines.append("App \(report.appVersion) (\(report.buildVersion)) · \(report.deviceModel) · iOS \(report.systemVersion)")
        lines.append("时间：\(Self.stamp.string(from: report.occurredAt)) · 场景：\(sceneText(report.scene))")
        lines.append("异常：\(report.exceptionType)\(report.signal.map { " / \($0)" } ?? "")")
        lines.append("")
        lines.append("调用栈（最近的在前）：")
        for frame in report.frames.prefix(frameLimit) {
            lines.append("· \(frame)")
        }
        if report.frames.isEmpty {
            lines.append("· （系统没有提供符号化的栈）")
        }
        if report.frames.count > frameLimit {
            lines.append("… 另有 \(report.frames.count - frameLimit) 帧")
        }
        lines.append("")
        lines.append("（本条由 App 自动投递；不含会话内容、消息正文与文件路径。）")
        return lines.joined(separator: "\n")
    }

    private static func sceneText(_ scene: CrashReport.Scene) -> String {
        switch scene {
        case .foreground: return "前台"
        case .background: return "后台"
        case .unknown: return "未知"
        }
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

/// Where pending crash reports wait for a relay that is reachable.
///
/// A file, not `UserDefaults`: a report is a few kilobytes of frames and must
/// survive the launch it was captured in. Bounded, because an app that crashes
/// on every launch would otherwise grow this forever — and the oldest reports
/// are the least useful ones (they are from older builds).
public struct CrashReportArchive: Sendable {

    public static let limit = 20

    public let root: URL?

    public init(root: URL? = nil) {
        self.root = root
    }

    private static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("DSHMobile", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static func fileURL(root: URL? = nil) -> URL {
        (root ?? defaultRoot).appendingPathComponent("crashes.json")
    }

    /// Newest first. Never throws: a corrupt file reads as "nothing queued", and
    /// the next append rewrites it.
    public func reports() -> [CrashReport] {
        guard let data = try? Data(contentsOf: Self.fileURL(root: root)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([CrashReport].self, from: data)) ?? []
    }

    /// Records a crash, replacing any earlier report with the same ``CrashReport/id``
    /// (and keeping the earliest `occurredAt`, since that is when the bug first bit).
    @discardableResult
    public func append(_ report: CrashReport) -> [CrashReport] {
        var current = reports()
        if let index = current.firstIndex(where: { $0.id == report.id }) {
            var merged = report
            merged.occurredAt = min(current[index].occurredAt, report.occurredAt)
            // 已经发出去的，重发一次没有意义；保留发送状态。
            merged.sentAt = current[index].sentAt ?? report.sentAt
            current[index] = merged
        } else {
            current.insert(report, at: 0)
        }
        if current.count > Self.limit {
            current = Array(current.prefix(Self.limit))
        }
        save(current)
        return current
    }

    /// Reports with no `sentAt`, oldest first — the queue the next launch drains.
    public func pending() -> [CrashReport] {
        reports().filter { $0.sentAt == nil }.sorted { $0.occurredAt < $1.occurredAt }
    }

    public func markSent(id: String, at stamp: Date = Date()) {
        var current = reports()
        guard let index = current.firstIndex(where: { $0.id == id }) else { return }
        current[index].sentAt = stamp
        save(current)
    }

    private func save(_ reports: [CrashReport]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(reports) else { return }
        try? data.write(to: Self.fileURL(root: root), options: .atomic)
    }
}
