"""存储层：四张信件表与读写方法（014）—— mail 侧移植版。

表结构、列名与上限逐字照 `specs/014-feedback-channel/data-model.md`，与
旧中转库的同名表逐列一致（迁移脚本按列拷贝的前提，有测试钉住）。
本文件只用 `tmp_path` 里的库，绝不碰生产 `mail.db`。
"""

from __future__ import annotations

import sqlite3

import pytest

from store import (USER_LETTER_SQL, NotFound, Store, StoreError, is_user_letter, my_side,
                   page_thread_rows, sha256_hex)

NEW_TABLES = ("feedbackThreads", "feedbackMessages", "notices", "noticeDeliveries")

#: 逐字照 data-model.md 的四张表（列名与顺序）。`subject` 与两个 `format` 都在最后：
#: 与 relay 侧保持同序（那边是用 `ALTER TABLE … ADD COLUMN` 补上的，SQLite 把新列
#: 追加在末尾），迁移拷贝因此可以直接按位置对齐。
EXPECTED_COLUMNS = {
    "feedbackThreads": ["threadId", "ticketHash", "accountId", "deviceId", "appVersion",
                        "deviceModel", "systemVersion", "createdAt", "lastMessageAt",
                        "ownerReadAt", "userReadAt", "status", "clientRef", "subject",
                        "teamAccountId"],
    "feedbackMessages": ["messageId", "threadId", "author", "body", "createdAt", "clientRef",
                         "format"],
    "notices": ["noticeId", "subject", "body", "createdAt", "createdBy", "format"],
    # 019：收件人是账号而不是设备（设备维度已删）。
    "noticeDeliveries": ["noticeId", "accountId", "createdAt", "readAt"],
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


def test_a_fresh_database_creates_exactly_the_four_mail_tables(tmp_path):
    path = str(tmp_path / "mail.db")
    Store(path).close()
    for table, expected in EXPECTED_COLUMNS.items():
        assert columns(path, table) == expected, table
    # mail 是新服务的新库：只有这四张表，没有版本化迁移（user_version 保持 0）。
    assert tables(path) == set(NEW_TABLES)
    assert user_version(path) == 0


def test_indexes_the_readers_rely_on_exist(tmp_path):
    path = str(tmp_path / "mail.db")
    store = Store(path)
    try:
        assert {row[1] for row in store._rows("PRAGMA index_list(feedbackThreads)")} >= {
            "feedbackThreadsByDevice", "feedbackThreadsByAccount", "feedbackThreadsByStatus",
            "feedbackThreadsByTeam"}
        assert {row[1] for row in store._rows("PRAGMA index_list(feedbackMessages)")} >= {
            "feedbackMessagesByThread"}
        assert {row[1] for row in store._rows("PRAGMA index_list(noticeDeliveries)")} >= {
            "noticeDeliveriesByAccount"}
    finally:
        store.close()


def test_a_database_copied_from_the_relay_matches_a_fresh_one_column_for_column(tmp_path):
    """从 relay 迁过来的库（M3 的迁移脚本产物）与新建库逐列一致。

    这里手工搭一个"迁移形状"：四张表按 relay 的列序建好再塞数据。迁移脚本
    （mail/deploy/migrate_from_relay.py）落地的行数与内容核对在 M3 自己的
    演练里做；这条钉的是**列序**——`INSERT INTO … SELECT *` 式拷贝的前提。
    """
    relay_side = str(tmp_path / "relay.db")
    conn = sqlite3.connect(relay_side)
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
        " createdAt INTEGER NOT NULL, readAt INTEGER, PRIMARY KEY (noticeId, accountId));")
    conn.execute("INSERT INTO feedbackThreads(threadId, ticketHash, accountId, deviceId,"
                 " createdAt, lastMessageAt, status) VALUES('th_x','h','acc_a','dev_a',1,1,'open')")
    conn.commit()
    conn.close()

    # 迁移动作：按表整份拷进 mail 的新库（与 migrate 脚本同一条路）。
    mail_side = str(tmp_path / "mail.db")
    Store(mail_side).close()
    dest = sqlite3.connect(mail_side)
    source = sqlite3.connect(relay_side)
    for table in NEW_TABLES:
        rows = source.execute(f"SELECT * FROM {table}").fetchall()
        if rows:
            source_columns = [d[0] for d in source.execute(f"SELECT * FROM {table}").description]
            marks = ",".join("?" * len(source_columns))
            dest.executemany(f"INSERT OR REPLACE INTO {table}({','.join(source_columns)})"
                             f" VALUES({marks})", rows)
    dest.commit()
    dest.close()
    source.close()

    for table, expected in EXPECTED_COLUMNS.items():
        assert columns(mail_side, table) == expected, table
    store = Store(mail_side)
    try:
        thread = store.feedback_thread("th_x", None, messages_per_thread=0)
        assert thread is not None and thread["accountId"] == "acc_a"
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


