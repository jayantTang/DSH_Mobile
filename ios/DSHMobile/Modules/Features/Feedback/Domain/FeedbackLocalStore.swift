import DSHFoundation
import DSHKit
import Foundation
import RelayKit

/// 反馈记录在本机留两份东西，清理语义不同，所以分开存取。
///
/// - **取件凭据**放 Keychain（account `feedback.tickets`）：Keychain 项在删 App
///   重装后仍在，这是「重装后还能取回回信」的前提，丢了这台手机就再也拿不回那条线程。
/// - **记录镜像**放 `Caches/feedback/inbox.json`：只增不减地跟着服务端刷新，属于可重建
///   数据，设置页的「清除本地缓存」清它、**不**清凭据。
public struct FeedbackLocalStore: Sendable {
    /// 票据读/写端口（默认 Keychain；测试注入内存实现，避免碰真实钥匙串）。
    public let ticketReader: @Sendable (String) -> String?
    public let ticketWriter: @Sendable (String, String) throws -> Void


    /// Keychain 里那份凭据的名字；与现有 `profile-<uuid>` 同一套 `Keychain`。
    static let ticketsAccount = "feedback.tickets"
    /// 最多保留多少条凭据。判定在 DSHKit（`FeedbackTicketList.cap`），这里只是给调用点留个名字。
    static var maxTickets: Int { FeedbackTicketList.cap }

    /// 镜像根目录。传 `nil` 走 ``defaultRoot``；测试传自己的临时目录，避免并行套件
    /// 争抢进程级环境变量（与 `RelayResumeStore` 的教训一致）。
    public let root: URL?

    public init(root: URL? = nil,
                ticketReader: @escaping @Sendable (String) -> String? = { Keychain.get($0) },
                ticketWriter: @escaping @Sendable (String, String) throws -> Void = { try Keychain.set($1, for: $0) }) {
        self.root = root
        self.ticketReader = ticketReader
        self.ticketWriter = ticketWriter
    }

    /// 生产是 `Caches/feedback`；`#if DEBUG` 下允许测试用环境变量重定向，
    /// 发布版编译掉，任何一个真实构建都写不到开发者的 `~/Library/Caches`。
    static var defaultRoot: URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["DSH_FEEDBACK_STORE_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #endif
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("feedback", isDirectory: true)
    }

    static func mirrorURL(root: URL? = nil) -> URL {
        (root ?? defaultRoot).appendingPathComponent("inbox.json")
    }

    // MARK: - 取件凭据（Keychain）

    /// 本机保存的凭据，按时间倒序；坏数据当作没有，不让一条解析失败挡住整个记录页。
    ///
    /// 排序、去重、截断、坏数据容忍都在 DSHKit（`FeedbackTicketList`，有单测）；这里只读 Keychain。
    public func tickets() -> [FeedbackTicket] {
        FeedbackTicketList.decode(ticketReader(Self.ticketsAccount))
    }

    /// 记下一条凭据（同线程覆盖旧的），并把最旧的挤出去。
    public func save(_ ticket: FeedbackTicket) throws {
        let merged = FeedbackTicketList.saving(ticket, into: tickets())
        // Keychain 存字符串；凭据只含 base64url 与 UUID，UTF-8 往返无损。
        try ticketWriter(Self.ticketsAccount, FeedbackTicketList.encode(merged))
    }

    public func ticket(for threadId: String) -> FeedbackTicket? {
        tickets().first { $0.threadId == threadId }
    }

    /// 清凭据。清掉之后这台手机上的历史反馈不可恢复。
    ///
    /// **App 里目前没有入口调它**：2026-10-12 owner 要求把「从这台手机移除记录」这个选项删掉
    /// （记录页不再有那一行）。留着这个原语是为了将来真要给一条"彻底删除"的路时，最自然的位置是
    /// 设置页「清除本地缓存」旁边，而不是反馈记录页。
    public func removeCredentials() {
        Keychain.remove(Self.ticketsAccount)
    }

