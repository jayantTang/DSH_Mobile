"""存储层：四张信件表与读写方法（014）—— mail 侧移植版。

表结构、列名与上限逐字照 `specs/014-feedback-channel/data-model.md`，与
旧中转库的同名表逐列一致（迁移脚本按列拷贝的前提，有测试钉住）。
本文件只用 `tmp_path` 里的库，绝不碰生产 `mail.db`。
"""

from __future__ import annotations

import sqlite3

import pytest

from store import NotFound, Store, StoreError, sha256_hex

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
    """团队绑定只在调用方**给了** `team_account` 时参与命中（2026-10-17 事故）。

    事故形状是"开关被部署清空、库里的绑定还在"：修复前团队设备仍然拿得到用户的
    来信，于是 App 按用户视角把它们排进 owner 的「已发送」。这里从存储层钉住
    判据：不给 `team_account` 就没有团队那条路径，且**不影响**写信人自己的命中。
    """
    store = Store(str(tmp_path / "state.db"))
    try:
        letter = store.create_feedback_thread(ticket_hash=sha256_hex("fk_letter"), text="用户来信",
                                              device_id="dev_user", account_id="acc_user",
                                              team_account_id="acc_team", at=1_000)
        mine = store.create_feedback_thread(ticket_hash=sha256_hex("fk_mine"), text="owner 自己",
                                            device_id="dev_owner", account_id="acc_team", at=2_000)

        # 开关打开：团队看得到别人的来信，也看得到自己的。
        assert {t["threadId"] for t in store.feedback_threads_by_device(
            "dev_owner", "acc_team", team_account="acc_team")} == {letter["threadId"],
                                                                   mine["threadId"]}
        # 开关关闭：团队路径不参与，只剩自己那条；用户的来信仍在（写信人看得到）。
        assert [t["threadId"] for t in store.feedback_threads_by_device(
            "dev_owner", "acc_team")] == [mine["threadId"]]
        assert [t["threadId"] for t in store.feedback_threads_by_device(
            "dev_user", "acc_user")] == [letter["threadId"]], "写信人不受开关影响"
        # 开着开关也不会把别家的账号当成团队：线索仍按**调用方自己的**账号配对，
        # 无关账号一条都拿不到（开关只决定这条路径开不开）。
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
        store._conn.execute("UPDATE feedbackThreads SET teamAccountId='acc_team' WHERE threadId='th_old'")
        store._conn.commit()
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
