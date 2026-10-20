import DSHKit
import Foundation

/// 每个会话的暖转写缓存：最近用过的若干个会话的可见行与尾部记录。
///
/// 从 `ChatModel` 拆出的第四块。它只做"按会话存取 + 有界淘汰"，不碰网络、
/// 不碰时间线折叠；ChatModel 在 open/close 时调用它。
@MainActor
final class TranscriptCache {

    struct Entry {
        var timeline: ChatTimeline
        var hasOlder: Bool
        var oldestSeq: Int?
        var throughSeq: Int
        var records: [SessionRecord]
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let limit: Int

    init(limit: Int = 6) {
        self.limit = limit
    }

    func entry(for key: String) -> Entry? {
        entries[key]
    }

    func store(_ entry: Entry, for key: String) {
        entries[key] = entry
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > limit {
            entries.removeValue(forKey: order.removeFirst())
        }
    }

    func remove(_ key: String) {
        entries.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }

    func clear() {
        entries.removeAll()
        order.removeAll()
    }

    var count: Int { entries.count }
}