    // MARK: - 记录镜像（Caches）

    /// 镜像文件是否存在。第一次安装或换机后不存在，此时要以服务端为准补种已读状态。
    public var mirrorExists: Bool {
        FileManager.default.fileExists(atPath: Self.mirrorURL(root: root).path)
    }

    public func mirror() -> FeedbackMirror {
        guard let data = try? Data(contentsOf: Self.mirrorURL(root: root)),
              let mirror = try? Self.decoder.decode(FeedbackMirror.self, from: data)
        else { return FeedbackMirror() }
        return mirror
    }

    /// 原子写：掉电或被杀时留下一份完整可读的旧文件，而不是半截 JSON。
    public func save(_ mirror: FeedbackMirror) throws {
        let url = Self.mirrorURL(root: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Self.encoder.encode(mirror).write(to: url, options: .atomic)
    }

    /// 清镜像与已读标记，**保留** Keychain 凭据；下次拉取会重新填充。
    public func clearMirror() {
        try? FileManager.default.removeItem(at: Self.mirrorURL(root: root))
    }

    /// 时间戳一律毫秒 int，与 relay 的写法一致，落盘 JSON 与线上 body 读法相同。
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}

/// 镜像两条列表的行数上限（评审 A1 修正；原先两条都是 300，满 300 之后"加载更早"
/// 会变成"点了没变化"的空操作）。
///
/// 体积估算（按实测：通知摘要中位 ≈170 B，线程每条含最多 6 条留言 ≈1.5 KB）：
/// - 通知摘要 5000 条 ≈ 850 KB；
/// - 线程 1000 条 × ≈1.5 KB ≈ 1.5 MB；
/// - 正文缓存仍 20 篇（``FeedbackMirror/maxCachedBodies``），不在这个上限里。
///
/// 这两个数**从构造参数注入**（`FeedbackCenter(rowLimits:)` / `refreshing(rowLimits:)`），
/// 用例才能用很小的值把"触顶"的终止态跑出来；生产默认见 ``default``。
public struct FeedbackMirrorLimits: Sendable, Equatable {
    public var threads: Int
    public var notices: Int

    public static let `default` = FeedbackMirrorLimits(threads: 1000, notices: 5000)

    public init(threads: Int = 1000, notices: Int = 5000) {
        self.threads = threads
        self.notices = notices
    }
}

/// 这次响应**覆盖了哪几条列表的分页位置**。
///
/// 分页请求只推进它自己那一路的游标，但服务端每次仍会把另一路的首页一起返回
/// （协议约定，见 `docs/RELAY-PROTOCOL.md`）。如果那次响应缺了另一路的页
/// （旧的 `notices:false` 就会造成这种形状），把"没带"当成"没有更多"会覆盖掉本地游标。
/// 所以由调用方声明这份响应该更新哪一路——**一份响应只对它请求过的那一页负责**。
public struct FeedbackPageCoverage: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let threads = FeedbackPageCoverage(rawValue: 1 << 0)
    public static let notices = FeedbackPageCoverage(rawValue: 1 << 1)
    /// 首屏刷新：两路都从第一页开始，两个游标都归它更新。
    public static let both: FeedbackPageCoverage = [.threads, .notices]
}

/// `Caches/feedback/inbox.json` 的内容：服务端内容的只读镜像 + 本机事实的已读集合。
///
/// 字段名与顺序照 `specs/014-feedback-channel/data-model.md` 第二节，逐字一致；
/// 2026-10-27 的信件整改往里追加了**可选**键（`mySide`、`serverUnreadCount`、
/// `limits`、两路游标、通知的 `bodyCached`）：旧构建读到它们会忽略，旧镜像缺它们
/// 也能读——**退回旧构建不会重置镜像**。
public struct FeedbackMirror: Codable, Sendable, Equatable {

