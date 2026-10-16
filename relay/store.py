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
import json
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
  pushUpdatedAt   INTEGER,
  -- 同一台 client 的持久标识（032）。重装后带着同一个 key 回来即"复用原来那台"，
  -- 不再占新名额。**必须是本表最后一列**：迁移靠 `ALTER TABLE` 追加（`_migrate_to_6`）。
  -- 老设备没有这个值（NULL），认领时按新设备处理。
  deviceKey       TEXT
);
CREATE INDEX IF NOT EXISTS devices_agent ON devices(agentId);

CREATE TABLE IF NOT EXISTS pairCodes (
  codeHash  TEXT PRIMARY KEY,
  agentId   TEXT NOT NULL,
  accountId TEXT NOT NULL,
  createdAt INTEGER NOT NULL,
  -- 持久码没有过期时间（032）：NULL = 永久，直到用户点「重新生成」把它 `revokedAt`。
  expiresAt INTEGER,
  -- 首次认领审计。持久码可以被反复认领，所以它**不再是**认领门槛（见 `claim_pair_code`）。
  usedAt    INTEGER,
  deviceId  TEXT,
  -- 032：作废时刻（重新生成）、最后一次认领时刻、认领次数。
  -- 三列都必须是本表最后几列，迁移靠 `ALTER TABLE` 追加（`_migrate_to_6`）。
  revokedAt  INTEGER,
  lastUsedAt INTEGER,
  useCount   INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS pair_codes_agent ON pairCodes(agentId);

-- 账户级状态（032）：一台设备改了、同账户其他设备要跟着变的那几项——会话已读水位、
-- 角标水位、提醒开关、待回应已回答。值是一段 JSON 文本，**服务端只做两件事**：
-- 按 (accountId, key) 存取，以及保证 `updatedAt` 单调（拒绝更旧的写）。合并语义
-- （比如已读取最大值、开关后写覆盖）由写入方决定，中转不解释内容——这与 DLP
-- "不解析任何 DSH 语义"的立场一致。
--
-- 为什么不是每台设备各存一份：owner 2026-10-16 要的是"账户为单位"，即"我在这台手机
-- 上读过的信、关掉的提醒，另一台手机与浏览器看到的是同一份"。
CREATE TABLE IF NOT EXISTS accountState (
  accountId         TEXT NOT NULL,
  key               TEXT NOT NULL,
  value             TEXT NOT NULL,
  updatedAt         INTEGER NOT NULL,
  updatedByDeviceId TEXT,
  PRIMARY KEY (accountId, key)
);

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
  clientRef  TEXT UNIQUE,
  -- 正文格式（富文本 2026-10-12）：`text`（手机按 Markdown 渲染）/ `html`（锁死的容器）。
  -- **必须留在表的最后**：老库是靠 `_migrate_to_4` 的 `ALTER TABLE … ADD COLUMN` 补上它
  -- 的，SQLite 把新列追加在末尾，写在中间会让"新建的库"与"迁移过来的库"列序不一致。
  format     TEXT NOT NULL DEFAULT 'text'
);
CREATE INDEX IF NOT EXISTS feedbackMessagesByThread ON feedbackMessages(threadId, createdAt);

CREATE TABLE IF NOT EXISTS notices (
  noticeId   TEXT PRIMARY KEY,
  subject    TEXT,
  body       TEXT NOT NULL,
  createdAt  INTEGER NOT NULL,
  createdBy  TEXT,
  -- 同 `feedbackMessages.format`：取值与"留在表末"的理由完全一样。
  format     TEXT NOT NULL DEFAULT 'text'
);

