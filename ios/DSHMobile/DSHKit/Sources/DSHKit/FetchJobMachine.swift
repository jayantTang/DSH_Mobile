import Foundation

/// 历史取页任务的纯状态机（非 UI 层）。
///
/// 为什么单独成类型：任务的四态、尝试上限、退避序列与预算判定必须只有一个所有者；
/// 把它从 `SessionPipeline` 的异步代码里拆出来，才能在单测里钉住时序，
/// 而不是靠 UI 或真机日志反推。
public struct FetchJobMachine: Sendable, Equatable {
    public enum Slot: String, Sendable, Equatable {
        case user
        case prefetch
    }

    /// 四态终态齐全：succeeded / failed / cancelled 都是终态。
    public enum State: Sendable, Equatable {
        case queued
        case running(attempt: Int)
        case succeeded
        case failed(retryable: Bool)
        case cancelled
    }

    /// 一次失败的下一步。
    public enum Tick: Sendable, Equatable {
        case retry(after: TimeInterval)
        case fail
        case ignore
    }

    public static let defaultAttemptTimeout: TimeInterval = 3
    public static let defaultBatchBudget: TimeInterval = 6
    /// 首次 + 3 次退避，共 4 次尝试。
    public static let defaultMaxAttempts = 4
    public static let defaultBackoff: [TimeInterval] = [0.5, 1, 2]

    public let slot: Slot
    public let attemptTimeout: TimeInterval
    public let batchBudget: TimeInterval
    public let maxAttempts: Int
    public let backoff: [TimeInterval]
    public private(set) var state: State = .queued
    public private(set) var attempts = 0
    public private(set) var elapsed: TimeInterval = 0

    public init(slot: Slot,
                attemptTimeout: TimeInterval = FetchJobMachine.defaultAttemptTimeout,
                batchBudget: TimeInterval = FetchJobMachine.defaultBatchBudget,
                maxAttempts: Int = FetchJobMachine.defaultMaxAttempts,
                backoff: [TimeInterval] = FetchJobMachine.defaultBackoff) {
        self.slot = slot
        self.attemptTimeout = attemptTimeout
        self.batchBudget = batchBudget
        self.maxAttempts = maxAttempts
        self.backoff = backoff
    }

    public var isTerminal: Bool {
        switch state {
        case .succeeded, .failed, .cancelled: return true
        case .queued, .running: return false
        }
    }

    /// queued → running，并消耗一次尝试。重复调用返回 false。
    @discardableResult
    public mutating func start() -> Bool {
        guard case .queued = state else { return false }
        attempts += 1
        state = .running(attempt: attempts)
        return true
    }

    /// running → succeeded。终态调用忽略。
    public mutating func succeed() {
        guard case .running = state else { return }
        state = .succeeded
    }

    /// queued/running → cancelled。终态调用忽略。
    public mutating func cancel() {
        guard !isTerminal else { return }
        state = .cancelled
    }

    /// 推进时钟；超过批预算直接失败，返回下一步。
    @discardableResult
    public mutating func advance(by seconds: TimeInterval) -> Tick {
        guard case .running = state else { return .ignore }
        elapsed += seconds
        if elapsed >= batchBudget {
            state = .failed(retryable: true)
            return .fail
        }
        return .ignore
    }

    /// 一次尝试失败（超时或网络错误）。
    ///
    /// 预算内且还有退避次数 → 回到 queued 并给出延迟；否则 failed(retryable)。
    @discardableResult
    public mutating func attemptFailed(elapsed actual: TimeInterval? = nil) -> Tick {
        guard case .running = state else { return .ignore }
        // 用实际耗时，而不是假定每次都会拖满超时；否则快速失败会被预算误杀。
        elapsed += actual ?? attemptTimeout
        if elapsed >= batchBudget || attempts >= maxAttempts {
            state = .failed(retryable: true)
            return .fail
        }
        state = .queued
        return .retry(after: backoff[min(attempts - 1, backoff.count - 1)])
    }

    /// 休眠后重新开始下一次尝试。
    @discardableResult
    public mutating func resumeAfterBackoff(_ delay: TimeInterval) -> Bool {
        // 退避等待也是墙钟时间：从任务预算里扣，不能只算尝试耗时。
        elapsed += delay
        return start()
    }
}
