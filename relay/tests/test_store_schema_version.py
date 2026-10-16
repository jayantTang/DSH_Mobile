"""The database has a version, and an old database is brought forward on open.

``SCHEMA`` is entirely ``CREATE TABLE IF NOT EXISTS``. That is right for adding a
*table* to a live ``state.db`` and silently wrong for adding a *column*: the
upgraded relay would start, report ``/healthz`` fine, and then fail at runtime
with "no such column" the first time that column was written. On a relay that
only writes on an event, that can be hours later.

These tests pin the mechanism that turns that class of change into a startup
migration — the version is recorded, an old file is stamped rather than altered,
data survives, and a database from the *future* is left alone instead of being
downgraded by an older build.
"""

from __future__ import annotations

import sqlite3

from store import SCHEMA_VERSION, Store


def user_version(path: str) -> int:
    conn = sqlite3.connect(path)
    try:
        return int(conn.execute("PRAGMA user_version").fetchone()[0])
    finally:
        conn.close()


def test_a_fresh_database_is_stamped_with_the_current_version(tmp_path):
    path = str(tmp_path / "state.db")
    store = Store(path)
    store.close()
    assert user_version(path) == SCHEMA_VERSION


def test_an_unversioned_database_is_migrated_on_open(tmp_path):
    """The case the mechanism exists for: a ``state.db`` from before versioning.

    Built by hand — a real pre-versioning file, with rows already in it — rather
    than by asking ``Store`` to make one, because a store-created file would
    already carry the version and prove nothing.
    """
    path = str(tmp_path / "legacy.db")
    conn = sqlite3.connect(path)
    conn.executescript("""
        CREATE TABLE accounts (
          accountId TEXT PRIMARY KEY, name TEXT NOT NULL, createdAt INTEGER NOT NULL);
        CREATE TABLE agents (
          agentId TEXT PRIMARY KEY, accountId TEXT NOT NULL, name TEXT NOT NULL,
          secretHash TEXT NOT NULL, createdAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL,
          disabled INTEGER NOT NULL DEFAULT 0, lastSeenAt INTEGER);
        INSERT INTO accounts VALUES ('acc_old', 'old account', 1700000000000);
        INSERT INTO agents VALUES ('agt_old', 'acc_old', 'old mac', 'hash', 1, 1, 0, NULL);
    """)
    conn.commit()
    conn.close()
    assert user_version(path) == 0, "前提：这个库确实没有版本号"

    store = Store(path)
    try:
        # The version moved…
        assert user_version(path) == SCHEMA_VERSION
        # …the pre-existing rows are untouched…
        assert store.get_account("acc_old")["name"] == "old account"
        assert store.agent_by_id("agt_old")["name"] == "old mac"
        # …and the tables the old file never had are now present and usable.
        invite = store.mint_invite()
        assert store.claim_invite(invite["code"], "new machine")["agentId"].startswith("agt_")
        assert store.list_accounts() and len(store.list_accounts()) == 2
    finally:
        store.close()


def test_migrating_is_idempotent(tmp_path):
    """Reopening must not re-run steps or lose the stamp."""
    path = str(tmp_path / "state.db")
    Store(path).close()
    for _ in range(3):
        store = Store(path)
        store.close()
    assert user_version(path) == SCHEMA_VERSION


def test_a_newer_database_is_not_downgraded(tmp_path):
    """An older build must not silently rewrite a database it does not know.

    Skipping the stamp would be worse than doing nothing: the newer build's own
    migrations would then be re-run against a database that had already applied
    them.
    """
    path = str(tmp_path / "future.db")
    conn = sqlite3.connect(path)
    conn.execute(f"PRAGMA user_version = {SCHEMA_VERSION + 5}")
    conn.commit()
    conn.close()

    store = Store(path)
    store.close()
    assert user_version(path) == SCHEMA_VERSION + 5


def test_the_schema_and_the_version_agree(tmp_path):
    """A database the current code creates already has every column it expects.

    This is the guard against the original failure mode: bump ``SCHEMA_VERSION``
    for a column that ``SCHEMA`` does not create and forget the migration, and an
    existing database ends up structurally different from a fresh one.
    """
    fresh = str(tmp_path / "fresh.db")
    store = Store(fresh)
    try:
        columns = {row[1] for row in store._rows("PRAGMA table_info(usageDaily)")}
        assert {"day", "deviceId", "egressBytes", "lastBuild"} <= columns
        assert {row[0] for row in store._rows(
            "SELECT name FROM sqlite_master WHERE type='table'")} >= {
                "accounts", "agents", "devices", "pairCodes", "usageDaily", "invites"}
    finally:
        store.close()
    assert user_version(fresh) == SCHEMA_VERSION


