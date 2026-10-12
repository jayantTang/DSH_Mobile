import Foundation
import RelayKit

/// 反馈记录在本机留两份东西，清理语义不同，所以分开存取。
///
/// - **取件凭据**放 Keychain（account `feedback.tickets`）：Keychain 项在删 App
///   重装后仍在，这是「重装后还能取回回信」的前提，丢了这台手机就再也拿不回那条线程。
/// - **记录镜像**放 `Caches/feedback/inbox.json`：只增不减地跟着服务端刷新，属于可重建
///   数据，设置页的「清除本地缓存」清它、**不**清凭据。
struct FeedbackLocalStore: Sendable {

    /// Keychain 里那份凭据的名字；与现有 `profile-<uuid>` 同一套 `Keychain`。
    static let ticketsAccount = "feedback.tickets"
    /// 最多保留多少条凭据，超出丢最旧的（服务端仍在，只是这台手机取不回来）。
    static let maxTickets = 200

    /// 镜像根目录。传 `nil` 走 ``defaultRoot``；测试传自己的临时目录，避免并行套件
    /// 争抢进程级环境变量（与 `RelayResumeStore` 的教训一致）。
    let root: URL?

    init(root: URL? = nil) {
        self.root = root
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
    func tickets() -> [FeedbackTicket] {
        guard let raw = Keychain.get(Self.ticketsAccount),
              let data = raw.data(using: .utf8),
              let stored = try? JSONDecoder().decode([FeedbackTicket].self, from: data)
        else { return [] }
        return Array(sorted(stored).prefix(Self.maxTickets))
    }

    /// 记下一条凭据（同线程覆盖旧的），并把最旧的挤出去。
    func save(_ ticket: FeedbackTicket) throws {
        var list = tickets().filter { $0.threadId != ticket.threadId }
        list.append(ticket)
        let trimmed = Array(sorted(list).prefix(Self.maxTickets))
        let data = try JSONEncoder().encode(trimmed)
        // Keychain 存字符串；凭据只含 base64url 与 UUID，UTF-8 往返无损。
        try Keychain.set(String(decoding: data, as: UTF8.self), for: Self.ticketsAccount)
    }

    func ticket(for threadId: String) -> FeedbackTicket? {
        tickets().first { $0.threadId == threadId }
    }

    /// 清凭据。清掉之后这台手机上的历史反馈不可恢复。
    ///
    /// **App 里目前没有入口调它**：2026-10-12 owner 要求把「从这台手机移除记录」这个选项删掉
    /// （记录页不再有那一行）。留着这个原语是为了将来真要给一条"彻底删除"的路时，最自然的位置是
    /// 设置页「清除本地缓存」旁边，而不是反馈记录页。
    func removeCredentials() {
        Keychain.remove(Self.ticketsAccount)
    }

    private func sorted(_ list: [FeedbackTicket]) -> [FeedbackTicket] {
        list.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    // MARK: - 记录镜像（Caches）

    /// 镜像文件是否存在。第一次安装或换机后不存在，此时要以服务端为准补种已读状态。
    var mirrorExists: Bool {
        FileManager.default.fileExists(atPath: Self.mirrorURL(root: root).path)
    }

    func mirror() -> FeedbackMirror {
        guard let data = try? Data(contentsOf: Self.mirrorURL(root: root)),
              let mirror = try? Self.decoder.decode(FeedbackMirror.self, from: data)
        else { return FeedbackMirror() }
        return mirror
    }

    /// 原子写：掉电或被杀时留下一份完整可读的旧文件，而不是半截 JSON。
    func save(_ mirror: FeedbackMirror) throws {
        let url = Self.mirrorURL(root: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Self.encoder.encode(mirror).write(to: url, options: .atomic)
    }

    /// 清镜像与已读标记，**保留** Keychain 凭据；下次拉取会重新填充。
    func clearMirror() {
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

/// `Caches/feedback/inbox.json` 的内容：服务端内容的只读镜像 + 本机事实的已读集合。
///
/// 字段名与顺序照 `specs/014-feedback-channel/data-model.md` 第二节，逐字一致。
struct FeedbackMirror: Codable, Sendable, Equatable {

    struct Thread: Codable, Sendable, Equatable {
        var threadId: String
        /// 可选，理由同 `RelayKit.FeedbackThread.subject`：老镜像文件与还没有这个
        /// 字段的服务端都要能读，缺字段按未填处理。
        var subject: String? = nil
        var status: String
        var createdAt: Date
        var lastMessageAt: Date
        var messages: [Message]
    }

    struct Message: Codable, Sendable, Equatable {
        var messageId: String
        var author: String
        var body: String
        var createdAt: Date
    }

    struct Notice: Codable, Sendable, Equatable {
        var noticeId: String
        var subject: String?
        var body: String
        var createdAt: Date
    }

    var threads: [Thread] = []
    var notices: [Notice] = []
    /// 本机已读的 owner 消息。**只在用户真正打开某条时追加**：前台拉取与离线都不动它。
    var readOwnerMessageIds: [String] = []
    /// 本机已读的通知。
    var readNoticeIds: [String] = []
}

// 转换构造放在 extension 里：结构体内部一旦声明 init，逐成员 init 就会消失，
// 而 `insert(threadId:createdAt:)` 还要用它。
extension FeedbackMirror.Thread {
    /// 服务端时间戳缺失时退到纪元 0，而不是把整条线程丢掉；字段本身非可选。
    init(_ thread: FeedbackThread) {
        let created = thread.createdAt ?? Date(timeIntervalSince1970: 0)
        self.init(
            threadId: thread.threadId,
            subject: thread.subject,
            status: thread.status,
            createdAt: created,
            lastMessageAt: thread.lastMessageAt ?? created,
            messages: thread.messages.map(FeedbackMirror.Message.init)
        )
    }
}

extension FeedbackMirror.Message {
    /// 镜像里的 `author` 存线上原样的字符串（`user` / `owner`）。
    init(_ message: FeedbackMessage) {
        self.init(
            messageId: message.messageId,
            author: message.author.rawValue,
            body: message.body,
            createdAt: message.createdAt ?? Date(timeIntervalSince1970: 0)
        )
    }
}

extension FeedbackMirror.Notice {
    init(_ notice: FeedbackNotice) {
        self.init(
            noticeId: notice.noticeId,
            subject: notice.subject,
            body: notice.body,
            createdAt: notice.createdAt ?? Date(timeIntervalSince1970: 0)
        )
    }
}

// MARK: - 与服务端的一致性

extension FeedbackMirror {

    /// 用这次拉到的内容覆盖镜像；已读集合原样保留，所以刷新本身永远不会清未读。
    ///
    /// `seedingReadState` 只在镜像文件不存在（首次安装、换机、刚清过缓存）时为真：
    /// 那一次服务端的 `unread`/`read` 是唯一线索，用它补种，免得把早就读过的消息
    /// 重新标成未读。
    func refreshing(with inbox: FeedbackInbox, seedingReadState: Bool) -> FeedbackMirror {
        var next = seedingReadState ? FeedbackMirror.seeded(from: inbox) : self
        next.threads = inbox.threads.map(Thread.init)
        next.notices = inbox.notices.map(Notice.init)
        return next
    }

    static func seeded(from inbox: FeedbackInbox) -> FeedbackMirror {
        var mirror = FeedbackMirror()
        for thread in inbox.threads {
            let ownerIds = thread.messages
                .filter { $0.author == .owner }
                .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
                .map(\.messageId)
            let unread = max(0, min(thread.unread, ownerIds.count))
            mirror.readOwnerMessageIds.append(contentsOf: ownerIds.prefix(ownerIds.count - unread))
        }
        mirror.readNoticeIds = inbox.notices.filter(\.read).map(\.noticeId)
        return mirror
    }

    /// 提交成功后立刻把空线程塞进镜像，记录页不必等一次拉取就能看到它。
    /// 带着用户写的主题：提交响应里没有正文，主题是那一刻唯一能显示的东西。
    mutating func insert(threadId: String, subject: String? = nil, createdAt: Date) {
        guard !threads.contains(where: { $0.threadId == threadId }) else { return }
        threads.insert(Thread(threadId: threadId, subject: subject, status: "open", createdAt: createdAt,
                              lastMessageAt: createdAt, messages: []), at: 0)
    }

    /// 用户真正看过之后才追加已读标记。
    mutating func markRead(threadIds: [String], noticeIds: [String]) {
        for index in threads.indices where threadIds.contains(threads[index].threadId) {
            let ownerIds = threads[index].messages
                .filter { $0.author == FeedbackMessage.Author.owner.rawValue }
                .map(\.messageId)
            for id in ownerIds where !readOwnerMessageIds.contains(id) {
                readOwnerMessageIds.append(id)
            }
        }
        for id in noticeIds where !readNoticeIds.contains(id) {
            readNoticeIds.append(id)
        }
    }

    /// 本机口径的未读数：镜像里 owner 的、不在已读集合里的消息 + 未读通知。
    var localUnreadCount: Int {
        let readMessages = Set(readOwnerMessageIds)
        let readNotices = Set(readNoticeIds)
        let unreadMessages = threads
            .flatMap(\.messages)
            .filter { $0.author == FeedbackMessage.Author.owner.rawValue && !readMessages.contains($0.messageId) }
        let unreadNotices = notices.filter { !readNotices.contains($0.noticeId) }
        return unreadMessages.count + unreadNotices.count
    }

    /// 显示用的线程：`unread` 按本机已读集合现场算，排序与服务端一致（新的在前）。
    var displayThreads: [FeedbackThread] {
        let read = Set(readOwnerMessageIds)
        return threads.map { stored in
            let messages = stored.messages.map { message in
                FeedbackMessage(
                    messageId: message.messageId,
                    author: FeedbackMessage.Author(rawValue: message.author) ?? .unknown,
                    body: message.body,
                    createdAt: message.createdAt
                )
            }
            return FeedbackThread(
                threadId: stored.threadId,
                subject: stored.subject,
                status: stored.status,
                createdAt: stored.createdAt,
                lastMessageAt: stored.lastMessageAt,
                unread: messages.filter { $0.author == .owner && !read.contains($0.messageId) }.count,
                messages: messages
            )
        }
        .sorted { ($0.lastMessageAt ?? $0.createdAt ?? .distantPast)
            > ($1.lastMessageAt ?? $1.createdAt ?? .distantPast) }
    }

    /// 单条 owner 留言是否还没看过。列表的蓝点按**每一封信**标，所以不能只看线程的
    /// `unread`（那是整条线程的合计，一条线程里可能有多封回信）。
    func isUnread(messageId: String) -> Bool {
        !readOwnerMessageIds.contains(messageId)
    }

    /// 单条通知是否还没看过。
    func isUnread(noticeId: String) -> Bool {
        !readNoticeIds.contains(noticeId)
    }

    var displayNotices: [FeedbackNotice] {
        let read = Set(readNoticeIds)
        return notices
            .map { stored in
                FeedbackNotice(noticeId: stored.noticeId, subject: stored.subject,
                               body: stored.body, createdAt: stored.createdAt,
                               read: read.contains(stored.noticeId))
            }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }
}
