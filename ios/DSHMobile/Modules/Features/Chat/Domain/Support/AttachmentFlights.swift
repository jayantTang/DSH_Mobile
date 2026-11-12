import Foundation

/// "这张图还没有字节、链路恢复时应当重来"的唯一记录（设计 §5 B1）。
///
/// 与"还有一个尝试循环在跑"（``AttachmentImages`` 的 `drivers`）是**两个事实**：
///
/// - flight 存在 = 这张图仍然没有字节；
/// - driver 存在 = 现在正有一条尝试循环在跑。
///
/// 因此"自动次数用尽"只结束驱动，**不**结算 flight：链路恢复时 `linkEstablished()`
/// 仍有对象可重启，用户不必手动点重试。只有"已加载"与"用户取消 / 重置"才 `settle`。
///
/// 内部键是 `session|attachmentId`：附件 id 只在一个会话里有意义。
public struct AttachmentFlights: Sendable, Equatable {

    /// 一条待办：哪个会话里的哪张图（`variant` 是内容标识，可为空）。
    public struct Flight: Sendable, Equatable {
        public let session: String
        public let attachmentId: String
        public let variant: String?

        public init(session: String, attachmentId: String, variant: String?) {
            self.session = session
            self.attachmentId = attachmentId
            self.variant = variant
        }
    }

    private var flights: [String: Flight] = [:]

    public init() {}

    /// 内部键：`session|attachmentId`（会话 id 里没有 `|`，附件 id 是宿主给的）。
    public static func key(session: String, attachmentId: String) -> String {
        "\(session)|\(attachmentId)"
    }

    /// 登记一条待办（重复登记覆盖同一条，不产生第二条）。
    public mutating func register(id: String, variant: String?, session: String) {
        flights[Self.key(session: session, attachmentId: id)] = Flight(
            session: session, attachmentId: id, variant: variant)
    }

    /// 结案：字节已经拿到，或用户取消 / 重置。之后 `awaiting(session:)` 不再返回它。
    public mutating func settle(id: String, session: String) {
        flights.removeValue(forKey: Self.key(session: session, attachmentId: id))
    }

    /// 按内部键结案（驱动退出时手上只有键的情形）。
    public mutating func settle(key: String) {
        flights.removeValue(forKey: key)
    }

    /// 这个会话里还没拿到字节的那些（按登记顺序）。
    public func awaiting(session: String) -> [String: Flight] {
        flights.filter { $0.value.session == session }
    }

    /// 这个会话里的全部待办（同 `awaiting`，名字更直白）。
    public func pending(session: String) -> [Flight] {
        awaiting(session: session).values.sorted { $0.attachmentId < $1.attachmentId }
    }

    /// 某张图是否还欠着字节。
    public func isAwaiting(id: String, session: String) -> Bool {
        flights[Self.key(session: session, attachmentId: id)] != nil
    }

    /// 某张图登记的 variant（`nil` = 没登记过，或登记时没有 variant）。
    public func variant(id: String, session: String) -> String? {
        flights[Self.key(session: session, attachmentId: id)]?.variant
    }

    /// 只保留给定会话里的待办（切会话 / 裁剪状态桶时用）。
    public mutating func prune(sessions: Set<String>) {
        flights = flights.filter { sessions.contains($0.value.session) }
    }

    public mutating func removeAll() {
        flights.removeAll()
    }

    public var count: Int { flights.count }
}
