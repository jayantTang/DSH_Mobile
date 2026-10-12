"""存储层：四张新表与读写方法（014）。

表结构、列名与上限逐字照 `specs/014-feedback-channel/data-model.md`；凭据只存
SHA-256（与 `agentSecret`/`deviceToken` 同一套口径）。本文件只用 `tmp_path` 里的库，
绝不碰生产 `state.db`。
"""

from __future__ import annotations

import sqlite3

import pytest

from store import SCHEMA_VERSION, NotFound, Store, StoreError, sha256_hex

NEW_TABLES = ("feedbackThreads", "feedbackMessages", "notices", "noticeDeliveries")

OLD_TABLES = {"accounts", "agents", "devices", "pairCodes", "usageDaily", "invites"}

#: 逐字照 data-model.md 的四张表（列名与顺序）。`subject` 与两个 `format` 都在最后：
#: 它们是用 `ALTER TABLE … ADD COLUMN` 补上的，SQLite 把新列追加在末尾，`SCHEMA` 必须
#: 与之一致。
EXPECTED_COLUMNS = {
    "feedbackThreads": ["threadId", "ticketHash", "accountId", "deviceId", "appVersion",
                        "deviceModel", "systemVersion", "createdAt", "lastMessageAt",
                        "ownerReadAt", "userReadAt", "status", "clientRef", "subject"],
    "feedbackMessages": ["messageId", "threadId", "author", "body", "createdAt", "clientRef",
                         "format"],
    "notices": ["noticeId", "subject", "body", "createdAt", "createdBy", "format"],
    "noticeDeliveries": ["noticeId", "deviceId", "createdAt", "readAt"],
}


def columns(path: str, table: str) -> list[str]:
    conn = sqlite3.connect(path)
    try:
        return [row[1] for row in conn.execute(f"PRAGMA table_info({table})")]
    finally:
        conn.close()