    public struct Thread: Codable, Sendable, Equatable {
        public init(threadId: String, subject: String? = nil, status: String,
                    createdAt: Date, lastMessageAt: Date, teamUnread: Int = 0,
                    mySide: FeedbackThread.Side = .user,
                    source: FeedbackThreadSource? = nil, messages: [Message]) {
            self.threadId = threadId
            self.subject = subject
            self.status = status
            self.createdAt = createdAt
            self.lastMessageAt = lastMessageAt
            self.teamUnread = teamUnread
            self.mySide = mySide
            self.source = source
            self.messages = messages
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            threadId = try container.decode(String.self, forKey: .threadId)
            subject = try? container.decodeIfPresent(String.self, forKey: .subject)
            status = (try? container.decode(String.self, forKey: .status)) ?? "open"
            createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSince1970: 0)
            lastMessageAt = (try? container.decode(Date.self, forKey: .lastMessageAt)) ?? createdAt
            teamUnread = (try? container.decode(Int.self, forKey: .teamUnread)) ?? 0
            // 旧镜像没有这个键：先按用户侧读，刷新一次由服务端补齐。
            mySide = (try? container.decodeIfPresent(FeedbackThread.Side.self, forKey: .mySide)) ?? .user
            source = try? container.decodeIfPresent(FeedbackThreadSource.self, forKey: .source)
            messages = (try? container.decode([Message].self, forKey: .messages)) ?? []
        }
        public var threadId: String
        /// 可选，理由同 `RelayKit.FeedbackThread.subject`：老镜像文件与还没有这个
        /// 字段的服务端都要能读，缺字段按未填处理。
        public var subject: String? = nil
        public var status: String
        public var createdAt: Date
        public var lastMessageAt: Date
        /// 团队侧口径：这条线程里团队没读的用户来信条数（v1 投影才下发，缺省 0）。
        public var teamUnread: Int = 0
        /// 我这一侧（v2 的 `mySide`）：两栏方向、未读归属、回信入口的唯一依据。
        public var mySide: FeedbackThread.Side = .user
        /// 发件人标识（团队收件箱）；可选——老镜像与无来源的线程都没有。
        public var source: FeedbackThreadSource? = nil
        public var messages: [Message]
    }

    public struct Message: Codable, Sendable, Equatable {
        public var messageId: String
        public var author: String
        public var body: String
        /// 正文格式（FR-034）。可选，理由同上面 `subject`：老镜像文件里没有这一项，
        /// 缺字段按 `text` 渲染。**必须存**——离线时渲染路径只有这份 JSON 可依据，
        /// 丢了它 HTML 报告就会退成 Markdown 原文（FR-034 要求两种格式离线照常渲染）。
        public var format: String? = nil
        public var createdAt: Date
    }

    public struct Notice: Codable, Sendable, Equatable {
        public var noticeId: String
        public var subject: String?
        /// 正文。**字段始终是字符串**：还没取过时写 `""` + `bodyCached = false`。
        ///
        /// 为什么不省掉这个键：旧构建的 `Body` 是非可选的，缺键会让整份镜像解码失败
        /// 并被当成空镜像——那等于把用户的本机记录清空。写 `""` 则旧构建照常解码
        /// （显示成一封空信），重新升级后按 `bodyCached == false` 自动补取。
        public var body: String
        /// 同上：报告类通知靠它才能在离线时仍走 HTML 容器。
        public var format: String? = nil
        public var createdAt: Date
        /// 这份 `body` 是不是真取到过。旧镜像（有正文、没有这个键）视为已缓存。
        public var bodyCached: Bool = true

        public init(noticeId: String, subject: String?, body: String, format: String? = nil,
                    createdAt: Date, bodyCached: Bool = true) {
            self.noticeId = noticeId
            self.subject = subject
            self.body = body
            self.format = format
            self.createdAt = createdAt
            self.bodyCached = bodyCached
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            noticeId = try container.decode(String.self, forKey: .noticeId)
            subject = try? container.decodeIfPresent(String.self, forKey: .subject)
            let rawBody = (try? container.decodeIfPresent(String.self, forKey: .body)) ?? ""
            body = rawBody
            format = try? container.decodeIfPresent(String.self, forKey: .format)
            createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSince1970: 0)
            // 旧镜像只有 `body`：有内容就算取过，空串当没取过。
            bodyCached = (try? container.decodeIfPresent(Bool.self, forKey: .bodyCached)) ?? !rawBody.isEmpty
        }
    }

    public var threads: [Thread] = []
    public var notices: [Notice] = []
    /// 本机已读的 owner 消息。**只在用户真正打开某条时追加**：前台拉取与离线都不动它。
    public var readOwnerMessageIds: [String] = []
    /// 已读的通知。019 之后通知的已读是**账号级**一份（服务端权威）：这里既记"本机打开过"的，
    /// 也记每次拉取时服务端说已经读过的那批，两者取并集——只增不减。
    public var readNoticeIds: [String] = []
    /// 团队视角下「已读集合」记的是**用户来信**（与 readOwnerMessageIds 分侧，互不干扰）。
    public var readUserMessageIds: [String] = []
    /// 服务端判定的账号视角。**不再参与分类**（分类只看每线程 `mySide`）：它只用来给
    /// 旧服务端缺 `mySide` 的线程推导一次，以及离线时认出"这是团队账号"。
    public var teamPerspective: Bool = false
    /// 角标的唯一权威：服务端最后给的那个数。旧镜像没有这个键，按 0 读，刷新后补齐。
    public var serverUnreadCount: Int = 0
    /// 服务端下发的正文长度上限；旧镜像/旧服务端没有就是 nil（读方退编译期默认）。
    public var limits: FeedbackLimits? = nil
    /// 线程列表已加载到哪儿（本机最旧边界）；nil = 这一路没有分页。
    public var threadsPage: FeedbackPage? = nil
    /// 通知摘要列表已加载到哪儿；同上。
    public var noticesPage: FeedbackPage? = nil

    /// 正文缓存仍 20 篇（设计 §M6 / 评审 A1：这一项不动）。
    static let maxCachedBodies = 20

    private enum CodingKeys: String, CodingKey {
        case threads, notices, readOwnerMessageIds, readNoticeIds, readUserMessageIds, teamPerspective
        case serverUnreadCount, limits, threadsPage, noticesPage
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        threads = (try? container.decode([Thread].self, forKey: .threads)) ?? []
        notices = (try? container.decode([Notice].self, forKey: .notices)) ?? []
        readOwnerMessageIds = (try? container.decode([String].self, forKey: .readOwnerMessageIds)) ?? []
        readNoticeIds = (try? container.decode([String].self, forKey: .readNoticeIds)) ?? []
        readUserMessageIds = (try? container.decode([String].self, forKey: .readUserMessageIds)) ?? []
        teamPerspective = (try? container.decode(Bool.self, forKey: .teamPerspective)) ?? false
        serverUnreadCount = (try? container.decode(Int.self, forKey: .serverUnreadCount)) ?? 0
        limits = try? container.decodeIfPresent(FeedbackLimits.self, forKey: .limits)
        threadsPage = try? container.decodeIfPresent(FeedbackPage.self, forKey: .threadsPage)
        noticesPage = try? container.decodeIfPresent(FeedbackPage.self, forKey: .noticesPage)
    }

    public init() {}
}

