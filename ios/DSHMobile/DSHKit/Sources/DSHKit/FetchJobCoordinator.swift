import Foundation

/// 取页任务的准入与槽位（非 UI 层，纯值类型）。
///
/// 只回答三件事：这段范围现在能不能发、是不是已经有人在做、哪个槽位被占。
/// 任务自身的四态与预算在 `FetchJobMachine`；协调器不重复保存状态。
public struct FetchJobCoordinator: Sendable, Equatable {
    public enum Admission: Sendable, Equatable {
        /// 可以开始；调用方执行网络并回报结果。
        case run(FetchJobMachine)
        /// 同一范围已有任务在跑：搭车等待，不重复发。
        case joined
        /// 用户槽位已被另一段范围占用。
        case rejectedUserBusy
        /// 这段范围已在终态：忽略。
        case ignored
    }

    public static let maxDepth = 2

    /// 终态任务立即移除；只保留 queued/running。
    private var jobs: [ClosedRange<Int>: FetchJobMachine] = [:]

    public init() {}

    public var depth: Int { jobs.count }

    public func state(of range: ClosedRange<Int>) -> FetchJobMachine.State? {
        jobs[range]?.state
    }

    /// 请求一段范围。同一范围不重复发；用户槽位同时只允许一段范围。
    public mutating func request(_ range: ClosedRange<Int>,
                                 slot: FetchJobMachine.Slot) -> Admission {
        if let existing = jobs[range] {
            switch existing.state {
            case .queued, .running:
                return .joined
            default:
                jobs[range] = nil
                return .ignored
            }
        }
        if slot == .user, hasActiveJob(in: .user, excluding: range) {
            return .rejectedUserBusy
        }
        var job = FetchJobMachine(slot: slot)
        _ = job.start()
        jobs[range] = job
        return .run(job)
    }

    /// 任务成功：移除并返回 true；未知范围返回 false。
    @discardableResult
    public mutating func succeed(_ range: ClosedRange<Int>) -> Bool {
        finish(range, with: .succeeded)
    }

    /// 任务失败（可重试）：从活跃表移除，由调用方决定是否在退避后重发。
    @discardableResult
    public mutating func fail(_ range: ClosedRange<Int>, retryable: Bool = true) -> Bool {
        finish(range, with: .failed(retryable: retryable))
    }

    /// 只取消与给定范围重叠的用户任务；预取同范围一并取消。
    @discardableResult
    public mutating func cancel(overlapping range: ClosedRange<Int>) -> [ClosedRange<Int>] {
        let victims = jobs.keys.filter { $0.overlaps(range) }
        for key in victims {
            jobs[key]?.cancel()
            // 取消即终态：从活跃表移除，避免深度与"正在跑"读数被终态任务撑大。
            jobs[key] = nil
        }
        return victims.sorted { $0.lowerBound < $1.lowerBound }
    }

    public mutating func removeAll() {
        jobs.removeAll()
    }

    private func hasActiveJob(in slot: FetchJobMachine.Slot,
                              excluding range: ClosedRange<Int>) -> Bool {
        jobs.contains { key, job in
            key != range && job.slot == slot && !job.isTerminal
        }
    }

    /// 终态即移出活跃表：协调器只回答"现在谁在跑"，不保存终态历史。
    private mutating func finish(_ range: ClosedRange<Int>,
                                 with state: FetchJobMachine.State) -> Bool {
        guard jobs[range] != nil else { return false }
        jobs[range] = nil
        return true
    }
}
