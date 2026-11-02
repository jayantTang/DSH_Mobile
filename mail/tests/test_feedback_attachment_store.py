"""存储层：附件表、草稿与绑定、清扫编排（设计 M2-A/B/C、M4-A）。

要钉的事实：(a) 新表是**加法**（老库打开后自动获得它，既有四张表列不动）；
(b) 幂等、配额、绑定**只有一份实现**（handler 不重算）；(c) 空正文 + 0 草稿的
那次调用**不 commit**（线程/留言/绑定都不落库）。
"""

from __future__ import annotations

import os
import sqlite3

import pytest

import attachments as files
import mail as mail_module
from store import (Conflict, EmptyLetter, NotFound, QuotaExceeded, SealedLetter, Store,
                   StoreError, sha256_hex)

LIMITS = {"maxPerMessage": 8, "maxFileBytes": 8 * 1024 * 1024,
          "maxTotalBytes": 24 * 1024 * 1024, "maxPerThreadBytes": 48 * 1024 * 1024,
          "storageSoftBytes": 2 * 1024 * 1024 * 1024}

ATTACHMENT_COLUMNS = ["attachmentId", "scope", "draftRef", "slot", "threadId", "messageId",
                      "noticeId", "originDeviceId", "originAccountId", "clientRef", "fileName",
                      "contentType", "byteSize", "sha256", "width", "height", "state",
                      "storedPath", "createdAt", "storedAt", "boundAt"]
ATTACHMENT_INDEXES = {"feedbackAttachmentsDraftSlot", "feedbackAttachmentsByMessage",
                      "feedbackAttachmentsByNotice", "feedbackAttachmentsByState",
                      "feedbackAttachmentsByDraft", "feedbackAttachmentsNoticeRef"}


def columns(path: str, table: str) -> list[str]:
    conn = sqlite3.connect(path)
    try:
        return [row[1] for row in conn.execute(f"PRAGMA table_info({table})")]
    finally:
        conn.close()


def indexes(path: str, table: str) -> set[str]:
    conn = sqlite3.connect(path)
    try:
        return {row[1] for row in conn.execute(f"PRAGMA index_list({table})")}
    finally:
        conn.close()


def draft(store: Store, *, client_ref: str = "ref-1", slot: int = 0, size: int = 10,
          thread_id: str | None = None, device_id: str = "dev_1", account_id: str | None = None,
          name: str = "截屏.png", content_type: str = "image/png",
          limits: dict | None = None, at: int | None = None) -> dict:
    return store.begin_attachment(
        draft_ref=client_ref, slot=slot, thread_id=thread_id, file_name=name,
        content_type=content_type, byte_size=size, sha256=sha256_hex(f"{client_ref}:{slot}"),
        width=None, height=None, limits=limits or LIMITS,
        origin_device_id=None if thread_id else device_id,
        origin_account_id=account_id, at=at)


@pytest.fixture
def seeded(tmp_path):
    """一条线程（带 ticket）与它的首条留言 id。"""
    instance = Store(str(tmp_path / "mail.db"))
    try:
        thread = instance.create_feedback_thread(ticket_hash=sha256_hex("fk_one"),
                                                 text="原文", at=1_000)
        yield instance, thread
    finally:
        instance.close()


def test_a_fresh_database_also_creates_the_attachment_table(tmp_path):
    path = str(tmp_path / "mail.db")
    Store(path).close()
    assert columns(path, "feedbackAttachments") == ATTACHMENT_COLUMNS
    assert ATTACHMENT_INDEXES <= indexes(path, "feedbackAttachments")
    # 唯一索引必须是**部分索引**：草稿按 (draftRef, slot)、通知按 (noticeId, clientRef)。
    conn = sqlite3.connect(path)
    try:
        sql = {row[0]: row[1] for row in conn.execute(
            "SELECT name, sql FROM sqlite_master WHERE type='index'")}
    finally:
        conn.close()
    assert "UNIQUE INDEX" in sql["feedbackAttachmentsDraftSlot"]
    assert "draftRef, slot" in sql["feedbackAttachmentsDraftSlot"]
    assert "UNIQUE INDEX" in sql["feedbackAttachmentsNoticeRef"]