// 转换构造放在 extension 里：结构体内部一旦声明 init，逐成员 init 就会消失，
// 而 `insert(threadId:createdAt:)` 还要用它。
public extension FeedbackMirror.Thread {
    /// 服务端时间戳缺失时退到纪元 0，而不是把整条线程丢掉；字段本身非可选。
    init(_ thread: FeedbackThread) {
        let created = thread.createdAt ?? Date(timeIntervalSince1970: 0)
        self.init(
            threadId: thread.threadId,
            subject: thread.subject,
            status: thread.status,
            createdAt: created,
            lastMessageAt: thread.lastMessageAt ?? created,
            teamUnread: thread.teamUnread,
            mySide: thread.resolvedSide,
            source: thread.source,
            messages: thread.messages.map(FeedbackMirror.Message.init)
        )
    }
}

public extension FeedbackMirror.Message {
    /// 镜像里的 `author` 存线上原样的字符串（`user` / `owner`）；`format` 也按线上那套
    /// 归一后的取值存（`text` / `html`）。
    init(_ message: FeedbackMessage) {
        self.init(
            messageId: message.messageId,
            author: message.author.rawValue,
            body: message.body,
            format: message.bodyFormat.rawValue,
            createdAt: message.createdAt ?? Date(timeIntervalSince1970: 0)
        )
    }
}

