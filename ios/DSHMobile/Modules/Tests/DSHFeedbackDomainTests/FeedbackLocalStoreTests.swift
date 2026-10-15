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
/// * a refresh replaces the *server's* copy of threads and notices but never
///   shrinks the read sets (union, "只增不减");
/// * seeding (mirror file absent) is the one path that derives read state from
///   the server's `unread` count;
/// * what goes to disk comes back byte-for-byte equivalent, including Chinese
///   text and the optional fields that a pre-FR-034 mirror file never had.
final class FeedbackLocalStoreTests: XCTestCase {

    // MARK: - Merge semantics

    /// A refresh whose inbox no longer mentions a thread still keeps that
    /// thread's read ids, and pulls in the notices the server says were read
    /// somewhere else. Nothing in the read sets may go away.
    func test_refresh_replaces_the_server_copy_without_shrinking_the_read_set() {
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

        // Content follows the server; the old thread is gone from the mirror...
        XCTAssertEqual(next.threads.map(\.threadId), ["th_new"])
        XCTAssertEqual(next.notices.map(\.noticeId), ["n_server_read"])
        // ...but the read ids it carried are not.
        XCTAssertEqual(next.readOwnerMessageIds, ["m_1", "m_2"])
        XCTAssertEqual(next.readNoticeIds, ["n_local", "n_server_read"])

        // Refreshing again with the same answer changes nothing at all: the
        // union is idempotent, not append-on-every-pull.
        XCTAssertEqual(next.refreshing(with: inbox, seedingReadState: false), next)
    }

    /// A pull is read-only on the local side: it never marks owner messages as
    /// read, and it merges the server's account-level notice read state.
    func test_refresh_unions_server_read_notices_and_never_marks_threads_read() {
        var mirror = FeedbackMirror()
        mirror.threads = [mirrorThread("th_1", lastMessageAt: 2_000,
                                       messages: [mirrorOwnerMessage("m_1", at: 1_000),
                                                  mirrorOwnerMessage("m_2", at: 2_000)])]
        mirror.readNoticeIds = ["n_mine"]

        let inbox = FeedbackInbox(
            threads: [wireThread(threadId: "th_1", lastMessageAt: date(2_000), unread: 2,
                                 messages: [wireMessage("m_1", at: 1_000), wireMessage("m_2", at: 2_000)])],
            notices: [wireNotice("n_other_device", body: Zh.reportBody, createdAt: date(3_000), read: true),
                      wireNotice("n_open", body: Zh.notYetRead, createdAt: date(4_000), read: false)],
            unreadCount: 3
        )

        let next = mirror.refreshing(with: inbox, seedingReadState: false)

        XCTAssertTrue(next.readOwnerMessageIds.isEmpty)
        XCTAssertEqual(next.readNoticeIds, ["n_mine", "n_other_device"])
        XCTAssertFalse(next.isUnread(noticeId: "n_other_device"))
        XCTAssertTrue(next.isUnread(noticeId: "n_open"))
        // Two unread owner replies plus one unread notice.
        XCTAssertEqual(next.localUnreadCount, 3)
    }

    // MARK: - Seeding

    /// Seeding happens only when the mirror file is absent: the server's
    /// `unread` count is then the only clue, and it marks the *oldest* owner
    /// messages read. It is clamped, and it never touches user messages.
    func test_seeding_marks_the_older_owner_messages_read_from_the_server_unread_count() {
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
        XCTAssertFalse(seeded.readOwnerMessageIds.contains("u_1"))
        // Notices are not seeded here: `refreshing` merges them on every pull.
        XCTAssertTrue(seeded.readNoticeIds.isEmpty)

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
        XCTAssertEqual(mirror.readOwnerMessageIds, ["m_1"])
        XCTAssertEqual(mirror.readNoticeIds, ["n_1"])
        XCTAssertEqual(mirror.localUnreadCount, 0)

        try store.save(mirror)
        let rewritten = try root.mirrorText()
        XCTAssertFalse(rewritten.contains(#""format""#), rewritten)
        XCTAssertFalse(rewritten.contains(#""subject""#), rewritten)
        XCTAssertEqual(store.mirror(), mirror)
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

    /// The badge and the blue dots come from the local read set computed against
    /// the stored copy: owner messages only, sorted newest first.
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
    messages: [FeedbackMessage]
) -> FeedbackThread {
    FeedbackThread(threadId: threadId, subject: subject, status: status,
                   createdAt: createdAt ?? lastMessageAt,
                   lastMessageAt: lastMessageAt, unread: unread, messages: messages)
}

func wireMessage(_ messageId: String, author: FeedbackMessage.Author = .owner,
                 body: String = Zh.ownerReply, format: String? = nil, at millis: Int) -> FeedbackMessage {
    FeedbackMessage(messageId: messageId, author: author, body: body, format: format, createdAt: date(millis))
}

func wireNotice(_ noticeId: String, subject: String? = nil, body: String,
                format: String? = nil, createdAt: Date, read: Bool) -> FeedbackNotice {
    FeedbackNotice(noticeId: noticeId, subject: subject, body: body, format: format,
                   createdAt: createdAt, read: read)
}