def test_the_team_clause_of_by_device_is_gated_by_the_callers_switch(tmp_path):
    """团队那条命中路径只在调用方**就是**团队账号、且开关打开时参与（2026-10-17 事故）。

    归属是派生谓词（accountId / deviceModel + 当前团队账号），不是提交时的
    `teamAccountId` 快照；因此开关被部署清空时团队两侧都看不到来信，
    而写信人自己的可见性、以及团队自己的线程都不受影响。
    """
    store = Store(str(tmp_path / "state.db"))
    try:
        letter = store.create_feedback_thread(ticket_hash=sha256_hex("fk_letter"), text="用户来信",
                                              device_id="dev_user", account_id="acc_user",
                                              device_model="iPhone15,4", at=1_000)
        mine = store.create_feedback_thread(ticket_hash=sha256_hex("fk_mine"), text="owner 自己",
                                            device_id="dev_owner", account_id="acc_team",
                                            device_model="iPhone15,4", at=2_000)

        # 开关打开且调用方就是团队：别人的来信 + 自己那条。
        assert {t["threadId"] for t in store.feedback_threads_by_device(
            "dev_owner", "acc_team", team_account="acc_team")} == {letter["threadId"],
                                                                   mine["threadId"]}
        # 开关关闭：团队路径不参与，只剩自己那条；用户的来信仍在（写信人看得到）。
        assert [t["threadId"] for t in store.feedback_threads_by_device(
            "dev_owner", "acc_team")] == [mine["threadId"]]
        assert [t["threadId"] for t in store.feedback_threads_by_device(
            "dev_user", "acc_user")] == [letter["threadId"]], "写信人不受开关影响"
        # 开着开关也不会把别家的账号当成团队：判据是调用方自己的账号。
        assert store.feedback_threads_by_device("dev_other", "acc_other",
                                                team_account="acc_team") == []
        # 顺序仍是最近活动在前。
        assert [t["threadId"] for t in store.feedback_threads_by_device(
            "dev_owner", "acc_team", team_account="acc_team")] == [mine["threadId"],
                                                                    letter["threadId"]]
    finally:
        store.close()