public extension FeedbackMirror.Notice {
    /// 服务端摘要进镜像：有正文（v1 内联）就是已缓存；v2 摘要没有正文，`body` 写 `""`
    /// 并记 `bodyCached = false`——旧构建读到的是一封空信，不会整份镜像解码失败。
    init(_ notice: FeedbackNotice) {
        self.init(
            noticeId: notice.noticeId,
            subject: notice.subject,
            body: notice.body ?? "",
            format: notice.bodyFormat.rawValue,
            createdAt: notice.createdAt ?? Date(timeIntervalSince1970: 0),
            bodyCached: notice.body != nil
        )
    }
}

// MARK: - 与服务端的一致性

public extension FeedbackMirror {

    /// 用这次拉到的内容合并镜像；已读状态**只以服务端为准，只并集、只前进**。
    ///
    /// - 内容：服务端今回给的 ∪ 已加载过的更早页（同一 id 以服务端为准），按各自
    ///   排序键倒序、超上限丢最旧。
    /// - 已读：逐线程按"我这一侧的未读数"把更早的对侧留言并进已读集合。刷新本身
    ///   不会把任何已读变回未读，所以多设备之间只会朝"读过"走。
    /// - 角标：`unreadCount` 是服务端值，落盘（``serverUnreadCount``）。
    ///
    /// `seedingReadState` 只在镜像文件不存在（首次安装、换机、刚清过缓存）时为真：
    /// 那一次等于"从空镜像走同一套对齐"，不是第二套补种规则。
    public func refreshing(with inbox: FeedbackInbox, seedingReadState: Bool,
                           rowLimits: FeedbackMirrorLimits = .default,
                           covering: FeedbackPageCoverage = .both) -> FeedbackMirror {
        var next = seedingReadState ? FeedbackMirror() : self
        next.teamPerspective = inbox.teamPerspective
        next.serverUnreadCount = inbox.unreadCount
        if let limits = inbox.limits { next.limits = limits }
        next.merge(threads: inbox.threads, notices: inbox.notices, rowLimits: rowLimits)
        next.alignReadState(with: inbox)
        // 通知的已读是**账号级**一份：别的设备读过，这台设备的角标与蓝点跟着消失。
        for notice in inbox.notices where notice.read && !next.readNoticeIds.contains(notice.noticeId) {
            next.readNoticeIds.append(notice.noticeId)
        }
        // 刷新只拿到第一页：已加载过的更早页由游标记着，别让这次刷新把它忘掉。
        // 只更新这次请求覆盖的那一路：另一路的页即使缺了，也不能把本地游标改成"到底"。
        if covering.contains(.threads) {
            next.threadsPage = Self.merged(existing: next.threadsPage, incoming: inbox.threadsPage)
        }
        if covering.contains(.notices) {
            next.noticesPage = Self.merged(existing: next.noticesPage, incoming: inbox.noticesPage)
        }
        next.trimBodyCache()
        return next
    }

    /// "镜像缺失时补种"＝从空镜像跑同一套对齐（旧名字保留给调用点与用例）。
    static func seeded(from inbox: FeedbackInbox) -> FeedbackMirror {
        FeedbackMirror().refreshing(with: inbox, seedingReadState: true)
    }

