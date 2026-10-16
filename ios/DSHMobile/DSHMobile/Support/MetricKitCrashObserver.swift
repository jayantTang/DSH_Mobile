#if os(iOS)
import DSHFoundation
import Foundation
import MetricKit

/// Catches the crash diagnostics iOS hands back on the **next** launch.
///
/// Why this shape: `MXCrashDiagnostic` is the only crash signal an App Store
/// build can obtain without a third-party SDK, and it never arrives at the
/// moment of the crash — iOS stores it and replays it when the app next runs
/// (`didReceive(_ payloads:)`). So the flow is: capture into
/// ``DSHFoundation/CrashReportArchive``, hand the report to whoever can deliver
/// it, and let the feedback channel put it in the team inbox.
///
/// What this deliberately does **not** do: no network call of its own, no retry
/// loop, no third-party crash SDK. Delivery is
/// ``DSHFeedbackDomain/FeedbackCenter/flushCrashReports()`` on the next
/// foreground, which is also where the "send each crash once" rule lives.
///
/// `MXMetricManager` also delivers hang, CPU and disk-write diagnostics. Those
/// are metrics, not crashes, and each has its own sample/threshold semantics;
/// only the crash payloads are consumed here so the inbox does not fill with
/// noise (a hang report would otherwise read like a crash in the mailbox).
final class MetricKitCrashObserver: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {

    static let shared = MetricKitCrashObserver()

    /// MetricKit 在它自己的队列上回调；存档与回调都用同一把锁串起来。
    private let lock = NSLock()
    private var archive = CrashReportArchive()
    private var onCaptured: ((CrashReport) -> Void)?
    private var isStarted = false

    private override init() { super.init() }

    /// Registers with MetricKit once. Calling it twice is a no-op: two
    /// subscriptions would deliver every payload twice and look like two crashes.
    func start(archive: CrashReportArchive = CrashReportArchive(),
               onCaptured: @escaping (CrashReport) -> Void) {
        lock.lock()
        self.archive = archive
        self.onCaptured = onCaptured
        let alreadyStarted = isStarted
        isStarted = true
        lock.unlock()
        guard !alreadyStarted else { return }
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        lock.lock()
        let archive = self.archive
        let notify = self.onCaptured
        lock.unlock()
        for payload in payloads {
            for diagnostic in payload.crashDiagnostics ?? [] {
                // 报告的"发生时间"取这一批的结束时刻：MetricKit 只给区间。
                let report = Self.report(from: diagnostic, at: payload.timeStampEnd)
                archive.append(report)
                notify?(report)
            }
        }
    }

    // MARK: - 转换

    /// Builds one report from a MetricKit diagnostic. `metaData` carries the
    /// build, OS and device; the frames come out of the call-stack JSON, which is
    /// the only part that needs parsing.
    static func report(from diagnostic: MXCrashDiagnostic, at occurredAt: Date) -> CrashReport {
        let meta = diagnostic.metaData
        // `applicationVersion` 是短版本（1.0），`metaData.applicationBuildVersion`
        // 是构建号（20261013.2233）——收件箱里两个都要，方便对到具体发布版。
        let build = meta.applicationBuildVersion
        let exception = Self.exceptionName(diagnostic.exceptionType)
        let frames = Self.frames(from: diagnostic.callStackTree)
        return CrashReport(
            id: CrashReport.signature(build: build, exceptionType: exception, topFrame: frames.first),
            exceptionType: exception,
            signal: Self.signalName(diagnostic.signal),
            // MetricKit 不告诉你崩溃时在前台还是后台；填「未知」而不是猜一个。
            scene: .unknown,
            frames: frames,
            appVersion: diagnostic.applicationVersion,
            buildVersion: build,
            systemVersion: meta.osVersion,
            deviceModel: meta.deviceType,
            occurredAt: occurredAt
        )
    }

    /// MetricKit 给的是 NSNumber 形式的 Mach 异常码，翻成人能读的名字；
    /// 认不出来就原样写出数字，不丢信息。
    static func exceptionName(_ raw: NSNumber?) -> String {
        guard let raw else { return "unknown" }
        switch raw.intValue {
        case 1: return "EXC_BAD_ACCESS"
        case 2: return "EXC_BAD_INSTRUCTION"
        case 3: return "EXC_ARITHMETIC"
        case 4: return "EXC_EMULATION"
        case 5: return "EXC_SOFTWARE"
        case 6: return "EXC_BREAKPOINT"
        case 10: return "EXC_CRASH"
        case 11: return "EXC_GUARD"
        case 12: return "EXC_RESOURCE"
        default: return "EXC_\(raw.intValue)"
        }
    }

    static func signalName(_ raw: NSNumber?) -> String? {
        guard let raw else { return nil }
        switch raw.intValue {
        case 4: return "SIGILL"
        case 5: return "SIGTRAP"
        case 6: return "SIGABRT"
        case 8: return "SIGFPE"
        case 9: return "SIGKILL"
        case 10: return "SIGBUS"
        case 11: return "SIGSEGV"
        default: return "SIG\(raw.intValue)"
        }
    }

    /// Flattens the call-stack tree into symbol-ish frame lines.
    ///
    /// MetricKit ships *offsets*, not symbols: symbol names need the dSYM, which
    /// is applied later by hand. So each line is `binary @0xoffset` where the
    /// binary name is available — enough to tell "our code" from a system
    /// framework, and stable for a given build, which is what the dedupe key and
    /// the human reading the inbox both need.
    static func frames(from tree: MXCallStackTree, limit: Int = 40) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: tree.jsonRepresentation()),
              let root = object as? [String: Any],
              let trees = root["callStackTree"] as? [[String: Any]] else { return [] }

        var lines: [String] = []
        for entry in trees {
            let stacks = entry["callStacks"] as? [[String: Any]] ?? []
            // 只取被归属的那条栈：崩溃线程之外的都是同一时刻的旁观者。
            let attributed = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks.first
            guard let frames = attributed?["callStackRootFrames"] as? [[String: Any]] else { continue }
            for frame in frames {
                Self.collect(frame, into: &lines, limit: limit)
                if lines.count >= limit { return Array(lines.prefix(limit)) }
            }
        }
        return lines
    }

    private static func collect(_ frame: [String: Any], into lines: inout [String], limit: Int) {
        guard lines.count < limit else { return }
        let binary = (frame["binaryName"] as? String) ?? (frame["binaryUUID"] as? String) ?? "?"
        let offset = (frame["offsetIntoBinaryTextSegment"] as? NSNumber)?.uint64Value
        if let offset {
            lines.append("\(binary) @0x\(String(offset, radix: 16))")
        } else {
            lines.append(binary)
        }
        for sub in frame["subFrames"] as? [[String: Any]] ?? [] {
            collect(sub, into: &lines, limit: limit)
        }
    }
}
#endif
