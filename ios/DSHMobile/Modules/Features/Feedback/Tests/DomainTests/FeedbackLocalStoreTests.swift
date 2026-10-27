@testable import DSHFeedbackDomain
import Foundation
import RelayKit
import XCTest

/// `FeedbackLocalStore` / `FeedbackMirror`: the two things the records page is
/// built on — the mirror file (`Caches/feedback/inbox.json`) and the read set
/// that lives beside it.
///
/// What these cases pin down, in the words the code uses:
///
/// * a refresh merges the server's copy of threads/notices into the cached pages
///   and never shrinks the read sets (union, "只增不减");
/// * the **server is the only owner of read state**: every pull aligns each
///   thread's unread count into the local read set, and nothing ever turns a
///   read message unread again (the old "seeding only once" rule is gone);
/// * unread attribution follows **each thread's own `mySide`** — the account-level
///   `teamPerspective` no longer classifies anything;
/// * what goes to disk comes back byte-for-byte equivalent, including Chinese
///   text and the optional fields that earlier mirrors never had.
final class FeedbackLocalStoreTests: XCTestCase {

    // MARK: - Merge semantics

    /// A refresh whose inbox no longer mentions an old thread still keeps it (the
    /// cached earlier pages are the whole point of paging), and pulls in the
    /// notices the server says were read somewhere else. Nothing in the read sets
    /// may go away.
    func test_refresh_merges_the_server_copy_without_shrinking_the_read_set() {
        var mirror = FeedbackMirror()
        mirror.threads = [mirrorThread("th_old", lastMessageAt: 1_000, messages: [mirrorOwnerMessage("m_1", at: 1_000)])]
        mirror.readOwnerMessageIds = ["m_1", "m_2"]
        mirror.readNoticeIds = ["n_local"]

        let inbox = FeedbackInbox(
            threads: [wireThread(threadId: "th_new", subject: Zh.newThread, status: "open",
                                 createdAt: date(2_000), lastMessageAt: date(2_000), unread: 1,
                                 messages: [wireMessage("m_9", at: 2_000)])],
            notices: [wireNotice("n_server_read", body: Zh.weeklyReport, format: "html", createdAt: date(3_000), read: true)],
            unreadCount: 4
        )

        let next = mirror.refreshing(with: inbox, seedingReadState: false)

        // Content is the union: the fresh thread on top, the cached one still there.
        XCTAssertEqual(next.threads.map(\.threadId), ["th_new", "th_old"])
        XCTAssertEqual(next.notices.map(\.noticeId), ["n_server_read"])
        // ...but the read ids it carried are not.
        XCTAssertEqual(next.readOwnerMessageIds, ["m_1", "m_2"])
        XCTAssertEqual(next.readNoticeIds, ["n_local", "n_server_read"])
        XCTAssertEqual(next.serverUnreadCount, 4)

        // Refreshing again with the same answer changes nothing at all: the
        // union is idempotent, not append-on-every-pull.
        XCTAssertEqual(next.refreshing(with: inbox, seedingReadState: false), next)
    }

