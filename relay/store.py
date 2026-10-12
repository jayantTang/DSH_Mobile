"""SQLite persistence for the DLP relay.

Only *hashes* of secrets are stored: ``agentSecret``/``deviceToken`` are 256-bit
random values, so SHA-256 is enough (and lets us look a row up by hash), while
the short human-typed pairing codes are stretched with scrypt so an offline
brute force of a leaked database stays expensive. Invite codes get the same
treatment as agent secrets — they are long and machine-generated, so a SHA-256
lookup is both sufficient and fast enough for a single indexed read.

These are blocking sqlite3 calls; the HTTP handlers reach them through
:func:`asyncio.to_thread` where the work is non-trivial.
"""

from __future__ import annotations

import hashlib
import logging
import os
import secrets
import sqlite3
import threading
import time
from typing import Any, Iterable

SCHEMA = """
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS accounts (
  accountId  TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  createdAt  INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS agents (
  agentId    TEXT PRIMARY KEY,
  accountId  TEXT NOT NULL,
  name       TEXT NOT NULL,
  secretHash TEXT NOT NULL,
  createdAt  INTEGER NOT NULL,
  updatedAt  INTEGER NOT NULL,
  disabled   INTEGER NOT NULL DEFAULT 0,
  lastSeenAt INTEGER
);
CREATE INDEX IF NOT EXISTS agents_account ON agents(accountId);

CREATE TABLE IF NOT EXISTS devices (
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
  -- 推送登记（R-1）。`apnsToken` 是 App 通过 `POST /devices/push` 上报的 APNs
  -- 设备令牌（hex）；`apnsEnv` 是 `sandbox` / `production`，令牌与环境绑定，送错
  -- 主机 APNs 回 `BadDeviceToken`。两个 `push*` 是用户那两类提醒的开关。
  -- `pushUpdatedAt` 记最后一次上报的时刻，运维看"这台手机还活着吗"用。
  -- 换手机/重装/关权限都会让令牌失效，中转收到 `410`/`BadDeviceToken` 时清掉它。
  apnsToken       TEXT,
  apnsEnv         TEXT,
  pushTurnEnd     INTEGER NOT NULL DEFAULT 1,
  pushAttention   INTEGER NOT NULL DEFAULT 1,
  pushUpdatedAt   INTEGER
);
CREATE INDEX IF NOT EXISTS devices_agent ON devices(agentId);

CREATE TABLE IF NOT EXISTS pairCodes (
  codeHash  TEXT PRIMARY KEY,
  agentId   TEXT NOT NULL,
  accountId TEXT NOT NULL,
  createdAt INTEGER NOT NULL,
  expiresAt INTEGER NOT NULL,
  usedAt    INTEGER,
  deviceId  TEXT
);
CREATE INDEX IF NOT EXISTS pair_codes_agent ON pairCodes(agentId);

-- 按天按设备的出口用量。中转只在内存里记当日额度（断开就丢），"今天谁用了多少"
-- 这类问题以前只能靠猜；这张表就是那笔账：每台设备每天一行，UPSERT 累加。
--
-- `day` 是**服务器本地日**（YYYYMMDD，与操作者口里的"今天"一致）。日额度的判定也走同一个
-- `local_day()`（见 hub.DailyQuota），两边是同一个口径——以前额度按 UTC 日算，跨零点时会
-- 出现"记账说今天用了 0、额度说今天已经用完"。`lastBuild` 记当天最后一次上报的客户端构建号，
-- "谁一直没升级"顺手能答。
CREATE TABLE IF NOT EXISTS usageDaily (
  day         INTEGER NOT NULL,
  deviceId    TEXT NOT NULL,
  agentId     TEXT NOT NULL,
  accountId   TEXT NOT NULL,
  egressBytes INTEGER NOT NULL DEFAULT 0,
  connections INTEGER NOT NULL DEFAULT 0,
  firstSeenAt INTEGER NOT NULL,
  lastSeenAt  INTEGER NOT NULL,
  lastBuild   TEXT,
  PRIMARY KEY (day, deviceId)
);

CREATE INDEX IF NOT EXISTS usageDailyAccount ON usageDaily (day, accountId);

CREATE TABLE IF NOT EXISTS invites (
  codeHash        TEXT PRIMARY KEY,
  createdAt       INTEGER NOT NULL,
  expiresAt       INTEGER NOT NULL,
  usedAt          INTEGER,
  usedByAgentId   TEXT,
  note            TEXT
);

-- 反馈通道（014）。一条用户反馈 = 一个线程，线程里是往返的留言；通知与线程无关，
-- 投给每台设备各一行未读。列名、类型与上限逐字照
-- `specs/014-feedback-channel/data-model.md`。
--
-- 取件凭据（`ticketKey`）只存 SHA-256：原文只在创建响应里出现一次，与
-- `agentSecret`/`deviceToken` 同一套口径。没有外键约束——设备撤销与生命周期
-- 都不该让一条反馈消失（数据模型的明确决定）。
CREATE TABLE IF NOT EXISTS feedbackThreads (
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
  -- 可选的一句话主题（界面重做 2026-10-12）。**必须留在表的最后**：老库是靠
  -- `_migrate_to_3` 的 `ALTER TABLE … ADD COLUMN` 补上它的，SQLite 把新列追加在
  -- 末尾，写在中间会让"新建的库"与"迁移过来的库"列序不一致
  -- （`test_a_migrated_database_matches_a_fresh_one_column_for_column` 会红）。
  subject        TEXT
);
CREATE INDEX IF NOT EXISTS feedbackThreadsByDevice ON feedbackThreads(deviceId);
CREATE INDEX IF NOT EXISTS feedbackThreadsByAccount ON feedbackThreads(accountId);
CREATE INDEX IF NOT EXISTS feedbackThreadsByStatus ON feedbackThreads(status, lastMessageAt);

CREATE TABLE IF NOT EXISTS feedbackMessages (
  messageId  TEXT PRIMARY KEY,
  threadId   TEXT NOT NULL,
  author     TEXT NOT NULL,
  body       TEXT NOT NULL,
  createdAt  INTEGER NOT NULL,
  clientRef  TEXT UNIQUE
);
CREATE INDEX IF NOT EXISTS feedbackMessagesByThread ON feedbackMessages(threadId, createdAt);

CREATE TABLE IF NOT EXISTS notices (
  noticeId   TEXT PRIMARY KEY,
  subject    TEXT,
  body       TEXT NOT NULL,
  createdAt  INTEGER NOT NULL,
  createdBy  TEXT
);

CREATE TABLE IF NOT EXISTS noticeDeliveries (
  noticeId   TEXT NOT NULL,
  deviceId   TEXT NOT NULL,
  createdAt  INTEGER NOT NULL,
  readAt     INTEGER,
  PRIMARY KEY (noticeId, deviceId)
);
CREATE INDEX IF NOT EXISTS noticeDeliveriesByDevice ON noticeDeliveries(deviceId, readAt);
"""

DEFAULT_PAIR_TTL_MS = 10 * 60 * 1000
DEFAULT_DEVICE_TTL_MS = 365 * 24 * 60 * 60 * 1000

#: How far back a *rejected* pairing claim looks for the row it actually hit,
#: and how many rows it is willing to scrypt-verify to find it.
#:
#: The live-code scan is bounded by the TTL on its own; this second scan exists
#: only to answer "already used" or "expired" instead of "not valid", and scrypt
#: per row is deliberately expensive — a rejection path that walked the whole
#: table would be a CPU amplifier. Two hours is far past any TTL a person can
#: still be looking at, and 50 rows is far more than a machine mints in one.
_PAIR_REJECT_LOOKBACK_MS = 2 * 60 * 60 * 1000
_PAIR_REJECT_LIMIT = 50
#: Invites are handed out by a person and redeemed days later, unlike pairing
#: codes which live for minutes.
DEFAULT_INVITE_TTL_MS = 7 * 24 * 60 * 60 * 1000

#: 线程主题（`feedbackThreads.subject`）的字符上限，与
#: `specs/014-feedback-channel/contracts/feedback-http.md` 的 `subject` 一致。
#: 两处各有一份：接口层（`feedback.py`）按契约回 400，这里给 owner 侧命令把关。
MAX_SUBJECT_CHARS = 80