def test_an_old_database_gains_the_attachment_table_and_keeps_its_rows(tmp_path):
    """老库没有附件表：打开后自动补上，既有四张表与行原样。"""
    path = str(tmp_path / "mail.db")
    conn = sqlite3.connect(path)
    conn.executescript(
        "CREATE TABLE feedbackThreads (threadId TEXT PRIMARY KEY, ticketHash TEXT NOT NULL UNIQUE,"
        " accountId TEXT, deviceId TEXT, appVersion TEXT, deviceModel TEXT, systemVersion TEXT,"
        " createdAt INTEGER NOT NULL, lastMessageAt INTEGER NOT NULL, ownerReadAt INTEGER,"
        " userReadAt INTEGER, status TEXT NOT NULL DEFAULT 'open', clientRef TEXT UNIQUE,"
        " subject TEXT);"
        "CREATE TABLE feedbackMessages (messageId TEXT PRIMARY KEY, threadId TEXT NOT NULL,"
        " author TEXT NOT NULL, body TEXT NOT NULL, createdAt INTEGER NOT NULL,"
        " clientRef TEXT UNIQUE, format TEXT NOT NULL DEFAULT 'text');"
        "CREATE TABLE notices (noticeId TEXT PRIMARY KEY, subject TEXT, body TEXT NOT NULL,"
        " createdAt INTEGER NOT NULL, createdBy TEXT, format TEXT NOT NULL DEFAULT 'text');"
        "CREATE TABLE noticeDeliveries (noticeId TEXT NOT NULL, accountId TEXT NOT NULL,"
        " createdAt INTEGER NOT NULL, readAt INTEGER, PRIMARY KEY (noticeId, accountId));"
        "INSERT INTO feedbackThreads(threadId, ticketHash, createdAt, lastMessageAt)"
        " VALUES('th_old', '" + sha256_hex("fk_old") + "', 5, 5);")
    conn.commit()
    conn.close()

    store = Store(path)
    try:
        assert store.feedback_thread("th_old", sha256_hex("fk_old")) is not None
        assert store.attachments_for_messages(["fm_none"]) == {}
        assert columns(path, "feedbackAttachments") == ATTACHMENT_COLUMNS
    finally:
        store.close()


# ── 登记：幂等与配额（M2-A/B）─────────────────────────────────────────────


def test_begin_is_idempotent_per_draft_slot_and_conflicts_on_another_file(tmp_path):
    store = Store(str(tmp_path / "mail.db"))
    try:
        first = draft(store, client_ref="ref-a", slot=0, at=1_000)
        again = draft(store, client_ref="ref-a", slot=0, at=2_000)
        assert first["created"] is True and again["created"] is False
        assert again["attachmentId"] == first["attachmentId"]
        assert again["state"] == "pending"

        with pytest.raises(StoreError) as conflict:
            store.begin_attachment(
                draft_ref="ref-a", slot=0, file_name="别的.png", content_type="image/png",
                byte_size=10, sha256=sha256_hex("other"), limits=LIMITS, at=3_000)
        assert "slot 0" in str(conflict.value)
    finally:
        store.close()


def test_begin_counts_and_sizes_are_aggregated_by_draft_ref(tmp_path):
    store = Store(str(tmp_path / "mail.db"))
    try:
        small = {**LIMITS, "maxPerMessage": 2, "maxTotalBytes": 1_000}
        draft(store, client_ref="ref-a", slot=0, size=10, limits=small)
        draft(store, client_ref="ref-a", slot=1, size=10, limits=small)
        with pytest.raises(QuotaExceeded) as count:
            draft(store, client_ref="ref-a", slot=2, size=10, limits=small)
        assert count.value.reason == "count"

        with pytest.raises(QuotaExceeded) as too_big:
            draft(store, client_ref="ref-b", slot=0, size=1_100, limits=small)
        assert too_big.value.reason == "message-bytes"

        draft(store, client_ref="ref-c", slot=0, size=990,
              limits={**small, "maxTotalBytes": 24 * 1024 * 1024})
        assert store.draft_attachment_bytes("ref-c") == 990
    finally:
        store.close()


def test_begin_refuses_when_the_letter_or_the_library_is_full(tmp_path):
    store = Store(str(tmp_path / "mail.db"))
    try:
        thread = store.create_feedback_thread(ticket_hash=sha256_hex("fk_one"), text="原文")
        with pytest.raises(QuotaExceeded) as thread_full:
            draft(store, client_ref="ref-r", size=990, thread_id=thread["threadId"],
                  limits={**LIMITS, "maxPerThreadBytes": 15})
        assert thread_full.value.reason == "thread-bytes"

        with pytest.raises(QuotaExceeded) as storage:
            draft(store, client_ref="ref-s", size=65,
                  limits={**LIMITS, "storageSoftBytes": 64})
        assert storage.value.reason == "storage"
    finally:
        store.close()