    /// 刷新把服务端的已读并进来（读过的只会更多），并且任何路径都不会把已读
    /// 变回未读——替换掉旧用例 `never marks threads read`。
    func test_refresh_aligns_server_thread_read_state_and_never_regresses() {
        let messages = [wireMessage("u_1", author: .user, body: Zh.openSpins, at: 500),
                        wireMessage("m_1", at: 1_000),
                        wireMessage("m_2", at: 2_000),
                        wireMessage("m_3", at: 3_000)]

        var mirror = FeedbackMirror()
        mirror.threads = [mirrorThread("th_1", lastMessageAt: 3_000,
                                       messages: [mirrorUserMessage("u_1", at: 500),
                                                  mirrorOwnerMessage("m_1", at: 1_000),
                                                  mirrorOwnerMessage("m_2", at: 2_000),
                                                  mirrorOwnerMessage("m_3", at: 3_000)])]
        mirror.readNoticeIds = ["n_mine"]

        // The relay says one owner reply is still unread: the older two were read
        // somewhere (maybe another device), so they join the read set here.
        let oneUnread = FeedbackInbox(
            threads: [wireThread(threadId: "th_1", lastMessageAt: date(3_000), unread: 1, messages: messages)],
            notices: [wireNotice("n_other_device", body: Zh.reportBody, createdAt: date(4_000), read: true)],
            unreadCount: 2
        )
        let once = mirror.refreshing(with: oneUnread, seedingReadState: false)
        XCTAssertEqual(once.readOwnerMessageIds, ["m_1", "m_2"])
        XCTAssertFalse(once.isUnread(messageId: "m_1"))
        XCTAssertTrue(once.isUnread(messageId: "m_3"))
        XCTAssertEqual(once.serverUnreadCount, 2, "the badge is the server's number")
        XCTAssertEqual(once.readNoticeIds, ["n_mine", "n_other_device"],
                       "account-level notice read state keeps merging in")
        XCTAssertEqual(once.localUnreadCount, 1)

        // The relay now reports all three unread (state moved backwards): the local
        // read set must not follow it back.
        let allUnread = FeedbackInbox(
            threads: [wireThread(threadId: "th_1", lastMessageAt: date(3_000), unread: 3, messages: messages)],
            notices: [],
            unreadCount: 3
        )
        let twice = once.refreshing(with: allUnread, seedingReadState: false)
        XCTAssertEqual(twice.readOwnerMessageIds, ["m_1", "m_2"], "read state only moves forward")
        XCTAssertEqual(twice.localUnreadCount, 1)
        XCTAssertEqual(twice.serverUnreadCount, 3, "the badge still reports the server's number")
        XCTAssertEqual(twice.refreshing(with: allUnread, seedingReadState: false), twice)
    }

    /// A 设备读过的回信，B 设备的镜像刷新后蓝点消失、角标等于服务端值；再刷新幂等。
    func test_a_read_on_another_device_clears_the_dot_and_the_badge_here() {
        var mirror = FeedbackMirror()
        mirror.threads = [mirrorThread("th_1", lastMessageAt: 2_000,
                                       messages: [mirrorUserMessage("u_1", at: 1_000),
                                                  mirrorOwnerMessage("m_1", at: 2_000)])]
        mirror.serverUnreadCount = 1
        XCTAssertTrue(mirror.isUnread(messageId: "m_1"))

        let readElsewhere = FeedbackInbox(
            threads: [wireThread(threadId: "th_1", lastMessageAt: date(2_000), unread: 0,
                                 messages: [wireMessage("u_1", author: .user, body: Zh.openSpins, at: 1_000),
                                            wireMessage("m_1", at: 2_000)])],
            notices: [],
            unreadCount: 0
        )
        let next = mirror.refreshing(with: readElsewhere, seedingReadState: false)
        XCTAssertFalse(next.isUnread(messageId: "m_1"), "the other device's read must clear this dot")
        XCTAssertEqual(next.serverUnreadCount, 0)
        XCTAssertEqual(next.refreshing(with: readElsewhere, seedingReadState: false), next,
                       "a second pull is idempotent")
    }

    // MARK: - Seeding

