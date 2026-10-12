import Foundation

/// in-flight 页表（spec 009「支撑机制」/ tasks T006）：正在拉取的页登记处。
///
/// 三条纪律：
/// 1. **同页合并**：同一页的在途请求只发一次，后来者搭车（`.joined`），
///    快速滚动不打出重复网络请求。
/// 2. **可取消**：页不再被需要（用户跳走、窗口滑过）可取消；被取消页的回包
///    由代数（generation）判定作废，不写入。
/// 3. **可抢占**：用户动作（点开、跳到底部）能取消低优先级预取并插队。
///
/// 纯值类型；并发安全由持有它的 actor（SessionPipeline）保证。
public struct InFlightPageTable<Key: Hashable & Sendable>: Sendable {

    /// 拉取的优先级：数值越大越优先。用户直接触发的页高于一切预取。
    public enum Priority: Int, Comparable, Sendable {
        case prefetch = 0      // 预取瀑布
        case userVisible = 10  // 用户翻到的位置
        case jump = 20         // 点开/跳转（队首语义）
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        /// 诊断用的短名（017 `pager.fetch` 的 `source`）：预取 / 读者 / 跳转。
        public var name: String {
            switch self {
            case .prefetch: return "prefetch"
            case .userVisible: return "user"
            case .jump: return "jump"
            }
        }
    }

    public enum Decision: Equatable, Sendable {
        /// 需要发起网络请求；`generation` 是这次请求的回包有效凭证。
        case start(generation: Int)
        /// 同页已在途，搭车即可（不发新请求）。
        case joined
    }

    private struct Entry: Sendable {
        var priority: Priority
        var generation: Int
        /// 搭车计数：仅诊断用（排查"为什么这页没有发请求"）。
        var riders: Int
    }

    private var entries: [Key: Entry] = [:]
    private var nextGeneration = 1

    public init() {}

    public var count: Int { entries.count }
    public func isInFlight(_ key: Key) -> Bool { entries[key] != nil }
    public func generation(of key: Key) -> Int? { entries[key]?.generation }

    /// 登记一次拉取意图。同 key 在途：搭车；若新优先级更高则**升级**优先级
    /// （插队语义：同一页从预取升级为用户可见），不发新请求。
    @discardableResult
    public mutating func begin(_ key: Key, priority: Priority) -> Decision {
        if var entry = entries[key] {
            entry.riders += 1
            if priority > entry.priority { entry.priority = priority }
            entries[key] = entry
            return .joined
        }
        let generation = nextGeneration
        nextGeneration += 1
        entries[key] = Entry(priority: priority, generation: generation, riders: 0)
        return .start(generation: generation)
    }

    /// 回包核销。返回 true 表示这次结果有效（未取消、未换代）；
    /// false 表示请求已被取消或被取代，调用方必须丢弃结果。
    @discardableResult
    public mutating func finish(_ key: Key, generation: Int) -> Bool {
        guard let entry = entries[key], entry.generation == generation else { return false }
        entries.removeValue(forKey: key)
        return true
    }

    /// 取消一页（窗口滑走）。在途请求的回包将因代数不匹配被丢弃。
    public mutating func cancel(_ key: Key) {
        entries.removeValue(forKey: key)
    }

    /// 取消全部低于某优先级的页（用户动作抢占预取）。返回被取消的 key。
    @discardableResult
    public mutating func cancelAll(below priority: Priority) -> [Key] {
        let victims = entries.filter { $0.value.priority < priority }.map(\.key)
        for key in victims { entries.removeValue(forKey: key) }
        return victims
    }
}