def test_begin_keeps_the_optional_image_size_and_origin(tmp_path):
    store = Store(str(tmp_path / "mail.db"))
    try:
        row = store.begin_attachment(
            draft_ref="ref-a", slot=0, file_name="图.png", content_type="image/png",
            byte_size=10, sha256=sha256_hex("a"), width=1179, height=2556,
            origin_device_id="dev_1", origin_account_id="acc_1", limits=LIMITS)
        assert (row["width"], row["height"]) == (1179, 2556)
        assert (row["originDeviceId"], row["originAccountId"]) == ("dev_1", "acc_1")
        plain = draft(store, client_ref="ref-b", slot=0, name="日志.txt",
                      content_type="text/plain")
        assert (plain["width"], plain["height"]) == (None, None)
    finally:
        store.close()


# ── 绑定与建信/追加（M2-C）───────────────────────────────────────────────


def test_submit_binds_the_drafts_of_that_client_ref(tmp_path):
    store = Store(str(tmp_path / "mail.db"))
    try:
        first = draft(store, client_ref="ref-a", slot=1, device_id="dev_1")
        second = draft(store, client_ref="ref-a", slot=0, device_id="dev_1")
        store.mark_attachment_stored(first["attachmentId"], "2026/11/02/fa_b", 2_000)
        store.mark_attachment_stored(second["attachmentId"], "2026/11/02/fa_a", 2_000)

        thread = store.create_feedback_thread(
            ticket_hash=sha256_hex("fk_a"), text="", client_ref="ref-a", device_id="dev_1",
            limits=LIMITS, at=3_000)
        assert thread["attachmentsBound"] == 2
        rows = store.attachments_for_messages([thread["messageId"]])
        assert [row["slot"] for row in rows[thread["messageId"]]] == [0, 1], "按 slot 升序"
        assert store.attachment(first["attachmentId"])["boundAt"] == 3_000
        assert store.attachment(first["attachmentId"])["state"] == "stored", "绑定不改 state"

        again = store.create_feedback_thread(
            ticket_hash=sha256_hex("fk_b"), text="", client_ref="ref-a", device_id="dev_1",
            limits=LIMITS, at=4_000)
        assert again["threadId"] == thread["threadId"]
        assert again["attachmentsBound"] == 0, "重试不重复绑"
    finally:
        store.close()


def test_a_blank_letter_without_attachments_rolls_back_completely(tmp_path):
    store = Store(str(tmp_path / "mail.db"))
    try:
        with pytest.raises(EmptyLetter):
            store.create_feedback_thread(ticket_hash=sha256_hex("fk_a"), text="  ",
                                         client_ref="ref-empty", limits=LIMITS)
        assert store.list_feedback_threads(limit=10) == []
        assert store._row("SELECT COUNT(*) AS n FROM feedbackMessages")["n"] == 0

        thread = store.create_feedback_thread(ticket_hash=sha256_hex("fk_one"), text="原文")
        with pytest.raises(EmptyLetter):
            store.append_feedback_message(thread["threadId"], "", client_ref="ref-reply",
                                          limits=LIMITS, at=2_000)
        assert store.feedback_thread(thread["threadId"], None)["messageCount"] == 1
    finally:
        store.close()


def test_a_blank_letter_with_one_stored_draft_is_accepted(tmp_path):
    store = Store(str(tmp_path / "mail.db"))
    try:
        row = draft(store, client_ref="ref-only", slot=0, device_id="dev_1")
        store.mark_attachment_stored(row["attachmentId"], "2026/11/02/fa_a", 2_000)
        thread = store.create_feedback_thread(
            ticket_hash=sha256_hex("fk_a"), text="", client_ref="ref-only",
            device_id="dev_1", limits=LIMITS, at=3_000)
        assert thread["attachmentsBound"] == 1
        assert store.attachment(row["attachmentId"])["messageId"] == thread["messageId"]
    finally:
        store.close()


def test_binding_never_takes_another_devices_draft(tmp_path):
    store = Store(str(tmp_path / "mail.db"))
    try:
        mine = draft(store, client_ref="ref-shared", slot=0, device_id="dev_mine")
        store.mark_attachment_stored(mine["attachmentId"], "2026/11/02/fa_a", 2_000)

        with pytest.raises(EmptyLetter):
            store.create_feedback_thread(
                ticket_hash=sha256_hex("fk_b"), text="", client_ref="ref-shared",
                device_id="dev_other", limits=LIMITS, at=3_000)
        assert store.attachment(mine["attachmentId"])["messageId"] is None
        assert store.attachment(mine["attachmentId"])["threadId"] is None
    finally:
        store.close()