    /// Seeding happens only when the mirror file is absent: that pull is the same
    /// alignment run against an empty mirror. The server's per-thread `unread`
    /// marks the *oldest* messages read, clamped, and it never touches the other
    /// side's messages.
    func test_seeding_marks_the_older_incoming_messages_read_from_the_server_unread_count() {
        func inbox(unread: Int) -> FeedbackInbox {
            FeedbackInbox(
                threads: [wireThread(threadId: "th_1", lastMessageAt: date(3_000), unread: unread,
                                     messages: [wireMessage("u_1", author: .user, body: Zh.openSpins, at: 500),
                                                wireMessage("m_1", at: 1_000),
                                                wireMessage("m_2", at: 2_000),
                                                wireMessage("m_3", at: 3_000)])],
                notices: [wireNotice("n_1", body: Zh.noticeWord, createdAt: date(4_000), read: true)],
                unreadCount: unread
            )
        }

        let seeded = FeedbackMirror.seeded(from: inbox(unread: 1))
        XCTAssertEqual(seeded.readOwnerMessageIds, ["m_1", "m_2"])
        XCTAssertFalse(seeded.readOwnerMessageIds.contains("u_1"),
                       "the side I wrote is not what my unread count is about")
        // Seeding is the same alignment, so the content and the notice read state
        // come along too (there is no second, notice-less seeding path).
        XCTAssertEqual(seeded.threads.map(\.threadId), ["th_1"])
        XCTAssertEqual(seeded.readNoticeIds, ["n_1"])

        // A server that reports more unread messages than the thread has leaves
        // everything unread rather than over-reading.
        XCTAssertTrue(FeedbackMirror.seeded(from: inbox(unread: 9)).readOwnerMessageIds.isEmpty)
        // Zero unread means the whole thread was already read elsewhere.
        XCTAssertEqual(FeedbackMirror.seeded(from: inbox(unread: 0)).readOwnerMessageIds, ["m_1", "m_2", "m_3"])

        // Through `refreshing`, seeding is the branch that *replaces* local read
        // state — correct only because callers do it when the file is missing.
        let seededViaRefresh = FeedbackMirror().refreshing(with: inbox(unread: 1), seedingReadState: true)
        XCTAssertEqual(seededViaRefresh.readOwnerMessageIds, ["m_1", "m_2"])
        XCTAssertEqual(seededViaRefresh.readNoticeIds, ["n_1"])
    }

    // MARK: - Contract branches (v1 vs v2)

    /// v1 负载（没有 inboxVersion）：团队侧读 `teamUnread`（用户来信未读），
    /// 用户侧读 `unread`（owner 回信未读）。这正是旧服务端两个字段各自的含义。
    func test_v1_payload_reads_the_side_specific_unread_field() {
        let teamInbox = FeedbackInbox(
            threads: [wireThread(threadId: "th_1", lastMessageAt: date(2_000), unread: 5, teamUnread: 1,
                                 messages: [wireMessage("u_1", author: .user, body: Zh.openSpins, at: 1_000),
                                            wireMessage("o_1", at: 2_000)])],
            notices: [],
            unreadCount: 1,
            teamPerspective: true
        )
        let team = FeedbackMirror().refreshing(with: teamInbox, seedingReadState: true)
        XCTAssertEqual(team.threads.first?.mySide, .owner, "missing mySide falls back to the account side")
        XCTAssertEqual(team.readUserMessageIds, [], "one unread user letter out of one")
        XCTAssertTrue(team.isUnread(messageId: "u_1"))

        let userInbox = FeedbackInbox(
            threads: [wireThread(threadId: "th_1", lastMessageAt: date(2_000), unread: 1, teamUnread: 5,
                                 messages: [wireMessage("u_1", author: .user, body: Zh.openSpins, at: 1_000),
                                            wireMessage("o_1", at: 2_000)])],
            notices: [],
            unreadCount: 1
        )
        let user = FeedbackMirror().refreshing(with: userInbox, seedingReadState: true)
        XCTAssertEqual(user.threads.first?.mySide, .user)
        XCTAssertEqual(user.readOwnerMessageIds, [], "one unread owner reply out of one")
        XCTAssertTrue(user.isUnread(messageId: "o_1"))
        XCTAssertFalse(user.isUnread(messageId: "u_1"))
    }

    /// v2 负载只认 `unread`（我这一侧）：故意塞一个 `teamUnread` 也不改变结果，
    /// 两个分支不混读。
    func test_v2_payload_reads_only_unread_even_when_team_unread_is_present() {
        let inbox = FeedbackInbox(
            threads: [wireThread(threadId: "th_1", lastMessageAt: date(2_000), unread: 0, teamUnread: 9,
                                 mySide: .owner,
                                 messages: [wireMessage("u_1", author: .user, body: Zh.openSpins, at: 1_000),
                                            wireMessage("o_1", at: 2_000)])],
            notices: [],
            unreadCount: 0,
            teamPerspective: true,
            inboxVersion: 2
        )
        let mirror = FeedbackMirror().refreshing(with: inbox, seedingReadState: true)
        XCTAssertEqual(mirror.threads.first?.mySide, .owner)
        XCTAssertEqual(mirror.readUserMessageIds, ["u_1"],
                       "v2 unread is my side's; the injected teamUnread must be ignored")
        XCTAssertFalse(mirror.isUnread(messageId: "u_1"))
    }