def test_usage_rows_still_respect_the_day_column(tmp_path):
    """The table the quota now reads from keeps its shape and its index."""
    path = str(tmp_path / "state.db")
    store = Store(path)
    try:
        indexes = {row[1] for row in store._rows("PRAGMA index_list(usageDaily)")}
        assert "usageDailyAccount" in indexes
    finally:
        store.close()


#: v1 时代的 devices 表（推送那五列之前）。手工建，不用 `Store`——store 建出来的
#: 库已经带版本号，证明不了迁移。
_DEVICES_V1 = """
CREATE TABLE devices (
  deviceId        TEXT PRIMARY KEY,
  deviceTokenHash TEXT NOT NULL UNIQUE,
  agentId         TEXT NOT NULL,
  accountId       TEXT NOT NULL,
  name            TEXT NOT NULL,
  model           TEXT,
  appVersion      TEXT,
  createdAt       INTEGER NOT NULL,
  expiresAt       INTEGER NOT NULL,
  lastSeenAt      INTEGER,
  revokedAt       INTEGER
);
"""

PUSH_COLUMNS = {"apnsToken", "apnsEnv", "pushTurnEnd", "pushAttention", "pushUpdatedAt"}


def write_v1_database(path: str) -> None:
    """A database at generation 1, with rows in it, stamped as such."""
    conn = sqlite3.connect(path)
    conn.executescript(_DEVICES_V1)
    conn.executescript("""
        CREATE TABLE accounts (
          accountId TEXT PRIMARY KEY, name TEXT NOT NULL, createdAt INTEGER NOT NULL);
        CREATE TABLE agents (
          agentId TEXT PRIMARY KEY, accountId TEXT NOT NULL, name TEXT NOT NULL,
          secretHash TEXT NOT NULL, createdAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL,
          disabled INTEGER NOT NULL DEFAULT 0, lastSeenAt INTEGER);
    """)
    conn.execute("INSERT INTO accounts VALUES ('acc_old', 'old account', 1700000000000)")
    conn.execute("INSERT INTO agents VALUES ('agt_old', 'acc_old', 'old mac', 'hash', 1, 1, 0, NULL)")
    conn.execute(
        "INSERT INTO devices VALUES ('dev_old', 'hash_old', 'agt_old', 'acc_old', 'iPhone',"
        " 'iPhone17,1', '1.0', 1700000000000, 4102444800000, 1700000001000, NULL)")
    conn.execute("PRAGMA user_version = 1")
    conn.commit()
    conn.close()


def test_v1_gains_the_push_columns_without_losing_rows(tmp_path):
    """R-1 C-07：v1→v2 迁移。

    核心断言是**旧行数据不丢**：`CREATE TABLE IF NOT EXISTS` 对"加一列"是静默无效的，
    所以一个升级了代码、留着 `state.db` 的部署会带着一张缺列的 devices 表起来——
    中转报告自己健康，直到第一次写推送那一列才在运行时报 "no such column"。
    """
    path = str(tmp_path / "v1.db")
    write_v1_database(path)
    assert user_version(path) == 1, "前提：这个库是 v1"
    before = sqlite3.connect(path).execute("SELECT * FROM devices").fetchone()

    store = Store(path)
    try:
        assert user_version(path) == SCHEMA_VERSION
        columns = {row[1] for row in store._rows("PRAGMA table_info(devices)")}
        assert PUSH_COLUMNS <= columns, f"缺列：{PUSH_COLUMNS - columns}"

        # 旧行整行不动（含每一个旧列的值）。
        row = store.device_by_id("dev_old")
        assert row["name"] == "iPhone"
        assert row["deviceTokenHash"] == "hash_old"
        assert row["expiresAt"] == 4102444800000
        assert row["lastSeenAt"] == 1700000001000
        assert row["appVersion"] == "1.0"
        assert tuple(row[column] for column in (
            "deviceId", "deviceTokenHash", "agentId", "accountId", "name", "model",
            "appVersion", "createdAt", "expiresAt", "lastSeenAt", "revokedAt")) == before
        # 新列取默认值：两个开关默认开着，令牌为空。
        assert row["apnsToken"] is None
        assert row["apnsEnv"] is None
        assert row["pushTurnEnd"] == 1 and row["pushAttention"] == 1

        # 迁移后的表是可用的：登记一次推送走通。
        store.set_push("dev_old", "ab" * 32, "sandbox", True, False)
        assert store.push_targets("agt_old")[0]["apnsToken"] == "ab" * 32
    finally:
        store.close()


