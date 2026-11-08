//
//  AttachmentLoadMachine.swift
//  DSHChatDomain
//
//  一张图的加载状态机：谁是"这张图现在是什么状态"的唯一所有者。
//
//  为什么需要它：以前这份状态散在三处——解码后的位图（NSCache）、失败时间戳
//  （`failures`）、在飞任务（`inFlight`）——再叠上视图里 `hasFailed` 的一次读表。
//  失败以后没有任何东西会再问一次：视图那个 `.task` 只在附件 id 或链路代数变化时
//  重跑，而 15 秒的"静默窗"只挡住重复请求，不安排下一次尝试。结果是一次偶发失败
//  会把整屏图片钉死在「图片加载失败」，用户点重试也只是把同一个请求再发一遍。
//
//  这里只放纯逻辑：什么时候开始一次尝试、失败后等多久再试、重试几次为止、手动
//  重试怎么重置。下载、解码、计时与取消都由 UI 层那台驱动任务负责。
//

import Foundation

/// The load state of one picture, and the only place that decides what happens
/// after a failed attempt.
public struct AttachmentLoadMachine: Sendable, Equatable {

    /// What the transcript should draw for this picture.
    public enum Phase: Sendable, Equatable {
        /// Nothing is happening; the next attempt has not started.
        case idle
        /// One attempt is running (or being scheduled right now).
        case loading(attempt: Int)
        /// The bytes are decoded and in hand.
        case loaded
        /// The last attempt failed. `reason` is what the UI and diagnostics may show.
        case failed(attempt: Int, reason: String)
    }

    /// How many automatic attempts a picture gets before it waits for a tap.
    ///
    /// Bounded on purpose: a permanent failure (the Host genuinely does not have
    /// these bytes) must not turn into a request every few seconds for as long as
    /// the row stays on screen. The backoff table adds up to roughly two minutes,
    /// which covers a reconnect and a Host that was briefly busy.
    public static let maxAutomaticAttempts = 8

    public private(set) var phase: Phase = .idle
    public private(set) var attempt = 0
    /// 这台机器允许的自动尝试次数。缺省就是上面的上限；用例可以在 DEBUG 下把它
    /// 调小（`-DSHAttachmentAttempts`），以便在一次运行内看到"次数用尽 → 手动重试"。
    public let automaticAttemptLimit: Int

    public init(automaticAttemptLimit: Int = AttachmentLoadMachine.maxAutomaticAttempts) {
        self.automaticAttemptLimit = max(1, automaticAttemptLimit)
    }

    /// Start one attempt. Every call increments the attempt number.
    public mutating func begin() {
        attempt += 1
        phase = .loading(attempt: attempt)
    }

    /// The bytes arrived: nothing left to schedule.
    public mutating func succeed() {
        attempt = 0
        phase = .loaded
    }

    /// One attempt failed.
    ///
    /// Returns how long to wait before the next automatic attempt, or `nil` when
    /// the machine has used up its automatic attempts — the caller then stops and
    /// leaves the picture in `.failed` until someone taps it.
    @discardableResult
    public mutating func fail(reason: String) -> Duration? {
        phase = .failed(attempt: attempt, reason: reason)
        guard attempt < automaticAttemptLimit else { return nil }
        return Self.backoff(afterAttempt: attempt)
    }

    /// 链路未就绪（或请求被断线取消）：**不算可见的失败**，界面继续转圈。
    ///
    /// 但同样要退避：不然客户端一直不可用时会变成每秒一次的忙等。次数仍然累计，
    /// 长时间不可用（约两分钟）之后才落成失败态，把重试按钮交出去。
    @discardableResult
    public mutating func stall() -> Duration? {
        guard attempt < automaticAttemptLimit else {
            phase = .failed(attempt: attempt, reason: "未连接")
            return nil
        }
        phase = .loading(attempt: attempt)
        return Self.backoff(afterAttempt: attempt)
    }

    /// The person asked for this picture again: back to a clean first attempt.
    public mutating func prepareManualRetry() {
        attempt = 0
        phase = .idle
    }

    /// The link was rebuilt: whatever failed during the outage deserves a fresh
    /// first attempt, and a backing-off one should not wait out its timer.
    public mutating func invalidate() {
        attempt = 0
        phase = .idle
    }

    /// A row left the screen: no state change, but the caller stops driving.
    public var isFinished: Bool {
        switch phase {
        case .loaded: return true
        case .failed(_, _): return false
        case .idle, .loading: return false
        }
    }

    /// 1s, 2s, 4s, 8s, 15s, then 30s for every later attempt.
    ///
    /// Fast enough that a transient socket failure is invisible to the user,
    /// slow enough that a Host under load is not hit eight times a second.
    public static func backoff(afterAttempt attempt: Int) -> Duration {
        let table: [Int] = [1, 2, 4, 8, 15, 30]
        let index = min(max(attempt, 1), table.count) - 1
        return .seconds(table[index])
    }
}