    // MARK: - Per-thread side

    /// 团队账号自己的线程（mySide == .user）：不进收件箱、不产生未读、没有回信入口。
    /// 「不进收件箱」= 没有对侧来信（`incomingLetter == nil`）。
    func test_a_team_authored_letter_counts_no_unread_and_has_no_incoming_letter() {
        let thread = FeedbackThread(
            threadId: "th_own", status: "open",
            createdAt: date(1_000), lastMessageAt: date(1_000),
            unread: 0, mySide: .user,
            messages: [wireMessage("u_1", author: .user, body: Zh.userBody, at: 1_000)]
        )
        var mirror = FeedbackMirror()
        mirror.teamPerspective = true
        mirror.threads = [mirrorThread("th_own", lastMessageAt: 1_000, mySide: .user,
                                       messages: [mirrorUserMessage("u_1", body: Zh.userBody, at: 1_000)])]

        XCTAssertEqual(mirror.localUnreadCount, 0, "my own letter is not something I have not read")
        XCTAssertNil(thread.incomingLetter, "no counterpart letter: it does not belong in the inbox")
        XCTAssertNotNil(thread.myLetter)
        XCTAssertFalse(thread.canReply, "no reply entry for my own letter")
    }

    /// 未读归属按每线程 mySide：同一条线程在两侧之间切换时，数的是对侧那一封。
    func test_unread_follows_each_threads_own_side() {
        var mirror = FeedbackMirror()
        mirror.teamPerspective = true
        mirror.threads = [FeedbackMirror.Thread(
            threadId: "th_1", status: "open", createdAt: date(1), lastMessageAt: date(2),
            mySide: .owner,
            messages: [
                FeedbackMirror.Message(messageId: "u_1", author: "user", body: "question", createdAt: date(1)),
                FeedbackMirror.Message(messageId: "o_1", author: "owner", body: "answer", createdAt: date(2)),
            ])]
        XCTAssertEqual(mirror.localUnreadCount, 1, "team side counts the user's letter, not the owner's reply")

        // Same thread, now the side I am on is the user's (e.g. the team's own
        // submission): the count switches to the owner's reply.
        mirror.threads[0].mySide = .user
        XCTAssertEqual(mirror.localUnreadCount, 1, "user side counts the owner reply")

        mirror.readOwnerMessageIds = ["o_1"]
        XCTAssertEqual(mirror.localUnreadCount, 0, "reading the owner reply clears the user-side badge")
        XCTAssertFalse(mirror.readUserMessageIds.contains("u_1"), "the two read sets must not mix")
    }

    /// 账号视角仍随镜像落盘（离线时用来认出团队账号），但它不再决定分类。
    func test_team_perspective_survives_the_mirror_round_trip() throws {
        let root = TempFeedbackRoot(label: "perspective")
        defer { root.remove() }
        var mirror = FeedbackMirror()
        mirror.teamPerspective = true
        try root.store().save(mirror)
        XCTAssertTrue(root.store().mirror().teamPerspective)
    }

    // MARK: - Old mirror migration

