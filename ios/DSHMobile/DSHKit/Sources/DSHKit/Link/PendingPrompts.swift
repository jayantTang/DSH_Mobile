import Foundation

/// 宿主事件的**待答集合**（spec 023 边界收敛：从 `HostEventHub` 里抽出来的纯判定）。
///
/// ## 它管什么
///
/// 宿主用一条 waterfall 事件"挂住"自己，等手机回答；手机这边要维护一份"现在有哪些在等我"。
/// 这份集合有两个动作：**waterfall 把它推进来**（按 eventId 去重，重连补投不会出现两条），
/// **cancelled 把它拿掉**（宿主那边释放了 Agent Context）。
///
/// ## 为什么值得从 App 里抽出来
///
/// "手机看不出 agent 在等你"是本仓库反复踩的一类问题（见 `maintainers/PENDING-WATERFALL-LOSS.md`：
/// 提问发生的那一刻手机没连着，这条就再也不会到手机）。判定本身只有上面两条，但**它决定用户在
/// 手机上看得见什么**，而原来它写在一个 `@MainActor @Observable` 的类里、只能靠真机验。
/// 抽成值类型之后，去重/取消/按会话过滤都能在秒级单测里钉住。
/// ## 它同时是一个集合
///
/// 调用方习惯把它当数组用（`pending.map(\.id)` / `pending.first(where:)` / `isEmpty`），
/// 所以这里直接实现 `Collection`：读取面与数组一致，写入面只有下面那几个带判定的方法。
public struct PendingPrompts: Sendable, Equatable, RandomAccessCollection {

    /// 一个在等用户回应的提示。
    public struct Item: Sendable, Equatable, Identifiable {
        public let id: String
        public let event: String
        public let agentId: String
        public let request: JSONValue
        public let arrivedAt: Date

        /// 这条提示属于哪个会话（宿主用 agentId 指会话）。
        public var sessionId: String { agentId }

        public init(id: String, event: String, agentId: String, request: JSONValue, arrivedAt: Date) {
            self.id = id
            self.event = event
            self.agentId = agentId
            self.request = request
            self.arrivedAt = arrivedAt
        }
    }

    /// 到达顺序（先来的在前）。
    public private(set) var items: [Item]

    public init(items: [Item] = []) {
        self.items = items
    }

    // MARK: - Collection

    public typealias Element = Item
    public typealias Index = Int

    public var startIndex: Int { items.startIndex }
    public var endIndex: Int { items.endIndex }
    public func index(after i: Int) -> Int { items.index(after: i) }
    public func index(before i: Int) -> Int { items.index(before: i) }
    public subscript(position: Int) -> Item { items[position] }

    /// 某条事件对集合的影响。
    public enum Effect: Sendable, Equatable {
        /// 集合变了（新推进来一条 / 拿掉一条）。
        case changed
        /// 集合没变（重复推送、无关事件）。
        case unchanged
    }

    /// 应用一条宿主事件。
    ///
    /// * `.waterfall` → 按 `eventId` 去重后追加；
    /// * `.cancelled` → 移除该 `eventId`；
    /// * 其它事件不动集合（`.ready`/`.emit`/`.unknown` 由调用方自己处理）。
    @discardableResult
    public mutating func apply(_ event: HostEvent, now: Date = Date()) -> Effect {
        switch event {
        case .waterfall(let waterfall):
            guard !items.contains(where: { $0.id == waterfall.eventId }) else { return .unchanged }
            items.append(Item(id: waterfall.eventId,
                              event: waterfall.event,
                              agentId: waterfall.agentId,
                              request: waterfall.request,
                              arrivedAt: now))
            return .changed
        case .cancelled(let eventId):
            let before = items.count
            items.removeAll { $0.id == eventId }
            return items.count == before ? .unchanged : .changed
        case .ready, .emit, .unknown:
            return .unchanged
        }
    }

    /// 某条事件是否属于"会改变集合"的那两类（供调用方决定要不要记诊断）。
    public static func changesPending(_ event: HostEvent) -> Bool {
        switch event {
        case .waterfall, .cancelled: return true
        case .ready, .emit, .unknown: return false
        }
    }

    /// 等某个会话回应的那些提示。
    public func forSession(_ sessionId: String) -> [Item] {
        items.filter { $0.agentId == sessionId }
    }

    /// 用户回答（或转给别人）之后，本地先把它拿掉。
    public mutating func remove(id: String) {
        items.removeAll { $0.id == id }
    }

    /// 一次去掉多条（032：别的设备答掉的那批）。返回是否真的动了集合。
    @discardableResult
    public mutating func remove(ids: Set<String>) -> Bool {
        guard !ids.isEmpty else { return false }
        let before = items.count
        items.removeAll { ids.contains($0.id) }
        return items.count != before
    }

    /// 断开链路时清空：链路上的待答已经不可达了。
    public mutating func removeAll() {
        items.removeAll()
    }
}
