import Foundation

/// 历史取页的只读指标（非 UI 层）。
///
/// 只记录与聚合，不参与任何判定：首行/批完成/重复页/失败原因。
/// 环形缓冲固定容量，避免长期运行无限增长。
public struct FetchMetrics: Sendable, Equatable {
    public struct Sample: Sendable, Equatable {
        public let firstRowMs: Int?
        public let batchMs: Int
        public let pages: Int
        public let duplicatePages: Int
        public let failure: String?

        public init(firstRowMs: Int?, batchMs: Int, pages: Int,
                    duplicatePages: Int = 0, failure: String? = nil) {
            self.firstRowMs = firstRowMs
            self.batchMs = batchMs
            self.pages = pages
            self.duplicatePages = duplicatePages
            self.failure = failure
        }
    }

    public static let capacity = 200
    private(set) var samples: [Sample] = []

    public init() {}

    public mutating func record(_ sample: Sample) {
        samples.append(sample)
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }

    public var count: Int { samples.count }

    public var batchP50Ms: Int? { Self.percentile(samples.map(\.batchMs), 0.5) }
    public var batchP95Ms: Int? { Self.percentile(samples.map(\.batchMs), 0.95) }
    public var firstRowP95Ms: Int? { Self.percentile(samples.compactMap(\.firstRowMs), 0.95) }

    /// 重复页 / 总页数；没有页时为 0。
    public var duplicateRate: Double {
        let pages = samples.reduce(0) { $0 + $1.pages }
        guard pages > 0 else { return 0 }
        let duplicates = samples.reduce(0) { $0 + $1.duplicatePages }
        return Double(duplicates) / Double(pages)
    }

    public var failures: [String: Int] {
        samples.reduce(into: [:]) { counts, sample in
            guard let failure = sample.failure else { return }
            counts[failure, default: 0] += 1
        }
    }

    /// 最近 N 条的失败率；没有样本时为 0。
    public func failureRate(last n: Int = 50) -> Double {
        let window = samples.suffix(n)
        guard !window.isEmpty else { return 0 }
        let failed = window.filter { $0.failure != nil }.count
        return Double(failed) / Double(window.count)
    }

    /// 最近秩法（nearest-rank）：样本少时也给出确定值，不插值。
    static func percentile(_ values: [Int], _ p: Double) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = max(1, Int((p * Double(sorted.count)).rounded(.up)))
        return sorted[min(sorted.count, rank) - 1]
    }
}