def test_a_migrated_database_gains_the_team_column_and_the_index(tmp_path):
    """从中转迁过来的库缺 `teamAccountId`：`Store` 打开时补列 + 建索引，
    补出来的列照常参与团队命中（2026-10-15 的"索引随迁移建"热修）。"""
    path = str(tmp_path / "mail.db")
    conn = sqlite3.connect(path)
    conn.executescript(
        "CREATE TABLE feedbackThreads (threadId TEXT PRIMARY KEY, ticketHash TEXT NOT NULL UNIQUE,"
        " accountId TEXT, deviceId TEXT, appVersion TEXT, deviceModel TEXT, systemVersion TEXT,"
        " createdAt INTEGER NOT NULL, lastMessageAt INTEGER NOT NULL, ownerReadAt INTEGER,"
        " userReadAt INTEGER, status TEXT NOT NULL DEFAULT 'open', clientRef TEXT UNIQUE,"
        " subject TEXT);")
    conn.execute("INSERT INTO feedbackThreads(threadId, ticketHash, accountId, deviceId,"
                 " createdAt, lastMessageAt, status) VALUES('th_old','h','acc_user','dev_user',1,1,'open')")
    conn.commit()
    conn.close()

    store = Store(path)
    try:
        assert columns(path, "feedbackThreads") == EXPECTED_COLUMNS["feedbackThreads"]
        assert "feedbackThreadsByTeam" in {row[1] for row in
                                           store._rows("PRAGMA index_list(feedbackThreads)")}
        # 老库补出来的列照旧可读（回滚时 feedback-rebind 会按谓词把它补齐）；
        # 但归属判定已不再读它，团队路径按派生谓词命中。
        assert [t["threadId"] for t in store.feedback_threads_by_device(
            "dev_owner", "acc_team", team_account="acc_team")] == ["th_old"]
        assert store.feedback_threads_by_device("dev_owner", "acc_team") == []
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

        assert store.feedback_thread(thread["threadId"], None)["ownerUnread"] == 2
        assert store.mark_thread_read(thread["threadId"]) is True
        assert store.feedback_thread(thread["threadId"], None)["ownerUnread"] == 0
        assert store.feedback_thread(thread["threadId"], None)["userReadAt"] == 3_000

        # 幂等：重复标记不改变结果，也不把时间往前挪。
        assert store.mark_thread_read(thread["threadId"]) is True
        assert store.feedback_thread(thread["threadId"], None)["userReadAt"] == 3_000
        assert store.mark_thread_read(thread["threadId"], upto_ms=1_500) is True
        assert store.feedback_thread(thread["threadId"], None)["userReadAt"] == 3_000

        store.append_feedback_message(thread["threadId"], "回信三", author="owner", at=4_000)
        assert store.feedback_thread(thread["threadId"], None)["ownerUnread"] == 1
        assert store.mark_thread_read("th_nope") is False
    finally:
        store.close()


def test_notices_are_delivered_and_read_per_account(tmp_path):
    """019：投递与已读都按账号一份，不再按设备。"""
    store = Store(str(tmp_path / "state.db"))
    try:
        notice = store.create_notice("维护通知正文", "服务通知", ["acc_a", "acc_b", "acc_a"], at=5_000)
        assert notice["noticeId"].startswith("nt_") and notice["recipients"] == 2
        assert count(store, "SELECT COUNT(*) FROM notices") == 1
        assert count(store, "SELECT COUNT(*) FROM noticeDeliveries") == 2

        mine = store.notices_for_account("acc_a")
        assert [n["noticeId"] for n in mine] == [notice["noticeId"]]
        assert mine[0]["read"] is False and mine[0]["subject"] == "服务通知"

        assert store.mark_notices_read("acc_a", [notice["noticeId"]]) == 1
        assert store.notices_for_account("acc_a")[0]["read"] is True
        # 账号级一份已读：另一个账号看到的仍是同一封通知的**自己那一行**，未读。
        assert store.notices_for_account("acc_b")[0]["read"] is False
        # 幂等与空操作。
        assert store.mark_notices_read("acc_a", [notice["noticeId"]]) == 0
        assert store.mark_notices_read("acc_a", ["nt_nope"]) == 0
        assert store.notices_for_account("acc_c") == []
    finally:
        store.close()