def tables(path: str) -> set[str]:
    conn = sqlite3.connect(path)
    try:
        return {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    finally:
        conn.close()


def user_version(path: str) -> int:
    conn = sqlite3.connect(path)
    try:
        return int(conn.execute("PRAGMA user_version").fetchone()[0])
    finally:
        conn.close()


def count(store: Store, sql: str, params: tuple = ()) -> int:
    return int(store._rows(sql, params)[0][0])


# ── 表结构（T005）────────────────────────────────────────────────────────────


def test_a_fresh_database_creates_the_four_feedback_tables(tmp_path):
    path = str(tmp_path / "state.db")
    Store(path).close()
    for table, expected in EXPECTED_COLUMNS.items():
        assert columns(path, table) == expected, table
    # 版本号是 4（富文本给两张表加 `format` 那一列时 bump 的，见 test_store_schema_version.py）。
    assert user_version(path) == SCHEMA_VERSION == 4


def test_indexes_the_readers_rely_on_exist(tmp_path):
    path = str(tmp_path / "state.db")
    store = Store(path)
    try:
        assert {row[1] for row in store._rows("PRAGMA index_list(feedbackThreads)")} >= {
            "feedbackThreadsByDevice", "feedbackThreadsByAccount", "feedbackThreadsByStatus"}
        assert {row[1] for row in store._rows("PRAGMA index_list(feedbackMessages)")} >= {
            "feedbackMessagesByThread"}
        assert {row[1] for row in store._rows("PRAGMA index_list(noticeDeliveries)")} >= {
            "noticeDeliveriesByDevice"}
    finally:
        store.close()


def test_an_existing_database_gains_the_tables_on_open(tmp_path):
    """老库（只有那 6 张旧表）打开后四张新表补上，形状与新库逐列一致。"""
    path = str(tmp_path / "old.db")
    Store(path).close()
    conn = sqlite3.connect(path)
    for table in NEW_TABLES:
        conn.execute(f"DROP TABLE {table}")
    conn.commit()
    conn.close()
    assert tables(path) == OLD_TABLES, "前提：这是一个只有旧表的库"

    store = Store(path)
    try:
        for table, expected in EXPECTED_COLUMNS.items():
            assert columns(path, table) == expected, table
        assert user_version(path) == SCHEMA_VERSION, "补表不该动版本号"
        # 补上的表立刻可用。
        thread = store.create_feedback_thread(ticket_hash=sha256_hex("fk_x"), text="hello")
        assert thread["threadId"].startswith("th_")
    finally:
        store.close()


# ── 写入与幂等（T008）────────────────────────────────────────────────────────


def test_the_plaintext_ticket_never_reaches_the_database(tmp_path):
    store = Store(str(tmp_path / "state.db"))
    try:
        plaintext = "fk_" + "A" * 43
        thread = store.create_feedback_thread(ticket_hash=sha256_hex(plaintext), text="hi")
        row = store._row("SELECT ticketHash FROM feedbackThreads WHERE threadId=?",
                         (thread["threadId"],))
        assert len(row["ticketHash"]) == 64
        assert row["ticketHash"] != plaintext
        # 命中凭据才拿得到；错的凭据与不存在的线程一样，返回 None。
        assert store.feedback_thread(thread["threadId"], sha256_hex(plaintext)) is not None
        assert store.feedback_thread(thread["threadId"], sha256_hex("fk_wrong")) is None
        assert store.feedback_thread("th_nope", sha256_hex(plaintext)) is None
    finally:
        store.close()


def test_submit_is_idempotent_per_client_ref_and_reissues_the_ticket(tmp_path):
    store = Store(str(tmp_path / "state.db"))
    try:
        first = store.create_feedback_thread(ticket_hash=sha256_hex("fk_one"), text="点了没反应",
                                             client_ref="ref-1", at=1_000)
        second = store.create_feedback_thread(ticket_hash=sha256_hex("fk_two"), text="不该再存一次",
                                              client_ref="ref-1", at=2_000)
        assert second["threadId"] == first["threadId"]
        assert second["created"] is False and first["created"] is True
        assert count(store, "SELECT COUNT(*) FROM feedbackThreads") == 1
        assert count(store, "SELECT COUNT(*) FROM feedbackMessages") == 1
        # 重试发生在"上一条响应丢了"之后，所以第二次必须给出一把能用的凭据。
        assert store.feedback_thread(first["threadId"], sha256_hex("fk_one")) is None
        assert store.feedback_thread(first["threadId"], sha256_hex("fk_two")) is not None
    finally:
        store.close()


def test_append_flips_the_status_and_moves_last_message_at(tmp_path):
    store = Store(str(tmp_path / "state.db"))
    try:
        thread = store.create_feedback_thread(ticket_hash=sha256_hex("fk_one"), text="原文", at=1_000)
        assert store.feedback_thread(thread["threadId"], None)["status"] == "open"

        reply = store.append_feedback_message(thread["threadId"], "回信", author="owner", at=2_000)
        row = store.feedback_thread(thread["threadId"], None)
        assert row["status"] == "replied" and row["lastMessageAt"] == 2_000
        assert count(store, "SELECT COUNT(*) FROM feedbackMessages") == 2

        store.append_feedback_message(thread["threadId"], "补充一句", author="user", at=3_000)
        row = store.feedback_thread(thread["threadId"], None)
        assert row["status"] == "open", "用户补充后 owner 侧重新变成待回复"
        assert row["lastMessageAt"] == 3_000
        assert reply["messageId"].startswith("fm_")
    finally:
        store.close()


def test_append_is_idempotent_per_client_ref(tmp_path):
    store = Store(str(tmp_path / "state.db"))
    try:
        thread = store.create_feedback_thread(ticket_hash=sha256_hex("fk_one"), text="原文")
        first = store.append_feedback_message(thread["threadId"], "补充", client_ref="a-1", at=2_000)
        second = store.append_feedback_message(thread["threadId"], "补充", client_ref="a-1", at=3_000)
        assert second["messageId"] == first["messageId"] and second["created"] is False
        assert count(store, "SELECT COUNT(*) FROM feedbackMessages") == 2
    finally:
        store.close()


def test_append_to_a_missing_thread_says_so(tmp_path):
    store = Store(str(tmp_path / "state.db"))
    try:
        assert store.append_feedback_message("th_nope", "补充") is None
    finally:
        store.close()


def test_append_fills_in_the_device_binding_of_an_anonymous_thread(tmp_path):
    store = Store(str(tmp_path / "state.db"))
    try:
        thread = store.create_feedback_thread(ticket_hash=sha256_hex("fk_one"), text="匿名提交")
        store.append_feedback_message(thread["threadId"], "配对之后补充", author="user",
                                      bind_device_id="dev_1", bind_account_id="acc_1", at=2_000)
        row = store.feedback_thread(thread["threadId"], None)
        assert row["deviceId"] == "dev_1" and row["accountId"] == "acc_1"
        assert [t["threadId"] for t in store.feedback_threads_by_device("dev_1", "acc_1")] == [
            thread["threadId"]]
    finally:
        store.close()


# ── 读取、已读与通知（T008）──────────────────────────────────────────────────


def test_threads_are_found_by_ticket_or_by_device(tmp_path):
    store = Store(str(tmp_path / "state.db"))
    try:
        anonymous = store.create_feedback_thread(ticket_hash=sha256_hex("fk_one"), text="匿名", at=1_000)
        paired = store.create_feedback_thread(ticket_hash=sha256_hex("fk_two"), text="已配对",
                                              device_id="dev_1", account_id="acc_1", at=2_000)

        hits = store.feedback_threads_by_tickets([
            (anonymous["threadId"], sha256_hex("fk_one")),
            (anonymous["threadId"], sha256_hex("fk_one")),   # 重复的凭据只算一次
            (paired["threadId"], sha256_hex("fk_wrong")),    # 凭据不匹配：取不到
            ("th_nope", sha256_hex("fk_one")),
        ])
        assert [t["threadId"] for t in hits] == [anonymous["threadId"]]

        assert [t["threadId"] for t in store.feedback_threads_by_device("dev_1", "acc_1")] == [
            paired["threadId"]]
        # 重装后重新配对会换 deviceId，靠 accountId 也找得回来（R2）。
        assert [t["threadId"] for t in store.feedback_threads_by_device("dev_other", "acc_1")] == [
            paired["threadId"]]
        assert store.feedback_threads_by_device("dev_nope", "acc_nope") == []
        assert store.feedback_threads_by_tickets([]) == []
    finally:
        store.close()


def test_a_thread_returns_its_recent_messages_in_order(tmp_path):
    store = Store(str(tmp_path / "state.db"))
    try:
        thread = store.create_feedback_thread(ticket_hash=sha256_hex("fk_one"), text="原文", at=1_000)
        for index in range(4):
            store.append_feedback_message(thread["threadId"], f"第 {index} 条", at=2_000 + index)

        full = store.feedback_thread(thread["threadId"], sha256_hex("fk_one"))
        assert [m["body"] for m in full["messages"]] == ["原文", "第 0 条", "第 1 条", "第 2 条", "第 3 条"]

        recent = store.feedback_thread(thread["threadId"], sha256_hex("fk_one"), messages_per_thread=2)
        assert [m["body"] for m in recent["messages"]] == ["第 2 条", "第 3 条"], "取最近的 N 条，按时间升序"

        headless = store.feedback_thread(thread["threadId"], sha256_hex("fk_one"), messages_per_thread=0)
        assert headless["messages"] == [] and headless["threadId"] == thread["threadId"]
    finally:
        store.close()


def test_unread_counts_owner_messages_after_user_read_at(tmp_path):
    store = Store(str(tmp_path / "state.db"))
    try:
        thread = store.create_feedback_thread(ticket_hash=sha256_hex("fk_one"), text="原文", at=1_000)
        store.append_feedback_message(thread["threadId"], "回信一", author="owner", at=2_000)
        store.append_feedback_message(thread["threadId"], "回信二", author="owner", at=3_000)

        assert store.feedback_thread(thread["threadId"], None)["unread"] == 2
        assert store.mark_thread_read(thread["threadId"]) is True
        assert store.feedback_thread(thread["threadId"], None)["unread"] == 0
        assert store.feedback_thread(thread["threadId"], None)["userReadAt"] == 3_000

        # 幂等：重复标记不改变结果，也不把时间往前挪。
        assert store.mark_thread_read(thread["threadId"]) is True
        assert store.feedback_thread(thread["threadId"], None)["userReadAt"] == 3_000
        assert store.mark_thread_read(thread["threadId"], upto_ms=1_500) is True
        assert store.feedback_thread(thread["threadId"], None)["userReadAt"] == 3_000

        store.append_feedback_message(thread["threadId"], "回信三", author="owner", at=4_000)
        assert store.feedback_thread(thread["threadId"], None)["unread"] == 1
        assert store.mark_thread_read("th_nope") is False
    finally:
        store.close()


def test_notices_are_delivered_and_read_per_device(tmp_path):
    store = Store(str(tmp_path / "state.db"))
    try:
        notice = store.create_notice("维护通知正文", "服务通知", ["dev_a", "dev_b", "dev_a"], at=5_000)
        assert notice["noticeId"].startswith("nt_") and notice["recipients"] == 2
        assert count(store, "SELECT COUNT(*) FROM notices") == 1
        assert count(store, "SELECT COUNT(*) FROM noticeDeliveries") == 2

        mine = store.notices_for_device("dev_a")
        assert [n["noticeId"] for n in mine] == [notice["noticeId"]]
        assert mine[0]["read"] is False and mine[0]["subject"] == "服务通知"

        assert store.mark_notices_read("dev_a", [notice["noticeId"]]) == 1
        assert store.notices_for_device("dev_a")[0]["read"] is True
        # 同一批通知，每台设备各记各的未读（FR-017）。
        assert store.notices_for_device("dev_b")[0]["read"] is False
        # 幂等与空操作。
        assert store.mark_notices_read("dev_a", [notice["noticeId"]]) == 0
        assert store.mark_notices_read("dev_a", ["nt_nope"]) == 0
        assert store.notices_for_device("dev_c") == []
    finally:
        store.close()


def test_owner_unread_counts_and_touch_owner_read(tmp_path):
    store = Store(str(tmp_path / "state.db"))
    try:
        one = store.create_feedback_thread(ticket_hash=sha256_hex("fk_one"), text="一", at=1_000)
        two = store.create_feedback_thread(ticket_hash=sha256_hex("fk_two"), text="二", at=2_000)
        assert store.owner_unread_counts() == {one["threadId"]: 1, two["threadId"]: 1}

        assert store.touch_owner_read(one["threadId"], at=3_000) is True
        assert store.touch_owner_read("th_nope") is False
        assert store.owner_unread_counts() == {two["threadId"]: 1}

        store.append_feedback_message(one["threadId"], "补充", author="user", at=4_000)
        assert store.owner_unread_counts()[one["threadId"]] == 1
        # owner 的回信不算 owner 侧未读：把它加到已被 owner 读过的线程上，计数不变。
        assert store.touch_owner_read(two["threadId"], at=4_500) is True
        store.append_feedback_message(two["threadId"], "回信", author="owner", at=5_000)
        assert store.owner_unread_counts() == {one["threadId"]: 1}
    finally:
        store.close()


def test_delete_feedback_thread_takes_its_messages_with_it(tmp_path):
    store = Store(str(tmp_path / "state.db"))
    try:
        thread = store.create_feedback_thread(ticket_hash=sha256_hex("fk_one"), text="原文")
        store.append_feedback_message(thread["threadId"], "补充", at=2_000)
        assert store.delete_feedback_thread(thread["threadId"]) == 2
        assert store.feedback_thread(thread["threadId"], None) is None
        assert count(store, "SELECT COUNT(*) FROM feedbackMessages") == 0
        with pytest.raises(NotFound):
            store.delete_feedback_thread(thread["threadId"])
    finally:
        store.close()


# ── 主题 subject（T064/T065：界面重做 2026-10-12）────────────────────────────


def test_a_thread_carries_its_subject_through_every_read_path(tmp_path):
    """主题要在**每一条**线程 payload 里出来（清单/凭据/设备/日报摘要）。"""
    store = Store(str(tmp_path / "state.db"))
    try:
        thread = store.create_feedback_thread(ticket_hash=sha256_hex("fk_one"), text="点了没反应",
                                              subject="  新建会话一直转圈  ", device_id="dev_1",
                                              account_id="acc_1", at=1_000)
        # 存的是去过首尾空白的那一句，不是用户敲进来的原样。
        assert store.feedback_thread(thread["threadId"], None)["subject"] == "新建会话一直转圈"
        assert store.feedback_thread(thread["threadId"], sha256_hex("fk_one"))["subject"] \
            == "新建会话一直转圈"
        assert store.feedback_threads_by_tickets([(thread["threadId"], sha256_hex("fk_one"))])[0][
            "subject"] == "新建会话一直转圈"
        assert store.feedback_threads_by_device("dev_1", "acc_1")[0]["subject"] == "新建会话一直转圈"
        assert store.list_feedback_threads()[0]["subject"] == "新建会话一直转圈"
        assert store.feedback_digest([thread["threadId"]])[thread["threadId"]]["subject"] \
            == "新建会话一直转圈"
    finally:
        store.close()


def test_a_blank_subject_is_stored_as_null_not_as_an_empty_string(tmp_path):
    """没填 / 只敲了空格：一律 NULL——展示层才知道该拿正文首句兜底。"""
    store = Store(str(tmp_path / "state.db"))
    try:
        for index, subject in enumerate((None, "", "   ", "\n\t ")):
            thread = store.create_feedback_thread(ticket_hash=sha256_hex(f"fk_{index}"),
                                                  text=f"第 {index} 条", subject=subject, at=1_000)
            row = store._row("SELECT subject FROM feedbackThreads WHERE threadId=?",
                             (thread["threadId"],))
            assert row["subject"] is None, subject
            assert store.list_feedback_threads()[0]["subject"] is None
    finally:
        store.close()


def test_set_feedback_subject_edits_only_that_column(tmp_path):
    """`feedback-reply --subject` 的落点：改标题不是一次往返，别的列都不许动。"""
    store = Store(str(tmp_path / "state.db"))
    try:
        thread = store.create_feedback_thread(ticket_hash=sha256_hex("fk_one"), text="原文",
                                              subject="用户写的主题", at=1_000)
        store.append_feedback_message(thread["threadId"], "回信", author="owner", at=2_000)
        before = dict(store.feedback_thread(thread["threadId"], None))

        assert store.set_feedback_subject(thread["threadId"], "  我们改的主题  ") is True
        after = store.feedback_thread(thread["threadId"], None)
        assert after["subject"] == "我们改的主题"
        for column in ("status", "lastMessageAt", "ownerReadAt", "userReadAt", "createdAt"):
            assert after[column] == before[column], column
        assert after["status"] == "replied" and after["lastMessageAt"] == 2_000

        # 线程不存在：False，不静默新建。
        assert store.set_feedback_subject("th_nope", "主题") is False
    finally:
        store.close()


def test_set_feedback_subject_accepts_the_80_char_limit_and_refuses_beyond_it(tmp_path):
    """上限是 80 字符：正好 80 通过，81 抛 StoreError（owner 侧命令据此非零退出）。"""
    store = Store(str(tmp_path / "state.db"))
    try:
        thread = store.create_feedback_thread(ticket_hash=sha256_hex("fk_one"), text="原文")
        assert store.set_feedback_subject(thread["threadId"], "字" * 80) is True
        assert store.feedback_thread(thread["threadId"], None)["subject"] == "字" * 80

        with pytest.raises(StoreError):
            store.set_feedback_subject(thread["threadId"], "字" * 81)
        assert store.feedback_thread(thread["threadId"], None)["subject"] == "字" * 80, "越界不改库"
        with pytest.raises(StoreError):
            store.set_feedback_subject(thread["threadId"], 12)
    finally:
        store.close()


# ── 正文格式 format（T078/T079：富文本 2026-10-12）────────────────────────────


def test_a_user_submitted_message_is_always_stored_as_text(tmp_path):
    """用户提交的正文不接格式参数：手机那一侧没有别的格式可发（FR-034 只管我们发出的）。"""
    store = Store(str(tmp_path / "state.db"))
    try:
        thread = store.create_feedback_thread(ticket_hash=sha256_hex("fk_one"), text="点了没反应",
                                              subject="转圈")
        assert store._row("SELECT format FROM feedbackMessages WHERE threadId=?",
                          (thread["threadId"],))["format"] == "text"
        assert store.append_feedback_message(thread["threadId"], "补充一句")["created"] is True
        assert [message["format"] for message in
                store.feedback_thread(thread["threadId"], None)["messages"]] == ["text", "text"]
    finally:
        store.close()


def test_the_format_travels_through_every_message_read_path(tmp_path):
    """`html` 要在**每一条**线程 payload 的留言里出来（详情/凭据/设备/清单）。"""
    store = Store(str(tmp_path / "state.db"))
    try:
        thread = store.create_feedback_thread(ticket_hash=sha256_hex("fk_one"), text="日报没收到",
                                              device_id="dev_1", account_id="acc_1", at=1_000)
        store.append_feedback_message(thread["threadId"], "<h1>日报</h1>", author="owner",
                                      format="html", at=2_000)
        expected = ["text", "html"]
        assert [m["format"] for m in
                store.feedback_thread(thread["threadId"], None)["messages"]] == expected
        assert [m["format"] for m in store.feedback_thread(
            thread["threadId"], sha256_hex("fk_one"))["messages"]] == expected
        assert [m["format"] for m in store.feedback_threads_by_tickets(
            [(thread["threadId"], sha256_hex("fk_one"))])[0]["messages"]] == expected
        assert [m["format"] for m in
                store.feedback_threads_by_device("dev_1", "acc_1")[0]["messages"]] == expected
        assert [m["format"] for m in
                store.list_feedback_threads(messages_per_thread=5)[0]["messages"]] == expected
        # 摘要只带首条留言的格式（线程行本身不带留言）。
        assert store.feedback_digest([thread["threadId"]])[thread["threadId"]]["format"] == "text"
    finally:
        store.close()


def test_format_defaults_to_text_and_ignores_surrounding_whitespace(tmp_path):
    """默认 `text`；首尾空白去掉；空串与全空白与"没给"同义，不是错误。"""
    store = Store(str(tmp_path / "state.db"))
    try:
        thread = store.create_feedback_thread(ticket_hash=sha256_hex("fk_one"), text="原文")
        store.append_feedback_message(thread["threadId"], "默认", author="owner")
        store.append_feedback_message(thread["threadId"], "带空白", author="owner",
                                      format="  html\n")
        store.append_feedback_message(thread["threadId"], "空串", author="owner", format="")
        store.append_feedback_message(thread["threadId"], "全空白", author="owner", format="   ")
        assert [m["format"] for m in
                store.feedback_thread(thread["threadId"], None)["messages"]] == [
                    "text", "text", "html", "text", "text"]

        store.create_notice("正文", "通知", ["dev_1"], at=1_000)
        store.create_notice("正文", "日报", ["dev_1"], format="html", at=2_000)
        store.create_notice("正文", "带空白", ["dev_1"], format="  html\n", at=3_000)
        assert [n["format"] for n in store.notices_for_device("dev_1")] == ["html", "html", "text"]
    finally:
        store.close()


def test_an_unknown_format_is_refused_before_anything_is_written(tmp_path):
    """取值只认 `text`/`html`：别的一律 StoreError，且**一条留言/通知都不留**。"""
    store = Store(str(tmp_path / "state.db"))
    try:
        thread = store.create_feedback_thread(ticket_hash=sha256_hex("fk_one"), text="原文")
        for bad in ("rtf", "HTML", "markdown", 12, ["text"], {"format": "text"}):
            with pytest.raises(StoreError):
                store.append_feedback_message(thread["threadId"], "不该进库", format=bad)
            with pytest.raises(StoreError):
                store.create_notice("不该进库", "通知", ["dev_1"], format=bad)
        assert count(store, "SELECT COUNT(*) FROM feedbackMessages") == 1
        assert count(store, "SELECT COUNT(*) FROM notices") == 0
        assert count(store, "SELECT COUNT(*) FROM noticeDeliveries") == 0
    finally:
        store.close()
