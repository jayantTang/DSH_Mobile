import Foundation

/// 本机保存的**反馈取件凭据**列表的判定（spec 023 边界收敛：从 App 的 `FeedbackLocalStore` 抽出）。
///
/// ## 它管什么
///
/// 凭据是"重装 App 之后还能取回那条回信"的唯一凭据，所以这份列表有几条硬规则：
///
/// * 同一线程只留最新的一条（同 `threadId` 覆盖）；
/// * 按时间倒序，超出上限丢最旧的（服务端仍在，只是这台手机取不回来）；
/// * **坏数据当空**：一条解析失败不能把整个记录页挡住；
/// * 编码用同一份策略往返（毫秒时间戳，与 relay 的写法一致）。
///
/// ## 为什么抽出来
///
/// 这几条判定原来写在 App 的 `FeedbackLocalStore` 里，而那个文件同时管 Keychain 与文件 IO，
/// **一条测试都没有**。抽出来之后：判定是纯函数（可在这台 Mac 上跑），IO 留在 App。
///
/// ## 与 RelayKit 的关系
///
/// 凭据类型 `FeedbackTicket` 属于 RelayKit（它依赖本包），所以这里不引用它，只认一个协议；
/// RelayKit 给它的类型补一句 conformance 即可。
public protocol FeedbackTicketLike: Codable, Sendable {
    var threadId: String { get }
    var createdAt: Date? { get }
}

public enum FeedbackTicketList {

    /// 最多保留多少条。超出丢最旧的。
    public static let cap = 200

    /// 从 Keychain 里那串字符串解出列表。
    ///
    /// **坏数据当空**：解析失败就当成没有，而不是抛错——记录页不该因为一条坏凭据打不开。
    public static func decode<T: FeedbackTicketLike>(_ raw: String?) -> [T] {
        guard let raw, let data = raw.data(using: .utf8),
              let stored = try? JSONDecoder().decode([T].self, from: data)
        else { return [] }
        return normalized(stored)
    }

    /// 编成可以放进 Keychain 的字符串（凭据只含 base64url 与 UUID，UTF-8 往返无损）。
    public static func encode<T: FeedbackTicketLike>(_ tickets: [T]) throws -> String {
        try String(decoding: JSONEncoder().encode(normalized(tickets)), as: UTF8.self)
    }

    /// 排序 + 截断。
    ///
    /// - Parameter cap: 上限；传 0 表示不截断（用例用）。
    public static func normalized<T: FeedbackTicketLike>(_ tickets: [T], cap: Int = FeedbackTicketList.cap) -> [T] {
        let sorted = tickets.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        guard cap > 0 else { return sorted }
        return Array(sorted.prefix(cap))
    }

    /// 记下一条凭据：同线程覆盖旧的，然后把最旧的挤出去。
    public static func saving<T: FeedbackTicketLike>(_ ticket: T,
                                                     into existing: [T],
                                                     cap: Int = FeedbackTicketList.cap) -> [T] {
        var list = existing.filter { $0.threadId != ticket.threadId }
        list.append(ticket)
        return normalized(list, cap: cap)
    }
}