def test_one_account_has_exactly_one_delivery_row_per_notice(tmp_path):
    """同一封通知对同一账号只留一行：重复投递不会翻倍（不变式 1）。"""
    store = Store(str(tmp_path / "state.db"))
    try:
        notice = store.create_notice("正文", "通知", ["acc_a"], at=5_000)
        again = store.create_notice("正文", "通知", ["acc_a"], at=6_000)
        assert count(store, "SELECT COUNT(*) FROM noticeDeliveries WHERE noticeId=?",
                     (notice["noticeId"],)) == 1
        assert count(store, "SELECT COUNT(*) FROM noticeDeliveries WHERE noticeId=?",
                     (again["noticeId"],)) == 1
        # 一封通知一个账号一行——不是"一个账号下每台设备一行"。
        assert [n["noticeId"] for n in store.notices_for_account("acc_a")] == [
            again["noticeId"], notice["noticeId"]]
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

        store.create_notice("正文", "通知", ["acc_1"], at=1_000)
        store.create_notice("正文", "日报", ["acc_1"], format="html", at=2_000)
        store.create_notice("正文", "带空白", ["acc_1"], format="  html\n", at=3_000)
        assert [n["format"] for n in store.notices_for_account("acc_1")] == ["html", "html", "text"]
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
                store.create_notice("不该进库", "通知", ["acc_1"], format=bad)
        assert count(store, "SELECT COUNT(*) FROM feedbackMessages") == 1
        assert count(store, "SELECT COUNT(*) FROM notices") == 0
        assert count(store, "SELECT COUNT(*) FROM noticeDeliveries") == 0
    finally:
        store.close()


# ── M1：线程归属谓词（SQL 片段 + 纯函数）与每线程 mySide ────────────────────
#
# 「这条线程是不是写给团队的用户来信」只有一个事实、两份实现（SQL 用于命中与
# 未读聚合，纯函数用于内存判定），两者由下面的组合穷举钉成等价。

TEAM = "acc_team"
OTHER = "acc_other"


@pytest.mark.parametrize("account_id,device_model,expected", [
    (None, None, True),
    (None, "iPhone12,1", True),
    (None, "arm64", False),
    (TEAM, None, False),
    (TEAM, "iPhone12,1", False),
    (TEAM, "arm64", False),
    (OTHER, None, True),
    (OTHER, "iPhone12,1", True),
    (OTHER, "arm64", False),
])
def test_the_user_letter_predicate_over_every_combination(account_id, device_model, expected):
    assert is_user_letter(account_id, device_model, TEAM) is expected


def test_the_sql_fragment_and_the_pure_function_agree_on_every_combination(tmp_path):
    """谓词的两个实现必须逐格等价：`{NULL, 团队, 他人} × {NULL, arm64, iPhone12,1}`。"""
    store = Store(str(tmp_path / "state.db"))
    try:
        thread_ids: dict[tuple[str | None, str | None], str] = {}
        for account_id in (None, TEAM, OTHER):
            for device_model in (None, "arm64", "iPhone12,1"):
                thread = store.create_feedback_thread(
                    ticket_hash=sha256_hex(f"fk_{account_id}_{device_model}"), text="正文",
                    account_id=account_id, device_model=device_model, at=1_000)
                thread_ids[(account_id, device_model)] = thread["threadId"]

        sql_hits = {row["threadId"] for row in store._rows(
            f"SELECT threadId FROM feedbackThreads WHERE {USER_LETTER_SQL}", (TEAM,))}
        pure_hits = {thread_id for (account_id, device_model), thread_id in thread_ids.items()
                     if is_user_letter(account_id, device_model, TEAM)}

        assert sql_hits == pure_hits
        assert len(pure_hits) == 4, "匿名与他人 × 真实机型这四格是用户来信"
        assert thread_ids[(TEAM, "iPhone12,1")] not in sql_hits, "团队自己写的不算来信"
        assert thread_ids[(None, "arm64")] not in sql_hits, "测试机型不算来信"
    finally:
        store.close()


def test_my_side_is_owner_only_for_the_team_on_a_user_letter():
    assert my_side(True, caller_is_team=True) == "owner"
    assert my_side(True, caller_is_team=False) == "user", "普通用户永远是 user 侧"
    assert my_side(False, caller_is_team=True) == "user", "团队自己的信落在 user 侧"
    assert my_side(False, caller_is_team=False) == "user"