    /// 两次分页游标合一个：保留更靠后（更旧）的那一个。
    ///
    /// - 今回这一页说"没有更早的了" → 以它为准（我们已经翻到底）。
    /// - 之前已经翻到底 → 保留（刷新拿到第一页的 `more: true` 不能让按钮重新出现）。
    /// - 否则取更旧的那个边界（`loadEarlier` 因此只会往前走）。
    private static func merged(existing: FeedbackPage?, incoming: FeedbackPage?) -> FeedbackPage? {
        guard let incoming else { return existing }
        if !incoming.more { return incoming }
        guard let existing else { return incoming }
        if !existing.more { return existing }
        guard let existingCursor = existing.nextBefore, let incomingCursor = incoming.nextBefore else {
            return existing
        }
        return existingCursor.boundary <= incomingCursor.boundary ? existing : incoming
    }

    /// 逐线程对齐已读：服务端的每线程未读数说明"最后 N 条对侧留言还没读"。
    ///
    /// 契约分支只读该版本定义的字段：v2 的 `unread` 就是我这一侧；旧服务端的 `unread`
    /// 是用户侧（owner 回信未读）、`teamUnread` 是团队侧（用户来信未读）。
    mutating func alignReadState(with inbox: FeedbackInbox) {
        for thread in inbox.threads {
            let side = thread.resolvedSide
            let unread = inbox.isVersion2
                ? thread.unread
                : (side == .owner ? thread.teamUnread : thread.unread)
            let incoming = thread.messages
                .filter { $0.author.rawValue == side.counterpart.rawValue }
                .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
                .map(\.messageId)
            let unreadCount = max(0, min(unread, incoming.count))
            appendRead(ids: Array(incoming.prefix(incoming.count - unreadCount)), side: side)
        }
    }

    /// 把一串留言并进"我这一侧"的已读集合；已有的不重复追加。
    private mutating func appendRead(ids: [String], side: FeedbackThread.Side) {
        switch side {
        case .owner:
            var seen = Set(readUserMessageIds)
            for id in ids where seen.insert(id).inserted {
                readUserMessageIds.append(id)
            }
        case .user:
            var seen = Set(readOwnerMessageIds)
            for id in ids where seen.insert(id).inserted {
                readOwnerMessageIds.append(id)
            }
        }
    }

    /// 合并内容：同一 id 以服务端今回返回的为准；更早的分页留在原地。
    mutating func merge(threads incoming: [FeedbackThread], notices incomingNotices: [FeedbackNotice],
                        rowLimits: FeedbackMirrorLimits = .default) {
        var threadById = Dictionary(uniqueKeysWithValues: threads.map { ($0.threadId, $0) })
        for thread in incoming {
            threadById[thread.threadId] = Thread(thread)
        }
        threads = Array(Array(threadById.values).sorted(by: Self.threadOrder).prefix(max(0, rowLimits.threads)))

        var noticeById = Dictionary(uniqueKeysWithValues: notices.map { ($0.noticeId, $0) })
        for notice in incomingNotices {
            if let cached = noticeById[notice.noticeId] {
                noticeById[notice.noticeId] = cached.merged(with: notice)
            } else {
                noticeById[notice.noticeId] = Notice(notice)
            }
        }
        notices = Array(Array(noticeById.values).sorted(by: Self.noticeOrder).prefix(max(0, rowLimits.notices)))
    }

    /// 丢掉两路分页游标（v1 回落时用）：旧服务端/服务端单侧回滚没有分页字段，
    /// 本机留着上次 v2 的游标会让底部"加载更早"点得动却不前进（设计 §2.5：v1 无加载更早）。
    /// **只动游标**，已读集合与镜像内容一律不碰。
    mutating func clearPageCursors() {
        threadsPage = nil
        noticesPage = nil
    }