def test_the_push_migration_is_idempotent(tmp_path):
    """迁移可重复跑（部分提交后重试不能失败）：`ADD COLUMN` 在 SQLite 里不是幂等的。"""
    path = str(tmp_path / "v1.db")
    write_v1_database(path)
    Store(path).close()
    for _ in range(3):
        store = Store(path)   # 版本已是最新，这几步实际不会再跑迁移
        store.close()
    assert user_version(path) == SCHEMA_VERSION

    # 直接再调一次迁移函数本身：必须自己发现列已存在而不是抛 duplicate column。
    import store as store_module
    conn = sqlite3.connect(path)
    try:
        store_module._migrate_to_2(conn)  # noqa: SLF001 - 就是这个幂等性要在测
        store_module._migrate_to_2(conn)  # noqa: SLF001
        conn.commit()
    finally:
        conn.close()


#: v2 时代的 feedbackThreads（界面重做加 `subject` 之前）：13 列，没有 subject。
#: 手工建，不用 `Store`——store 建出来的库已经带版本号与新列，证明不了迁移。
_FEEDBACK_V2 = """
CREATE TABLE feedbackThreads (
  threadId       TEXT PRIMARY KEY,
  ticketHash     TEXT NOT NULL UNIQUE,
  accountId      TEXT,
  deviceId       TEXT,
  appVersion     TEXT,
  deviceModel    TEXT,
  systemVersion  TEXT,
  createdAt      INTEGER NOT NULL,
  lastMessageAt  INTEGER NOT NULL,
  ownerReadAt    INTEGER,
  userReadAt     INTEGER,
  status         TEXT NOT NULL DEFAULT 'open',
  clientRef      TEXT UNIQUE
);
CREATE TABLE feedbackMessages (
  messageId  TEXT PRIMARY KEY,
  threadId   TEXT NOT NULL,
  author     TEXT NOT NULL,
  body       TEXT NOT NULL,
  createdAt  INTEGER NOT NULL,
  clientRef  TEXT UNIQUE
);
"""

#: v2 的线程行（13 列）。用来核对迁移之后**整行**没被动过。
_V2_THREAD = ("th_old", "hash_old", "acc_old", "dev_old", "1.0", "iPhone17,1", "18.2",
              1700000000000, 1700000005000, None, None, "open", None)

V2_THREAD_COLUMNS = ("threadId", "ticketHash", "accountId", "deviceId", "appVersion",
                     "deviceModel", "systemVersion", "createdAt", "lastMessageAt",
                     "ownerReadAt", "userReadAt", "status", "clientRef")


def write_v2_database(path: str) -> None:
    """A database at generation 2, with a feedback thread (and its message) already in it."""
    conn = sqlite3.connect(path)
    conn.executescript(_FEEDBACK_V2)
    conn.execute(f"INSERT INTO feedbackThreads VALUES ({','.join('?' * len(_V2_THREAD))})",
                 _V2_THREAD)
    conn.execute("INSERT INTO feedbackMessages VALUES ('fm_old', 'th_old', 'user', '老反馈',"
                 " 1700000000000, NULL)")
    conn.execute("PRAGMA user_version = 2")
    conn.commit()
    conn.close()