def test_the_payload_reports_my_side_and_only_my_side_unread(tmp_path):
    """团队与用户在**同一条来信**上看到各自一侧的未读；对方的那个数不出现。"""
    store = Store(str(tmp_path / "state.db"))
    try:
        letter = store.create_feedback_thread(ticket_hash=sha256_hex("fk_one"), text="第一句",
                                              account_id=OTHER, device_model="iPhone12,1", at=1_000)
        store.append_feedback_message(letter["threadId"], "回信", author="owner", at=2_000)
        store.append_feedback_message(letter["threadId"], "补充", author="user", at=3_000)

        as_user = store.feedback_thread(letter["threadId"], None, team=TEAM, caller_account=OTHER)
        assert as_user["userLetter"] is True and as_user["mySide"] == "user"
        assert as_user["callerIsTeam"] is False
        assert as_user["ownerUnread"] == 1, "我们写的留言里用户还没读的条数"
        assert as_user["userUnread"] == 2, "用户写的留言里我们还没读的条数"

        as_team = store.feedback_thread(letter["threadId"], None, team=TEAM, caller_account=TEAM)
        assert as_team["mySide"] == "owner" and as_team["callerIsTeam"] is True
        assert as_team["ownerUnread"] == 1 and as_team["userUnread"] == 2, "两个原始计数与视角无关"

        store.mark_team_thread_read(letter["threadId"])
        after = store.feedback_thread(letter["threadId"], None, team=TEAM, caller_account=TEAM)
        assert after["userUnread"] == 0, "团队读完来信"
        assert after["ownerUnread"] == 1, "用户那一侧没变"
    finally:
        store.close()


def test_the_teams_own_letter_never_counts_as_unread_for_the_team(tmp_path):
    store = Store(str(tmp_path / "state.db"))
    try:
        mine = store.create_feedback_thread(ticket_hash=sha256_hex("fk_mine"), text="自己测试",
                                            account_id=TEAM, device_model="iPhone15,4", at=1_000)
        payload = store.feedback_thread(mine["threadId"], None, team=TEAM, caller_account=TEAM)
        assert payload["userLetter"] is False
        assert payload["mySide"] == "user", "自己的提交归已发送那一侧"
        assert payload["callerIsTeam"] is True, "调用方确实是团队（否则 v1 不需归零）"
        assert payload["ownerUnread"] == 0 and payload["userUnread"] == 1
    finally:
        store.close()


def test_the_team_path_lists_user_letters_but_never_answers_a_non_team_caller(tmp_path):
    """第三条命中路径的判据是「调用方**就是**团队账号」——隔离用例的存储层一半。"""
    store = Store(str(tmp_path / "state.db"))
    try:
        letter = store.create_feedback_thread(ticket_hash=sha256_hex("fk_letter"), text="用户来信",
                                              account_id=OTHER, device_model="iPhone12,1",
                                              device_id="dev_user", at=1_000)
        own = store.create_feedback_thread(ticket_hash=sha256_hex("fk_own"), text="团队自己",
                                           account_id=TEAM, device_model="iPhone15,4",
                                           device_id="dev_team", at=2_000)
        anonymous = store.create_feedback_thread(ticket_hash=sha256_hex("fk_anon"), text="匿名来信",
                                                 device_model="iPhone17,1", at=3_000)
        simulator = store.create_feedback_thread(ticket_hash=sha256_hex("fk_sim"), text="验收单",
                                                 device_model="arm64", at=4_000)

        team_view = {thread["threadId"] for thread in store.feedback_threads_by_device(
            "dev_team", TEAM, team_account=TEAM)}
        assert team_view == {letter["threadId"], own["threadId"], anonymous["threadId"]}, \
            "团队看得到来信（含匿名），看不到验收单，也看得到自己那条"
        assert simulator["threadId"] not in team_view

        # 别人拿着同一个团队开关参数，一条来信都命中不了（且不是信的作者）。
        assert store.feedback_threads_by_device("dev_stranger", "acc_stranger",
                                                team_account=TEAM) == []
        # 开关关闭（team_account 为空）：团队只剩自己的线程。
        assert [t["threadId"] for t in store.feedback_threads_by_device("dev_team", TEAM)] == [
            own["threadId"]]
        # 写信人自己的可见性不受团队那条路径影响。
        assert [t["threadId"] for t in store.feedback_threads_by_device(
            "dev_user", OTHER)] == [letter["threadId"]]
    finally:
        store.close()