CREATE TABLE IF NOT EXISTS noticeDeliveries (
  noticeId   TEXT NOT NULL,
  accountId  TEXT NOT NULL,
  createdAt  INTEGER NOT NULL,
  readAt     INTEGER,
  PRIMARY KEY (noticeId, accountId)
);
-- `noticeDeliveriesByAccount` 的索引**故意不写在这里**：`CREATE INDEX` 没有
-- "列不存在就先跳过"这回事，而老的库里 `noticeDeliveries` 还是 `deviceId` 那一版，
-- `IF NOT EXISTS` 不会重建它，于是这条索引会让"打开一个老库"当场报
-- `no such column: accountId`。索引由 `_migrate_to_5` 建（两条路径都会跑到它）。
"""

DEFAULT_PAIR_TTL_MS = 10 * 60 * 1000
DEFAULT_DEVICE_TTL_MS = 365 * 24 * 60 * 60 * 1000

#: 一个账户最多能有多少台**未撤销**的 client（iOS / Web，032）。
#:
#: 为什么要有这个数（owner 2026-10-16 定为 8）：日流量额度是按**设备**算的
#: （`hub.DailyQuota`），连接器又为每台接入过的设备各留一条 `$events` 值班流；
#: 再加一个"泄漏的 deviceToken 就是一个入口"，设备数需要有上限。
#: 上限在**认领**处拦（这里），"同时连接数"上限在 attach 处拦（`hub`），两层都要。
DEFAULT_MAX_PAIRED_DEVICES = 8

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

#: 正文格式（FR-034）的**唯一一份**取值定义：`text` 由手机按 Markdown 渲染，`html`
#: 走 App 里那个锁死的 HTML 容器。接口层的 400、owner 侧命令的 `--format` 与两张表的
#: 默认值都从这一份来，不要在各处再抄一遍字面量。
FEEDBACK_FORMATS = ("text", "html")
DEFAULT_FEEDBACK_FORMAT = "text"

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
SCHEMA_VERSION = 7


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


def _migrate_to_4(conn: sqlite3.Connection) -> None:
    """富文本：``feedbackMessages`` 与 ``notices`` 各加 ``format``（正文格式）。

    两张表一起补：一张装回信、一张装通知，取值口径相同（`text`/`html`）。幂等性照
    ``_migrate_to_2``/``_migrate_to_3`` 的口径：``ADD COLUMN`` 在 SQLite 里没有
    ``IF NOT EXISTS``，所以先查列。``NOT NULL DEFAULT 'text'`` 让老行直接读到 ``text``，
    旧值一个都不动——回信与通知都是已经发出去的东西，不改写。

    ``format`` 在 ``SCHEMA`` 里也是两张表的最后一列：`ALTER TABLE` 只追加到末尾，
    写在中间会让迁移过来的库与新建的库列序分叉。
    """
    for table in ("feedbackMessages", "notices"):
        existing = {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}
        if "format" not in existing:
            conn.execute(f"ALTER TABLE {table} ADD COLUMN format TEXT NOT NULL DEFAULT 'text'")


def _migrate_to_5(conn: sqlite3.Connection) -> None:
    """收件箱归属从设备换成账号（019）：`noticeDeliveries` 重建为 `(noticeId, accountId)`。

    为什么是重建而不是加列：主键从 `(noticeId, deviceId)` 变成 `(noticeId, accountId)`，
    SQLite 改不了主键；而且留着 `deviceId` 会让"迁移过来的库"与"新建的库"列不一致
    （`:func:`_migrate` 之上那条守卫用例正是查这个）。

    回填规则：旧行经 `devices.accountId` 找到所属账号，同一 `(noticeId, accountId)` 合并成一行，
    `createdAt` 取最早的一次投递，`readAt` 取最早的一次已读（只前进；全未读则保持 NULL）。
    设备行已经不存在的旧行（本机清理过 2000+ 台已撤销设备，确实会有）**跳过**，
    只把条数写进日志——为一条无法归属的历史行让整库迁移失败，代价远大于丢掉它。

    幂等：先看列，已经只有 `accountId` 就认为迁过了（重复启动、迁移到一半重试都安全）——
    但索引仍要补一次：新库是先由 `SCHEMA` 建表（那里**故意不建**这条索引，见 `SCHEMA` 里的注释），
    再走迁移的，所以"表已经对了"不等于"索引已经在了"。
    """
    existing = {row[1] for row in conn.execute("PRAGMA table_info(noticeDeliveries)")}
    if "accountId" in existing and "deviceId" not in existing:
        conn.execute("CREATE INDEX IF NOT EXISTS noticeDeliveriesByAccount"
                     " ON noticeDeliveries(accountId, readAt)")
        return

    skipped = int(conn.execute(
        "SELECT COUNT(*) FROM noticeDeliveries d"
        " LEFT JOIN devices v ON v.deviceId = d.deviceId WHERE v.deviceId IS NULL"
    ).fetchone()[0])
    conn.execute(
        "CREATE TABLE noticeDeliveries_new ("
        "  noticeId   TEXT NOT NULL,"
        "  accountId  TEXT NOT NULL,"
        "  createdAt  INTEGER NOT NULL,"
        "  readAt     INTEGER,"
        "  PRIMARY KEY (noticeId, accountId)"
        ")")
    conn.execute(
        "INSERT OR IGNORE INTO noticeDeliveries_new(noticeId, accountId, createdAt, readAt)"
        " SELECT d.noticeId, v.accountId, MIN(d.createdAt),"
        "        MIN(CASE WHEN d.readAt IS NOT NULL THEN d.readAt END)"
        "   FROM noticeDeliveries d JOIN devices v ON v.deviceId = d.deviceId"
        "  GROUP BY d.noticeId, v.accountId")
    conn.execute("DROP TABLE noticeDeliveries")
    conn.execute("ALTER TABLE noticeDeliveries_new RENAME TO noticeDeliveries")
    conn.execute("CREATE INDEX IF NOT EXISTS noticeDeliveriesByAccount"
                 " ON noticeDeliveries(accountId, readAt)")
    if skipped:
        logging.getLogger("relay.store").info(
            "relay: migrate 5: %d notice delivery row(s) skipped (device gone)", skipped)


#: ``generation → function``, applied in order. Each step must be idempotent:
#: a migration that fails after a partial commit is retried on the next start.
def _migrate_to_6(conn: sqlite3.Connection) -> None:
    """持久配对码与设备标识（032）。

    `pairCodes` 加三列：`revokedAt`（用户点"重新生成"作废旧码）、`lastUsedAt`、
    `useCount`（持久码可反复认领，得留下使用痕迹）。`expiresAt` 允许为 NULL =
    永久有效——SQLite 的列类型本来就是灵活的，老行与非空约束都不受影响。

    `devices` 加 `deviceKey`（同设备重装复用），并为"按账户找这台设备"建一条部分索引：
    只索引未撤销的行，撤销掉的历史不参与查找。索引只在这里建，不写进 `SCHEMA`——
    理由同 `_migrate_to_5` 那条注释：老库里 `deviceKey` 列还不存在时，`CREATE INDEX`
    会让"打开一个老库"当场报 `no such column`。

    幂等性照既有口径：`ADD COLUMN` 没有 `IF NOT EXISTS`，所以先查列。
    """
    existing = {row[1] for row in conn.execute("PRAGMA table_info(pairCodes)")}
    for column, declaration in (
        ("revokedAt", "INTEGER"),
        ("lastUsedAt", "INTEGER"),
        ("useCount", "INTEGER NOT NULL DEFAULT 0"),
    ):
        if column not in existing:
            conn.execute(f"ALTER TABLE pairCodes ADD COLUMN {column} {declaration}")

    device_columns = {row[1] for row in conn.execute("PRAGMA table_info(devices)")}
    if "deviceKey" not in device_columns:
        conn.execute("ALTER TABLE devices ADD COLUMN deviceKey TEXT")

    conn.execute(
        "CREATE INDEX IF NOT EXISTS devices_account_deviceKey"
        " ON devices(accountId, deviceKey) WHERE deviceKey IS NOT NULL AND revokedAt IS NULL"
    )


def _paircodes_expires_at_allows_null(conn: sqlite3.Connection) -> bool:
    """`pairCodes.expiresAt` 现在允许 NULL 了吗（持久码没有过期时间）。"""
    for row in conn.execute("PRAGMA table_info(pairCodes)"):
        if row[1] == "expiresAt":
            return not bool(row[3])
    return True


def _migrate_to_7(conn: sqlite3.Connection) -> None:
    """`pairCodes.expiresAt` 从 NOT NULL 改成可空（持久码要写 NULL）。

    为什么必须重建表：SQLite 的 `ALTER TABLE` 改不了列的 NOT NULL，只能
    「建新表 → 拷数据 → 删旧表 → 改名」。**这是 2026-10-16 生产上当场暴露的**：
    v6 迁移只加了列，没改约束，于是第一枚持久码在服务器上 `NOT NULL constraint failed`。
    本机测试没抓到，因为造"老库"用的是 `CREATE TABLE … AS SELECT`（它把约束一起丢了）。

    幂等：先看 `PRAGMA table_info` 的 notnull 标志，已经可空就什么都不做。
    """
    if _paircodes_expires_at_allows_null(conn):
        return
    conn.execute(
        """CREATE TABLE pairCodes_new (
             codeHash  TEXT PRIMARY KEY,
             agentId   TEXT NOT NULL,
             accountId TEXT NOT NULL,
             createdAt INTEGER NOT NULL,
             expiresAt INTEGER,
             usedAt    INTEGER,
             deviceId  TEXT,
             revokedAt  INTEGER,
             lastUsedAt INTEGER,
             useCount   INTEGER NOT NULL DEFAULT 0
           )"""
    )
    conn.execute(
        "INSERT INTO pairCodes_new(codeHash, agentId, accountId, createdAt, expiresAt,"
        " usedAt, deviceId, revokedAt, lastUsedAt, useCount)"
        " SELECT codeHash, agentId, accountId, createdAt, expiresAt,"
        " usedAt, deviceId, revokedAt, lastUsedAt, useCount FROM pairCodes"
    )
    conn.execute("DROP TABLE pairCodes")
    conn.execute("ALTER TABLE pairCodes_new RENAME TO pairCodes")
    conn.execute("CREATE INDEX IF NOT EXISTS pair_codes_agent ON pairCodes(agentId)")


_MIGRATIONS: dict[int, Any] = {
    1: _migrate_to_1,
    2: _migrate_to_2,
    3: _migrate_to_3,
    6: _migrate_to_6,
    7: _migrate_to_7,
    4: _migrate_to_4,
    5: _migrate_to_5,
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


class PairedDeviceLimitReached(Conflict):
    """一个账户已配对的 client 到顶了（032 FR-003）。

    跟着"拒绝新认领"走（owner 选择的策略），不自动替换任何已有设备：被悄悄踢掉的
    那台可能是用户唯一在用的。带 ``limit`` 与 ``live`` 两个数字，接口层据此给出
    "去设备列表先删一台"的可执行提示。
    """

    def __init__(self, limit: int, live: int):
        super().__init__(
            f"this account already has {live} paired devices (limit {limit})")
        self.limit = limit
        self.live = live


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


def clean_feedback_format(value: Any) -> str:
    """正文格式（FR-034）：去首尾空白，空（或没给）按默认 `text`，别的一律 :class:`StoreError`。

    "没给"与"给了空白"都算默认，而不是错误——两条写入路径（`append_feedback_message`/
    `create_notice`）的默认值就是 `text`。取值只认 :data:`FEEDBACK_FORMATS`：多一个格式就
    多一种 App 侧的渲染分支，不该由调用方随手发明。接口层（`feedback.py`）先按契约回 400，
    这里是落到库前的最后一道。
    """
    if value is None:
        return DEFAULT_FEEDBACK_FORMAT
    if not isinstance(value, str):
        raise StoreError("format must be a string")
    trimmed = value.strip()
    if not trimmed:
        return DEFAULT_FEEDBACK_FORMAT
    if trimmed not in FEEDBACK_FORMATS:
        raise StoreError("format must be one of: " + ", ".join(FEEDBACK_FORMATS))
    return trimmed


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

    def mint_pair_code(self, agent_id: str, ttl_ms: int | None = None) -> dict[str, Any]:
        """铸一枚配对码。``ttl_ms=None`` = **持久码**（032）：不过期，直到用户重新生成。

        为什么默认改成持久：owner 2026-10-16 要求"码长期有效，直到用户点重新生成"，
        这样重装、换机、加一台 Web 都不用回到电脑前出码。老连接器仍在请求里带 `ttlMs`，
        那条路径一字未改（带 TTL 的码行为与今天完全一致）。
        """
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
        expires = None if ttl_ms is None else created + int(ttl_ms)
        self._write(
            "INSERT INTO pairCodes(codeHash, agentId, accountId, createdAt, expiresAt)"
            " VALUES(?,?,?,?,?)",
            (hash_pair_code(code), agent_id, agent["accountId"], created, expires),
        )
        return {"code": code, "expiresAt": expires, "agentId": agent_id,
                "ttlMs": None if ttl_ms is None else int(ttl_ms), "persistent": ttl_ms is None}

    def regenerate_pair_code(self, agent_id: str, ttl_ms: int | None = None) -> dict[str, Any]:
        """用户点「重新生成」：作废该 agent 现存的所有码，再铸一枚新的。

        **只作废码，不碰 devices**（032 FR-002）：已经在用的手机/浏览器靠各自的
        deviceToken 活着，换码不该把它们踢下线。返回里带 `revoked` 条数，便于日志与用例断言。
        """
        agent = self.agent_by_id(agent_id)
        if agent is None:
            raise NotFound(f"agent {agent_id} does not exist")
        if agent["disabled"]:
            raise Conflict(f"agent {agent_id} is disabled")
        stamp = now_ms()
        with self._lock:
            cur = self._conn.execute(
                "UPDATE pairCodes SET revokedAt=? WHERE agentId=? AND revokedAt IS NULL",
                (stamp, agent_id),
            )
            revoked = cur.rowcount or 0
            self._conn.commit()
        minted = self.mint_pair_code(agent_id, ttl_ms=ttl_ms)
        return {**minted, "revoked": revoked}

    def claim_pair_code(self, code: str, *, device_name: str, model: str | None = None,
                        app_version: str | None = None,
                        ttl_ms: int = DEFAULT_DEVICE_TTL_MS,
                        device_key: str | None = None,
                        max_paired_devices: int = DEFAULT_MAX_PAIRED_DEVICES) -> dict[str, Any]:
        """Redeem a pairing code and mint a long-lived device token.

        **可以反复认领**（032）：持久码不是一次性的，所以门槛是"未撤销且未过期"
        （没有 ``expiresAt`` 的行 = 永久）。第一次认领仍会写 ``usedAt``/``deviceId``
        留痕，但那是审计，不是门槛。

        两条去重/限额规则：

        * 带 ``device_key``（同一台 client 重装、或浏览器的 localStorage）且命中一台
          **未撤销**的设备 → **复用它的 deviceId、只换发 token**，不占新名额；
        * 否则按账户统计未撤销设备数，达到 ``max_paired_devices`` 就拒绝
          （``PairedDeviceLimitReached``），**不铸 token**。

        The lookup has to scan live codes because each row carries its own scrypt
        salt; the candidate set is the non-revoked, non-expired tail of the table.
        A miss is not simply "not found": see :meth:`_pair_code_rejection`.
        """
        normalized = normalize_pair_code(code)
        if not normalized:
            raise NotFound("empty pairing code")
        stamp = now_ms()
        with self._lock:
            rows = self._conn.execute(
                "SELECT * FROM pairCodes WHERE revokedAt IS NULL"
                " AND (expiresAt IS NULL OR expiresAt > ?) ORDER BY createdAt DESC LIMIT 200",
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

            reused = None
            if device_key:
                reused = self._conn.execute(
                    "SELECT * FROM devices WHERE accountId=? AND deviceKey=? AND revokedAt IS NULL"
                    " ORDER BY createdAt DESC LIMIT 1",
                    (agent["accountId"], device_key),
                ).fetchone()

            if reused is None:
                live = int(self._conn.execute(
                    "SELECT COUNT(*) FROM devices WHERE accountId=? AND revokedAt IS NULL",
                    (agent["accountId"],),
                ).fetchone()[0])
                if int(max_paired_devices) > 0 and live >= int(max_paired_devices):
                    raise PairedDeviceLimitReached(int(max_paired_devices), int(live))

            token = new_token("dt")
            expires = stamp + int(ttl_ms)
            if reused is not None:
                device_id = reused["deviceId"]
                self._conn.execute(
                    "UPDATE devices SET deviceTokenHash=?, name=?, model=?, appVersion=?,"
                    " expiresAt=?, lastSeenAt=? WHERE deviceId=?",
                    (sha256_hex(token), device_name or reused["name"], model or reused["model"],
                     app_version or reused["appVersion"], expires, stamp, device_id),
                )
            else:
                device_id = new_id("dev")
                self._conn.execute(
                    "INSERT INTO devices(deviceId, deviceTokenHash, agentId, accountId, name, model,"
                    " appVersion, createdAt, expiresAt, deviceKey) VALUES(?,?,?,?,?,?,?,?,?,?)",
                    (device_id, sha256_hex(token), agent["agentId"], agent["accountId"],
                     device_name or "iOS device", model, app_version, stamp, expires, device_key),
                )
            self._conn.execute(
                "UPDATE pairCodes SET useCount=useCount+1, lastUsedAt=?,"
                " usedAt=COALESCE(usedAt, ?), deviceId=COALESCE(deviceId, ?) WHERE codeHash=?",
                (stamp, stamp, device_id, match["codeHash"]),
            )
            self._conn.commit()
        return {
            "ok": True,
            "agentId": agent["agentId"],
            "agentName": agent["name"],
            "accountId": agent["accountId"],
            "deviceId": device_id,
            "deviceToken": token,
            "expiresAt": expires,
            "reused": reused is not None,
        }

    def _pair_code_rejection(self, normalized: str, stamp: int) -> PairCodeClaimRejected:
        """Why a claim missed every live code: revoked, expired, or never issued.

        Called only from the failure path of :meth:`claim_pair_code`, with the
        lock held. The candidate query deliberately excludes rows that are still
        live — those were already scanned and did not match, so a hit here can
        only mean revoked or expired, and the answer can never contradict the
        decision that produced it. Bounded by both time and row count; see
        ``_PAIR_REJECT_LOOKBACK_MS``.

        **`used` 不再是原因**（032）：持久码可以反复认领，一条已经被认领过的码
        仍然是有效码。留着"已使用"这条原因只会把正常行为报成失败。
        """
        rows = self._conn.execute(
            "SELECT * FROM pairCodes WHERE createdAt > ?"
            " AND (revokedAt IS NOT NULL OR (expiresAt IS NOT NULL AND expiresAt <= ?))"
            " ORDER BY createdAt DESC LIMIT ?",
            (stamp - _PAIR_REJECT_LOOKBACK_MS, stamp, _PAIR_REJECT_LIMIT),
        ).fetchall()
        hit = next((row for row in rows if _verify_pair_code(normalized, row["codeHash"])), None)
        if hit is None:
            return PairCodeClaimRejected("unknown", "that pairing code is not valid")
        if hit["revokedAt"] is not None:
            return PairCodeClaimRejected(
                "revoked", "that pairing code was replaced by a newer one",
                agentId=hit["agentId"], createdAt=int(hit["createdAt"]),
                revokedAt=int(hit["revokedAt"]))
        return PairCodeClaimRejected(
            "expired", "that pairing code has expired",
            agentId=hit["agentId"], createdAt=int(hit["createdAt"]),
            expiresAt=int(hit["expiresAt"]))

    # ── 账户级状态（032）────────────────────────────────────────────────────

    def count_paired_devices(self, account_id: str) -> int:
        """该账户未撤销的 client 台数（032 的 8 台上限就是比它）。"""
        return int(self._conn.execute(
            "SELECT COUNT(*) FROM devices WHERE accountId=? AND revokedAt IS NULL",
            (account_id,)).fetchone()[0])

    def account_state(self, account_id: str, keys: list[str] | None = None) -> dict[str, dict[str, Any]]:
        """读一个账户的状态条目。``keys=None`` 读全部。

        返回值形状：``{key: {"value": <解析后的 JSON>, "updatedAt": ms, "updatedByDeviceId": id}}``。
        值解析不出来（手工写坏、旧版本格式）时按字符串原样返回，不抛错——一条坏状态
        不该让整次读取失败，其他设备还要靠它对齐。
        """
        if keys:
            placeholders = ",".join("?" for _ in keys)
            rows = self._conn.execute(
                f"SELECT * FROM accountState WHERE accountId=? AND key IN ({placeholders})",
                (account_id, *keys),
            ).fetchall()
        else:
            rows = self._conn.execute(
                "SELECT * FROM accountState WHERE accountId=?", (account_id,)).fetchall()
        out: dict[str, dict[str, Any]] = {}
        for row in rows:
            try:
                value = json.loads(row["value"])
            except (TypeError, ValueError):
                value = row["value"]
            out[row["key"]] = {
                "value": value,
                "updatedAt": int(row["updatedAt"]),
                "updatedByDeviceId": row["updatedByDeviceId"],
            }
        return out

    def put_account_state(self, account_id: str, key: str, value: Any, *, updated_at: int,
                          device_id: str | None = None) -> dict[str, Any]:
        """写一条账户状态，**只前进不后退**。

        单调规则：来件的 ``updatedAt`` 不大于已存的就拒收（`applied: False`），返回已存的
        那份。为什么必须有这条：多台设备并发写同一项（"两台手机同时把会话标已读"）时，
        没有它就会出现"旧的那台晚到一步、把新的状态盖回旧值"。相等按幂等处理——同一次
        写的重试不该被当成冲突。

        合并在写入方做（例如已读水位取 max），中转只看时间戳，不解释值。
        """
        serialized = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
        stamp = int(updated_at)
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM accountState WHERE accountId=? AND key=?", (account_id, key),
            ).fetchone()
            if row is not None and int(row["updatedAt"]) >= stamp:
                return {"applied": False, "stored": {
                    "key": key, "value": json.loads(row["value"]), "updatedAt": int(row["updatedAt"]),
                    "updatedByDeviceId": row["updatedByDeviceId"]}}
            self._conn.execute(
                "INSERT INTO accountState(accountId, key, value, updatedAt, updatedByDeviceId)"
                " VALUES(?,?,?,?,?)"
                " ON CONFLICT(accountId, key) DO UPDATE SET"
                " value=excluded.value, updatedAt=excluded.updatedAt,"
                " updatedByDeviceId=excluded.updatedByDeviceId",
                (account_id, key, serialized, stamp, device_id),
            )
            self._conn.commit()
        return {"applied": True, "stored": {
            "key": key, "value": value, "updatedAt": stamp, "updatedByDeviceId": device_id}}

    def purge_expired(self, at: int | None = None) -> int:
        """删掉过期码，以及**早就作废**的码（032）。

        作废码（用户点了"重新生成"）自己不会过期（持久码 `expiresAt IS NULL`），如果一直留着，
        每点一次"重新生成"就永久多一行。留到"拒绝原因查找窗口"之外再删：窗口内还要靠它把
        `pair/revoked-code` 与"打错字"分开，删早了用户只会看到 `pair/invalid-code`。
        """
        stamp = at or now_ms()
        with self._lock:
            cursor = self._conn.execute(
                "DELETE FROM pairCodes WHERE (expiresAt IS NOT NULL AND expiresAt < ?)"
                " OR (revokedAt IS NOT NULL AND revokedAt < ?)",
                (stamp, stamp - _PAIR_REJECT_LOOKBACK_MS),
            )
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

    def device_hygiene(self, agent_id: str | None = None) -> dict[str, int]:
        """设备记录的健康计数：在用 / 已撤销 / 已过期 / 合计。

        为什么要有这个数：中转在每次连接器连上时会把该 agent 名下所有"永远回不来"
        的设备逐条重放给连接器（`hub.py:_tell_agent_about_the_gone`），2012 条曾把
        连接器的处理链堵住（maintainers/ANALYSIS-20261012-connector-flap.md）。
        所以"现在攒了多少"必须一眼看得到：运维从 `/stats` 读它，阈值告警也从同
        一个判据去比。

        口径与清理工具（`purge-revoked-devices.py`）**逐字相同**，两处并用：
        `revoked` 是 `revokedAt IS NOT NULL`，`expired` 是 `expiresAt <= now`，
        `live` 是两者都不成立（= 唯一还会被 `device_by_token` 接受的那些）。
        撤销过的行也可能同时过期，所以 `revoked + expired >= dead`——`dead` 才是
        真正会被重放的条数（并集去重后），不要拿前两个相加当它。
        """
        stamp = now_ms()
        clause = " WHERE agentId=?" if agent_id else ""
        row = self._row(
            "SELECT COUNT(*) AS total,"
            " COALESCE(SUM(CASE WHEN revokedAt IS NOT NULL THEN 1 ELSE 0 END), 0) AS revoked,"
            " COALESCE(SUM(CASE WHEN expiresAt <= ? THEN 1 ELSE 0 END), 0) AS expired,"
            " COALESCE(SUM(CASE WHEN revokedAt IS NULL AND expiresAt > ? THEN 1 ELSE 0 END), 0)"
            "   AS live,"
            " COALESCE(SUM(CASE WHEN revokedAt IS NOT NULL OR expiresAt <= ? THEN 1 ELSE 0 END), 0)"
            "   AS dead"
            f" FROM devices{clause}",
            # 占位符按 SQL 里出现的顺序绑定：expired、live、dead、agentId
            [stamp, stamp, stamp, agent_id] if agent_id else [stamp, stamp, stamp])
        counts = {key: int(row[key]) for key in ("total", "live", "revoked", "expired", "dead")}
        if agent_id:
            counts["agentId"] = agent_id
        return counts

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
                # 用户自己敲进来的正文永远是纯文本，所以 `format` 在这里**写死** `'text'`、
                # 不给参数：App 那一侧没有别的格式可发（FR-034 只约束**我们**发出的正文）。
                "INSERT INTO feedbackMessages(messageId, threadId, author, body, format, createdAt)"
                " VALUES(?,?,'user',?,'text',?)", (new_id("fm"), thread_id, text, stamp))
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
                                format: str = DEFAULT_FEEDBACK_FORMAT,
                                client_ref: str | None = None, bind_device_id: str | None = None,
                                bind_account_id: str | None = None,
                                at: int | None = None) -> dict[str, Any] | None:
        """线程里加一条留言；线程不存在返回 None。

        `author='user'`（手机补充）把线程拨回 `open`，`author='owner'`（回信）置
        `replied`。`clientRef` 命中唯一索引时返回既有那条、不重复写。带设备时顺带
        补上匿名线程的绑定：匿名提交后来配对了，这台设备也能找回来。

        `format` 是这条留言的正文格式（`:func:`clean_feedback_format`，默认 `text`）：
        手机侧用户补充永远是 `text`，`html` 只走 owner 回的"报告类"回信。校验在读库之前，
        非法取值不留半条留言。
        """
        cleaned_format = clean_feedback_format(format)
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
                "INSERT INTO feedbackMessages(messageId, threadId, author, body, format, createdAt,"
                " clientRef) VALUES(?,?,?,?,?,?,?)",
                (message_id, thread_id, author, body, cleaned_format, stamp, client_ref))
            self._conn.execute(
                "UPDATE feedbackThreads SET lastMessageAt=?, status=? WHERE threadId=?",
                (stamp, "replied" if author == "owner" else "open", thread_id))
            self._conn.commit()
        return {"messageId": message_id, "threadId": thread_id, "createdAt": stamp, "created": True}

    def create_notice(self, body: str, subject: str | None, account_ids: Iterable[str], *,
                      format: str = DEFAULT_FEEDBACK_FORMAT,
                      created_by: str | None = None, at: int | None = None) -> dict[str, Any]:
        """发一条通知，并给每个收件账号写一行未读投递（发送记录就在这两张表里）。

        收件人是**账号**（019）：一封通知对一个账号恰好一行，账号下的哪台设备在读、有几台，
        都不影响投递行。收件人由调用方定（`admin.py` 的 `--all` 是全部账号）；
        这里只去重，不核对账号是否存在——投给一个刚建好还没配手机的账号是调度问题，
        不是存储问题（`admin.py` 在更上层做校验并把错报给操作者）。

        `format` 是这条通知的正文格式（`:func:`clean_feedback_format`，默认 `text`）；
        `html` 给日报这类带图的正文用。
        """
        cleaned_format = clean_feedback_format(format)
        stamp = at or now_ms()
        notice_id = new_id("nt")
        targets = list(dict.fromkeys(target for target in account_ids if target))
        with self._lock:
            self._conn.execute(
                "INSERT INTO notices(noticeId, subject, body, format, createdAt, createdBy)"
                " VALUES(?,?,?,?,?,?)",
                (notice_id, subject, body, cleaned_format, stamp, created_by))
            self._conn.executemany(
                "INSERT OR IGNORE INTO noticeDeliveries(noticeId, accountId, createdAt) VALUES(?,?,?)",
                [(notice_id, account_id, stamp) for account_id in targets])
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

    def notices_for_account(self, account_id: str, *, limit: int = 200) -> list[dict[str, Any]]:
        """投给这个账号的通知，最近的在前；`read` 是**账号级**已读（019）。"""
        rows = self._rows(
            "SELECT n.noticeId AS noticeId, n.subject AS subject, n.body AS body,"
            " n.format AS format, n.createdAt AS createdAt, n.createdBy AS createdBy,"
            " d.readAt AS readAt"
            " FROM notices n JOIN noticeDeliveries d ON d.noticeId = n.noticeId"
            " WHERE d.accountId=? ORDER BY n.createdAt DESC, n.noticeId DESC LIMIT ?",
            (account_id, limit))
        return [{**dict(row), "read": row["readAt"] is not None} for row in rows]

    def mark_notices_read(self, account_id: str, notice_ids: Iterable[str],
                          at: int | None = None) -> int:
        """把这个账号的这几条通知投递行标已读；返回被改的行数（幂等、只前进）。

        账号下任一设备调用即全账号已读：`readAt IS NULL` 才写，所以第二台设备
        再标一次是 0 行、不倒退（019 的"一份已读"）。
        """
        ids = list(dict.fromkeys(notice_id for notice_id in notice_ids if notice_id))
        if not ids:
            return 0
        marks = ",".join("?" * len(ids))
        with self._lock:
            cursor = self._conn.execute(
                f"UPDATE noticeDeliveries SET readAt=? WHERE accountId=? AND readAt IS NULL"
                f" AND noticeId IN ({marks})", [at or now_ms(), account_id, *ids])
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
        """每条线程的**首条**留言摘要、主题、格式与**首条** owner 回信时间；只读。

        `list_feedback_threads` 默认不带留言（清单只要摘要），而 owner 要的两个数都在
        消息表里：用户先说了什么（前 `excerpt_chars` 字）、我们隔了多久回第一句。一次
        查完，不逐线程再查一遍；不存在的 id 直接跳过。`subject` 在另一张表上，所以
        清单里那几行的主题也一并取回（为空仍是 NULL，由展示层用摘要兜底）。
        `format` 是**首条留言**（`excerpt` 的来源）的正文格式，与 `excerpt` 同一条记录。
        """
        ids = list(dict.fromkeys(thread_id for thread_id in thread_ids if thread_id))
        if not ids:
            return {}
        marks = ",".join("?" * len(ids))
        subjects = {row["threadId"]: row["subject"] for row in self._rows(
            f"SELECT threadId, subject FROM feedbackThreads WHERE threadId IN ({marks})", ids)}
        digest: dict[str, dict[str, Any]] = {}
        for row in self._rows(
                "SELECT threadId, author, body, format, createdAt FROM feedbackMessages"
                f" WHERE threadId IN ({marks}) ORDER BY threadId, createdAt, rowid", ids):
            entry = digest.setdefault(row["threadId"],
                                      {"subject": subjects.get(row["threadId"]),
                                       "excerpt": row["body"][:excerpt_chars],
                                       "format": row["format"],
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
        + 用户侧未读 + 留言总数。

        留言整行取出（`SELECT *`），所以每条都自带 `format`——清单/凭据/设备三条读路径
        共用这一个形状，没有第二处要补列的渲染。
        """
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