def test_v2_gains_the_subject_column_without_touching_the_old_rows(tmp_path):
    """界面重做（2026-10-12）：v2→v3 迁移。

    这是本项目**第一次给一张已经有数据的表加列**：生产库上的反馈线程已经存在，
    `CREATE TABLE IF NOT EXISTS` 对"加一列"是静默无效的，所以升级后的部署会带着一张
    缺 `subject` 的表起来——中转报告自己健康，直到第一次写那一列才在运行时报
    "no such column"。核心断言是**旧行数据不丢**。
    """
    path = str(tmp_path / "v2.db")
    write_v2_database(path)
    assert user_version(path) == 2, "前提：这个库是 v2"
    before = sqlite3.connect(path).execute("SELECT * FROM feedbackThreads").fetchone()

    store = Store(path)
    try:
        assert user_version(path) == SCHEMA_VERSION
        columns = {row[1] for row in store._rows("PRAGMA table_info(feedbackThreads)")}
        assert "subject" in columns, "缺列：subject"

        # 旧行整行不动（含每一个旧列的值），新列是 NULL。
        row = store.feedback_thread("th_old", None, messages_per_thread=1)
        assert row["subject"] is None, "旧行没有主题，不是空串"
        assert tuple(row[column] for column in V2_THREAD_COLUMNS) == before
        assert [message["body"] for message in row["messages"]] == ["老反馈"]

        # 迁移后的表立刻可用：写主题、读回来、按设备查也带得出这一列。
        assert store.set_feedback_subject("th_old", "  升级之后能写主题  ") is True
        assert store.feedback_thread("th_old", None)["subject"] == "升级之后能写主题"
        assert store.feedback_threads_by_device("dev_old", "acc_old")[0]["subject"] \
            == "升级之后能写主题"
    finally:
        store.close()


def test_the_subject_migration_is_idempotent(tmp_path):
    """v2→v3 的 `ADD COLUMN` 同样不是幂等的：重复跑必须自己发现列已存在。"""
    path = str(tmp_path / "v2.db")
    write_v2_database(path)
    Store(path).close()
    for _ in range(3):
        Store(path).close()
    assert user_version(path) == SCHEMA_VERSION

    import store as store_module
    conn = sqlite3.connect(path)
    try:
        store_module._migrate_to_3(conn)  # noqa: SLF001 - 就是这个幂等性要在测
        store_module._migrate_to_3(conn)  # noqa: SLF001
        conn.commit()
    finally:
        conn.close()


#: v3 时代的反馈表（富文本加 `format` 之前）：`feedbackThreads` 已经有 `subject`，
#: `feedbackMessages` 与 `notices` 都还没有 `format`。手工建，不用 `Store`——store 建出来
#: 的库已经带版本号与新列，证明不了迁移。
_FEEDBACK_V3 = """
CREATE TABLE feedbackThreads (
  threadId       TEXT PRIMARY KEY,
  ticketHash     TEXT NOT NULL UNIQUE,
  accountId      TEXT,
  deviceId       TEXT,
  appVersion     TEXT,
  deviceModel    TEXT,
  systemVersion  TEXT,
  createdAt      INTEGER NOT NULL,
  lastMessageAt  INTEGER NOT NULL,
  ownerReadAt    INTEGER,
  userReadAt     INTEGER,
  status         TEXT NOT NULL DEFAULT 'open',
  clientRef      TEXT UNIQUE,
  subject        TEXT
);
CREATE TABLE feedbackMessages (
  messageId  TEXT PRIMARY KEY,
  threadId   TEXT NOT NULL,
  author     TEXT NOT NULL,
  body       TEXT NOT NULL,
  createdAt  INTEGER NOT NULL,
  clientRef  TEXT UNIQUE
);
CREATE TABLE notices (
  noticeId   TEXT PRIMARY KEY,
  subject    TEXT,
  body       TEXT NOT NULL,
  createdAt  INTEGER NOT NULL,
  createdBy  TEXT
);
CREATE TABLE noticeDeliveries (
  noticeId   TEXT NOT NULL,
  deviceId   TEXT NOT NULL,
  createdAt  INTEGER NOT NULL,
  readAt     INTEGER,
  PRIMARY KEY (noticeId, deviceId)
);
"""

#: v3 的留言行（6 列，没有 format）。用来核对迁移之后**整行**没被动过。
_V3_MESSAGE = ("fm_old", "th_old", "user", "老反馈", 1700000000000, None)

#: v3 的通知行（5 列，没有 format）。
_V3_NOTICE = ("nt_old", "老通知", "正文", 1700000000000, "admin.py")

V3_MESSAGE_COLUMNS = ("messageId", "threadId", "author", "body", "createdAt", "clientRef")
V3_NOTICE_COLUMNS = ("noticeId", "subject", "body", "createdAt", "createdBy")

#: 两张表迁移之后多出来的那一列（必须落在末尾）。
FORMAT_COLUMN = "format"


