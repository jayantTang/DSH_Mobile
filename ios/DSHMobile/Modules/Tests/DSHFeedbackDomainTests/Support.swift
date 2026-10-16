@testable import DSHFeedbackDomain
import DSHFoundation
import DSHTestingSupport
import Foundation
import RelayKit
import XCTest

/// 用例里的中文数据。
///
/// 字面量一律写成 `\u{...}` 转义，**源码里没有一个 CJK 字符**：
/// `scripts/dev/check-localization.mjs` 把任何含 CJK 的 Swift 字符串字面量当成
/// 硬编码的用户文案（Tests 也在扫描范围），而这几条用例要测的恰恰是中文经过
/// JSON 编解码与落盘之后还完好。转义之后的运行时取值就是行尾注释里那几个词。
enum Zh {
    static let threadSubject = "\u{4F1A}\u{8BDD}\u{5217}\u{8868}\u{4E00}\u{76F4}\u{8F6C}\u{5708}"  // 会话列表一直转圈
    static let userBody = "\u{70B9}\u{4E86}\u{65B0}\u{5EFA}\u{4F1A}\u{8BDD}\u{5C31}\u{8F6C}\u{5708}"  // 点了新建会话就转圈
    static let openSpins = "\u{70B9}\u{5F00}\u{5C31}\u{8F6C}\u{5708}"  // 点开就转圈
    static let ownerReply = "\u{6536}\u{5230}\u{FF0C}\u{6B63}\u{5728}\u{67E5}"  // 收到，正在查
    static let ownerReplySpins = "\u{6536}\u{5230}\u{FF0C}\u{6B63}\u{5728}\u{67E5}\u{8FD9}\u{4E2A}\u{8F6C}\u{5708}"  // 收到，正在查这个转圈
    static let noticeBody = "\u{672C}\u{5468}\u{66F4}\u{65B0}"  // 本周更新
    static let noticeBody2 = "\u{65B0}\u{7684}\u{901A}\u{77E5}"  // 新的通知
    static let fixedReply = "\u{5DF2}\u{7ECF}\u{4FEE}\u{597D}\u{4E86}"  // 已经修好了
    static let noticeWord = "\u{901A}\u{77E5}"  // 通知
    static let noticeText = "\u{901A}\u{77E5}\u{6B63}\u{6587}"  // 通知正文
    static let reportBody = "\u{62A5}\u{544A}"  // 报告
    static let notYetRead = "\u{8FD8}\u{6CA1}\u{770B}"  // 还没看
    static let weeklyReport = "\u{5468}\u{62A5}"  // 周报
    static let newThread = "\u{65B0}\u{7EBF}\u{7A0B}"  // 新线程
    static let oldMirrorReply = "\u{8001}\u{955C}\u{50CF}\u{7684}\u{56DE}\u{4FE1}"  // 老镜像的回信
    static let oldMirrorNotice = "\u{8001}\u{955C}\u{50CF}\u{7684}\u{901A}\u{77E5}"  // 老镜像的通知
    static let threadA = "\u{7532}"  // 甲
    static let notJson = "\u{8FD9}\u{4E0D}\u{662F}"  // 这不是
    static let htmlNotice = "<p>" + noticeBody + "</p>"  // <p>本周更新</p>
    /// 半截 JSON：结构开了口、正文不是 JSON（`{"threads": [ 这不是 JSON`）。
    static let corruptMirror = #"{"threads": [ "# + notJson + " JSON"
}

/// Shared scaffolding for the feedback-domain cases.
///
/// Three rules this file exists to enforce:
///
/// * **every case gets its own mirror root.** `FeedbackLocalStore` takes `root`
///   precisely so a suite never reaches the developer's real
///   `Caches/feedback/inbox.json`; the root lives under the process temp dir and
///   is deleted whichever way the case ended.
/// * **wire answers are written as JSON text.** The relay's inbox body is what
///   the client decodes, so the fixtures are strings the loopback stub replays —
///   the case then exercises decoding, not a hand-built object graph.
/// * **nothing here touches the Keychain.** `FeedbackLocalStore.tickets()` reads
///   `feedback.tickets` from the real keychain; that read is harmless (no such
///   item exists on a development machine, verified), but no case writes one:
///   `FeedbackLocalStore.save(_ ticket:)` has no injection seam, so the submit
///   success path is deliberately left to the simulator lanes.

/// A throwaway mirror root for one case.
final class TempFeedbackRoot {
    let url: URL

    init(label: String) {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-feedback-tests", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func store() -> FeedbackLocalStore { FeedbackLocalStore(root: url) }

    var mirrorURL: URL { FeedbackLocalStore.mirrorURL(root: url) }

    func writeMirror(_ text: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: mirrorURL)
    }