    /// 提交成功后立刻把空线程塞进镜像，记录页不必等一次拉取就能看到它。
    /// 带着用户写的主题：提交响应里没有正文，主题是那一刻唯一能显示的东西。
    ///
    /// 团队账号的提交也是"用户那一侧"（设计 §2.4），所以这里恒为 `.user`。
    mutating func insert(threadId: String, subject: String? = nil, createdAt: Date) {
        guard !threads.contains(where: { $0.threadId == threadId }) else { return }
        threads.insert(Thread(threadId: threadId, subject: subject, status: "open", createdAt: createdAt,
                              lastMessageAt: createdAt, mySide: .user, messages: []), at: 0)
    }

    /// 用户真正看过之后才追加已读标记：只标"我这一侧的对侧"那些留言。
    mutating func markRead(threadIds: [String], noticeIds: [String]) {
        for index in threads.indices where threadIds.contains(threads[index].threadId) {
            let thread = threads[index]
            let incoming = thread.messages
                .filter { $0.author == thread.mySide.counterpart.rawValue }
                .map(\.messageId)
            appendRead(ids: incoming, side: thread.mySide)
        }
        for id in noticeIds where !readNoticeIds.contains(id) {
            readNoticeIds.append(id)
        }
    }

    /// 本机口径的未读数（只给用例与本机诊断看；**角标不读它**，见 `serverUnreadCount`）。
    /// 归属按每线程 `mySide`：用户侧数对侧回信，团队侧数用户来信；通知两侧同一份。
    public var localUnreadCount: Int {
        let readNotices = Set(readNoticeIds)
        let unreadNotices = notices.filter { !readNotices.contains($0.noticeId) }.count
        var unreadMessages = 0
        for thread in threads {
            let read = Set(readIds(for: thread.mySide))
            unreadMessages += thread.messages.filter {
                $0.author == thread.mySide.counterpart.rawValue && !read.contains($0.messageId)
            }.count
        }
        return unreadMessages + unreadNotices
    }

    /// 显示用的线程：`unread` 按本机已读集合现场算，排序与服务端一致（新的在前）。
    public var displayThreads: [FeedbackThread] {
        threads.map { stored in
            let read = Set(readIds(for: stored.mySide))
            let messages = stored.messages.map { message in
                FeedbackMessage(
                    messageId: message.messageId,
                    author: FeedbackMessage.Author(rawValue: message.author) ?? .unknown,
                    body: message.body,
                    format: message.format,
                    createdAt: message.createdAt
                )
            }
            return FeedbackThread(
                threadId: stored.threadId,
                subject: stored.subject,
                status: stored.status,
                createdAt: stored.createdAt,
                lastMessageAt: stored.lastMessageAt,
                unread: messages.filter {
                    $0.author == stored.mySide.counterpart && !read.contains($0.messageId)
                }.count,
                teamUnread: stored.teamUnread,
                mySide: stored.mySide,
                source: stored.source,
                messages: messages
            )
        }
        .sorted(by: Self.threadOrder)
    }

    /// 单条留言是否还没看过。未读归属只看它所属线程的 `mySide`：只有**对侧**写的才算未读，
    /// 我这一侧写的那封（自己发出去的）永远不是"没读"。
    public func isUnread(messageId: String) -> Bool {
        guard let thread = threads.first(where: { $0.messages.contains { $0.messageId == messageId } }),
              let message = thread.messages.first(where: { $0.messageId == messageId }),
              message.author == thread.mySide.counterpart.rawValue
        else { return false }
        return !readIds(for: thread.mySide).contains(messageId)
    }

    /// 单条通知是否还没看过（账号口径：别的设备读过就等于读过）。
    public func isUnread(noticeId: String) -> Bool {
        !readNoticeIds.contains(noticeId)
    }

    public var displayNotices: [FeedbackNotice] {
        let read = Set(readNoticeIds)
        return notices.map { stored in
            FeedbackNotice(noticeId: stored.noticeId, subject: stored.subject,
                           // 没取过正文就是 nil：列表只要标题，详情页据此显示"需要联网查看"。
                           body: stored.bodyCached ? stored.body : nil,
                           format: stored.format,
                           createdAt: stored.createdAt,
                           read: read.contains(stored.noticeId))
        }
        .sorted(by: Self.noticeOrder)
    }