#: v3 时代的 `devices`（推送那几列已经在）：019 的回填要靠它把设备映射到账号。
_DEVICES_V3 = """
CREATE TABLE devices (
  deviceId        TEXT PRIMARY KEY,
  deviceTokenHash TEXT NOT NULL UNIQUE,
  agentId         TEXT NOT NULL,
  accountId       TEXT NOT NULL,
  name            TEXT NOT NULL,
  model           TEXT,
  appVersion      TEXT,
  createdAt       INTEGER NOT NULL,
  expiresAt       INTEGER NOT NULL,
  lastSeenAt      INTEGER,
  revokedAt       INTEGER,
  apnsToken       TEXT,
  apnsEnv         TEXT,
  pushTurnEnd     INTEGER NOT NULL DEFAULT 1,
  pushAttention   INTEGER NOT NULL DEFAULT 1,
  pushUpdatedAt   INTEGER
);
"""

#: v3 时代的投递行：设备维度（019 之前）。
_V3_DELIVERY = ("nt_old", "dev_old", 1700000000000, None)


def write_v3_database(path: str) -> None:
    """A database at generation 3, with a message and a notice already in it."""
    conn = sqlite3.connect(path)
    conn.executescript(_DEVICES_V3)
    conn.execute(
        "INSERT INTO devices VALUES ('dev_old', 'hash_old', 'agt_old', 'acc_old', 'iPhone',"
        " 'iPhone17,1', '1.0', 1700000000000, 4102444800000, 1700000001000, NULL,"
        " NULL, NULL, 1, 1, NULL)")
    conn.executescript(_FEEDBACK_V3)
    conn.execute(f"INSERT INTO feedbackThreads VALUES ({','.join('?' * len(_V2_THREAD))}, ?)",
                 (*_V2_THREAD, "用户写的主题"))
    conn.execute(f"INSERT INTO feedbackMessages VALUES ({','.join('?' * len(_V3_MESSAGE))})",
                 _V3_MESSAGE)
    conn.execute(f"INSERT INTO notices VALUES ({','.join('?' * len(_V3_NOTICE))})", _V3_NOTICE)
    conn.execute(f"INSERT INTO noticeDeliveries VALUES ({','.join('?' * len(_V3_DELIVERY))})",
                 _V3_DELIVERY)
    conn.execute("PRAGMA user_version = 3")
    conn.commit()
    conn.close()


def test_v3_gains_the_format_column_on_both_tables_without_touching_the_old_rows(tmp_path):
    """富文本（2026-10-12 第四轮）：v3→v4 迁移，两张表各加 `format`。

    回信（`feedbackMessages`）与通知（`notices`）都可能带 `html`，所以两张表都要补。
    核心断言与前两次迁移一样是**旧行数据不丢**：`CREATE TABLE IF NOT EXISTS` 对"加一列"
    是静默无效的，升级后的部署会带着缺列的表起来——中转报告自己健康，直到第一次写那一列
    才在运行时报 "no such column"。旧行拿不到旧值就是改写历史：那些信与通知已经发出去了。
    """
    path = str(tmp_path / "v3.db")
    write_v3_database(path)
    assert user_version(path) == 3, "前提：这个库是 v3"
    conn = sqlite3.connect(path)
    try:
        before_message = conn.execute("SELECT * FROM feedbackMessages").fetchone()
        before_notice = conn.execute("SELECT * FROM notices").fetchone()
    finally:
        conn.close()

    store = Store(path)
    try:
        assert user_version(path) == SCHEMA_VERSION
        for table in ("feedbackMessages", "notices"):
            columns = [row[1] for row in store._rows(f"PRAGMA table_info({table})")]
            assert FORMAT_COLUMN in columns, f"{table} 缺列：format"
            assert columns[-1] == FORMAT_COLUMN, f"{table} 的 format 必须在最后一列"

        # 旧行整行不动（含每一个旧列的值），新列取默认 `text`。
        message = store.feedback_thread("th_old", None, messages_per_thread=1)["messages"][0]
        assert message["format"] == "text", "已经发出去的信不会被改写成别的格式"
        assert tuple(message[column] for column in V3_MESSAGE_COLUMNS) == before_message
        # 通知走**账号**维度读（019）：老通知在那台设备所属账号的收件箱里，格式同样是 text。
        (notice,) = store.notices_for_account("acc_old")
        assert notice["format"] == "text"
        assert tuple(notice[column] for column in V3_NOTICE_COLUMNS) == before_notice
        # 摘要（日报/清单的那一份）也带得出格式。
        assert store.feedback_digest(["th_old"])["th_old"]["format"] == "text"

        # 迁移后的两张表立刻可用：写一条 html 回信与一条 html 通知都走通。
        written = store.append_feedback_message("th_old", "<h1>报告</h1>", author="owner",
                                                format="html")
        assert store.feedback_thread("th_old", None)["messages"][-1]["format"] == "html"
        assert written["messageId"].startswith("fm_")
        store.create_notice("<h1>日报</h1>", "日报", ["acc_old"], format="html")
        assert store.notices_for_account("acc_old")[0]["format"] == "html"
    finally:
        store.close()