#: The schema generation this code expects, tracked in SQLite's own
#: ``PRAGMA user_version``.
#:
#: Why it exists: ``SCHEMA`` is all ``CREATE TABLE IF NOT EXISTS``, which is
#: exactly right for adding a *table* to a live database — and silently wrong for
#: adding a *column*. A deployment that upgraded the code and kept its
#: ``state.db`` would come up with the new table present and the new column
#: missing, and the first write touching that column would fail at runtime with
#: "no such column" — on a relay that had otherwise reported itself healthy.
#: Bumping this number and adding a step to ``_MIGRATIONS`` is what turns that
#: into a startup migration.
SCHEMA_VERSION = 3


def _migrate_to_1(conn: sqlite3.Connection) -> None:
    """Baseline. Databases older than versioning existed are stamped, not altered.

    Everything up to and including this generation was created by ``SCHEMA``
    alone, so there is nothing to change — the step exists so that the *next*
    column addition has somewhere to go, and so that an existing database is
    recorded as being at version 1 rather than at 0 (which is what SQLite reports
    for a file that predates the pragma).
    """
    return None


def _migrate_to_2(conn: sqlite3.Connection) -> None:
    """推送登记：``devices`` 加五列（R-1 C-07）。

    A fresh database gets these from ``SCHEMA``; this step is only for a live one
    that already has a ``devices`` table without them — ``CREATE TABLE IF NOT
    EXISTS`` would leave it untouched, and the first push write would then fail
    at runtime on a relay that had reported itself healthy.

    Idempotent as the contract requires: a re-run after a partial commit must not
    fail. ``ADD COLUMN`` is not ``IF NOT EXISTS`` in SQLite, so the column list is
    checked first.
    """
    existing = {row[1] for row in conn.execute("PRAGMA table_info(devices)")}
    additions = (
        ("apnsToken", "TEXT"),
        ("apnsEnv", "TEXT"),
        ("pushTurnEnd", "INTEGER NOT NULL DEFAULT 1"),
        ("pushAttention", "INTEGER NOT NULL DEFAULT 1"),
        ("pushUpdatedAt", "INTEGER"),
    )
    for column, declaration in additions:
        if column in existing:
            continue
        # `PRAGMA table_info` 给不出带 NOT NULL DEFAULT 的语句，所以这里拼的是
        # 写死的字面量（不是用户输入），不能参数化。
        conn.execute(f"ALTER TABLE devices ADD COLUMN {column} {declaration}")


def _migrate_to_3(conn: sqlite3.Connection) -> None:
    """界面重做：``feedbackThreads`` 加 ``subject``（可选的一句话主题）。

    这是本项目**第一次给一张已经有数据的表加列**：生产库上的反馈线程已经存在，
    ``CREATE TABLE IF NOT EXISTS`` 不会补列，所以必须走 ``ALTER TABLE``。幂等性照
    ``_migrate_to_2`` 的口径：``ADD COLUMN`` 在 SQLite 里没有 ``IF NOT EXISTS``，
    所以先查列；旧行只是多一个 NULL，不动任何一个已有值。

    ``subject`` 在 ``SCHEMA`` 里也是最后一列——迁移过来的库与新建的库列序必须相同
    （见 ``SCHEMA`` 里那条注释）。
    """
    existing = {row[1] for row in conn.execute("PRAGMA table_info(feedbackThreads)")}
    if "subject" not in existing:
        conn.execute("ALTER TABLE feedbackThreads ADD COLUMN subject TEXT")


#: ``generation → function``, applied in order. Each step must be idempotent:
#: a migration that fails after a partial commit is retried on the next start.
_MIGRATIONS: dict[int, Any] = {
    1: _migrate_to_1,
    2: _migrate_to_2,
    3: _migrate_to_3,
}

_SCRYPT_N = 1 << 14
_SCRYPT_R = 8
_SCRYPT_P = 1

class StoreError(Exception):
    """Base class for store-level failures."""

class NotFound(StoreError):
    """The requested row does not exist (or is disabled/expired)."""

class Conflict(StoreError):
    """The requested write violates a uniqueness invariant."""

class PairCodeRejected(StoreError):
    """A redemption was refused because the caller's failure budget is spent.

    Distinct from :class:`InviteRejected`: nothing was learned about the code —
    the budget answered first, so no failure is charged for this attempt. It
    exists so the rate limit can be enforced *inside* ``claim_*`` next to the row
    read, which closes the window in which concurrent guesses all see a bucket
    that the others have not filled yet.
    """

class InviteRejected(StoreError):
    """An invite code could not be redeemed.

    Carries *why* so the caller can be told the difference between a typo, a
    code someone already used, and one that has simply run out of time.
    """

    def __init__(self, reason: str, message: str):
        super().__init__(message)
        self.reason = reason


class PairCodeClaimRejected(NotFound):
    """A pairing code could not be claimed, and *why*.

    The same argument as :class:`InviteRejected`, for the other code a person
    reads off a screen: one sentence covering a typo, a second scan of a code
    that is already spent, and a code that simply ran out of time cannot be acted
    on — not by the person, and not by whoever ends up reading the log line.

    ``reason`` is ``unknown`` | ``used`` | ``expired``; ``details`` carries the
    timestamps and identity of the row the submitted code matched when one did,
    which is what turns "扫码没反应" into an answerable report.

    Subclasses :class:`NotFound` on purpose: every existing caller that treats a
    lost code as "not found" keeps working unchanged.
    """

    def __init__(self, reason: str, message: str, **details: Any):
        super().__init__(message)
        self.reason = reason
        self.details = details


def clean_feedback_subject(subject: Any) -> str | None:
    """线程主题：去首尾空白，空（或全空白）按"没填"存 NULL，超长抛 :class:`StoreError`。

    接口层（`feedback.py`）先按契约给 400；这里是落到库前的最后一道，owner 侧的
    `feedback-reply --subject` 只有这一道。非字符串按类型错误拒绝，而不是静默丢掉
    调用方写的东西。
    """
    if subject is None:
        return None
    if not isinstance(subject, str):
        raise StoreError("subject must be a string")
    trimmed = subject.strip()
    if len(trimmed) > MAX_SUBJECT_CHARS:
        raise StoreError(f"subject may be at most {MAX_SUBJECT_CHARS} characters")
    return trimmed or None


def local_day(stamp: float | None = None) -> int:
    """服务器本地日的序号，形如 20260921。

    记账与日额度判定都用本地日（操作者问的"今天"是本地时间）：额度那套见
    ``hub.DailyQuota``，它读的也是这个函数，两边不要各算一套。
    """
    return int(time.strftime("%Y%m%d", time.localtime(time.time() if stamp is None else stamp)))


def day_floor(days: int, stamp: float | None = None) -> int:
    """`days` 天前那一天的序号（含今天，所以 days=1 就是今天）。"""
    import datetime as _dt
    today = _dt.date.fromtimestamp(time.time() if stamp is None else stamp)
    return int((today - _dt.timedelta(days=max(1, days) - 1)).strftime("%Y%m%d"))


def now_ms() -> int:
    return int(time.time() * 1000)