    /// 旧镜像（无 mySide / serverUnreadCount / limits）读入不丢记录；刷新一次补齐。
    func test_an_old_mirror_loads_without_losing_rows_and_is_filled_by_one_refresh() throws {
        let root = TempFeedbackRoot(label: "old-mirror")
        defer { root.remove() }
        var old = FeedbackMirror()
        old.threads = [mirrorThread("th_1", lastMessageAt: 2_000,
                                    messages: [mirrorUserMessage("u_1", at: 1_000),
                                               mirrorOwnerMessage("m_1", at: 2_000)])]
        old.notices = [mirrorNotice("n_1", at: 3_000)]
        old.readNoticeIds = ["n_1"]
        try root.store().save(old)

        let loaded = root.store().mirror()
        XCTAssertEqual(loaded.threads.map(\.threadId), ["th_1"])
        XCTAssertNil(loaded.limits)
        XCTAssertEqual(loaded.serverUnreadCount, 0)

        let inbox = FeedbackInbox(
            threads: [wireThread(threadId: "th_1", lastMessageAt: date(2_000), unread: 0,
                                 mySide: .owner,
                                 messages: [wireMessage("u_1", author: .user, body: Zh.openSpins, at: 1_000),
                                            wireMessage("m_1", at: 2_000)])],
            notices: [],
            unreadCount: 7,
            teamPerspective: true,
            inboxVersion: 2,
            limits: FeedbackLimits(textChars: 4_100, textBytes: 12_300)
        )
        let refreshed = loaded.refreshing(with: inbox, seedingReadState: false)
        XCTAssertEqual(refreshed.threads.first?.mySide, .owner, "the server's mySide overwrites the default")
        XCTAssertEqual(refreshed.serverUnreadCount, 7)
        XCTAssertEqual(refreshed.limits, FeedbackLimits(textChars: 4_100, textBytes: 12_300))
        XCTAssertEqual(refreshed.readUserMessageIds, ["u_1"],
                       "the freshly resolved team side reads the user letter; the old read set is kept")
    }

    // MARK: - Disk