    func mirrorText() throws -> String {
        try String(contentsOf: mirrorURL, encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
        // Drops the shared container too, but only while it is empty — a case
        // running in parallel would have left something in it, and the failure
        // to remove is silent on purpose.
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

/// 取件凭据放哪儿：用例注入的内存实现。
///
/// `FeedbackLocalStore` 默认把凭据写进**真实钥匙串**（account `feedback.tickets`），
/// 所以只有需要走通"提交成功"那条路的用例才注入它——提交成功必须能测，但绝不能
/// 在开发者机器上留下一条 Keychain 项。读写都在锁里，闭包是 `@Sendable` 的。
final class TicketBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    var text: String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func write(_ value: String) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}

/// Shared scaffolding for the cases that drive a real `FeedbackCenter` over the
/// loopback stub.
///
/// One stub and one mirror root per case, both torn down whichever way the case
/// ended: the stub is what makes the request count observable, and the root is
/// what keeps a case off the developer's real `Caches/feedback/inbox.json`.
@MainActor
class FeedbackCenterTestCase: XCTestCase {
    /// The loopback relay this case talks to. Set by ``makeStub()``.
    private(set) var stub: LoopbackHTTPStub!
    /// 每条用例自己的镜像根，`tearDown` 里全部删掉。
    private var roots: [TempFeedbackRoot] = []

    override func tearDown() {
        stub?.stop()
        stub = nil
        for root in roots { root.remove() }
        roots = []
        super.tearDown()
    }

    func makeRoot(_ label: String) -> TempFeedbackRoot {
        let root = TempFeedbackRoot(label: label)
        roots.append(root)
        return root
    }

    func makeStub() throws -> LoopbackHTTPStub {
        let stub = try LoopbackHTTPStub()
        self.stub = stub
        return stub
    }

    /// A center pointed at one loopback endpoint; `interval` is the throttle.
    func center(
        store: FeedbackLocalStore,
        interval: TimeInterval = 0,
        url: URL? = nil,
        token: String? = nil
    ) -> FeedbackCenter {
        let target = url ?? stub.baseURL
        return FeedbackCenter(store: store, minimumRefreshInterval: interval, endpointProvider: {
            FeedbackCenter.Endpoint(url: target, deviceToken: token)
        })
    }

    /// A mirror with one owner reply it has not read and one unread notice.
    func unreadMirror() -> FeedbackMirror {
        var mirror = FeedbackMirror()
        mirror.threads = [mirrorThread("th_1", subject: Zh.threadSubject, lastMessageAt: 2_000,
                                       messages: [mirrorUserMessage("m_u1", at: 1_000),
                                                  mirrorOwnerMessage("m_1", at: 2_000)])]
        mirror.notices = [mirrorNotice("n_1", body: Zh.noticeBody, at: 3_000)]
        return mirror
    }
}

// MARK: - Mirror fixtures (what lands in inbox.json)

func date(_ millis: Int) -> Date { Date(timeIntervalSince1970: Double(millis) / 1000) }

func mirrorOwnerMessage(_ id: String, body: String = Zh.ownerReply, format: String? = nil, at millis: Int) -> FeedbackMirror.Message {
    FeedbackMirror.Message(messageId: id, author: "owner", body: body, format: format, createdAt: date(millis))
}

func mirrorUserMessage(_ id: String, body: String = Zh.openSpins, at millis: Int) -> FeedbackMirror.Message {
    FeedbackMirror.Message(messageId: id, author: "user", body: body, format: "text", createdAt: date(millis))
}

func mirrorThread(
    _ id: String,
    subject: String? = nil,
    status: String = "replied",
    createdAt: Int? = nil,
    lastMessageAt: Int,
    messages: [FeedbackMirror.Message]
) -> FeedbackMirror.Thread {
    FeedbackMirror.Thread(
        threadId: id,
        subject: subject,
        status: status,
        createdAt: date(createdAt ?? lastMessageAt),
        lastMessageAt: date(lastMessageAt),
        messages: messages
    )
}

func mirrorNotice(
    _ id: String,
    subject: String? = nil,
    body: String = Zh.noticeText,
    format: String? = nil,
    at millis: Int
) -> FeedbackMirror.Notice {
    FeedbackMirror.Notice(noticeId: id, subject: subject, body: body, format: format, createdAt: date(millis))
}

// MARK: - Wire fixtures (what the relay answers)

func wireMessageJSON(
    _ id: String,
    author: String = "owner",
    body: String,
    format: String? = nil,
    at millis: Int
) -> String {
    var fields = [
        #""messageId":"\#(id)""#,
        #""author":"\#(author)""#,
        #""body":"\#(body)""#,
        #""createdAt":\#(millis)"#,
    ]
    if let format { fields.append(#""format":"\#(format)""#) }
    return "{\(fields.joined(separator: ","))}"
}

func wireThreadJSON(
    _ id: String,
    subject: String? = nil,
    status: String = "replied",
    unread: Int = 0,
    lastMessageAt: Int,
    messages: [String]
) -> String {
    var fields = [
        #""threadId":"\#(id)""#,
        #""status":"\#(status)""#,
        #""unread":\#(unread)"#,
        #""createdAt":\#(lastMessageAt)"#,
        #""lastMessageAt":\#(lastMessageAt)"#,
    ]
    if let subject { fields.append(#""subject":"\#(subject)""#) }
    fields.append(#""messages":[\#(messages.joined(separator: ","))]"#)
    return "{\(fields.joined(separator: ","))}"
}

func wireNoticeJSON(
    _ id: String,
    body: String,
    format: String? = nil,
    read: Bool,
    at millis: Int
) -> String {
    var fields = [
        #""noticeId":"\#(id)""#,
        #""body":"\#(body)""#,
        #""createdAt":\#(millis)"#,
        #""read":\#(read)"#,
    ]
    if let format { fields.append(#""format":"\#(format)""#) }
    return "{\(fields.joined(separator: ","))}"
}

/// One `/feedback/inbox` answer.
func inboxJSON(threads: [String] = [], notices: [String] = [], unreadCount: Int = 0) -> String {
    #"{"ok":true,"threads":[\#(threads.joined(separator: ","))],"notices":[\#(notices.joined(separator: ","))],"unreadCount":\#(unreadCount)}"#
}

/// One `/feedback/read` answer.
func markReadJSON(unreadCount: Int) -> String {
    #"{"ok":true,"unreadCount":\#(unreadCount)}"#
}

/// A JSON body that is not the envelope the client expects — the "relay
/// answered something else" branch.
let notTheEnvelope = "<html><body>502</body></html>"