def test_the_format_migration_is_idempotent(tmp_path):
    """v3→v4 的 `ADD COLUMN` 同样不是幂等的：重复跑必须自己发现列已存在。"""
    path = str(tmp_path / "v3.db")
    write_v3_database(path)
    Store(path).close()
    for _ in range(3):
        Store(path).close()
    assert user_version(path) == SCHEMA_VERSION

    import store as store_module
    conn = sqlite3.connect(path)
    try:
        store_module._migrate_to_4(conn)  # noqa: SLF001 - 就是这个幂等性要在测
        store_module._migrate_to_4(conn)  # noqa: SLF001
        conn.commit()
    finally:
        conn.close()


#: v4 时代的通知投递：收件人是**设备**（019 要换掉的那一版）。
_FEEDBACK_V4 = """
CREATE TABLE notices (
  noticeId   TEXT PRIMARY KEY,
  subject    TEXT,
  body       TEXT NOT NULL,
  createdAt  INTEGER NOT NULL,
  createdBy  TEXT,
  format     TEXT NOT NULL DEFAULT 'text'
);
CREATE TABLE noticeDeliveries (
  noticeId   TEXT NOT NULL,
  deviceId   TEXT NOT NULL,
  createdAt  INTEGER NOT NULL,
  readAt     INTEGER,
  PRIMARY KEY (noticeId, deviceId)
);
CREATE INDEX noticeDeliveriesByDevice ON noticeDeliveries(deviceId, readAt);
"""

#: v4 的投递行：(noticeId, deviceId, createdAt, readAt)。
#: - `nt_one` 投给同一账号的两台设备，其中一台已读 → 合并成一行、保留那次已读；
#: - `nt_two` 只投给一台设备且未读 → 一行未读；
#: - `nt_three` 投给一台**设备表里已经没有**的设备 → 孤儿，迁移跳过。
_V4_DELIVERIES = (
    ("nt_one", "dev_a", 1_700_000_000_000, None),
    ("nt_one", "dev_b", 1_700_000_001_000, 1_700_000_009_000),
    ("nt_two", "dev_a", 1_700_000_002_000, None),
    ("nt_three", "dev_gone", 1_700_000_003_000, None),
)


def write_v4_database(path: str) -> None:
    """A database at generation 4: notices delivered per device, one row orphaned."""
    conn = sqlite3.connect(path)
    conn.executescript(_DEVICES_V3)
    conn.execute(
        "INSERT INTO devices VALUES ('dev_a', 'hash_a', 'agt_old', 'acc_one', 'iPhone',"
        " 'iPhone17,1', '1.0', 1700000000000, 4102444800000, 1700000001000, NULL,"
        " NULL, NULL, 1, 1, NULL)")
    conn.execute(
        "INSERT INTO devices VALUES ('dev_b', 'hash_b', 'agt_old', 'acc_one', 'iPad',"
        " 'iPad17,1', '1.0', 1700000000000, 4102444800000, 1700000001000, NULL,"
        " NULL, NULL, 1, 1, NULL)")
    conn.executescript(_FEEDBACK_V4)
    for notice_id, subject in (("nt_one", "老通知一"), ("nt_two", "老通知二"), ("nt_three", "孤儿")):
        conn.execute("INSERT INTO notices VALUES (?,?,?,?,?,?)",
                     (notice_id, subject, "正文", 1_700_000_000_000, "admin.py", "text"))
    conn.executemany(
        f"INSERT INTO noticeDeliveries VALUES ({','.join('?' * 4)})", _V4_DELIVERIES)
    conn.execute("PRAGMA user_version = 4")
    conn.commit()
    conn.close()


