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

import pytest

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
        assert user_version(path) == SCHEMA_VERSION == 2
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
        store = Store(path)   # 版本已是 2，这一步实际不会再跑迁移
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