def test_a_reply_draft_binds_by_its_thread(tmp_path):
    store = Store(str(tmp_path / "mail.db"))
    try:
        thread = store.create_feedback_thread(ticket_hash=sha256_hex("fk_one"), text="原文")
        row = draft(store, client_ref="ref-reply", slot=0, thread_id=thread["threadId"])
        store.mark_attachment_stored(row["attachmentId"], "2026/11/02/fa_a", 2_000)

        message = store.append_feedback_message(thread["threadId"], "",
                                                client_ref="ref-reply", limits=LIMITS, at=3_000)
        assert message["attachmentsBound"] == 1
        assert store.attachment(row["attachmentId"])["messageId"] == message["messageId"]
        assert store.attachment(row["attachmentId"])["threadId"] == thread["threadId"]

        retried = store.append_feedback_message(thread["threadId"], "",
                                                client_ref="ref-reply", limits=LIMITS, at=4_000)
        assert retried["created"] is False and retried["attachmentsBound"] == 0, \
            "提交即封口：回信重试不绑"
    finally:
        store.close()


def test_begin_refuses_a_client_ref_that_was_already_sent(tmp_path):
    """提交即封口（R5）：发出之后同一 clientRef 不再收新草稿。"""
    store = Store(str(tmp_path / "mail.db"))
    try:
        row = draft(store, client_ref="ref-sealed", slot=0)
        store.mark_attachment_stored(row["attachmentId"], "2026/11/02/fa_a", 2_000)
        store.create_feedback_thread(ticket_hash=sha256_hex("fk_a"), text="",
                                     client_ref="ref-sealed", device_id="dev_1",
                                     limits=LIMITS, at=3_000)
        with pytest.raises(SealedLetter):
            draft(store, client_ref="ref-sealed", slot=1)
        with pytest.raises(SealedLetter):
            draft(store, client_ref="ref-sealed", slot=0)   # 同一个 slot 也不放行
        assert store.list_attachments(limit=10) and len(store.list_attachments(limit=10)) == 1
    finally:
        store.close()


def test_binding_marks_unusable_bytes_lost_and_skips_them(tmp_path):
    """`stored` 但文件不在/大小不符的行不得被绑定：标 lost、不计入绑定数。"""
    store = Store(str(tmp_path / "mail.db"))
    try:
        good = draft(store, client_ref="ref-usable", slot=0, device_id="dev_1")
        bad = draft(store, client_ref="ref-usable", slot=1, device_id="dev_1")
        store.mark_attachment_stored(good["attachmentId"], "2026/11/02/fa_g", 2_000)
        store.mark_attachment_stored(bad["attachmentId"], "2026/11/02/fa_b", 2_000)

        thread = store.create_feedback_thread(
            ticket_hash=sha256_hex("fk_a"), text="", client_ref="ref-usable",
            device_id="dev_1", limits=LIMITS, at=3_000,
            usable=lambda row: row["attachmentId"] == good["attachmentId"])
        assert thread["attachmentsBound"] == 1
        assert store.attachment(bad["attachmentId"])["state"] == "lost"
        assert store.attachment(good["attachmentId"])["messageId"] == thread["messageId"]
    finally:
        store.close()


def _fresh_row(path: str, sql: str, params: tuple = ()):
    """新开一个连接读库：用来证明"失败路径没有留下未提交写入"。"""
    conn = sqlite3.connect(path)
    try:
        return conn.execute(sql, params).fetchone()
    finally:
        conn.close()


def test_a_conflict_append_leaves_no_uncommitted_device_binding(tmp_path):
    """R4：跨线程 409 之后，`deviceId`/`accountId` 不许留在共享连接的事务里。"""
    path = str(tmp_path / "mail.db")
    store = Store(path)
    try:
        first = store.create_feedback_thread(ticket_hash=sha256_hex("fk_a"), text="甲")
        anonymous = store.create_feedback_thread(ticket_hash=sha256_hex("fk_b"), text="乙")
        store.append_feedback_message(first["threadId"], "甲的回信", client_ref="ref-x",
                                      at=2_000)

        with pytest.raises(StoreError):
            store.append_feedback_message(anonymous["threadId"], "乙的回信",
                                          client_ref="ref-x", bind_device_id="devB",
                                          bind_account_id="accB", at=3_000)
        # 任意一次无关写：如果 409 留下了未提交事务，它会在这里被顺带提交。
        store.mark_thread_read(anonymous["threadId"])
        assert _fresh_row(path, "SELECT deviceId, accountId FROM feedbackThreads"
                                " WHERE threadId=?", (anonymous["threadId"],)) == (None, None)
    finally:
        store.close()


