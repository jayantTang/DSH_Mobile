import Foundation

/// 单条步骤正文的本地缓存（按会话一份，LRU + 总字节上限）。
///
/// 为什么需要上限：正文可以到 2 MB 一条，没有预算的话一本会话翻几十个工具卡就能
/// 把本地库撑到几百 MB；又没有淘汰，旧会话删掉了正文还留着。
/// 这里只管**数据结构**（纯函数），读写与落库由 `ChatModel+StepBody` 做。
public struct StepBodyCache: Sendable, Equatable, Codable {

    public struct Entry: Sendable, Equatable, Codable {
        public let id: String
        public let text: String
        public let bytes: Int
        /// 最近一次使用时刻（LRU 的排序键）。
        public let usedAt: TimeInterval

        public init(id: String, text: String, bytes: Int, usedAt: TimeInterval) {
            self.id = id
            self.text = text
            self.bytes = bytes
            self.usedAt = usedAt
        }
    }

    /// 默认总预算：8 MB（单条最多 2 MB，够缓存几条最常看的正文）。
    public static let defaultLimitBytes = 8 * 1024 * 1024

    private var entriesByID: [String: Entry]

    public init(entries: [Entry] = []) {
        entriesByID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    public var entries: [Entry] {
        entriesByID.values.sorted { $0.usedAt < $1.usedAt }
    }

    public var totalBytes: Int {
        entriesByID.values.reduce(0) { $0 + $1.bytes }
    }

    public var isEmpty: Bool { entriesByID.isEmpty }

    public func text(for id: String) -> String? { entriesByID[id]?.text }

    /// 命中也算一次使用：把这一条挪到 LRU 的"最新"端（只改内存，落库由调用方决定）。
    public mutating func touch(_ id: String, at now: Date) {
        guard let entry = entriesByID[id] else { return }
        entriesByID[id] = Entry(id: entry.id, text: entry.text, bytes: entry.bytes,
                                usedAt: now.timeIntervalSince1970)
    }

    /// 记一条正文：先覆盖同 id，再按总预算淘汰最久没用的。
    ///
    /// 单条超过上限时不缓存（返回 false）：这种正文本身就是终态"输出过大"，
    /// 存进来只会把别的条目挤掉。
    @discardableResult
    public mutating func record(_ id: String, text: String, bytes: Int,
                                at now: Date,
                                limitBytes: Int = StepBodyCache.defaultLimitBytes) -> Bool {
        guard bytes <= limitBytes else { return false }
        entriesByID[id] = Entry(id: id, text: text, bytes: bytes,
                                usedAt: now.timeIntervalSince1970)
        evict(limitBytes: limitBytes)
        return true
    }

    /// 总字节超上限时，从最久没用的开始丢，直到装得下。
    public mutating func evict(limitBytes: Int) {
        guard totalBytes > limitBytes else { return }
        for entry in entries where totalBytes > limitBytes {
            entriesByID.removeValue(forKey: entry.id)
        }
    }
}
