import Foundation

/// 有效连续区间集（spec 009 §6）：本地（热窗口 + 磁盘）确定完整、无需联网的 seq 范围。
///
/// 有序、不重叠、不相邻（相邻即合并）的闭区间数组。每会话区间数量级 ≤ 几十段
/// （多段主要来自搜索跳转），数组二分足够，不引入区间树（research D3）。
///
/// 纯函数、零依赖，是快闸的主要测试对象（tasks T003）。
public struct RangeIndex: Sendable, Equatable {

    /// 一段连续区间，闭区间（seq 两端都含）。Codable：随会话快照持久化到
    /// `session_state.ranges_json`（data-model），冷启动预取判定用。
    public struct Span: Sendable, Equatable, Codable {
        public var start: Int
        public var end: Int

        public init(_ start: Int, _ end: Int) {
            precondition(start <= end, "span start must not exceed end")
            self.start = start
            self.end = end
        }

        public var count: Int { end - start + 1 }

        private enum CodingKeys: String, CodingKey { case start, end }

        /// 显式解码而不是合成的那份：合成的 `init(from:)` 直接给存储属性赋值，
        /// **绕过** `init(_:_:)` 里 `start <= end` 的前置条件。`ranges_json` 是磁盘上的
        /// 外部输入（跨版本、写坏、手工改过都算），解出一个 start > end 的段会在
        /// `RangeIndex.insert` 与 `SessionPipeline.adoptPersistedRanges` 的闭区间构造处
        /// trap（SIGTRAP，不是可捕获的错误）。这里把不合法当解码失败：区间集是纯缓存，
        /// 调用方拿到空区间集重拉即可（`sessionStates` 本来就是 `try?`）。
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let start = try container.decode(Int.self, forKey: .start)
            let end = try container.decode(Int.self, forKey: .end)
            guard start <= end else {
                throw DecodingError.dataCorruptedError(
                    forKey: .end, in: container,
                    debugDescription: "span start \(start) exceeds end \(end)")
            }
            self.init(start, end)
        }
    }

    /// 一次取值的判定结果（spec §6 三分支）。
    public enum Coverage: Equatable, Sendable {
        /// 全命中：本地直接返回，零网络。
        case full
        /// 部分命中：`covered` 可直接用，`missing` 需要按页补齐（有序、不重叠）。
        case partial(covered: [Span], missing: [Span])
        /// 完全不命中：整段都要拉。
        case none
    }

    public private(set) var spans: [Span] = []

    public init() {}

    public init(spans: [Span]) {
        for span in spans { insert(span.start...span.end) }
    }

    public var isEmpty: Bool { spans.isEmpty }

    /// 全部区间覆盖的 seq 总数。
    public var coveredCount: Int { spans.reduce(0) { $0 + $1.count } }

    /// 已覆盖的最大 seq（列表/增量的对齐基准），空集为 nil。
    public var newest: Int? { spans.last?.end }

    /// 已覆盖的最小 seq，空集为 nil。
    public var oldest: Int? { spans.first?.start }

    // MARK: - 写入

    /// 合并一段新到的连续范围。与既有区间重叠或相邻（端点差 1）即并段。
    public mutating func insert(_ range: ClosedRange<Int>) {
        var start = range.lowerBound
        var end = range.upperBound
        // 第一个 end >= start-1 的位置：左侧区间与本段不相交也不相邻。
        let low = spans.partitioningIndex { $0.end >= start - 1 }
        var high = low
        // 吸收所有相交/相邻的既有区间。
        while high < spans.count, spans[high].start <= end + 1 {
            start = min(start, spans[high].start)
            end = max(end, spans[high].end)
            high += 1
        }
        spans.replaceSubrange(low..<high, with: [Span(start, end)])
    }

    /// 单个 seq 等价于一个点的区间。
    public mutating func insert(_ seq: Int) {
        insert(seq...seq)
    }

    // MARK: - 查询

    /// 判定一个范围的本地覆盖情况（spec §6：全命中/部分命中/不命中）。
    public func coverage(of range: ClosedRange<Int>) -> Coverage {
        var covered: [Span] = []
        var missing: [Span] = []
        var cursor = range.lowerBound

        for span in spans where span.end >= range.lowerBound && span.start <= range.upperBound {
            if span.start > cursor {
                missing.append(Span(cursor, span.start - 1))
            }
            let from = max(span.start, cursor)
            let to = min(span.end, range.upperBound)
            if from <= to { covered.append(Span(from, to)) }
            cursor = max(cursor, span.end + 1)
            if cursor > range.upperBound { break }
        }
        if cursor <= range.upperBound {
            missing.append(Span(cursor, range.upperBound))
        }

        if missing.isEmpty { return .full }
        if covered.isEmpty { return .none }
        return .partial(covered: covered, missing: missing)
    }

    /// 单个 seq 是否已被覆盖。
    public func contains(_ seq: Int) -> Bool {
        let index = spans.partitioningIndex { $0.end >= seq }
        guard spans.indices.contains(index) else { return false }
        return spans[index].start <= seq
    }

    /// 一个窗口内的缺口列表（gap 行的数据源，spec「缺口行的生命周期」）。
    /// 只返回落在 `window` 内、且不被覆盖的段，有序。
    /// 完全不命中时整个 window 是"未加载区"，由调用方决定是否整体视为一个缺口；
    /// 这里只在"有数据但有空洞"时给出中间缺口。
    public func gaps(within window: ClosedRange<Int>) -> [Span] {
        switch coverage(of: window) {
        case .full, .none:
            return []
        case .partial(_, let missing):
            return missing
        }
    }
}

private extension Array {
    /// 标准库没有二分分割点；predicate 在数组上呈"前 false 后 true"。
    func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var low = startIndex
        var high = endIndex
        while low < high {
            let mid = index(low, offsetBy: distance(from: low, to: high) / 2)
            if predicate(self[mid]) {
                high = mid
            } else {
                low = index(after: mid)
            }
        }
        return low
    }
}
