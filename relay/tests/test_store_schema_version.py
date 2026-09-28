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