def test_owner_unread_counts_only_user_letters(tmp_path):
    """owner 清单的未读只算来信：团队自己的与测试机型的都不再显示 1 条清不掉的未读。"""
    store = Store(str(tmp_path / "state.db"))
    try:
        letter = store.create_feedback_thread(ticket_hash=sha256_hex("fk_letter"), text="来信",
                                              account_id=OTHER, device_model="iPhone12,1", at=1_000)
        own = store.create_feedback_thread(ticket_hash=sha256_hex("fk_mine"), text="自己",
                                     account_id=TEAM, device_model="iPhone15,4", at=2_000)
        store.create_feedback_thread(ticket_hash=sha256_hex("fk_sim"), text="验收",
                                     device_model="arm64", at=3_000)
        assert store.owner_unread_counts(TEAM) == {letter["threadId"]: 1}
        # 团队账号为空时谓词只剩"非测试机型"这一半：验收单照样出去，其余都算。
        # 管理命令因此必须用 --team-account 给出同一个团队账号（与服务的配置同源）。
        assert store.owner_unread_counts() == {letter["threadId"]: 1,
                                               own["threadId"]: 1}
    finally:
        store.close()


def test_rebind_rewrites_the_legacy_column_from_the_predicate(tmp_path):
    """回滚到旧包之前的唯一写入口：把旧列按谓词补齐，`--dry-run` 零写入。"""
    store = Store(str(tmp_path / "state.db"))
    try:
        letter = store.create_feedback_thread(ticket_hash=sha256_hex("fk_letter"), text="来信",
                                              account_id=OTHER, device_model="iPhone12,1", at=1_000)
        own = store.create_feedback_thread(ticket_hash=sha256_hex("fk_mine"), text="自己",
                                           account_id=TEAM, device_model="iPhone15,4", at=2_000)
        simulator = store.create_feedback_thread(ticket_hash=sha256_hex("fk_sim"), text="验收",
                                                 device_model="arm64", at=3_000)

        dry = store.rebind_team_account(TEAM, dry_run=True)
        assert dry == {"team": TEAM, "bound": 1, "cleared": 0, "dryRun": True}
        assert store._row("SELECT teamAccountId FROM feedbackThreads WHERE threadId=?",
                          (letter["threadId"],))["teamAccountId"] is None, "dry-run 不写库"

        run = store.rebind_team_account(TEAM)
        assert run == {"team": TEAM, "bound": 1, "cleared": 0, "dryRun": False}
        column = {row["threadId"]: row["teamAccountId"] for row in store._rows(
            "SELECT threadId, teamAccountId FROM feedbackThreads")}
        assert column[letter["threadId"]] == TEAM
        assert column[own["threadId"]] is None and column[simulator["threadId"]] is None
        # 幂等：再跑一遍不再改动任何一行。
        assert store.rebind_team_account(TEAM)["bound"] == 0
    finally:
        store.close()


# ── M2：两条列表共用一套「游标 + limit+1」分页，通知详情与未读聚合 ────────────


def test_notice_pages_walk_the_whole_history_without_gaps(tmp_path):
    store = Store(str(tmp_path / "state.db"))
    try:
        created = [store.create_notice(f"正文 {index}", f"通知 {index}", ["acc_a"], at=1_000 + index)
                   for index in range(205)]

        seen: list[str] = []
        pages = 0
        before = None
        while True:
            page, more = store.notice_page("acc_a", limit=40, before=before)
            assert len(page) == (40 if more else 5), "每页 40，最后一页 5"
            seen.extend(notice["noticeId"] for notice in page)
            pages += 1
            if not more:
                break
            before = {"createdAt": page[-1]["createdAt"], "noticeId": page[-1]["noticeId"]}
        assert pages == 6
        assert len(seen) == 205 == len(set(seen)), "并集 205、无重复、无缺口"
        assert seen == [notice["noticeId"] for notice in reversed(created)], "最近的在最前"

        # 旧入口是同一份实现的第一页：v1 仍拿 200 条窗口。
        assert len(store.notices_for_account("acc_a")) == 200
    finally:
        store.close()