def test_a_refused_resubmit_keeps_the_ticket_and_writes_nothing(tmp_path):
    """R4：失败的重提交不许改写 `ticketHash`（那等于作废客户端手里的旧凭据）。"""
    path = str(tmp_path / "mail.db")
    store = Store(path)
    try:
        first = store.create_feedback_thread(ticket_hash=sha256_hex("fk_old"), text="原文",
                                             client_ref="ref-a", device_id="devA",
                                             account_id="accA")
        with pytest.raises(Conflict):
            store.create_feedback_thread(ticket_hash=sha256_hex("fk_new"), text="重试",
                                         client_ref="ref-a", device_id="devB",
                                         account_id="accB")
        store.mark_thread_read(first["threadId"])
        assert _fresh_row(path, "SELECT ticketHash FROM feedbackThreads WHERE threadId=?",
                          (first["threadId"],))[0] == sha256_hex("fk_old")
    finally:
        store.close()


def test_binding_rechecks_the_message_and_thread_caps(tmp_path):
    store = Store(str(tmp_path / "mail.db"))
    try:
        for slot in range(3):
            row = draft(store, client_ref="ref-cap", slot=slot, size=10, device_id="dev_1")
            store.mark_attachment_stored(row["attachmentId"], f"2026/11/02/fa_{slot}", 2_000)
        with pytest.raises(QuotaExceeded) as count:
            store.create_feedback_thread(
                ticket_hash=sha256_hex("fk_a"), text="", client_ref="ref-cap",
                device_id="dev_1", limits={**LIMITS, "maxPerMessage": 2}, at=3_000)
        assert count.value.reason == "count"
        assert store.list_feedback_threads(limit=10) == []
        assert all(row["messageId"] is None for row in store.list_attachments(limit=10))
    finally:
        store.close()


def test_append_client_ref_is_scoped_to_its_thread(tmp_path):
    """同一个 `clientRef` 在另一条线程回信：409，绝不复用那条线程的留言（F-V4-1）。"""
    store = Store(str(tmp_path / "mail.db"))
    try:
        first = store.create_feedback_thread(ticket_hash=sha256_hex("fk_a"), text="甲")
        second = store.create_feedback_thread(ticket_hash=sha256_hex("fk_b"), text="乙")
        mine = store.append_feedback_message(first["threadId"], "甲的回信",
                                             client_ref="ref-shared", at=2_000)
        assert mine["created"] is True

        with pytest.raises(StoreError) as clash:
            store.append_feedback_message(second["threadId"], "乙的回信",
                                          client_ref="ref-shared", at=3_000)
        assert "another thread" in str(clash.value) or "belongs" in str(clash.value)
        payload = store.feedback_thread(second["threadId"], None, messages_per_thread=10)
        assert [message["body"] for message in payload["messages"]] == ["乙"]
        # 两条线程各 1 条首信 + 甲那一封回信 = 3；乙那次被拒，一行都没写。
        assert store._row("SELECT COUNT(*) AS n FROM feedbackMessages")["n"] == 3
    finally:
        store.close()


def test_binding_refuses_a_message_from_another_thread(tmp_path):
    """`messageId` 不属于 `threadId` 时不绑、也不撞库（F-V4-1 第 2 条）。"""
    store = Store(str(tmp_path / "mail.db"))
    try:
        first = store.create_feedback_thread(ticket_hash=sha256_hex("fk_a"), text="甲")
        second = store.create_feedback_thread(ticket_hash=sha256_hex("fk_b"), text="乙")
        row = draft(store, client_ref="ref-mix", slot=0, thread_id=second["threadId"])
        store.mark_attachment_stored(row["attachmentId"], "2026/11/02/fa_a", 2_000)

        with pytest.raises(StoreError):
            store.bind_draft_attachments("ref-mix", first["threadId"],
                                         second["messageId"], limits=LIMITS,
                                         device_id="dev_1", at=3_000)
        assert store.attachment(row["attachmentId"])["messageId"] is None
    finally:
        store.close()


def test_begin_never_returns_another_letters_slot_metadata(tmp_path):
    """别人的 `(draftRef, slot)` 一律冲突，不回显 attachmentId/sha（F-V4-3）。"""
    store = Store(str(tmp_path / "mail.db"))
    try:
        mine = draft(store, client_ref="ref-owner", slot=0, device_id="dev_mine")
        with pytest.raises(StoreError):
            store.begin_attachment(
                draft_ref="ref-owner", slot=0, file_name="抢.png", content_type="image/png",
                byte_size=10, sha256=sha256_hex("theirs"), limits=LIMITS,
                origin_device_id="dev_other")
        with pytest.raises(StoreError):
            store.begin_attachment(
                draft_ref="ref-owner", slot=0, file_name="抢.png", content_type="image/png",
                byte_size=10, sha256=sha256_hex("theirs"), limits=LIMITS,
                origin_device_id="dev_mine", origin_account_id="acc_other")
        assert store.attachment(mine["attachmentId"])["fileName"] == "截屏.png"
    finally:
        store.close()