def test_v4_deliveries_are_backfilled_and_merged_into_the_account(tmp_path):
    """019：v4→v5 把"一台设备一行"合并成"一个账号一行"，已读只前进，孤儿行跳过。

    这是本特性唯一会改到**已经存在的数据**的一步：合并之后无法原地还原，
    所以断言要一条一条对着来（哪一行该在、该是什么状态）。
    """
    path = str(tmp_path / "v4.db")
    write_v4_database(path)
    assert user_version(path) == 4, "前提：这个库是 v4"

    store = Store(path)
    try:
        assert user_version(path) == SCHEMA_VERSION

        rows = [dict(row) for row in store._rows(
            "SELECT noticeId, accountId, readAt FROM noticeDeliveries ORDER BY noticeId")]
        # 四行旧投递 → 两行账号投递（nt_three 的设备已经不在设备表里，跳过）。
        assert [(row["noticeId"], row["accountId"]) for row in rows] == [
            ("nt_one", "acc_one"), ("nt_two", "acc_one")]
        assert rows[0]["readAt"] == 1_700_000_009_000, "两台设备各一行时取最早的那次已读"
        assert rows[1]["readAt"] is None

        # 账号视角：两条通知，一条已读一条未读。
        inbox = store.notices_for_account("acc_one")
        assert [n["noticeId"] for n in inbox] == ["nt_two", "nt_one"]
        assert [n["read"] for n in inbox] == [False, True]
        # 孤儿通知不再出现在任何账号里（它本来就没有归属）。
        assert all(n["noticeId"] != "nt_three" for n in inbox)

        # 迁移后的表立刻可用：标已读、再投一条都走通。
        assert store.mark_notices_read("acc_one", ["nt_two"]) == 1
        assert store.notices_for_account("acc_one")[0]["read"] is True
        fresh = store.create_notice("新正文", "新通知", ["acc_one"], at=1_700_000_010_000)
        assert store.notices_for_account("acc_one")[0]["noticeId"] == fresh["noticeId"]

        # 老索引随老表一起消失了，不会留下指向已删列的索引。
        indexes = {row[1] for row in store._rows("PRAGMA index_list(noticeDeliveries)")
                   if not row[1].startswith("sqlite_autoindex")}
        assert indexes == {"noticeDeliveriesByAccount"}
    finally:
        store.close()


def test_the_notice_migration_is_idempotent(tmp_path):
    """v4→v5 重建表：重复跑必须自己发现"已经是账号口径"，不重建、不再动数据。"""
    path = str(tmp_path / "v4.db")
    write_v4_database(path)
    Store(path).close()
    snapshot = sqlite3.connect(path).execute(
        "SELECT noticeId, accountId, readAt FROM noticeDeliveries ORDER BY noticeId").fetchall()

    for _ in range(3):
        Store(path).close()
    assert user_version(path) == SCHEMA_VERSION
    assert sqlite3.connect(path).execute(
        "SELECT noticeId, accountId, readAt FROM noticeDeliveries ORDER BY noticeId").fetchall() == snapshot

    import store as store_module
    conn = sqlite3.connect(path)
    try:
        store_module._migrate_to_5(conn)  # noqa: SLF001 - 就是这个幂等性要在测
        store_module._migrate_to_5(conn)  # noqa: SLF001
        conn.commit()
    finally:
        conn.close()
    assert sqlite3.connect(path).execute(
        "SELECT noticeId, accountId, readAt FROM noticeDeliveries ORDER BY noticeId").fetchall() == snapshot


def test_the_notice_deliveries_table_of_a_migrated_database_matches_a_fresh_one(tmp_path):
    """迁移过来的 `noticeDeliveries` 与新库逐列一致：不留 `deviceId`、列序相同、索引同名。"""
    migrated = str(tmp_path / "migrated.db")
    write_v4_database(migrated)
    Store(migrated).close()
    fresh = str(tmp_path / "fresh.db")
    Store(fresh).close()

    def shape(path: str) -> list[tuple]:
        conn = sqlite3.connect(path)
        try:
            return [tuple(row) for row in conn.execute("PRAGMA table_info(noticeDeliveries)")]
        finally:
            conn.close()

    assert shape(migrated) == shape(fresh)
    assert "deviceId" not in [column[1] for column in shape(fresh)]


def test_the_format_columns_of_a_migrated_database_match_a_fresh_one(tmp_path):
    """迁移过来的两张表与新库逐列一致（列序也要一致）。

    `ALTER TABLE … ADD COLUMN` 把新列追加在末尾，所以 `format` 在 `SCHEMA` 里也必须写在
    最后；写在中间会让两个部署的行形状分叉（第三条读路径全靠 `SELECT *` 取这一列）。
    """
    migrated = str(tmp_path / "migrated.db")
    write_v3_database(migrated)
    Store(migrated).close()
    fresh = str(tmp_path / "fresh.db")
    Store(fresh).close()

    def shape(path: str, table: str) -> list[tuple]:
        conn = sqlite3.connect(path)
        try:
            return [tuple(row) for row in conn.execute(f"PRAGMA table_info({table})")]
        finally:
            conn.close()

    for table in ("feedbackMessages", "notices"):
        assert shape(migrated, table) == shape(fresh, table), table


