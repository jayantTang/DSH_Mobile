#if DIAGNOSTICS
import DSHFoundation
import Foundation
import MetricKit

/// 卡死/崩溃留证：MetricKit 的 hang/crash 诊断 + 主线程心跳。
///
/// OTA 构建专用（`DIAGNOSTICS`）。不改变产品行为，只把下一次卡死/退出时的
/// 现场写进现有诊断日志（`DSHLog` → `_link/logs`），避免再出现“没有 hang 栈”。
final class HangDiagnostics: NSObject, MXMetricManagerSubscriber {
    nonisolated(unsafe) static let shared = HangDiagnostics()

    static func start() {
        MXMetricManager.shared.add(shared)
        MainThreadWatchdog.start()
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for hang in payload.hangDiagnostics ?? [] {
                log("hang", durationMs: hang.hangDuration.converted(to: .milliseconds).value,
                    tree: hang.callStackTree)
            }
            for crash in payload.crashDiagnostics ?? [] {
                DSHLog.event("diag.crash", [
                    "exception": String(crash.exceptionType?.intValue ?? -1),
                    "signal": String(crash.signal?.intValue ?? -1),
                    "reason": crash.terminationReason ?? "-",
                ])
                log("crash", durationMs: 0, tree: crash.callStackTree)
            }
        }
    }

    private func log(_ kind: String, durationMs: Double, tree: MXCallStackTree) {
        let json = String(data: tree.jsonRepresentation(), encoding: .utf8) ?? "{}"
        DSHLog.event("diag.\(kind)", [
            "ms": String(format: "%.0f", durationMs),
            "tree": String(json.prefix(3_000)),
        ])
    }
}

/// 主线程心跳：后台每 0.5 秒问一次主线程；超过 2 秒没回应就记一条 stall。
/// 只记录，不采样其他线程栈（不安全）；配合 MetricKit 的 hang 栈定位。
enum MainThreadWatchdog {
    private static let queue = DispatchQueue(label: "dsh.main-watchdog")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var ticks = 0
    nonisolated(unsafe) private static var answeredTicks = 0
    nonisolated(unsafe) private static var reported = false
    nonisolated(unsafe) private static var started = false

    static func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler {
            lock.lock()
            ticks += 1
            let current = ticks
            let answered = answeredTicks
            let alreadyReported = reported
            lock.unlock()
            DispatchQueue.main.async {
                lock.lock()
                answeredTicks = max(answeredTicks, current)
                lock.unlock()
            }
            if current - answered > 4, !alreadyReported {
                lock.lock(); reported = true; lock.unlock()
                DSHLog.event("main.stall", ["ms": String((current - answered) * 500)])
            } else if current - answered <= 1 {
                lock.lock(); reported = false; lock.unlock()
            }
        }
        timer.resume()
        storage = timer
    }

    /// 持有 timer，避免被释放。
    nonisolated(unsafe) private static var storage: DispatchSourceTimer?
}
#endif