# ── 投影：只出现已绑定的行 ────────────────────────────────────────────────


def test_message_payloads_only_carry_bound_rows_and_notice_payloads_stored_ones(
        tmp_path):
    store = Store(str(tmp_path / "mail.db"))
    try:
        thread = store.create_feedback_thread(ticket_hash=sha256_hex("fk_one"), text="原文")
        bound = draft(store, client_ref="ref-a", slot=0)
        store.mark_attachment_stored(bound["attachmentId"], "2026/11/02/fa_a", 2_000)
        store.bind_draft_attachments("ref-a", thread["threadId"], thread["messageId"],
                                     limits=LIMITS, device_id="dev_1", at=3_000)
        loose = draft(store, client_ref="ref-loose", slot=0)
        store.mark_attachment_stored(loose["attachmentId"], "2026/11/02/fa_b", 2_000)
        pending = draft(store, client_ref="ref-a", slot=1)

        payload = store.feedback_thread(thread["threadId"], None, messages_per_thread=5)
        names = [row["fileName"] for row in payload["messages"][0]["attachments"]]
        assert names == ["截屏.png"], "草稿与 pending 都不进投影"
        assert store.attachment(pending["attachmentId"])["state"] == "pending"

        notice = store.create_notice("通知正文", "服务通知", ["acc_a"], at=1_000)
        stored = store.begin_attachment(
            notice_id=notice["noticeId"], client_ref="n1", file_name="附件.png",
            content_type="image/png", byte_size=10, sha256=sha256_hex("n1"), limits=LIMITS)
        store.mark_attachment_stored(stored["attachmentId"], "2026/11/02/fa_n", 3_000)
        rows = store.notices_for_account("acc_a")
        assert [row["fileName"] for row in rows[0]["attachments"]] == ["附件.png"]
    finally:
        store.close()


def test_attachment_counts_only_count_bound_and_stored_rows(tmp_path):
    store = Store(str(tmp_path / "mail.db"))
    try:
        thread = store.create_feedback_thread(ticket_hash=sha256_hex("fk_one"), text="原文")
        bound = draft(store, client_ref="ref-a", slot=0)
        store.mark_attachment_stored(bound["attachmentId"], "2026/11/02/fa_a", 2_000)
        store.bind_draft_attachments("ref-a", thread["threadId"], thread["messageId"],
                                     limits=LIMITS, device_id="dev_1", at=3_000)
        # 回信草稿挂在线上：它算线程的量，但不算"已绑定"，也不进投影。
        pending = draft(store, client_ref="ref-a", slot=1, thread_id=thread["threadId"])
        store.mark_attachment_stored(pending["attachmentId"], "2026/11/02/fa_b", 2_000)

        assert store.attachment_counts_by_thread([thread["threadId"]]) == {
            thread["threadId"]: 1}
        assert store.message_attachment_stats(thread["messageId"]) == {"count": 1, "bytes": 10}
        assert store.thread_attachment_bytes(thread["threadId"]) == 20, "草稿字节也算线程量"
    finally:
        store.close()


# ── 删除与草稿回收 ────────────────────────────────────────────────────────


def test_delete_thread_reports_the_attachment_paths_it_orphaned(tmp_path):
    store = Store(str(tmp_path / "mail.db"))
    try:
        thread = store.create_feedback_thread(ticket_hash=sha256_hex("fk_one"), text="原文")
        bound = draft(store, client_ref="ref-a", slot=0)
        store.mark_attachment_stored(bound["attachmentId"], "2026/11/02/fa_a", 2_000)
        store.bind_draft_attachments("ref-a", thread["threadId"], thread["messageId"],
                                     limits=LIMITS, device_id="dev_1", at=3_000)
        reply_draft = draft(store, client_ref="ref-reply", slot=0,
                            thread_id=thread["threadId"])
        store.mark_attachment_stored(reply_draft["attachmentId"], "2026/11/02/fa_b", 2_000)

        removed = store.delete_feedback_thread(thread["threadId"])
        assert removed["messages"] == 1
        assert sorted(removed["attachmentPaths"]) == ["2026/11/02/fa_a", "2026/11/02/fa_b"]
        assert store.list_attachments(limit=10) == []
        with pytest.raises(NotFound):
            store.delete_feedback_thread(thread["threadId"])
    finally:
        store.close()