    // MARK: - 通知正文缓存

    /// 离线可读的那份正文：只有真取到过才返回。
    public func cachedBody(of noticeId: String) -> String? {
        guard let notice = notices.first(where: { $0.noticeId == noticeId }), notice.bodyCached
        else { return nil }
        return notice.body
    }

    /// 打开通知取到正文后写进镜像（`body` + `bodyCached = true`）；列表里没有这条摘要就补一条。
    mutating func storeBody(of notice: FeedbackNotice, cachedBody: String,
                            noticeLimit: Int = FeedbackMirrorLimits.default.notices) {
        if let index = notices.firstIndex(where: { $0.noticeId == notice.noticeId }) {
            notices[index].body = cachedBody
            notices[index].bodyCached = true
            notices[index].subject = notice.subject
            if let format = notice.format { notices[index].format = format }
            if let createdAt = notice.createdAt { notices[index].createdAt = createdAt }
        } else {
            notices.append(Notice(noticeId: notice.noticeId, subject: notice.subject,
                                  body: cachedBody, format: notice.format,
                                  createdAt: notice.createdAt ?? Date(timeIntervalSince1970: 0),
                                  bodyCached: true))
        }
        notices = Array(notices.sorted(by: Self.noticeOrder).prefix(max(0, noticeLimit)))
        trimBodyCache()
    }

    /// 正文缓存上限 20 篇，超了丢最旧。
    mutating func trimBodyCache() {
        let cached = notices.indices
            .filter { notices[$0].bodyCached }
            .sorted { notices[$0].createdAt < notices[$1].createdAt }
        guard cached.count > Self.maxCachedBodies else { return }
        for index in cached.prefix(cached.count - Self.maxCachedBodies) {
            notices[index].body = ""
            notices[index].bodyCached = false
        }
    }

    private func readIds(for side: FeedbackThread.Side) -> [String] {
        side == .owner ? readUserMessageIds : readOwnerMessageIds
    }

    /// 新的在前；同一时刻按 id 倒序（与服务端 `lastMessageAt DESC, threadId DESC` 一致）。
    private static func threadOrder(_ lhs: Thread, _ rhs: Thread) -> Bool {
        if lhs.lastMessageAt != rhs.lastMessageAt { return lhs.lastMessageAt > rhs.lastMessageAt }
        return lhs.threadId > rhs.threadId
    }

    private static func noticeOrder(_ lhs: Notice, _ rhs: Notice) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.noticeId > rhs.noticeId
    }

    /// 显示层的排序键与镜像层同口径（两处各一份重载，规则只有这一句）。
    private static func threadOrder(_ lhs: FeedbackThread, _ rhs: FeedbackThread) -> Bool {
        let left = lhs.lastMessageAt ?? lhs.createdAt ?? .distantPast
        let right = rhs.lastMessageAt ?? rhs.createdAt ?? .distantPast
        if left != right { return left > right }
        return lhs.threadId > rhs.threadId
    }

    private static func noticeOrder(_ lhs: FeedbackNotice, _ rhs: FeedbackNotice) -> Bool {
        let left = lhs.createdAt ?? .distantPast
        let right = rhs.createdAt ?? .distantPast
        if left != right { return left > right }
        return lhs.noticeId > rhs.noticeId
    }
}

// MARK: - 通知摘要合并

extension FeedbackMirror.Notice {
    /// 服务端今回的摘要覆盖标题/时间/格式；正文只有这次真给了才换——v2 摘要不带正文，
    /// 已缓存的正文必须留住。
    func merged(with summary: FeedbackNotice) -> FeedbackMirror.Notice {
        var next = self
        next.subject = summary.subject
        if let format = summary.format { next.format = format }
        if let createdAt = summary.createdAt { next.createdAt = createdAt }
        if let body = summary.body {
            next.body = body
            next.bodyCached = true
        }
        return next
    }
}