def test_notice_pages_stay_stable_when_rows_share_one_timestamp(tmp_path):
    """同毫秒多条：靠 noticeId 做幂等键，翻页不重不漏。"""
    store = Store(str(tmp_path / "state.db"))
    try:
        created = [store.create_notice("正文", "通知", ["acc_a"], at=5_000) for _ in range(9)]
        seen: list[str] = []
        before = None
        while True:
            page, more = store.notice_page("acc_a", limit=2, before=before)
            seen.extend(notice["noticeId"] for notice in page)
            if not more:
                break
            before = {"createdAt": page[-1]["createdAt"], "noticeId": page[-1]["noticeId"]}
        assert len(seen) == 9 == len(set(seen))
        assert seen == sorted((notice["noticeId"] for notice in created), reverse=True)
    finally:
        store.close()


def test_the_notice_detail_is_only_available_to_its_recipient(tmp_path):
    store = Store(str(tmp_path / "state.db"))
    try:
        notice = store.create_notice("通知正文", "标题", ["acc_a"], at=5_000)
        detail = store.notice_for_account("acc_a", notice["noticeId"])
        assert detail["body"] == "通知正文" and detail["read"] is False
        assert detail["subject"] == "标题" and detail["format"] == "text"
        assert store.notice_for_account("acc_b", notice["noticeId"]) is None, "没这条投递"
        assert store.notice_for_account("acc_a", "nt_nope") is None, "不存在"
    finally:
        store.close()


def test_the_unread_notice_count_is_independent_of_any_window(tmp_path):
    store = Store(str(tmp_path / "state.db"))
    try:
        ids = [store.create_notice("正文", "通知", ["acc_a"], at=1_000 + index)["noticeId"]
               for index in range(205)]
        assert store.unread_notice_count("acc_a") == 205
        store.mark_notices_read("acc_a", ids[:5])
        assert store.unread_notice_count("acc_a") == 200
        assert store.unread_notice_count("acc_b") == 0
    finally:
        store.close()


def test_the_notice_delivery_stats_count_the_audience(tmp_path):
    store = Store(str(tmp_path / "state.db"))
    try:
        notice = store.create_notice("正文", "标题", ["acc_a", "acc_b", "acc_c"], at=5_000)
        store.mark_notices_read("acc_a", [notice["noticeId"]])
        assert store.notice_delivery_stats(notice["noticeId"]) == {
            "noticeId": notice["noticeId"], "subject": "标题", "delivered": 3, "read": 1,
            "unread": 2}
        assert store.notice_delivery_stats("nt_nope") is None
    finally:
        store.close()


def test_thread_pages_walk_every_thread_without_gaps(tmp_path):
    store = Store(str(tmp_path / "state.db"))
    try:
        created = []
        for index in range(205):
            thread = store.create_feedback_thread(
                ticket_hash=sha256_hex(f"fk_{index}"), text=f"第 {index} 封",
                device_id="dev_walk", account_id="acc_walk", at=1_000 + index)
            for extra in range(5):
                store.append_feedback_message(thread["threadId"], f"补充 {extra}", author="owner",
                                              at=1_000 + index)
            created.append(thread["threadId"])

        # 可见集合一次取全部行，再切页（未读合并不受窗口影响的前提）。
        rows = store.visible_thread_rows((), "dev_walk", "acc_walk")
        custom = store.unread_counts_by_thread([row["threadId"] for row in rows])

        seen: list[str] = []
        before = None
        while True:
            page_rows, more = page_thread_rows(rows, limit=30, before=before)
            page = store.thread_payloads(page_rows, 6, unread=custom)
            assert all(len(thread["messages"]) == 6 for thread in page)
            seen.extend(thread["threadId"] for thread in page)
            if not more:
                break
            before = {"lastMessageAt": page[-1]["lastMessageAt"],
                      "threadId": page[-1]["threadId"]}
        assert len(seen) == 205 == len(set(seen)), "并集 205、无重复、无缺口"
        assert seen == list(reversed(created)), "lastMessageAt 倒序（同毫秒按 threadId）"
    finally:
        store.close()