def test_expire_drafts_leaves_bound_rows_and_fresh_ones_alone(tmp_path):
    store = Store(str(tmp_path / "mail.db"))
    try:
        thread = store.create_feedback_thread(ticket_hash=sha256_hex("fk_one"), text="原文")
        bound = draft(store, client_ref="ref-a", slot=0, at=1_000)
        store.mark_attachment_stored(bound["attachmentId"], "2026/11/02/fa_a", 1_000)
        store.bind_draft_attachments("ref-a", thread["threadId"], thread["messageId"],
                                     limits=LIMITS, device_id="dev_1", at=1_000)
        stale = draft(store, client_ref="ref-stale", slot=0, at=1_000)
        store.mark_attachment_stored(stale["attachmentId"], "2026/11/02/fa_s", 1_000)
        fresh = draft(store, client_ref="ref-fresh", slot=0, at=9_000)
        store.mark_attachment_stored(fresh["attachmentId"], "2026/11/02/fa_f", 9_000)
        pending = draft(store, client_ref="ref-pending", slot=0, at=1_000)

        expired = store.expire_draft_attachments(older_than_ms=5_000)
        assert expired == ["2026/11/02/fa_s"], "只报删掉的草稿的字节路径"
        remaining = {row["attachmentId"] for row in store.list_attachments(limit=10)}
        assert remaining == {bound["attachmentId"], fresh["attachmentId"],
                             pending["attachmentId"]}

        assert store.expire_pending_attachments(older_than_ms=5_000) == 1
        assert store.attachment(pending["attachmentId"]) is None
    finally:
        store.close()


def test_expire_pending_leaves_stored_rows_alone(tmp_path):
    store = Store(str(tmp_path / "mail.db"))
    try:
        """pending 是"没传完"的记录：过期删行；stored（含草稿）不归这一步管。"""
        old = draft(store, client_ref="ref-old", slot=0, at=1_000)
        done = draft(store, client_ref="ref-done", slot=0, at=1_000)
        store.mark_attachment_stored(done["attachmentId"], "2026/11/02/fa_a", 1_000)
        fresh = draft(store, client_ref="ref-fresh", slot=0, at=9_000)

        assert store.expire_pending_attachments(older_than_ms=5_000) == 1
        remaining = {row["attachmentId"] for row in store.list_attachments(limit=10)}
        assert remaining == {done["attachmentId"], fresh["attachmentId"]}
        assert old["attachmentId"] not in remaining

        assert store.attachment_bytes_total() == 20
        assert store.mark_attachments_lost([done["attachmentId"]]) == 1
        assert store.attachment_bytes_total() == 10, "lost 的字节不再占配额"
    finally:
        store.close()


# ── 清扫（M4-A）：草稿 TTL、翻页、坏路径、截断 ────────────────────────────


async def test_the_sweeper_removes_expired_drafts_and_their_bytes(tmp_path):
    root = files.ensure_dirs(files.root_for(str(tmp_path / "mail.db")))
    store = Store(str(tmp_path / "mail.db"))
    try:
        stale = draft(store, client_ref="ref-stale", slot=0, at=1_000)
        relative = files.stored_path(3_000, stale["attachmentId"])
        final = files.final_path(root, 3_000, stale["attachmentId"])
        os.makedirs(os.path.dirname(final), exist_ok=True)
        with open(final, "wb") as handle:
            handle.write(b"0123456789")
        store.mark_attachment_stored(stale["attachmentId"], relative, 3_000)

        fresh = draft(store, client_ref="ref-fresh", slot=0, at=9_000_000_000_000)
        store.mark_attachment_stored(fresh["attachmentId"],
                                     files.stored_path(9_000, fresh["attachmentId"]), 9_000)
        fresh_path = files.final_path(root, 9_000, fresh["attachmentId"])
        os.makedirs(os.path.dirname(fresh_path), exist_ok=True)
        with open(fresh_path, "wb") as handle:
            handle.write(b"0123456789")

        now = 8 * 24 * 3600 * 1000                     # 第 8 天
        swept = await mail_module.sweep_attachments_once(store, root, now=now)
        assert swept["drafts"] == 1
        assert store.attachment(stale["attachmentId"]) is None
        assert not os.path.exists(final), "过期草稿的字节要一起删"
        assert store.attachment(fresh["attachmentId"]) is not None
        assert os.path.exists(fresh_path), "7 天内的草稿不动"
    finally:
        store.close()