    /// Save then read returns an equal mirror, Chinese intact and the optional
    /// fields still absent rather than turned into `null`.
    func test_saving_then_reading_the_mirror_round_trips_chinese_and_absent_fields() throws {
        let root = TempFeedbackRoot(label: "roundtrip")
        defer { root.remove() }
        let store = root.store()

        var mirror = FeedbackMirror()
        mirror.threads = [mirrorThread(
            "th_zh",
            subject: Zh.threadSubject,
            status: "replied",
            createdAt: 1_760_000_000_000,
            lastMessageAt: 1_760_000_001_000,
            messages: [mirrorUserMessage("m_u1", body: Zh.userBody, at: 1_760_000_000_500),
                       mirrorOwnerMessage("m_o1", body: Zh.ownerReplySpins, format: "text", at: 1_760_000_001_000)]
        )]
        // A notice without a subject and with an HTML body: both optional fields
        // matter, one absent, one present.
        mirror.notices = [mirrorNotice("n_1", subject: nil, body: Zh.htmlNotice, format: "html", at: 1_760_000_002_000)]
        mirror.readOwnerMessageIds = ["m_o1"]

        try store.save(mirror)

        XCTAssertTrue(store.mirrorExists)
        XCTAssertEqual(store.mirror(), mirror)

        // On-disk shape: epoch milliseconds as a number, Chinese as UTF-8 text,
        // absent optionals omitted entirely.
        let text = try root.mirrorText()
        XCTAssertTrue(text.contains("1760000001000"), text)
        XCTAssertFalse(text.contains(#""1760000001000""#), text)
        XCTAssertTrue(text.contains(Zh.threadSubject), text)
        XCTAssertTrue(text.contains(Zh.ownerReplySpins), text)
        // …and as raw UTF-8, not as `\uXXXX` escapes: a mirror another reader
        // opens by eye should show the words, not the code points.
        XCTAssertFalse(text.contains(#"\u"#), text)
        XCTAssertTrue(text.contains(#""format":"html""#), text)
        XCTAssertFalse(text.contains(#""subject":null"#), text)
        XCTAssertFalse(text.contains(#""format":null"#), text)

        // The escape-written fixtures themselves have to be the characters the
        // comments promise: 8 CJK scalars, three bytes each, first one 0x4F1A.
        XCTAssertEqual(Zh.threadSubject.count, 8)
        XCTAssertEqual(Data(Zh.threadSubject.utf8).count, 24)
        XCTAssertEqual(Zh.threadSubject.unicodeScalars.first, "\u{4F1A}")
    }

    /// A mirror file written before the optional fields existed still reads, and
    /// saving it again does not invent keys for them.
    func test_a_legacy_mirror_file_without_the_optional_keys_still_reads() throws {
        let root = TempFeedbackRoot(label: "legacy")
        defer { root.remove() }
        let store = root.store()

        // 正文经 `\#(...)` 插进来：老镜像确实是没有 `subject`/`format` 键的。
        let legacy = #"""
        {"threads":[{"threadId":"th_1","status":"replied","createdAt":1760000000000,"lastMessageAt":1760000001000,"messages":[{"messageId":"m_1","author":"owner","body":"\#(Zh.oldMirrorReply)","createdAt":1760000001000}]}],"notices":[{"noticeId":"n_1","body":"\#(Zh.oldMirrorNotice)","createdAt":1760000002000}],"readOwnerMessageIds":["m_1"],"readNoticeIds":["n_1"]}
        """#
        try root.writeMirror(legacy)

        let mirror = store.mirror()

        XCTAssertNil(mirror.threads.first?.subject)
        XCTAssertNil(mirror.threads.first?.messages.first?.format)
        XCTAssertNil(mirror.notices.first?.subject)
        XCTAssertNil(mirror.notices.first?.format)
        XCTAssertEqual(mirror.threads.first?.messages.first?.body, Zh.oldMirrorReply)
        XCTAssertEqual(mirror.threads.first?.createdAt, date(1_760_000_000_000))
        XCTAssertEqual(mirror.threads.first?.mySide, .user, "a mirror without mySide reads as the user side")
        XCTAssertEqual(mirror.notices.first?.bodyCached, true, "an old notice with a body counts as cached")
        XCTAssertEqual(mirror.readOwnerMessageIds, ["m_1"])
        XCTAssertEqual(mirror.readNoticeIds, ["n_1"])
        XCTAssertEqual(mirror.localUnreadCount, 0)

        try store.save(mirror)
        let rewritten = try root.mirrorText()
        XCTAssertFalse(rewritten.contains(#""format""#), rewritten)
        XCTAssertFalse(rewritten.contains(#""subject""#), rewritten)
        XCTAssertEqual(store.mirror(), mirror)
    }

    /// 新构建写出的镜像（未取正文时 `body: ""` + `bodyCached: false`）用旧构建的形状
    /// 解码不抛错、不重置；旧构建读到的正文是空串。降级因此是平滑的。
    func test_a_legacy_shape_can_decode_the_mirror_this_build_writes() throws {
        struct LegacyMirror: Decodable {
            struct Thread: Decodable {
                let threadId: String
                let subject: String?
                let status: String
                let createdAt: Date
                let lastMessageAt: Date
                let messages: [Message]
            }
            struct Message: Decodable {
                let messageId: String
                let author: String
                let body: String
                let createdAt: Date
            }
            struct Notice: Decodable {
                let noticeId: String
                let subject: String?
                let body: String
                let createdAt: Date
            }
            let threads: [Thread]
            let notices: [Notice]
            let readOwnerMessageIds: [String]
            let readNoticeIds: [String]
        }

        let root = TempFeedbackRoot(label: "downgrade")
        defer { root.remove() }
        var mirror = FeedbackMirror()
        mirror.threads = [mirrorThread("th_1", lastMessageAt: 2_000, mySide: .owner,
                                       messages: [mirrorOwnerMessage("m_1", at: 2_000)])]
        mirror.readOwnerMessageIds = ["m_1"]
        // 还没取过正文的通知：写 "" 占位。
        mirror.notices = [mirrorNotice("n_1", body: "", at: 3_000, bodyCached: false)]
        mirror.serverUnreadCount = 2
        mirror.threadsPage = FeedbackPage(more: true, nextBefore: FeedbackPageCursor(
            lastMessageAt: date(2_000), threadId: "th_1"))
        try root.store().save(mirror)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let legacy = try decoder.decode(LegacyMirror.self, from: Data(contentsOf: root.mirrorURL))

        XCTAssertEqual(legacy.threads.map(\.threadId), ["th_1"])
        XCTAssertEqual(legacy.notices.map(\.noticeId), ["n_1"])
        XCTAssertEqual(legacy.notices.first?.body, "", "the old build shows an empty letter, not a reset")
        XCTAssertEqual(legacy.readOwnerMessageIds, ["m_1"])
    }

    /// Missing, unreadable and half-written files all read as an empty mirror:
    /// the records page must open with nothing rather than not open at all.
    func test_a_missing_or_corrupt_mirror_reads_as_empty_and_clear_removes_the_file() throws {
        let root = TempFeedbackRoot(label: "corrupt")
        defer { root.remove() }
        let store = root.store()

        XCTAssertFalse(store.mirrorExists)
        XCTAssertEqual(store.mirror(), FeedbackMirror())

        try root.writeMirror(Zh.corruptMirror)
        XCTAssertTrue(store.mirrorExists)
        XCTAssertEqual(store.mirror(), FeedbackMirror())

        var mirror = FeedbackMirror()
        mirror.threads = [mirrorThread("th_1", lastMessageAt: 1_000, messages: [])]
        try store.save(mirror)
        XCTAssertTrue(store.mirrorExists)
        XCTAssertEqual(store.mirror().threads.count, 1)

        store.clearMirror()

        XCTAssertFalse(store.mirrorExists)
        XCTAssertEqual(store.mirror(), FeedbackMirror())
        // Clearing twice is fine — the settings page's "清除本地缓存" is idempotent.
        store.clearMirror()
        XCTAssertFalse(store.mirrorExists)
    }

    // MARK: - Read rows

    /// The blue dots and `localUnreadCount` come from the local read set computed
    /// against the stored copy; owner messages only, sorted newest first.
    func test_local_unread_count_and_display_rows_follow_the_local_read_set() {
        var mirror = FeedbackMirror()
        mirror.threads = [
            mirrorThread("th_a", subject: Zh.threadA, lastMessageAt: 20_000,
                         messages: [mirrorUserMessage("u_1", at: 18_000),
                                    mirrorOwnerMessage("m_1", at: 19_000),
                                    mirrorOwnerMessage("m_2", format: "html", at: 20_000)]),
            mirrorThread("th_b", status: "open", lastMessageAt: 10_000,
                         messages: [mirrorOwnerMessage("m_3", at: 10_000)]),
        ]
        mirror.notices = [mirrorNotice("n_1", at: 30_000), mirrorNotice("n_2", at: 5_000)]
        mirror.readOwnerMessageIds = ["m_1"]
        mirror.readNoticeIds = ["n_2"]

        XCTAssertEqual(mirror.localUnreadCount, 3)

        let rows = mirror.displayThreads
        XCTAssertEqual(rows.map(\.threadId), ["th_a", "th_b"])
        XCTAssertEqual(rows[0].unread, 1)
        XCTAssertEqual(rows[1].unread, 1)
        XCTAssertEqual(rows[0].mySide, .user)
        XCTAssertEqual(rows[0].messages.count, 3)
        XCTAssertEqual(rows[0].messages[1].author, .owner)
        XCTAssertEqual(rows[0].messages[1].bodyFormat, .text)
        XCTAssertEqual(rows[0].messages[2].bodyFormat, .html)

        XCTAssertFalse(mirror.isUnread(messageId: "m_1"))
        XCTAssertTrue(mirror.isUnread(messageId: "m_2"))
        XCTAssertTrue(mirror.isUnread(messageId: "m_3"))
        XCTAssertTrue(mirror.isUnread(noticeId: "n_1"))
        XCTAssertFalse(mirror.isUnread(noticeId: "n_2"))

        let notices = mirror.displayNotices
        XCTAssertEqual(notices.map(\.noticeId), ["n_1", "n_2"])
        XCTAssertFalse(notices[0].read)
        XCTAssertTrue(notices[1].read)
        XCTAssertEqual(notices[0].format, nil)
        XCTAssertEqual(notices[0].body, Zh.noticeText, "a cached body is visible to the detail page")
    }

    // MARK: - Notice body cache

    /// 通知正文按需缓存：写进去之后离线可读；超过 20 篇丢最旧；
    /// 刷新只带摘要时不会把已缓存的正文冲掉。
    func test_notice_bodies_are_cached_up_to_twenty_and_survive_a_summary_only_refresh() {
        var mirror = FeedbackMirror()
        for index in 1...21 {
            mirror.notices.append(mirrorNotice("n_\(index)", body: "", at: index * 1_000, bodyCached: false))
        }
        for index in 1...21 {
            mirror.storeBody(
                of: FeedbackNotice(noticeId: "n_\(index)", subject: "s", body: Zh.noticeText,
                                   format: "text", createdAt: date(index * 1_000), read: false),
                cachedBody: Zh.noticeText)
        }

        XCTAssertEqual(mirror.notices.filter(\.bodyCached).count, 20, "twenty bodies at most")
        XCTAssertNil(mirror.cachedBody(of: "n_1"), "the oldest body is the one dropped")
        XCTAssertEqual(mirror.cachedBody(of: "n_21"), Zh.noticeText)

        // A pull that only carries summaries must not erase the cached body.
        let summaryOnly = FeedbackInbox(
            threads: [],
            notices: [wireNotice("n_21", subject: "s", format: "text", createdAt: date(21_000), read: true)],
            unreadCount: 0,
            inboxVersion: 2
        )
        let refreshed = mirror.refreshing(with: summaryOnly, seedingReadState: false)
        XCTAssertEqual(refreshed.cachedBody(of: "n_21"), Zh.noticeText)
        XCTAssertTrue(refreshed.displayNotices.first(where: { $0.noticeId == "n_21" })?.read == true,
                      "the summary's read flag still lands")

        // A notice the mirror has never seen has no body to show.
        XCTAssertNil(refreshed.cachedBody(of: "n_missing"))
    }
}

// MARK: - RelayKit fixtures

/// The wire types the client decodes. Built through the public initialisers so
/// the cases read like the relay's answers rather than like JSON plumbing.
func wireThread(
    threadId: String,
    subject: String? = nil,
    status: String = "replied",
    createdAt: Date? = nil,
    lastMessageAt: Date,
    unread: Int,
    teamUnread: Int = 0,
    mySide: FeedbackThread.Side? = nil,
    messages: [FeedbackMessage]
) -> FeedbackThread {
    FeedbackThread(threadId: threadId, subject: subject, status: status,
                   createdAt: createdAt ?? lastMessageAt,
                   lastMessageAt: lastMessageAt, unread: unread,
                   teamUnread: teamUnread, mySide: mySide, messages: messages)
}

func wireMessage(_ messageId: String, author: FeedbackMessage.Author = .owner,
                 body: String = Zh.ownerReply, format: String? = nil, at millis: Int) -> FeedbackMessage {
    FeedbackMessage(messageId: messageId, author: author, body: body, format: format, createdAt: date(millis))
}

func wireNotice(_ noticeId: String, subject: String? = nil, body: String? = nil,
                format: String? = nil, createdAt: Date, read: Bool) -> FeedbackNotice {
    FeedbackNotice(noticeId: noticeId, subject: subject, body: body, format: format,
                   createdAt: createdAt, read: read)
}

extension FeedbackLocalStoreTests {
    /// 028：票据写入走注入端口，不碰真实钥匙串（此前 submit 成功路径会写真 Keychain）。
    func testTicketWriterGoesThroughTheInjectedPort() throws {
        var memory: [String: String] = [:]
        let store = FeedbackLocalStore(
            root: nil,
            ticketReader: { memory[$0] },
            ticketWriter: { memory[$0] = $1 })
        XCTAssertTrue(store.tickets().isEmpty)

        let ticket = FeedbackTicket(threadId: "t-1", ticketKey: "k-1")
        try store.save(ticket)
        XCTAssertEqual(store.tickets().map(\.threadId), ["t-1"])
        XCTAssertNotNil(memory["feedback.tickets"], "the write must land in the injected store")
    }
}