def sha256_hex(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()

def new_id(prefix: str, nbytes: int = 9) -> str:
    return f"{prefix}_{secrets.token_hex(nbytes)}"

def new_token(prefix: str, nbytes: int = 32) -> str:
    return f"{prefix}_{secrets.token_urlsafe(nbytes)}"

def normalize_pair_code(code: str) -> str:
    """Pair codes are case-insensitive and ignore separators when claimed."""
    return "".join(ch for ch in code.strip().upper() if ch.isalnum())

#: Invite alphabet: no 0/O/1/I/L, because the code is read off one screen and
#: typed on another (or pasted into an installer and retyped from a chat).
INVITE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
INVITE_GROUPS = 4
INVITE_GROUP_LEN = 4

def new_invite_code(groups: int = INVITE_GROUPS) -> str:
    """A fresh `XXXX-XXXX-XXXX-XXXX` invite code."""
    total = groups * INVITE_GROUP_LEN
    raw = "".join(secrets.choice(INVITE_ALPHABET) for _ in range(total))
    return "-".join(raw[index:index + INVITE_GROUP_LEN]
                    for index in range(0, total, INVITE_GROUP_LEN))

def normalize_invite_code(code: str) -> str:
    return normalize_pair_code(code)

def hash_invite_code(code: str) -> str:
    """SHA-256, not scrypt.

    The code is long and machine-generated, so there is nothing to brute force,
    and a single indexed lookup beats scanning every unused invite through a
    deliberately expensive KDF.
    """
    return sha256_hex(normalize_invite_code(code))

def hash_pair_code(code: str, *, salt: bytes | None = None) -> str:
    normalized = normalize_pair_code(code)
    salt = salt or os.urandom(16)
    digest = hashlib.scrypt(
        normalized.encode("utf-8"), salt=salt, n=_SCRYPT_N, r=_SCRYPT_R, p=_SCRYPT_P, dklen=32
    )
    return f"scrypt${salt.hex()}${digest.hex()}"

def _verify_pair_code(code: str, stored: str) -> bool:
    try:
        scheme, salt_hex, digest_hex = stored.split("$")
        if scheme != "scrypt":
            return False
        candidate = hashlib.scrypt(
            normalize_pair_code(code).encode("utf-8"),
            salt=bytes.fromhex(salt_hex),
            n=_SCRYPT_N,
            r=_SCRYPT_R,
            p=_SCRYPT_P,
            dklen=32,
        )
        return secrets.compare_digest(candidate.hex(), digest_hex)
    except (ValueError, AttributeError):
        return False

class Store:
    """A small synchronous SQLite store with an async-friendly surface."""

    def __init__(self, path: str):
        self.path = path
        directory = os.path.dirname(os.path.abspath(path))
        if directory:
            os.makedirs(directory, exist_ok=True)
        self._lock = threading.RLock()
        self._conn = sqlite3.connect(path, check_same_thread=False, timeout=15)
        self._conn.row_factory = sqlite3.Row
        with self._lock:
            # Order matters. `SCHEMA` first so a brand-new file is complete and so
            # an existing one gains any *new table*; then the versioned migrations
            # for the changes `IF NOT EXISTS` cannot express (new columns,
            # backfills). A database that predates versioning reports 0 and is
            # brought up through every step.
            self._conn.executescript(SCHEMA)
            applied = self._migrate()
            self._conn.commit()
        if applied:
            logging.getLogger("relay.store").info(
                "relay: migrated the database schema to version %d", applied)

    def _migrate(self) -> int:
        """Bring the database up to :data:`SCHEMA_VERSION`; returns the new version.

        Runs under the caller's lock, inside the constructor's transaction. Each
        step runs once and the version is stamped in the same commit, so a
        half-applied migration is not recorded as done. A version *newer* than
        this code understands is left alone: a rollback to an older build must not
        silently "downgrade" a database by skipping steps it never had.
        """
        current = int(self._conn.execute("PRAGMA user_version").fetchone()[0])
        if current >= SCHEMA_VERSION:
            return current
        for version in sorted(step for step in _MIGRATIONS if step > current):
            if version > SCHEMA_VERSION:
                break
            _MIGRATIONS[version](self._conn)
            # `PRAGMA user_version` does not take a bound parameter.
            self._conn.execute(f"PRAGMA user_version = {int(version)}")
        return SCHEMA_VERSION

    def close(self) -> None:
        with self._lock:
            self._conn.close()

    # ── internal helpers ────────────────────────────────────────────────────

    def _execute(self, sql: str, params: Iterable[Any] = ()) -> sqlite3.Cursor:
        with self._lock:
            cursor = self._conn.execute(sql, tuple(params))
            return cursor

    def _write(self, sql: str, params: Iterable[Any] = ()) -> None:
        with self._lock:
            self._conn.execute(sql, tuple(params))
            self._conn.commit()

    def _row(self, sql: str, params: Iterable[Any] = ()) -> sqlite3.Row | None:
        with self._lock:
            return self._conn.execute(sql, tuple(params)).fetchone()

    def _rows(self, sql: str, params: Iterable[Any] = ()) -> list[sqlite3.Row]:
        with self._lock:
            return list(self._conn.execute(sql, tuple(params)).fetchall())

    # ── accounts ────────────────────────────────────────────────────────────

    def create_account(self, name: str) -> dict[str, Any]:
        account_id = new_id("acc")
        created = now_ms()
        self._write(
            "INSERT INTO accounts(accountId, name, createdAt) VALUES(?,?,?)",
            (account_id, name, created),
        )
        return {"accountId": account_id, "name": name, "createdAt": created}

    def get_account(self, account_id: str) -> dict[str, Any] | None:
        row = self._row("SELECT * FROM accounts WHERE accountId=?", (account_id,))
        return dict(row) if row else None

    def list_accounts(self) -> list[dict[str, Any]]:
        return [dict(row) for row in self._rows("SELECT * FROM accounts ORDER BY createdAt")]

    # ── agents ──────────────────────────────────────────────────────────────

    def register_agent(self, account_id: str, name: str, agent_id: str | None = None) -> dict[str, Any]:
        """Create an agent (or rotate the secret of an existing one)."""
        if self.get_account(account_id) is None:
            raise NotFound(f"account {account_id} does not exist")
        secret = new_token("as")
        stamp = now_ms()
        if agent_id is None:
            agent_id = new_id("agt")
            self._write(
                "INSERT INTO agents(agentId, accountId, name, secretHash, createdAt, updatedAt)"
                " VALUES(?,?,?,?,?,?)",
                (agent_id, account_id, name, sha256_hex(secret), stamp, stamp),
            )
        else:
            row = self._row("SELECT * FROM agents WHERE agentId=?", (agent_id,))
            if row is None:
                raise NotFound(f"agent {agent_id} does not exist")
            self._write(
                "UPDATE agents SET name=?, secretHash=?, updatedAt=?, disabled=0 WHERE agentId=?",
                (name, sha256_hex(secret), stamp, agent_id),
            )
        return {"agentId": agent_id, "agentSecret": secret, "accountId": account_id, "name": name}

    def set_agent_disabled(self, agent_id: str, disabled: bool) -> None:
        if self._row("SELECT agentId FROM agents WHERE agentId=?", (agent_id,)) is None:
            raise NotFound(f"agent {agent_id} does not exist")
        self._write("UPDATE agents SET disabled=?, updatedAt=? WHERE agentId=?",
                    (1 if disabled else 0, now_ms(), agent_id))

    def agent_by_id(self, agent_id: str) -> dict[str, Any] | None:
        row = self._row("SELECT * FROM agents WHERE agentId=?", (agent_id,))
        return dict(row) if row else None

    def agent_by_secret(self, secret: str) -> dict[str, Any] | None:
        if not secret:
            return None
        row = self._row("SELECT * FROM agents WHERE secretHash=?", (sha256_hex(secret),))
        if row is None or row["disabled"]:
            return None
        return dict(row)

    def list_agents(self, account_id: str | None = None) -> list[dict[str, Any]]:
        if account_id:
            rows = self._rows("SELECT * FROM agents WHERE accountId=? ORDER BY createdAt", (account_id,))
        else:
            rows = self._rows("SELECT * FROM agents ORDER BY createdAt")
        return [dict(row) for row in rows]

    def touch_agent(self, agent_id: str, at: int | None = None) -> None:
        self._write("UPDATE agents SET lastSeenAt=? WHERE agentId=?", (at or now_ms(), agent_id))

    # ── pairing ─────────────────────────────────────────────────────────────

    def mint_pair_code(self, agent_id: str, ttl_ms: int = DEFAULT_PAIR_TTL_MS) -> dict[str, Any]:
        agent = self.agent_by_id(agent_id)
        if agent is None:
            raise NotFound(f"agent {agent_id} does not exist")
        if agent["disabled"]:
            raise Conflict(f"agent {agent_id} is disabled")
        # 8 chars from an unambiguous alphabet, rendered as XXXX-XXXX.
        alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        raw = "".join(secrets.choice(alphabet) for _ in range(8))
        code = f"{raw[:4]}-{raw[4:]}"
        created = now_ms()
        expires = created + int(ttl_ms)
        self._write(
            "INSERT INTO pairCodes(codeHash, agentId, accountId, createdAt, expiresAt) VALUES(?,?,?,?,?)",
            (hash_pair_code(code), agent_id, agent["accountId"], created, expires),
        )
        return {"code": code, "expiresAt": expires, "agentId": agent_id, "ttlMs": int(ttl_ms)}

    def claim_pair_code(self, code: str, *, device_name: str, model: str | None = None,
                        app_version: str | None = None,
                        ttl_ms: int = DEFAULT_DEVICE_TTL_MS) -> dict[str, Any]:
        """Consume a pairing code and mint a long-lived device token.

        The lookup has to scan live unused codes because each row carries its
        own scrypt salt; the candidate set is tiny (codes expire in minutes).

        A miss is not simply "not found": see :meth:`_pair_code_rejection`, which
        re-checks the bounded recent history so the caller can say whether the
        code was already spent or had run out.
        """
        normalized = normalize_pair_code(code)
        if not normalized:
            raise NotFound("empty pairing code")
        stamp = now_ms()
        with self._lock:
            rows = self._conn.execute(
                "SELECT * FROM pairCodes WHERE usedAt IS NULL AND expiresAt > ? ORDER BY createdAt DESC LIMIT 200",
                (stamp,),
            ).fetchall()
            match = next((row for row in rows if _verify_pair_code(normalized, row["codeHash"])), None)
            if match is None:
                raise self._pair_code_rejection(normalized, stamp)
            agent = self._conn.execute(
                "SELECT * FROM agents WHERE agentId=?", (match["agentId"],)
            ).fetchone()
            if agent is None or agent["disabled"]:
                raise NotFound("the agent for this pairing code is unavailable")
            device_id = new_id("dev")
            token = new_token("dt")
            expires = stamp + int(ttl_ms)
            self._conn.execute(
                "INSERT INTO devices(deviceId, deviceTokenHash, agentId, accountId, name, model,"
                " appVersion, createdAt, expiresAt) VALUES(?,?,?,?,?,?,?,?,?)",
                (device_id, sha256_hex(token), agent["agentId"], agent["accountId"],
                 device_name or "iOS device", model, app_version, stamp, expires),
            )
            self._conn.execute("UPDATE pairCodes SET usedAt=?, deviceId=? WHERE codeHash=?",
                               (stamp, device_id, match["codeHash"]))
            self._conn.commit()
        return {
            "ok": True,
            "agentId": agent["agentId"],
            "agentName": agent["name"],
            "accountId": agent["accountId"],
            "deviceId": device_id,
            "deviceToken": token,
            "expiresAt": expires,
        }

    def _pair_code_rejection(self, normalized: str, stamp: int) -> PairCodeClaimRejected:
        """Why a claim missed every live code: spent, expired, or never issued.

        Called only from the failure path of :meth:`claim_pair_code`, with the
        lock held. The candidate query deliberately excludes rows that are still
        live — those were already scanned and did not match, so a hit here can
        only mean used or expired, and the answer can never contradict the
        decision that produced it. Bounded by both time and row count; see
        ``_PAIR_REJECT_LOOKBACK_MS``.
        """
        rows = self._conn.execute(
            "SELECT * FROM pairCodes WHERE createdAt > ? AND (usedAt IS NOT NULL OR expiresAt <= ?)"
            " ORDER BY createdAt DESC LIMIT ?",
            (stamp - _PAIR_REJECT_LOOKBACK_MS, stamp, _PAIR_REJECT_LIMIT),
        ).fetchall()
        hit = next((row for row in rows if _verify_pair_code(normalized, row["codeHash"])), None)
        if hit is None:
            return PairCodeClaimRejected("unknown", "that pairing code is not valid")
        if hit["usedAt"] is not None:
            return PairCodeClaimRejected(
                "used", "that pairing code has already been used",
                agentId=hit["agentId"], createdAt=int(hit["createdAt"]),
                usedAt=int(hit["usedAt"]), deviceId=hit["deviceId"])
        return PairCodeClaimRejected(
            "expired", "that pairing code has expired",
            agentId=hit["agentId"], createdAt=int(hit["createdAt"]),
            expiresAt=int(hit["expiresAt"]))

    def purge_expired(self, at: int | None = None) -> int:
        stamp = at or now_ms()
        with self._lock:
            cursor = self._conn.execute("DELETE FROM pairCodes WHERE expiresAt < ?", (stamp,))
            self._conn.commit()
            return cursor.rowcount or 0

    # ── invites ─────────────────────────────────────────────────────────────

    def mint_invite(self, ttl_ms: int = DEFAULT_INVITE_TTL_MS, note: str | None = None,
                    code: str | None = None) -> dict[str, Any]:
        """Mint a one-time invite code.

        The plaintext code is returned exactly once — only its hash is stored,
        so nobody (including the operator, later) can read it back out of the
        database. ``code`` exists so tests can pin a known value.
        """
        plaintext = code or new_invite_code()
        created = now_ms()
        expires = created + int(ttl_ms)
        self._write(
            "INSERT INTO invites(codeHash, createdAt, expiresAt, note) VALUES(?,?,?,?)",
            (hash_invite_code(plaintext), created, expires, note),
        )
        return {"code": plaintext, "expiresAt": expires, "ttlMs": int(ttl_ms), "note": note}

    def invite_status(self, code: str) -> dict[str, Any]:
        """Inspect an invite without consuming it.

        Used for error reporting: a caller who typed a used code should be told
        that, not told the code does not exist.
        """
        row = self._row("SELECT * FROM invites WHERE codeHash=?", (hash_invite_code(code),))
        if row is None:
            return {"exists": False}
        if row["usedAt"] is not None:
            return {"exists": True, "state": "used", "usedAt": row["usedAt"],
                    "usedByAgentId": row["usedByAgentId"]}
        if int(row["expiresAt"]) <= now_ms():
            return {"exists": True, "state": "expired", "expiresAt": row["expiresAt"]}
        return {"exists": True, "state": "unused", "expiresAt": row["expiresAt"]}

    def claim_invite(self, code: str, name: str, limiter: Any | None = None, *,
                     count_key: str | None = None,
                     client_key: str | None = None) -> dict[str, Any]:
        """Redeem one invite: create the account and its first agent.

        One transaction, so an invite can never be marked used without the
        identity existing, and a race between two machines redeeming the same
        code leaves exactly one winner.

        ``limiter`` is the rate limiter the caller is charging failures to, and
        it is passed in so those charges happen **inside** this lock, next to the
        row read. The HTTP handler can only consult a bucket before calling here
        (the row is not known until we look), so a burst of concurrent guesses
        against one code would otherwise all pass that check before any of them
        recorded a failure — a window exactly as wide as the number of requests
        the client can have in flight. ``PairCodeRejected`` is raised for such an
        already-frozen bucket, so the row is never touched and the failure is not
        charged twice. Leaving ``limiter`` unset keeps this a plain redemption,
        which is what the admin path and the store-level tests use.
        """
        normalized = normalize_invite_code(code)
        stamp = now_ms()
        with self._lock:
            # Consult the budget before anything else, so a burst of concurrent
            # guesses cannot all read a bucket that the others have not filled
            # yet. The consult does not charge anything — see below.
            if limiter is not None and count_key is not None:
                if limiter.blocked(count_key):
                    raise PairCodeRejected("rate-limited",
                                           "too many failed attempts for that invite code")

            row = None
            if normalized:
                row = self._conn.execute(
                    "SELECT * FROM invites WHERE codeHash=?", (hash_invite_code(normalized),)
                ).fetchone()
            reason: str | None = None
            if row is None:
                reason = "unknown"
            elif row["usedAt"] is not None:
                reason = "used"
            elif int(row["expiresAt"]) <= stamp:
                reason = "expired"

            # Charge the failure only once we know this attempt failed, and do it
            # here — still inside the lock, next to the read that decided it — so
            # the charge cannot drift from the decision. Charging before the
            # lookup would bill a *successful* redemption as a failure, and the
            # operator's tally would report guesses nobody made.
            if reason is not None:
                if limiter is not None and count_key is not None:
                    # One request is one failure: the code bucket counts it
                    # towards the operator's tally, the client bucket only
                    # records it.
                    limiter.count_failure(count_key)
                    if client_key is not None:
                        limiter.count_failure(client_key, total=False)
                raise InviteRejected(reason, {
                    "unknown": "that invite code is not valid",
                    "used": "that invite code has already been used",
                    "expired": "that invite code has expired",
                }[reason])

            account_id = new_id("acc")
            agent_id = new_id("agt")
            secret = new_token("as")
            agent_name = (name or "").strip() or "My computer"
            self._conn.execute(
                "INSERT INTO accounts(accountId, name, createdAt) VALUES(?,?,?)",
                (account_id, agent_name, stamp),
            )
            self._conn.execute(
                "INSERT INTO agents(agentId, accountId, name, secretHash, createdAt, updatedAt)"
                " VALUES(?,?,?,?,?,?)",
                (agent_id, account_id, agent_name, sha256_hex(secret), stamp, stamp),
            )
            self._conn.execute(
                "UPDATE invites SET usedAt=?, usedByAgentId=? WHERE codeHash=?",
                (stamp, agent_id, row["codeHash"]),
            )
            self._conn.commit()
        return {
            "ok": True,
            "accountId": account_id,
            "agentId": agent_id,
            "agentName": agent_name,
            "agentSecret": secret,
            "inviteNote": row["note"],
        }

    def list_invites(self, *, include_used: bool = False) -> list[dict[str, Any]]:
        """Invites as the operator sees them — hashes only, never the code."""
        where = "" if include_used else " WHERE usedAt IS NULL"
        rows = self._rows(f"SELECT * FROM invites{where} ORDER BY createdAt")
        return [dict(row) for row in rows]

    def revoke_invite(self, code: str, at: int | None = None) -> dict[str, Any]:
        """Retire an invite that should no longer be redeemable.

        Needed because an invite can leak — a code pasted into review notes, a
        screenshot, a chat — and the only other ways to neutralise it were to
        wait out its TTL or to hand-edit the database. The code is hashed for
        lookup like everywhere else, and only the hash is ever reported back.

        Revoking sets the expiry to now rather than deleting the row: the
        failure an invitee sees stays "expired", and the note stays visible in
        `invite-list --all` as the record of what happened.
        """
        stamp = at or now_ms()
        normalized = normalize_invite_code(code)
        if not normalized:
            return {"revoked": False, "reason": "malformed"}
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM invites WHERE codeHash=?", (hash_invite_code(normalized),)
            ).fetchone()
            if row is None:
                return {"revoked": False, "reason": "unknown"}
            if row["usedAt"] is not None:
                return {"revoked": False, "reason": "used", "usedAt": row["usedAt"],
                        "usedByAgentId": row["usedByAgentId"]}
            if int(row["expiresAt"]) <= stamp:
                return {"revoked": False, "reason": "already-expired",
                        "expiresAt": row["expiresAt"]}
            self._conn.execute(
                "UPDATE invites SET expiresAt=? WHERE codeHash=?",
                (stamp, hash_invite_code(normalized)),
            )
            self._conn.commit()
        return {"revoked": True, "codeHash": hash_invite_code(normalized)[:12],
                "note": row["note"], "expiresAt": stamp}

    def purge_invites(self, at: int | None = None) -> int:
        stamp = at or now_ms()
        with self._lock:
            cursor = self._conn.execute(
                "DELETE FROM invites WHERE expiresAt < ? OR usedAt IS NOT NULL", (stamp,)
            )
            self._conn.commit()
            return cursor.rowcount or 0

    # ── devices ─────────────────────────────────────────────────────────────

    def device_by_token(self, token: str) -> dict[str, Any] | None:
        if not token:
            return None
        row = self._row("SELECT * FROM devices WHERE deviceTokenHash=?", (sha256_hex(token),))
        if row is None:
            return None
        if row["revokedAt"] is not None:
            return None
        if int(row["expiresAt"]) <= now_ms():
            return None
        return dict(row)

    def device_by_id(self, device_id: str) -> dict[str, Any] | None:
        row = self._row("SELECT * FROM devices WHERE deviceId=?", (device_id,))
        return dict(row) if row else None

    def revoked_ids_among(self, device_ids: Iterable[str]) -> set[str]:
        """Of these device ids, which ones are revoked in the database?

        The reconcile loop asks this about the devices it currently has *live*:
        a row that is revoked but whose socket is still open is exactly the state
        the relay must never sit in. Read-only, chunked because SQLite's bound-
        variable ceiling is historically 999.
        """
        ids = [d for d in dict.fromkeys(device_ids) if d]
        if not ids:
            return set()
        found: set[str] = set()
        for start in range(0, len(ids), 500):
            chunk = ids[start:start + 500]
            marks = ",".join("?" * len(chunk))
            rows = self._rows(
                f"SELECT deviceId FROM devices WHERE revokedAt IS NOT NULL "
                f"AND deviceId IN ({marks})", chunk)
            found.update(row["deviceId"] for row in rows)
        return found

    def gone_ids_among(self, device_ids: Iterable[str]) -> set[str]:
        """Of these device ids, which ones can never authenticate again?

        Two ways a device row becomes permanently unusable: it was revoked, or
        its pairing is older than the device TTL (``expiresAt`` has passed —
        ``touch_device`` refreshes ``lastSeenAt`` but never the TTL, so a phone
        that has been paired for a year expires even if it is currently
        connected). ``device_by_token`` refuses both, so the phone can never
        reconnect and anything left waiting for it is waste.

        The reconcile loop uses this **only** for devices that are not currently
        online; see :meth:`RelayHub.reconcile_revoked_devices` for why a live
        socket is never cut for expiry alone.
        """
        ids = [d for d in dict.fromkeys(device_ids) if d]
        if not ids:
            return set()
        found: set[str] = set()
        stamp = now_ms()
        for start in range(0, len(ids), 500):
            chunk = ids[start:start + 500]
            marks = ",".join("?" * len(chunk))
            rows = self._rows(
                f"SELECT deviceId FROM devices WHERE "
                f"(revokedAt IS NOT NULL OR expiresAt <= ?) "
                f"AND deviceId IN ({marks})", [stamp, *chunk])
            found.update(row["deviceId"] for row in rows)
        return found

    def expired_ids_of_agent(self, agent_id: str) -> set[str]:
        """The agent's devices whose pairing has passed the TTL.

        Used by :meth:`RelayHub.attach_agent` to tell a reconnecting connector
        which of its leftovers are dead for good. Revoked devices are handled
        separately (and are what ``list_devices(include_revoked=True)`` covers),
        so this answers only the expiry half.
        """
        rows = self._rows(
            "SELECT deviceId FROM devices WHERE agentId=? AND expiresAt <= ?",
            (agent_id, now_ms()))
        return {row["deviceId"] for row in rows}

    def list_devices(self, agent_id: str | None = None, *, include_revoked: bool = False) -> list[dict[str, Any]]:
        clauses: list[str] = []
        params: list[Any] = []
        if agent_id:
            clauses.append("agentId=?")
            params.append(agent_id)
        if not include_revoked:
            clauses.append("revokedAt IS NULL")
        where = f" WHERE {' AND '.join(clauses)}" if clauses else ""
        rows = self._rows(f"SELECT * FROM devices{where} ORDER BY createdAt", params)
        return [dict(row) for row in rows]

    def refresh_device(self, token: str, ttl_ms: int = DEFAULT_DEVICE_TTL_MS) -> dict[str, Any]:
        device = self.device_by_token(token)
        if device is None:
            raise NotFound("device token is invalid, revoked, or expired")
        new = new_token("dt")
        expires = now_ms() + int(ttl_ms)
        self._write("UPDATE devices SET deviceTokenHash=?, expiresAt=? WHERE deviceId=?",
                    (sha256_hex(new), expires, device["deviceId"]))
        return {
            "ok": True,
            "deviceId": device["deviceId"],
            "agentId": device["agentId"],
            "accountId": device["accountId"],
            "deviceToken": new,
            "expiresAt": expires,
        }

    def revoke_device(self, device_id: str) -> None:
        if self._row("SELECT deviceId FROM devices WHERE deviceId=?", (device_id,)) is None:
            raise NotFound(f"device {device_id} does not exist")
        # 撤销顺手清掉推送登记：这台设备不会再回来，留着令牌只会让中转继续往一台
        # 已经解绑的手机推（那是这台手机的用户明确表示"别再找我了"）。
        self._write(
            "UPDATE devices SET revokedAt=?, apnsToken=NULL, apnsEnv=NULL, pushUpdatedAt=? "
            "WHERE deviceId=?",
            (now_ms(), now_ms(), device_id))

    # ── push registration (R-1) ─────────────────────────────────────────────

    def set_push(self, device_id: str, token: str | None, env: str | None,
                 turn_end: bool, attention: bool) -> None:
        """Record (or clear) one device's APNs registration.

        ``token`` empty means *clear*: the app reports an empty token when the
        user turns notifications off, and that has to be as easy as registering.
        The two switches are stored separately from the token so "notify me about
        finished runs but not questions" is expressible.
        """
        if self._row("SELECT deviceId FROM devices WHERE deviceId=?", (device_id,)) is None:
            raise NotFound(f"device {device_id} does not exist")
        value = (token or "").strip() or None
        self._write(
            "UPDATE devices SET apnsToken=?, apnsEnv=?, pushTurnEnd=?, pushAttention=?, "
            "pushUpdatedAt=? WHERE deviceId=?",
            (value, env if value else None, 1 if turn_end else 0, 1 if attention else 0,
             now_ms(), device_id))

    def clear_push(self, device_id: str) -> None:
        """Forget a device's APNs token without touching anything else.

        Used when Apple says the token is dead (``410 Unregistered`` /
        ``BadDeviceToken``): the phone is gone or reinstalled, so retrying is
        pointless until it registers again.
        """
        self._write(
            "UPDATE devices SET apnsToken=NULL, apnsEnv=NULL, pushUpdatedAt=? WHERE deviceId=?",
            (now_ms(), device_id))

    def push_targets(self, agent_id: str) -> list[dict[str, Any]]:
        """The devices of one agent that are candidates for a push.

        Filtered here rather than in the caller because every condition is a
        column: registered token, known environment, not revoked, not expired.
        Whether the device is *online right now* is deliberately not part of this
        — only the relay's hub knows that.
        """
        rows = self._rows(
            "SELECT * FROM devices WHERE agentId=? AND apnsToken IS NOT NULL "
            "AND apnsEnv IS NOT NULL AND revokedAt IS NULL AND expiresAt > ? "
            "ORDER BY createdAt",
            (agent_id, now_ms()))
        return [dict(row) for row in rows]

    def set_device_app_version(self, device_id: str, version: str) -> None:
        """Record the build a device just reported.

        The row is written when the phone pairs and, until this existed, never
        again — so an operator asking "is that phone current?" was reading a
        version that could be days old. The device reports it on every
        handshake; this is where that lands.
        """
        self._write("UPDATE devices SET appVersion=? WHERE deviceId=?", (version, device_id))

    # ── enrollment (who took an invite) ─────────────────────────────────────

    def list_enrollments(self) -> list[dict[str, Any]]:
        """每一次成功的登记：邀请码被兑换 → 建账号 → 建电脑。

        `invite-list` 只给得出码的哈希与状态；"谁来了"要把 invites 与 agents/accounts
        连起来看，所以单独一条。给 `admin.py enrollments` 用（只读）。
        """
        return [dict(row) for row in self._rows(
            """
            SELECT i.usedAt        AS usedAt,
                   i.note          AS inviteNote,
                   a.accountId     AS accountId,
                   acc.name        AS accountName,
                   a.agentId       AS agentId,
                   a.name          AS agentName,
                   (SELECT COUNT(*) FROM devices d WHERE d.agentId = a.agentId) AS devices,
                   (SELECT MAX(d.lastSeenAt) FROM devices d WHERE d.agentId = a.agentId)
                     AS lastSeenAt
            FROM invites i
            JOIN agents a ON a.agentId = i.usedByAgentId
            LEFT JOIN accounts acc ON acc.accountId = a.accountId
            WHERE i.usedAt IS NOT NULL
            ORDER BY i.usedAt DESC
            """)]

    def invite_totals(self) -> dict[str, int]:
        """码的账：铸了多少、用掉多少、还剩多少。"""
        row = self._row(
            """
            SELECT COUNT(*) AS minted,
                   SUM(CASE WHEN usedAt IS NOT NULL THEN 1 ELSE 0 END) AS used,
                   SUM(CASE WHEN usedAt IS NULL THEN 1 ELSE 0 END) AS remaining
            FROM invites
            """)
        return {key: int(row[key] or 0) for key in ("minted", "used", "remaining")}

    # ── daily usage ─────────────────────────────────────────────────────────

    def add_usage(self, entries: Iterable[dict[str, Any]]) -> int:
        """把一批按天按设备的出口字节累加进 `usageDaily`（UPSERT，一次事务）。

        调用方是 hub 的冲盘任务：它把内存里攒的增量交过来，这里只负责"加上去"。
        累加而不是覆盖，是因为冲盘是周期性的——一行一天会被写很多次。
        """
        rows = list(entries)
        if not rows:
            return 0
        with self._lock:
            self._conn.executemany(
                """
                INSERT INTO usageDaily(day, deviceId, agentId, accountId, egressBytes,
                                       connections, firstSeenAt, lastSeenAt, lastBuild)
                VALUES(:day, :deviceId, :agentId, :accountId, :egressBytes,
                       :connections, :at, :at, :lastBuild)
                ON CONFLICT(day, deviceId) DO UPDATE SET
                  egressBytes = egressBytes + excluded.egressBytes,
                  connections = connections + excluded.connections,
                  firstSeenAt = MIN(firstSeenAt, excluded.firstSeenAt),
                  lastSeenAt  = MAX(lastSeenAt, excluded.lastSeenAt),
                  lastBuild   = COALESCE(excluded.lastBuild, lastBuild),
                  agentId     = excluded.agentId,
                  accountId   = excluded.accountId
                """,
                rows,
            )
            self._conn.commit()
        return len(rows)

    def usage_rows(self, day: int) -> list[dict[str, Any]]:
        """一天里每台设备一行（按出口字节降序）。"""
        return [dict(row) for row in self._rows(
            "SELECT * FROM usageDaily WHERE day=? ORDER BY egressBytes DESC", (day,))]

    def usage_totals(self, *, days: int = 7, by: str = "account") -> list[dict[str, Any]]:
        """最近 `days` 天按账号或按设备汇总，最近的排在前面。

        汇总放 SQL 里做，是因为调用它的是一次性的运维命令——
        行数再多也不用把它全读进 Python。
        """
        key = "accountId" if by == "account" else "deviceId"
        name = ("(SELECT name FROM accounts WHERE accounts.accountId = u.accountId)"
                if by == "account" else
                "(SELECT name FROM devices WHERE devices.deviceId = u.deviceId)")
        return [dict(row) for row in self._rows(
            f"""
            SELECT u.day AS day, u.{key} AS {key},
                   {name} AS name,
                   SUM(u.egressBytes) AS egressBytes,
                   SUM(u.connections) AS connections,
                   MAX(u.lastSeenAt)  AS lastSeenAt,
                   MAX(u.lastBuild)   AS lastBuild,
                   COUNT(DISTINCT u.deviceId) AS devices
            FROM usageDaily u
            WHERE u.day >= ?
            GROUP BY u.day, u.{key}
            ORDER BY u.day DESC, egressBytes DESC
            """,
            (day_floor(days),))]

    def touch_device(self, device_id: str, at: int | None = None) -> None:
        self._write("UPDATE devices SET lastSeenAt=? WHERE deviceId=?", (at or now_ms(), device_id))

    # ── feedback channel (014) ──────────────────────────────────────────────
    #
    # 四个 HTTP 接口（`relay/feedback.py`）与 owner 侧命令（`admin.py`）共用的读写。
    # 凭据在调用方就已经哈希好（与 `agentSecret`/`deviceToken` 同一套口径），这里
    # 只做比对。线程永远不因设备撤销而消失——所以没有外键。

    def create_feedback_thread(self, *, ticket_hash: str, text: str,
                               account_id: str | None = None, device_id: str | None = None,
                               app_version: str | None = None, device_model: str | None = None,
                               system_version: str | None = None, client_ref: str | None = None,
                               subject: str | None = None,
                               at: int | None = None) -> dict[str, Any]:
        """建一条线程，并把用户原文作为线程里的第一条留言。

        `subject` 可选（≤80 字符）：去首尾空白，空白按未填存 NULL——展示层用正文首句
        兜底，服务端不替用户补一句话（`data-model.md` 的 `subject`）。

        `clientRef` 命中唯一索引时**不新建**：返回既有那条（`created` 为 False），
        并把 `ticketHash` 换成这一次带来的哈希——重试发生在"上一条响应丢了"之后，
        所以重试必须拿到一把能用的凭据。同一个 `clientRef` 来自别的来源时抛
        :class:`Conflict`，不把线程交出去。
        """
        stamp = at or now_ms()
        with self._lock:
            if client_ref:
                existing = self._feedback_row_by("clientRef", client_ref)
                if existing is not None:
                    if not self._feedback_source_matches(existing, device_id, account_id):
                        raise Conflict(f"clientRef {client_ref} belongs to another source")
                    self._conn.execute("UPDATE feedbackThreads SET ticketHash=? WHERE threadId=?",
                                       (ticket_hash, existing["threadId"]))
                    self._conn.commit()
                    return {"threadId": existing["threadId"], "createdAt": int(existing["createdAt"]),
                            "lastMessageAt": int(existing["lastMessageAt"]), "created": False}
            thread_id = new_id("th")
            self._conn.execute(
                "INSERT INTO feedbackThreads(threadId, ticketHash, accountId, deviceId, appVersion,"
                " deviceModel, systemVersion, createdAt, lastMessageAt, status, clientRef, subject)"
                " VALUES(?,?,?,?,?,?,?,?,?,'open',?,?)",
                (thread_id, ticket_hash, account_id, device_id, app_version, device_model,
                 system_version, stamp, stamp, client_ref, clean_feedback_subject(subject)))
            self._conn.execute(
                "INSERT INTO feedbackMessages(messageId, threadId, author, body, createdAt)"
                " VALUES(?,?,'user',?,?)", (new_id("fm"), thread_id, text, stamp))
            self._conn.commit()
        return {"threadId": thread_id, "createdAt": stamp, "lastMessageAt": stamp, "created": True}

    def set_feedback_subject(self, thread_id: str, subject: str | None) -> bool:
        """改一条线程的主题（`feedback-reply --subject`）；线程不存在返回 False。

        规范化与上限走 :func:`clean_feedback_subject`，与 :meth:`create_feedback_thread`
        同一个口径：空白存 NULL（等于把主题清掉），超 80 字符抛 :class:`StoreError`。
        只动这一列，不碰 `lastMessageAt`/`status`——改标题不是一次往返。
        """
        cleaned = clean_feedback_subject(subject)
        with self._lock:
            cursor = self._conn.execute(
                "UPDATE feedbackThreads SET subject=? WHERE threadId=?", (cleaned, thread_id))
            self._conn.commit()
            return bool(cursor.rowcount)

    def append_feedback_message(self, thread_id: str, body: str, *, author: str = "user",
                                client_ref: str | None = None, bind_device_id: str | None = None,
                                bind_account_id: str | None = None,
                                at: int | None = None) -> dict[str, Any] | None:
        """线程里加一条留言；线程不存在返回 None。

        `author='user'`（手机补充）把线程拨回 `open`，`author='owner'`（回信）置
        `replied`。`clientRef` 命中唯一索引时返回既有那条、不重复写。带设备时顺带
        补上匿名线程的绑定：匿名提交后来配对了，这台设备也能找回来。
        """
        stamp = at or now_ms()
        with self._lock:
            thread = self._conn.execute("SELECT * FROM feedbackThreads WHERE threadId=?",
                                        (thread_id,)).fetchone()
            if thread is None:
                return None
            if bind_device_id and thread["deviceId"] is None:
                self._conn.execute("UPDATE feedbackThreads SET deviceId=?, accountId=? WHERE threadId=?",
                                   (bind_device_id, bind_account_id, thread_id))
            if client_ref:
                existing = self._conn.execute("SELECT * FROM feedbackMessages WHERE clientRef=?",
                                              (client_ref,)).fetchone()
                if existing is not None:
                    self._conn.commit()
                    return {"messageId": existing["messageId"], "threadId": existing["threadId"],
                            "createdAt": int(existing["createdAt"]), "created": False}
            message_id = new_id("fm")
            self._conn.execute(
                "INSERT INTO feedbackMessages(messageId, threadId, author, body, createdAt, clientRef)"
                " VALUES(?,?,?,?,?,?)", (message_id, thread_id, author, body, stamp, client_ref))
            self._conn.execute(
                "UPDATE feedbackThreads SET lastMessageAt=?, status=? WHERE threadId=?",
                (stamp, "replied" if author == "owner" else "open", thread_id))
            self._conn.commit()
        return {"messageId": message_id, "threadId": thread_id, "createdAt": stamp, "created": True}

    def create_notice(self, body: str, subject: str | None, device_ids: Iterable[str], *,
                      created_by: str | None = None, at: int | None = None) -> dict[str, Any]:
        """发一条通知，并给每台收件设备写一行未读投递（发送记录就在这两张表里）。

        收件人由调用方定（`admin.py` 的 `--all` 是全部未撤销设备）；这里只去重，
        不核对设备是否存在——投给一台刚被撤销的手机是调度问题，不是存储问题。
        """
        stamp = at or now_ms()
        notice_id = new_id("nt")
        targets = list(dict.fromkeys(target for target in device_ids if target))
        with self._lock:
            self._conn.execute(
                "INSERT INTO notices(noticeId, subject, body, createdAt, createdBy) VALUES(?,?,?,?,?)",
                (notice_id, subject, body, stamp, created_by))
            self._conn.executemany(
                "INSERT OR IGNORE INTO noticeDeliveries(noticeId, deviceId, createdAt) VALUES(?,?,?)",
                [(notice_id, device_id, stamp) for device_id in targets])
            self._conn.commit()
        return {"noticeId": notice_id, "createdAt": stamp, "recipients": len(targets)}

    def feedback_thread(self, thread_id: str, ticket_hash: str | None = None, *,
                        messages_per_thread: int = 50) -> dict[str, Any] | None:
        """一条线程（最近 N 条留言 + 用户侧未读 + 留言总数）；取不到返回 None。

        `ticket_hash` 给了就必须匹配，否则和"线程不存在"一样返回 None——调用方对
        这两种情况给同一个答复，不泄露线程是否存在。传 None 是内部/owner 路径。
        """
        row = self._row("SELECT * FROM feedbackThreads WHERE threadId=?", (thread_id,))
        if row is None:
            return None
        if ticket_hash is not None and not secrets.compare_digest(row["ticketHash"], ticket_hash):
            return None
        return self._feedback_payload(row, messages_per_thread)

    def feedback_threads_by_tickets(self, pairs: Iterable[tuple[str, str]], *,
                                    messages_per_thread: int = 50) -> list[dict[str, Any]]:
        """凭据命中的线程；对子里是 `(threadId, ticketHash)`。

        逐个按主键取，因为每行的凭据哈希各不相同，没法用一条 `IN` 查完；调用方
        （`feedback.py`）已经把对子数限制在 50 以内。同一个线程只出现一次。
        """
        found: list[dict[str, Any]] = []
        seen: set[str] = set()
        for thread_id, ticket_hash in pairs:
            if not thread_id or not ticket_hash or thread_id in seen:
                continue
            thread = self.feedback_thread(thread_id, ticket_hash,
                                          messages_per_thread=messages_per_thread)
            if thread is None:
                continue
            seen.add(thread_id)
            found.append(thread)
        return found

    def feedback_threads_by_device(self, device_id: str, account_id: str | None = None, *,
                                   messages_per_thread: int = 50) -> list[dict[str, Any]]:
        """绑定到这台设备**或它所属账号**的线程，最近的在前。

        账号也算命中：重装后重新配对换来一个新的 `deviceId`，只有账号还是同一个，
        "重装后重新配对即可找回"（spec US1）靠的就是这一条。
        """
        rows = self._rows(
            "SELECT * FROM feedbackThreads WHERE deviceId=?"
            " OR (accountId IS NOT NULL AND accountId=?) ORDER BY lastMessageAt DESC",
            (device_id, account_id))
        return [self._feedback_payload(row, messages_per_thread) for row in rows]

    def mark_thread_read(self, thread_id: str, upto_ms: int | None = None) -> bool:
        """把这台手机的 `userReadAt` 推到 `upto_ms`；默认推到最后一条 owner 消息。

        只前进不后退，所以重复调用结果不变（幂等）：`read` 接口可以放心重试。
        线程不存在返回 False；还没有 owner 消息时不动——那时未读本来就是 0。
        """
        with self._lock:
            row = self._conn.execute("SELECT * FROM feedbackThreads WHERE threadId=?",
                                     (thread_id,)).fetchone()
            if row is None:
                return False
            stamp = upto_ms
            if stamp is None:
                latest = self._conn.execute(
                    "SELECT MAX(createdAt) FROM feedbackMessages WHERE threadId=? AND author='owner'",
                    (thread_id,)).fetchone()[0]
                stamp = int(latest) if latest is not None else None
            if stamp is not None and (row["userReadAt"] is None or int(stamp) > int(row["userReadAt"])):
                self._conn.execute("UPDATE feedbackThreads SET userReadAt=? WHERE threadId=?",
                                   (int(stamp), thread_id))
            self._conn.commit()
        return True

    def notices_for_device(self, device_id: str, *, limit: int = 200) -> list[dict[str, Any]]:
        """投给这台设备的通知，最近的在前；`read` 是**这台设备自己**的已读状态。"""
        rows = self._rows(
            "SELECT n.noticeId AS noticeId, n.subject AS subject, n.body AS body,"
            " n.createdAt AS createdAt, n.createdBy AS createdBy, d.readAt AS readAt"
            " FROM notices n JOIN noticeDeliveries d ON d.noticeId = n.noticeId"
            " WHERE d.deviceId=? ORDER BY n.createdAt DESC, n.noticeId DESC LIMIT ?",
            (device_id, limit))
        return [{**dict(row), "read": row["readAt"] is not None} for row in rows]

    def mark_notices_read(self, device_id: str, notice_ids: Iterable[str],
                          at: int | None = None) -> int:
        """把这几条通知在本设备上的投递行标已读；返回被改的行数（幂等）。"""
        ids = list(dict.fromkeys(notice_id for notice_id in notice_ids if notice_id))
        if not ids:
            return 0
        marks = ",".join("?" * len(ids))
        with self._lock:
            cursor = self._conn.execute(
                f"UPDATE noticeDeliveries SET readAt=? WHERE deviceId=? AND readAt IS NULL"
                f" AND noticeId IN ({marks})", [at or now_ms(), device_id, *ids])
            self._conn.commit()
            return cursor.rowcount or 0

    def owner_unread_counts(self) -> dict[str, int]:
        """owner 还没看过的用户消息数，按线程。清单里标"新"用。"""
        rows = self._rows(
            "SELECT m.threadId AS threadId, COUNT(*) AS unread FROM feedbackMessages m"
            " JOIN feedbackThreads t ON t.threadId = m.threadId"
            " WHERE m.author='user' AND (t.ownerReadAt IS NULL OR m.createdAt > t.ownerReadAt)"
            " GROUP BY m.threadId")
        return {row["threadId"]: int(row["unread"]) for row in rows}

    def touch_owner_read(self, thread_id: str, at: int | None = None) -> bool:
        """记下 owner 读过这条线程；线程不存在返回 False。"""
        with self._lock:
            cursor = self._conn.execute("UPDATE feedbackThreads SET ownerReadAt=? WHERE threadId=?",
                                        (at or now_ms(), thread_id))
            self._conn.commit()
            return bool(cursor.rowcount)

    def list_feedback_threads(self, *, status: str | None = None, since_ms: int | None = None,
                              limit: int = 50, messages_per_thread: int = 0) -> list[dict[str, Any]]:
        """owner 清单：按最近活动倒序的线程。

        `status` 只认 `open`/`replied`（不给就是全部），`since_ms` 卡 `createdAt`。
        默认不带留言——清单只要摘要，完整往返走 :meth:`feedback_thread`。
        """
        clauses: list[str] = []
        params: list[Any] = []
        if status:
            clauses.append("status=?")
            params.append(status)
        if since_ms is not None:
            clauses.append("createdAt >= ?")
            params.append(int(since_ms))
        where = f" WHERE {' AND '.join(clauses)}" if clauses else ""
        params.append(int(limit))
        rows = self._rows(
            f"SELECT * FROM feedbackThreads{where} ORDER BY lastMessageAt DESC LIMIT ?", params)
        return [self._feedback_payload(row, messages_per_thread) for row in rows]

    def delete_feedback_thread(self, thread_id: str) -> int:
        """连线程带它的留言一起删（响应隐私删除请求）；返回删掉的留言数。

        线程不存在抛 :class:`NotFound`，调用方据此报错而不是默默成功。
        """
        with self._lock:
            if self._conn.execute("SELECT threadId FROM feedbackThreads WHERE threadId=?",
                                  (thread_id,)).fetchone() is None:
                raise NotFound(f"feedback thread {thread_id} does not exist")
            cursor = self._conn.execute("DELETE FROM feedbackMessages WHERE threadId=?", (thread_id,))
            self._conn.execute("DELETE FROM feedbackThreads WHERE threadId=?", (thread_id,))
            self._conn.commit()
            return cursor.rowcount or 0

    def feedback_digest(self, thread_ids: Iterable[str], *, excerpt_chars: int = 80
                        ) -> dict[str, dict[str, Any]]:
        """每条线程的**首条**留言摘要、主题与**首条** owner 回信时间；只读。

        `list_feedback_threads` 默认不带留言（清单只要摘要），而 owner 要的两个数都在
        消息表里：用户先说了什么（前 `excerpt_chars` 字）、我们隔了多久回第一句。一次
        查完，不逐线程再查一遍；不存在的 id 直接跳过。`subject` 在另一张表上，所以
        清单里那几行的主题也一并取回（为空仍是 NULL，由展示层用摘要兜底）。
        """
        ids = list(dict.fromkeys(thread_id for thread_id in thread_ids if thread_id))
        if not ids:
            return {}
        marks = ",".join("?" * len(ids))
        subjects = {row["threadId"]: row["subject"] for row in self._rows(
            f"SELECT threadId, subject FROM feedbackThreads WHERE threadId IN ({marks})", ids)}
        digest: dict[str, dict[str, Any]] = {}
        for row in self._rows(
                "SELECT threadId, author, body, createdAt FROM feedbackMessages"
                f" WHERE threadId IN ({marks}) ORDER BY threadId, createdAt, rowid", ids):
            entry = digest.setdefault(row["threadId"],
                                      {"subject": subjects.get(row["threadId"]),
                                       "excerpt": row["body"][:excerpt_chars],
                                       "firstReplyAt": None})
            if row["author"] == "owner" and entry["firstReplyAt"] is None:
                entry["firstReplyAt"] = int(row["createdAt"])
        return digest

    def _feedback_row_by(self, column: str, value: str) -> sqlite3.Row | None:
        """按线程表上的**固定列名**取一行；列名只由本模块的字面量给出，不是用户输入。"""
        return self._row(f"SELECT * FROM feedbackThreads WHERE {column}=?", (value,))

    @staticmethod
    def _feedback_source_matches(row: sqlite3.Row, device_id: str | None,
                                 account_id: str | None) -> bool:
        """这次提交是不是这条线程原来的来源（幂等重试的判据）。

        匿名线程（两个字段都空）没有任何可核对的来源，只认 `clientRef` 本身；
        绑定过的线程要求设备或账号对得上，否则不把线程交出去。
        """
        if row["deviceId"] is None and row["accountId"] is None:
            return True
        if device_id and row["deviceId"] == device_id:
            return True
        return bool(account_id) and row["accountId"] == account_id

    def _feedback_payload(self, row: sqlite3.Row, messages_per_thread: int = 50) -> dict[str, Any]:
        """一行线程（含 `subject`，可为 None）+ 最近 N 条留言（按时间升序）
        + 用户侧未读 + 留言总数。"""
        thread_id = row["threadId"]
        messages: list[dict[str, Any]] = []
        if messages_per_thread > 0:
            # `rowid` 兜同一毫秒内的插入顺序：`messageId` 是随机串，用它排序等于乱排。
            recent = self._rows(
                "SELECT * FROM feedbackMessages WHERE threadId=?"
                " ORDER BY createdAt DESC, rowid DESC LIMIT ?",
                (thread_id, int(messages_per_thread)))
            messages = [dict(message) for message in reversed(recent)]
        read_at = row["userReadAt"]
        unread = self._row(
            "SELECT COUNT(*) AS n FROM feedbackMessages WHERE threadId=? AND author='owner'"
            " AND (? IS NULL OR createdAt > ?)", (thread_id, read_at, read_at))
        count = self._row("SELECT COUNT(*) AS n FROM feedbackMessages WHERE threadId=?", (thread_id,))
        return {**dict(row), "messages": messages, "messageCount": int(count["n"]),
                "unread": int(unread["n"])}