async def test_the_sweeper_pages_through_every_stored_row(tmp_path):
    """`known` 必须覆盖**全部**已存行（F4）：只取一页会把下一页的文件当孤儿删掉。"""
    root = files.ensure_dirs(files.root_for(str(tmp_path / "mail.db")))
    store = Store(str(tmp_path / "mail.db"))
    try:
        finals: list[str] = []
        for index in range(5):
            row = draft(store, client_ref=f"ref-{index}", slot=0, at=9_000_000_000_000)
            stored_at = 9_000_000_000_000 + index
            relative = files.stored_path(stored_at, row["attachmentId"])
            final = files.final_path(root, stored_at, row["attachmentId"])
            os.makedirs(os.path.dirname(final), exist_ok=True)
            with open(final, "wb") as handle:
                handle.write(b"0123456789")       # 与登记的 byte_size=10 一致
            os.utime(final, (2_800, 2_800))       # 比 now 老，够格被当孤儿
            store.mark_attachment_stored(row["attachmentId"], relative, stored_at)
            finals.append(final)

        swept = await mail_module.sweep_attachments_once(store, root, now=10_000_000,
                                                         page_size=2)
        assert swept["orphans"] == 0 and swept["drafts"] == 0
        assert all(os.path.exists(path) for path in finals)
        assert len(store.list_attachments(state="stored", limit=10)) == 5
    finally:
        store.close()


async def test_the_sweeper_marks_a_bad_path_lost_and_keeps_going(tmp_path):
    """`storedPath` 越界只该让那**一行**变成 lost，不许整次清扫中断（F10）。"""
    root = files.ensure_dirs(files.root_for(str(tmp_path / "mail.db")))
    store = Store(str(tmp_path / "mail.db"))
    try:
        finals: dict[str, str] = {}
        for name in ("good", "bad"):
            row = draft(store, client_ref=f"ref-{name}", slot=0, at=9_000_000_000_000)
            stored_at = 9_000_000_000_000
            relative = files.stored_path(stored_at, row["attachmentId"])
            final = files.final_path(root, stored_at, row["attachmentId"])
            os.makedirs(os.path.dirname(final), exist_ok=True)
            with open(final, "wb") as handle:
                handle.write(b"0123456789")
            store.mark_attachment_stored(row["attachmentId"], relative, stored_at)
            finals[name] = final
            if name == "bad":
                bad_id = row["attachmentId"]
        store._conn.execute("UPDATE feedbackAttachments SET storedPath='../../../etc/passwd'"
                            " WHERE attachmentId=?", (bad_id,))
        store._conn.commit()

        orphan = files.final_path(root, 9_000_000_000_000, "fa_orphan")
        with open(orphan, "wb") as handle:
            handle.write(b"nobody's")
        os.utime(orphan, (2_800, 2_800))

        swept = await mail_module.sweep_attachments_once(store, root, now=10_000_000)
        assert swept["lost"] == 1 and swept["orphans"] == 1
        assert store.attachment(bad_id)["state"] == "lost"
        assert os.path.exists(finals["good"])
        assert not os.path.exists(orphan)
    finally:
        store.close()


async def test_the_sweeper_marks_truncated_and_missing_files_lost(tmp_path):
    root = files.ensure_dirs(files.root_for(str(tmp_path / "mail.db")))
    store = Store(str(tmp_path / "mail.db"))
    try:
        truncated = draft(store, client_ref="ref-trunc", slot=0)
        store.mark_attachment_stored(truncated["attachmentId"], "2026/11/02/fa_t", 1_000)
        final = files.final_path(root, 1_000, truncated["attachmentId"])
        os.makedirs(os.path.dirname(final), exist_ok=True)
        with open(final, "wb") as handle:
            handle.write(b"12345")                # 登记 10 字节，实际 5 字节
        missing = draft(store, client_ref="ref-missing", slot=0)
        store.mark_attachment_stored(missing["attachmentId"], "2026/11/02/fa_m", 1_000)

        swept = await mail_module.sweep_attachments_once(store, root, now=10_000_000)
        assert swept["lost"] == 2
        assert store.attachment(truncated["attachmentId"])["state"] == "lost"
        assert store.attachment(missing["attachmentId"])["state"] == "lost"
        assert os.path.exists(final), "清扫只标行，不删这个有行的文件"
    finally:
        store.close()


async def test_the_sweeper_removes_expired_pending_rows_and_temp_files(tmp_path):
    root = files.ensure_dirs(files.root_for(str(tmp_path / "mail.db")))
    store = Store(str(tmp_path / "mail.db"))
    try:
        pending = draft(store, client_ref="ref-pending", slot=0, at=1_000)
        stale_part = files.temp_path(root)
        with open(stale_part, "wb") as handle:
            handle.write(b"partial")
        os.utime(stale_part, (2_800, 2_800))

        swept = await mail_module.sweep_attachments_once(store, root, now=10_000_000)
        assert swept["expired"] == 1 and swept["temp"] == 1
        assert store.attachment(pending["attachmentId"]) is None
        assert not os.path.exists(stale_part)
    finally:
        store.close()