def test_the_migrated_feedback_table_matches_a_fresh_one_column_for_column(tmp_path):
    """迁移过来的 feedbackThreads 与新库逐列一致（列序也要一致）。

    `ALTER TABLE … ADD COLUMN` 把新列追加在末尾，所以 `subject` 在 `SCHEMA` 里也必须
    写在最后；写在中间会让两个部署的行形状分叉。
    """
    migrated = str(tmp_path / "migrated.db")
    write_v2_database(migrated)
    Store(migrated).close()

    fresh = str(tmp_path / "fresh.db")
    Store(fresh).close()

    conn = sqlite3.connect(migrated)
    try:
        migrated_columns = [tuple(row) for row in conn.execute("PRAGMA table_info(feedbackThreads)")]
    finally:
        conn.close()
    conn = sqlite3.connect(fresh)
    try:
        fresh_columns = [tuple(row) for row in conn.execute("PRAGMA table_info(feedbackThreads)")]
    finally:
        conn.close()
    assert migrated_columns == fresh_columns


def test_a_migrated_database_matches_a_fresh_one_column_for_column(tmp_path):
    """迁移后的库与新库的形状必须逐列一致（否则两个部署的行为会分叉）。"""
    migrated = str(tmp_path / "migrated.db")
    write_v1_database(migrated)
    Store(migrated).close()

    fresh = str(tmp_path / "fresh.db")
    Store(fresh).close()

    def shape(path: str) -> dict[str, list[tuple]]:
        conn = sqlite3.connect(path)
        try:
            tables = [row[0] for row in conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]
            return {
                table: [tuple(row) for row in conn.execute(f"PRAGMA table_info({table})")]
                for table in tables
            }
        finally:
            conn.close()

    migrated_shape, fresh_shape = shape(migrated), shape(fresh)
    assert set(migrated_shape) == set(fresh_shape)
    for table, columns in fresh_shape.items():
        assert migrated_shape[table] == columns, f"{table} 的列不一致"


def test_push_targets_excludes_revoked_and_unregistered_devices(tmp_path):
    """`push_targets` 的过滤条件全部落在列上（"在不在线"由 hub 判，不在这里）。"""
    path = str(tmp_path / "state.db")
    store = Store(path)
    try:
        account = store.create_account("acc")
        agent = store.register_agent(account["accountId"], "mac")
        code = store.mint_pair_code(agent["agentId"], ttl_ms=60_000)
        one = store.claim_pair_code(code["code"], device_name="iPhone")
        code = store.mint_pair_code(agent["agentId"], ttl_ms=60_000)
        two = store.claim_pair_code(code["code"], device_name="iPad")

        assert store.push_targets(agent["agentId"]) == [], "没登记令牌的设备不该是候选"

        store.set_push(one["deviceId"], "aa" * 32, "sandbox", True, True)
        assert [row["deviceId"] for row in store.push_targets(agent["agentId"])] == [one["deviceId"]]

        store.set_push(two["deviceId"], "bb" * 32, "production", True, True)
        assert len(store.push_targets(agent["agentId"])) == 2

        # 空令牌 = 清除登记（用户在设置里关掉通知权限时 App 就是这么报的）。
        store.set_push(one["deviceId"], "", None, True, True)
        assert [row["deviceId"] for row in store.push_targets(agent["agentId"])] == [two["deviceId"]]

        # 撤销顺手清登记：这台不会回来了。
        store.revoke_device(two["deviceId"])
        assert store.push_targets(agent["agentId"]) == []
        assert store.device_by_id(two["deviceId"])["apnsToken"] is None

        # clear_push 只清令牌，不动别的列。
        store.set_push(one["deviceId"], "cc" * 32, "sandbox", False, True)
        store.clear_push(one["deviceId"])
        row = store.device_by_id(one["deviceId"])
        assert row["apnsToken"] is None and row["apnsEnv"] is None
        assert row["pushAttention"] == 1
    finally:
        store.close()