def test_a_thread_that_moves_while_paging_is_never_lost(tmp_path):
    """翻页中途来了一条回信：`lastMessageAt` 前移，最多重复，绝不丢。"""
    store = Store(str(tmp_path / "state.db"))
    try:
        for index in range(65):
            store.create_feedback_thread(
                ticket_hash=sha256_hex(f"fk_{index}"), text=f"第 {index} 封",
                device_id="dev_walk", account_id="acc_walk", at=1_000 + index)

        rows = store.visible_thread_rows((), "dev_walk", "acc_walk")
        first_rows, more = page_thread_rows(rows, limit=30)
        assert more is True
        first = store.thread_payloads(first_rows, 6)
        moved = first[-1]["threadId"]
        store.append_feedback_message(moved, "翻页途中来的回信", author="user", at=9_000_000)

        seen = [thread["threadId"] for thread in first]
        before = {"lastMessageAt": first[-1]["lastMessageAt"], "threadId": moved}
        while True:
            page_rows, more = page_thread_rows(rows, limit=30, before=before)
            page = store.thread_payloads(page_rows, 6)
            seen.extend(thread["threadId"] for thread in page)
            if not more:
                break
            before = {"lastMessageAt": page[-1]["lastMessageAt"],
                      "threadId": page[-1]["threadId"]}
        assert set(seen) == {thread["threadId"] for thread in store.list_feedback_threads(limit=1000)}
        assert len(seen) == len(set(seen)), "时间只增不减时不该重复"
    finally:
        store.close()


def test_thread_pages_stay_stable_when_rows_share_one_timestamp(tmp_path):
    """同毫秒多条：`(lastMessageAt DESC, threadId DESC)`，2/页走到尾，不丢不重。"""
    store = Store(str(tmp_path / "state.db"))
    try:
        for index in range(5):
            store.create_feedback_thread(
                ticket_hash=sha256_hex(f"fk_same_ms_{index}"), text=f"第 {index} 封",
                device_id="dev_same", account_id="acc_same", at=5_000)

        rows = store.visible_thread_rows((), "dev_same", "acc_same")
        counts = store.unread_counts_by_thread([row["threadId"] for row in rows])
        seen: list[str] = []
        before = None
        while True:
            page_rows, more = page_thread_rows(rows, limit=2, before=before)
            page = store.thread_payloads(page_rows, 1, unread=counts)
            assert [int(t["lastMessageAt"]) for t in page] == [5_000] * len(page)
            seen.extend(t["threadId"] for t in page)
            if not more:
                break
            before = {"lastMessageAt": page[-1]["lastMessageAt"],
                      "threadId": page[-1]["threadId"]}

        assert len(seen) == 5 == len(set(seen)), "同毫秒也不丢不重"
        assert seen == sorted(seen, reverse=True), "同毫秒时 threadId 降序（与文档一致）"
        # 游标的 SQL 口径与内存口径必须一致：`id <` 而不是 `id >`。
        from store import is_after_before
        assert is_after_before({"lastMessageAt": 5_000, "threadId": "th_b"},
                               {"lastMessageAt": 5_000, "threadId": "th_c"},
                               "lastMessageAt", "threadId") is True
        assert is_after_before({"lastMessageAt": 5_000, "threadId": "th_d"},
                               {"lastMessageAt": 5_000, "threadId": "th_c"},
                               "lastMessageAt", "threadId") is False
    finally:
        store.close()
