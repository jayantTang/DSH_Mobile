"""mail 服务的存储：信件 4 张表与全部读写方法。

信件服务的存储层（DESIGN-20261015 从旧中转拆出）。与中转库的差异：

- 只有 feedbackThreads / feedbackMessages / notices / noticeDeliveries 与
  feedbackAttachments 五张表，没有账号/设备/配对/用量——那些归中转，mail 只按值
  引用 accountId/deviceId（不透明字符串，等值比较，无外键、不复制）。
- 附件只存**元数据**：字节落在磁盘上（见 :mod:`attachments`），这里只记行。
- 没有版本化迁移：这是新服务的新库；生产数据由 M3 的迁移脚本从中转
  state.db 按列拷入，列序与本文件的建表语句逐列一致（有测试钉住）。
- 方法体沿用拆分时那份实现（只改 docstring 里的指代），
  让两边的行为可以用同一批移植用例钉住。
"""

from __future__ import annotations

import hashlib
import logging
import os
import secrets
import sqlite3
import threading
import time
from typing import Any, Callable, Iterable

MAX_SUBJECT_CHARS = 80
FEEDBACK_FORMATS = ("text", "html")

#: 测试台来源的机型（团队收件箱的过滤口径，与中转管理命令同一份名单）：
#: 这些来源的提交是验收单，不是用户来信，不进团队收件箱。
TEST_DEVICE_MODELS = {"arm64", "x86_64", "deploy-check", "Node", "simulator", "test-harness"}
DEFAULT_FEEDBACK_FORMAT = "text"

# ── 线程归属：「这条线程是不是写给团队的用户来信」──────────────────────────
#
# 归属是**派生谓词**，不是提交时的配置快照（P2-7：`teamAccountId` 在团队开关为空
# 期间收的信上永远是 NULL，补不回来；快照也回答不了"团队自己写的那条算不算"）。
#
#   is_user_letter(thread, team) =
#       (thread.accountId is NULL or thread.accountId != team)
#       and (thread.deviceModel is NULL or thread.deviceModel not in TEST_DEVICE_MODELS)
#
# 两份实现必须逐格等价，由 `test_the_sql_fragment_and_the_pure_function_agree_on_every_combination`
# 穷举钉住：SQL 片段用于命中查询与未读聚合，纯函数用于内存判定（回信侧、管理清单）。
_MODELS_SQL = ",".join("'" + model.replace("'", "''") + "'" for model in sorted(TEST_DEVICE_MODELS))
_USER_LETTER_TEMPLATE = (
    "({p}accountId IS NULL OR {p}accountId <> ?)"
    " AND ({p}deviceModel IS NULL OR {p}deviceModel NOT IN (" + _MODELS_SQL + "))")

#: 无表别名的谓词（一次请求里只有 feedbackThreads 一张表）。
USER_LETTER_SQL = _USER_LETTER_TEMPLATE.format(p="")
#: `JOIN feedbackThreads t` 里的谓词（未读聚合用）。
USER_LETTER_SQL_T = _USER_LETTER_TEMPLATE.format(p="t.")


def is_user_letter(account_id: str | None, device_model: str | None, team: str) -> bool:
    """谓词的内存实现：这封是不是"给团队的用户来信"。参数取**线程**的来源与当前团队账号。"""
    if account_id is not None and account_id == team:
        return False
    return device_model is None or device_model not in TEST_DEVICE_MODELS


def my_side(user_letter: bool, caller_is_team: bool) -> str:
    """调用方在这条线程上的视角：只有"调用方是团队"且"这条是用户来信"时才是 owner 侧。

    客户端此后只用它决定两栏方向、未读归哪一侧、回信入口；不再按账号级布尔去猜。
    """
    return "owner" if (user_letter and caller_is_team) else "user"


def _before_clause(time_column: str, id_column: str, before: dict[str, Any] | None,
                   time_key: str, id_key: str) -> tuple[str, list[Any]]:
    """keyset 游标：严格早于 `(before.time, before.id)`。两条列表共用这一份。

    排序键是 `(时间 DESC, id DESC)`；线程的时间是 `lastMessageAt`（会因新回信前移），
    通知是 `createdAt`（不可变）。幂等键在两种情况下都保证"不漏"（最多重复）。
    同毫秒多条时按 id **降序**，与 `page_thread_rows` 的排序、以及线程查询的
    `ORDER BY lastMessageAt DESC, threadId DESC` 是同一个口径。
    """
    if not before:
        return "", []
    stamp, ident = int(before[time_key]), str(before[id_key])
    return (f" AND ({time_column} < ? OR ({time_column} = ? AND {id_column} < ?))",
            [stamp, stamp, ident])


def take_page(rows: list[Any], limit: int) -> tuple[list[Any], bool]:
    """limit+1 多取一条判 `more`。两条列表（以及合并后的线程列表）共用这一份判定。"""
    return list(rows[:limit]), len(rows) > limit


def my_unread(counts: dict[str, int], side: str) -> int:
    """两侧未读明细里取"我这一侧"的那一个数——不在这里重新判侧（侧由 `my_side` 决定）。"""
    return int(counts.get(side, 0))


def page_thread_rows(rows: list[Any], *, limit: int | None,
                     before: dict[str, Any] | None = None
                     ) -> tuple[list[Any], bool]:
    """线程行的一页：`(lastMessageAt DESC, threadId DESC)` → 跳过游标 → 多取一条判 `more`。

    `limit=None` 是不设窗口的旧路径（v1 不会翻页）。切片只在这里发生：先取**全部**
    可见行，再切页，未读合计因此可以覆盖全部可见线程（角标不受窗口影响）。
    """
    # 排序口径只有这一处：`(lastMessageAt DESC, threadId DESC)`，与 SQL 的 ORDER BY 和
    # `is_after_before` 的 `id <` 一致（同毫秒多条时 threadId 降序）。
    ordered = sorted(rows, key=lambda row: (int(row["lastMessageAt"]), str(row["threadId"])),
                     reverse=True)
    ordered = [row for row in ordered if is_after_before(row, before, "lastMessageAt", "threadId")]
    if limit is None:
        return ordered, False
    return take_page(ordered, limit)


def is_after_before(row: dict[str, Any], before: dict[str, Any] | None,
                    time_key: str, id_key: str) -> bool:
    """内存侧的同一个游标口径：这一行是否**严格晚于** `before`（`_before_clause` 的镜像）。

    排序键是 `(时间 DESC, id DESC)`，所以"更晚"= 时间更小，或同时间 id **更小**
    （降序里 id 小的排在后面）——与 `_before_clause` 的 `id < ?` 逐字对应。
    合并列表（凭据命中 ∪ 绑定命中）只能在这里过滤。
    """
    if not before:
        return True
    row_time, row_id = int(row[time_key]), str(row[id_key])
    before_time, before_id = int(before[time_key]), str(before[id_key])
    return row_time < before_time or (row_time == before_time and row_id < before_id)


SCHEMA = """
-- 列序与迁移源（旧中转库）的同名表一致：迁移脚本按列名拷贝，且「迁移库 vs 新建库
-- 列序一致」有测试钉住（沿用 relay 侧 subject/format 必须留在表末的理由）。
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
  subject        TEXT,
  -- 团队收件箱（2026-10-15）：曾经在提交时把线程绑到团队账号。归属改为派生谓词
  -- 之后本列不再读也不再写，只留给"回滚到旧包"的 `feedback-rebind` 补齐（M9 处置）。
  teamAccountId  TEXT
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
  -- v4：`clientRef` 是**线程内**的幂等键（同一封信的回信重试），不再是全表唯一。
  -- 全表唯一会把"两条线程碰巧用了同一个 clientRef"变成一次错误复用（F-V4-1）。
  clientRef  TEXT,
  format     TEXT NOT NULL DEFAULT 'text'
);
CREATE INDEX IF NOT EXISTS feedbackMessagesByThread ON feedbackMessages(threadId, createdAt);
CREATE UNIQUE INDEX IF NOT EXISTS feedbackMessagesByThreadRef
  ON feedbackMessages(threadId, clientRef)
  WHERE clientRef IS NOT NULL;

CREATE TABLE IF NOT EXISTS notices (
  noticeId   TEXT PRIMARY KEY,
  subject    TEXT,
  body       TEXT NOT NULL,
  createdAt  INTEGER NOT NULL,
  createdBy  TEXT,
  format     TEXT NOT NULL DEFAULT 'text'
);

CREATE TABLE IF NOT EXISTS noticeDeliveries (
  noticeId   TEXT NOT NULL,
  accountId  TEXT NOT NULL,
  createdAt  INTEGER NOT NULL,
  readAt     INTEGER,
  PRIMARY KEY (noticeId, accountId)
);
CREATE INDEX IF NOT EXISTS noticeDeliveriesByAccount ON noticeDeliveries(accountId);

-- 信件附件（2026-11-02；v4 改为「先传后发、按 clientRef 绑定」）：只记元数据，
-- 字节在 attachments/ 目录（见 mail/attachments.py）。
--   * draftRef 是**信件级 clientRef**（同一封信的附件共用），slot 是这封信里的序号；
--     UNIQUE(draftRef, slot) 同时承担幂等（同 slot 重试）与顺序（提交按 slot 升序）。
--   * messageId 为 NULL = **未绑定的草稿**（不进任何列表）；提交时一次性写入，
--     这就是"已绑定"的唯一判据。
--   * clientRef 只留给通知侧（UNIQUE(noticeId, clientRef)）；线程附件用 draftRef + slot，
--     同一列不承载两种语义。
CREATE TABLE IF NOT EXISTS feedbackAttachments (
  attachmentId    TEXT PRIMARY KEY,
  scope           TEXT NOT NULL DEFAULT 'thread',
  draftRef        TEXT,
  slot            INTEGER,
  threadId        TEXT,
  messageId       TEXT,
  noticeId        TEXT,
  originDeviceId  TEXT,
  originAccountId TEXT,
  clientRef       TEXT,
  fileName        TEXT NOT NULL,
  contentType     TEXT NOT NULL,
  byteSize        INTEGER NOT NULL,
  sha256          TEXT NOT NULL,
  width           INTEGER,
  height          INTEGER,
  state           TEXT NOT NULL DEFAULT 'pending',
  storedPath      TEXT,
  createdAt       INTEGER NOT NULL,
  storedAt        INTEGER,
  boundAt         INTEGER
);
CREATE UNIQUE INDEX IF NOT EXISTS feedbackAttachmentsDraftSlot
  ON feedbackAttachments(draftRef, slot)
  WHERE draftRef IS NOT NULL AND slot IS NOT NULL;
CREATE INDEX IF NOT EXISTS feedbackAttachmentsByMessage
  ON feedbackAttachments(threadId, messageId, createdAt);
CREATE INDEX IF NOT EXISTS feedbackAttachmentsByNotice
  ON feedbackAttachments(noticeId, createdAt);
CREATE INDEX IF NOT EXISTS feedbackAttachmentsByState
  ON feedbackAttachments(state, createdAt);
CREATE INDEX IF NOT EXISTS feedbackAttachmentsByDraft
  ON feedbackAttachments(draftRef, state);
CREATE UNIQUE INDEX IF NOT EXISTS feedbackAttachmentsNoticeRef
  ON feedbackAttachments(noticeId, clientRef)
  WHERE noticeId IS NOT NULL AND clientRef IS NOT NULL;
"""


#: 附件行的完整字段清单：读法只有这一份（投影再按 v1/v2/CLI 各自取用）。
_ATTACHMENT_COLUMNS = ("attachmentId, scope, draftRef, slot, threadId, messageId, noticeId,"
                       " originDeviceId, originAccountId, clientRef, fileName, contentType,"
                       " byteSize, sha256, width, height, state, storedPath, createdAt,"
                       " storedAt, boundAt")
_ATTACHMENT_SELECT = f"SELECT {_ATTACHMENT_COLUMNS} FROM feedbackAttachments"


class StoreError(Exception):
    """Base class for store-level failures."""

class NotFound(StoreError):
    """The requested row does not exist."""

class Conflict(StoreError):
    """The requested write violates a uniqueness invariant."""

class EmptyLetter(StoreError):
    """正文为空且没有任何可绑定的已存附件：这不构成一封信（`400 feedback/bad-request`）。

    抛它的那次调用**不 commit**：线程/留言/绑定都不落库（"服务端不会出现空信"）。
    """


class SealedLetter(StoreError):
    """这封信已经提交过（`clientRef` 已落到线程或留言上）：不再接受新的附件草稿。

    owner 2026-11-02 的第 4 条裁定是"**提交即封口**"——已发出的信不许在重试里多出
    附件。`begin` 命中它回 409 `feedback/attachment-conflict`（免得留下只能等 7 天
    TTL 的孤儿草稿）。
    """


class QuotaExceeded(StoreError):
    """附件配额不够。`reason` 只用来让调用方挑错误码：

    `storage` → 507 `feedback/storage-full`（全库软上限），其余 → 413
    `feedback/too-large`（单封条数/单封合计/单线程合计）。
    """

    def __init__(self, reason: str):
        super().__init__(f"attachment quota exceeded: {reason}")
        self.reason = reason


def clean_feedback_subject(subject: Any) -> str | None:
    """线程主题：去首尾空白，空（或全空白）按"没填"存 NULL，超长抛 :class:`StoreError`。"""
    if subject is None:
        return None
    if not isinstance(subject, str):
        raise StoreError("subject must be a string")
    trimmed = subject.strip()
    if len(trimmed) > MAX_SUBJECT_CHARS:
        raise StoreError(f"subject may be at most {MAX_SUBJECT_CHARS} characters")
    return trimmed or None


def clean_feedback_format(value: Any) -> str:
    """正文格式：去首尾空白，空按默认 `text`，别的一律 :class:`StoreError`。"""
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


def now_ms() -> int:
    return int(time.time() * 1000)

def sha256_hex(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()

def new_id(prefix: str, nbytes: int = 9) -> str:
    return f"{prefix}_{secrets.token_hex(nbytes)}"


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
            self._conn.executescript(SCHEMA)
            self._migrate()
            self._conn.commit()
        logging.getLogger("mail.store").info("mail: store ready at %s", path)

    def _migrate(self) -> None:
        """`CREATE TABLE IF NOT EXISTS` 不会给老库补新列；按需 ALTER，幂等。

        列一律追加在表末（SQLite 的 ALTER 语义如此），与 relay 侧 subject/format
        的处理同一条约定：新建库与迁移库列序一致（有测试钉住）。
        """
        columns = {row[1] for row in self._conn.execute("PRAGMA table_info(feedbackThreads)")}
        if "teamAccountId" not in columns:
            # 老库补列（新建库由 SCHEMA 直接带上）。索引必须等列存在之后建——
            # 放在 SCHEMA 里会在老库上先炸（2026-10-15 生产实测）。
            self._conn.execute("ALTER TABLE feedbackThreads ADD COLUMN teamAccountId TEXT")
            logging.getLogger("mail.store").info("mail: added column feedbackThreads.teamAccountId")
        self._conn.execute("CREATE INDEX IF NOT EXISTS feedbackThreadsByTeam"
                           " ON feedbackThreads(teamAccountId, lastMessageAt)")

    def close(self) -> None:
        with self._lock:
            self._conn.close()

    # ── internal helpers ────────────────────────────────────────────────────

    def _row(self, sql: str, params: Iterable[Any] = ()) -> sqlite3.Row | None:
        with self._lock:
            return self._conn.execute(sql, tuple(params)).fetchone()

    def _rows(self, sql: str, params: Iterable[Any] = ()) -> list[sqlite3.Row]:
        with self._lock:
            return self._conn.execute(sql, tuple(params)).fetchall()

    # ── 线程与留言 ──────────────────────────────────────────────────────────

    def create_feedback_thread(self, *, ticket_hash: str, text: str,
                               account_id: str | None = None, device_id: str | None = None,
                               app_version: str | None = None, device_model: str | None = None,
                               system_version: str | None = None, client_ref: str | None = None,
                               subject: str | None = None, at: int | None = None,
                               limits: dict[str, int] | None = None,
                               usable: "Callable[[dict[str, Any]], bool] | None" = None
                               ) -> dict[str, Any]:
        """建一条线程，并把用户原文作为线程里的第一条留言；**同一事务内绑定附件草稿**。

        `clientRef` 同时是这封信的 `draftRef`：提交时把这一封信的已存草稿（§3.1 的
        归属谓词）一次性绑到新 `messageId`，返回 `attachmentsBound`。

        `clientRef` 命中唯一索引时**不新建**：返回既有那条（`created` 为 False），
        并把 `ticketHash` 换成这一次带来的哈希。**重试恒 0 绑定**（owner 裁定"提交即
        封口"）：已经发出的信不会在重试里多出附件，新草稿由 `begin` 的封口判据挡在
        源头（:class:`SealedLetter`）。

        **空信不可能**：正文为空（`text.strip()`）且这次一个附件都没绑上时抛
        :class:`EmptyLetter`，并且**不 commit**——线程与留言都不落库，草稿保持未绑定。
        配额不足（:class:`QuotaExceeded`）同样整笔回滚。同一个 `clientRef` 来自别的
        来源时抛 :class:`Conflict`，不把线程交出去。

        **失败路径零写入（R4）**：幂等分支里的 `ticketHash` 改写与新建分支的插入都在
        同一段 `try/except BaseException: rollback` 里——失败时未提交事务被丢弃，不会
        被后续任意一次 `commit()` 顺带提交（共享连接上尤其要紧）。
        """
        stamp = at or now_ms()
        with self._lock:
            try:
                if client_ref:
                    existing = self._feedback_row_by("clientRef", client_ref)
                    if existing is not None:
                        if not self._feedback_source_matches(existing, device_id, account_id):
                            raise Conflict(f"clientRef {client_ref} belongs to another source")
                        self._conn.execute(
                            "UPDATE feedbackThreads SET ticketHash=? WHERE threadId=?",
                            (ticket_hash, existing["threadId"]))
                        first = self._conn.execute(
                            "SELECT messageId FROM feedbackMessages WHERE threadId=?"
                            " ORDER BY createdAt, rowid LIMIT 1",
                            (existing["threadId"],)).fetchone()
                        self._conn.commit()
                        return {"threadId": existing["threadId"],
                                "createdAt": int(existing["createdAt"]),
                                "lastMessageAt": int(existing["lastMessageAt"]), "created": False,
                                "messageId": first["messageId"] if first is not None else None,
                                "attachmentsBound": 0}     # R5：重试恒 0 绑定
                thread_id = new_id("th")
                message_id = new_id("fm")
                self._conn.execute(
                    "INSERT INTO feedbackThreads(threadId, ticketHash, accountId, deviceId,"
                    " appVersion, deviceModel, systemVersion, createdAt, lastMessageAt, status,"
                    " clientRef, subject) VALUES(?,?,?,?,?,?,?,?,?,'open',?,?)",
                    (thread_id, ticket_hash, account_id, device_id, app_version, device_model,
                     system_version, stamp, stamp, client_ref,
                     clean_feedback_subject(subject)))
                self._conn.execute(
                    "INSERT INTO feedbackMessages(messageId, threadId, author, body, format,"
                    " createdAt) VALUES(?,?,'user',?,'text',?)", (message_id, thread_id, text, stamp))
                bound = 0
                if client_ref and limits is not None:
                    bound = self._bind_locked(client_ref, thread_id, message_id, limits=limits,
                                              device_id=device_id, account_id=account_id,
                                              at=stamp, usable=usable)
                if not text.strip() and bound == 0:
                    raise EmptyLetter("a letter needs text or at least one stored attachment")
            except BaseException:
                self._conn.rollback()      # 整笔回滚：不建线程、不建留言、不动草稿
                raise
            self._conn.commit()
        return {"threadId": thread_id, "createdAt": stamp, "lastMessageAt": stamp, "created": True,
                "messageId": message_id, "attachmentsBound": bound}

    def set_feedback_subject(self, thread_id: str, subject: str | None) -> bool:
        """改一条线程的主题；线程不存在返回 False。只动这一列，不碰别的。"""
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
                                at: int | None = None,
                                limits: dict[str, int] | None = None,
                                usable: "Callable[[dict[str, Any]], bool] | None" = None
                                ) -> dict[str, Any] | None:
        """线程里加一条留言并**在同一事务内绑定附件草稿**；线程不存在返回 None。

        `author='user'`（手机补充）把线程拨回 `open`，`author='owner'`（回信）置
        `replied`。`clientRef` 是**线程内**的幂等键：命中本线程的既有留言就返回它、
        不重复写，且**重试恒 0 绑定**（owner 裁定"提交即封口"，R5）。带设备时顺带补上
        匿名线程的绑定。

        **空信不可能**：正文为空且这次一个附件都没绑上时抛 :class:`EmptyLetter`，
        并且不 commit（留言不落库，草稿保持未绑定）。

        **失败路径零写入（R4）**：设备绑定、幂等查找、跨线程冲突判据、插入与绑定全在
        同一段 `try/except BaseException: rollback` 里——失败时（409/413）不会把
        `deviceId`/`accountId` 留在共享连接的未提交事务里。
        """
        cleaned_format = clean_feedback_format(format)
        stamp = at or now_ms()
        with self._lock:
            thread = self._conn.execute("SELECT * FROM feedbackThreads WHERE threadId=?",
                                        (thread_id,)).fetchone()
            if thread is None:
                return None
            try:
                if bind_device_id and thread["deviceId"] is None:
                    self._conn.execute(
                        "UPDATE feedbackThreads SET deviceId=?, accountId=? WHERE threadId=?",
                        (bind_device_id, bind_account_id, thread_id))
                if client_ref:
                    # 幂等键是**线程内**的：同一 clientRef 在别的线程里存在不是"我的重试"，
                    # 复用它会拿错 messageId（F-V4-1）。先按本线程查，再查是否在别处。
                    existing = self._conn.execute(
                        "SELECT * FROM feedbackMessages WHERE threadId=? AND clientRef=?",
                        (thread_id, client_ref)).fetchone()
                    elsewhere = self._conn.execute(
                        "SELECT threadId FROM feedbackMessages WHERE clientRef=? AND threadId<>?",
                        (client_ref, thread_id)).fetchone()
                    if existing is not None:
                        self._conn.commit()
                        return {"messageId": existing["messageId"],
                                "threadId": existing["threadId"],
                                "createdAt": int(existing["createdAt"]), "created": False,
                                "attachmentsBound": 0}     # R5：重试恒 0 绑定
                    if elsewhere is not None:
                        raise Conflict(
                            f"clientRef {client_ref} already belongs to thread "
                            f"{elsewhere['threadId']}")
                message_id = new_id("fm")
                self._conn.execute(
                    "INSERT INTO feedbackMessages(messageId, threadId, author, body, format,"
                    " createdAt, clientRef) VALUES(?,?,?,?,?,?,?)",
                    (message_id, thread_id, author, body, cleaned_format, stamp, client_ref))
                bound = 0
                if client_ref and limits is not None:
                    bound = self._bind_locked(client_ref, thread_id, message_id, limits=limits,
                                              device_id=bind_device_id,
                                              account_id=bind_account_id, at=stamp,
                                              usable=usable)
                if not body.strip() and bound == 0:
                    raise EmptyLetter("a letter needs text or at least one stored attachment")
                self._conn.execute(
                    "UPDATE feedbackThreads SET lastMessageAt=?, status=? WHERE threadId=?",
                    (stamp, "replied" if author == "owner" else "open", thread_id))
            except BaseException:
                self._conn.rollback()      # 整笔回滚：不追加留言、不动草稿、不动设备绑定
                raise
            self._conn.commit()
        return {"messageId": message_id, "threadId": thread_id, "createdAt": stamp, "created": True,
                "attachmentsBound": bound}

    def create_notice(self, body: str, subject: str | None, account_ids: Iterable[str], *,
                      format: str = DEFAULT_FEEDBACK_FORMAT,
                      created_by: str | None = None, at: int | None = None) -> dict[str, Any]:
        """发一条通知，并给每个收件账号写一行未读投递。

        收件人是**账号**；这里只去重，不核对账号是否存在——mail 没有账号表，
        账号名单的真值在中转（owner 工具负责从中转取名单再点名投递，DESIGN-20261015 I-4）。
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
                        messages_per_thread: int = 50, team: str = "",
                        caller_account: str | None = None) -> dict[str, Any] | None:
        """一条线程（最近 N 条留言 + 我这一侧未读 + 留言总数）；取不到返回 None。

        `ticket_hash` 给了就必须匹配，否则和"线程不存在"一样返回 None——不泄露
        线程是否存在。传 None 是内部/owner 路径。

        `team` / `caller_account` 决定 `mySide` 与"我这一侧"的未读；不给就是
        用户视角（owner 内部路径不需要分侧）。
        """
        row = self._row("SELECT * FROM feedbackThreads WHERE threadId=?", (thread_id,))
        if row is None:
            return None
        if ticket_hash is not None and not secrets.compare_digest(row["ticketHash"], ticket_hash):
            return None
        return self._feedback_payload(row, messages_per_thread, team=team,
                                      caller_account=caller_account)

    def visible_thread_rows(self, pairs: Iterable[tuple[str, str]] = (),
                            device_id: str | None = None, account_id: str | None = None, *,
                            team_account: str | None = None) -> list[sqlite3.Row]:
        """这次调用能看到的**全部**线程行（不带留言、不带未读）——可见性只有这一份实现。

        来源与判据（收件箱与已读共用，`feedback_threads_by_*` 只是它的两种投影）：

        1. 取件凭据：逐对按 `threadId` 取行、用 `compare_digest` 校验哈希——不把哈希
           比较交给 SQL 的字符串比较（那是把常量时间比较换成了提前返回）；
        2. 设备/账号：`deviceId` 相同，或 `accountId` 相同（重装重配靠账号找回）；
        3. 团队收件箱：`team_account` 非空**且**调用方自己就是团队账号时，再并上
           派生谓词 `USER_LETTER_SQL` 命中的线程（不是团队自己写的、也不是测试机型）。

        行按 `threadId` 去重；团队那条路径永远不会把别人的信交给非团队调用方。

        只返回**行**（不含留言、不含未读）：调用方先在这里拿到全部可见行，再切页、
        只给当页构造 payload；未读合计也覆盖全部可见行，因此角标不受窗口影响。
        每次请求取全部行的代价是 O(1) 条查询、行数受凭据上限与团队来信总量约束
        （生产实测团队账号 165 行），换来可见性只有这一份实现。
        """
        rows: dict[str, sqlite3.Row] = {}
        for thread_id, ticket_hash in pairs:
            if not thread_id or not ticket_hash or thread_id in rows:
                continue
            row = self._row("SELECT * FROM feedbackThreads WHERE threadId=?", (thread_id,))
            if row is not None and secrets.compare_digest(row["ticketHash"], ticket_hash):
                rows[thread_id] = row
        if device_id is not None:
            clauses = ["deviceId=?", "(accountId IS NOT NULL AND accountId=?)"]
            params: list[Any] = [device_id, account_id]
            if team_account and account_id == team_account:
                clauses.append(USER_LETTER_SQL)
                params.append(team_account)
            for row in self._rows(
                    f"SELECT * FROM feedbackThreads WHERE {' OR '.join(clauses)}", params):
                rows.setdefault(row["threadId"], row)
        return list(rows.values())

    def unread_counts_by_thread(self, thread_ids: Iterable[str]) -> dict[str, dict[str, int]]:
        """每个线程**两侧**各自的未读条数：`{threadId: {"user": n, "owner": m}}`。

        一次分组查询算全部线程（不按线程循环）：`reader` 由留言作者决定——我们写的
        留言算"用户侧还没读"，用户写的算"团队侧还没读"；"哪一侧是我"由调用方用
        `my_side` 去取，SQL 里不写这套规则。
        """
        ids = list(dict.fromkeys(thread_id for thread_id in thread_ids if thread_id))
        if not ids:
            return {}
        counts: dict[str, dict[str, int]] = {}
        for start in range(0, len(ids), 500):        # 参数个数上限之内分批，形状不变
            batch = ids[start:start + 500]
            marks = ",".join("?" * len(batch))
            for row in self._rows(
                    "SELECT m.threadId AS threadId, m.author AS author, COUNT(*) AS unread"
                    " FROM feedbackMessages m JOIN feedbackThreads t ON t.threadId = m.threadId"
                    f" WHERE m.threadId IN ({marks})"
                    " AND ((m.author='owner' AND (t.userReadAt IS NULL"
                    "        OR m.createdAt > t.userReadAt))"
                    "   OR (m.author='user' AND (t.ownerReadAt IS NULL"
                    "        OR m.createdAt > t.ownerReadAt)))"
                    " GROUP BY m.threadId, m.author", batch):
                reader = "owner" if row["author"] == "user" else "user"
                counts.setdefault(row["threadId"], {})[reader] = int(row["unread"])
        return counts

    def thread_payloads(self, rows: Iterable[sqlite3.Row], messages_per_thread: int = 50, *,
                        team: str = "", caller_account: str | None = None,
                        unread: dict[str, dict[str, int]] | None = None) -> list[dict[str, Any]]:
        """给这些行构造线程 payload：只给这一页取留言，未读取一次分组查询的结果。"""
        listed = list(rows)
        counts = unread if unread is not None else self.unread_counts_by_thread(
            [row["threadId"] for row in listed])
        return [self._feedback_payload(row, messages_per_thread, team=team,
                                       caller_account=caller_account,
                                       unread_counts=counts.get(row["threadId"], {}))
                for row in listed]

    def feedback_threads_by_tickets(self, pairs: Iterable[tuple[str, str]], *,
                                    messages_per_thread: int = 50, team: str = "",
                                    caller_account: str | None = None) -> list[dict[str, Any]]:
        """凭据命中的线程；对子里是 `(threadId, ticketHash)`。同一个线程只出现一次。"""
        rows = self.visible_thread_rows(pairs)
        return self.thread_payloads(rows, messages_per_thread, team=team,
                                    caller_account=caller_account)

    def feedback_threads_by_device(self, device_id: str, account_id: str | None = None, *,
                                   messages_per_thread: int = 50,
                                   team_account: str | None = None) -> list[dict[str, Any]]:
        """绑定到这台设备**或它所属账号**的线程（团队还并上来信），最近的在前。

        判据全部在 :meth:`visible_thread_rows` 里：这里只是"取全部行 → 构造 payload"，
        不复制一份可见性（团队那条路径的两半：`team_account` 非空、且调用方自己就是
        团队账号，也在那一处判）。
        """
        rows = self.visible_thread_rows((), device_id, account_id,
                                        team_account=team_account)
        rows, _more = page_thread_rows(rows, limit=None)
        return self.thread_payloads(rows, messages_per_thread, team=team_account or "",
                                    caller_account=account_id)

    def mark_thread_read(self, thread_id: str, upto_ms: int | None = None) -> bool:
        """把用户的 `userReadAt` 推到 `upto_ms`；默认推到最后一条 owner 消息。幂等只前进。"""
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

    def mark_team_thread_read(self, thread_id: str) -> bool:
        """团队侧已读：`ownerReadAt` 推到最后一条**用户**留言（只前进，幂等）。

        与 :meth:`mark_thread_read` 镜像：那边是用户读我们的回信，这边是我们读
        用户的来信。线程不存在返回 False。
        """
        with self._lock:
            row = self._conn.execute("SELECT ownerReadAt FROM feedbackThreads WHERE threadId=?",
                                     (thread_id,)).fetchone()
            if row is None:
                return False
            latest = self._conn.execute(
                "SELECT MAX(createdAt) FROM feedbackMessages WHERE threadId=? AND author='user'",
                (thread_id,)).fetchone()[0]
            stamp = int(latest) if latest is not None else None
            if stamp is not None and (row["ownerReadAt"] is None or stamp > int(row["ownerReadAt"])):
                self._conn.execute("UPDATE feedbackThreads SET ownerReadAt=? WHERE threadId=?",
                                   (stamp, thread_id))
            self._conn.commit()
        return True

    #: 通知的字段投影：详情与列表只差"要不要正文"（同一份行、同一份读法）。
    _NOTICE_SELECT = ("SELECT n.noticeId AS noticeId, n.subject AS subject, n.body AS body,"
                      " n.format AS format, n.createdAt AS createdAt, n.createdBy AS createdBy,"
                      " d.readAt AS readAt"
                      " FROM notices n JOIN noticeDeliveries d ON d.noticeId = n.noticeId")

    def notices_for_account(self, account_id: str, *, limit: int = 200,
                            before: dict[str, Any] | None = None) -> list[dict[str, Any]]:
        """投给这个账号的通知，最近的在前；`read` 是**账号级**已读。

        默认 200 条是 v1 投影的窗口；v2 用 :meth:`notice_page` 翻页。
        """
        return self.notice_page(account_id, limit=limit, before=before)[0]

    def notice_page(self, account_id: str, *, limit: int,
                    before: dict[str, Any] | None = None
                    ) -> tuple[list[dict[str, Any]], bool]:
        """一页通知与 `more`；排序 `(createdAt DESC, noticeId DESC)`。"""
        cursor, params = _before_clause("n.createdAt", "n.noticeId", before,
                                        "createdAt", "noticeId")
        rows = self._rows(self._NOTICE_SELECT + " WHERE d.accountId=?" + cursor
                          + " ORDER BY n.createdAt DESC, n.noticeId DESC LIMIT ?",
                          [account_id, *params, int(limit) + 1])
        page, more = take_page(rows, int(limit))
        payloads = [{**dict(row), "read": row["readAt"] is not None} for row in page]
        return self._with_notice_attachments(payloads), more

    def notice_for_account(self, account_id: str, notice_id: str) -> dict[str, Any] | None:
        """某条通知的全文——**只按 (accountId, noticeId) 授权**，没这条投递返回 None。

        详情是正文的唯一所有者：列表只给摘要，正文在这里按需取（P1-4）。
        """
        row = self._row(self._NOTICE_SELECT + " WHERE d.accountId=? AND n.noticeId=?",
                        (account_id, notice_id))
        if row is None:
            return None
        payload = {**dict(row), "read": row["readAt"] is not None}
        return self._with_notice_attachments([payload])[0]

    def _with_notice_attachments(self, notices: list[dict[str, Any]]) -> list[dict[str, Any]]:
        """给这一页通知各挂上它**已存**的附件（一次分组查询，不按条循环）。

        v1 投影不读这个键，v2 与 `/feedback/notice` 读它——同一份事实，两种投影。
        """
        ids = [notice["noticeId"] for notice in notices]
        if not ids:
            return notices
        grouped = self.attachments_for_notices(ids)
        for notice in notices:
            notice["attachments"] = grouped.get(notice["noticeId"], [])
        return notices

    def unread_notice_count(self, account_id: str) -> int:
        """这个账号还没读的通知数——与任何窗口无关（角标不再随 200 条截断）。"""
        return int(self._row(
            "SELECT COUNT(*) AS n FROM noticeDeliveries WHERE accountId=? AND readAt IS NULL",
            (account_id,))["n"])

    def notice_delivery_stats(self, notice_id: str) -> dict[str, Any] | None:
        """某次群发的覆盖与已读：`delivered` / `read` / `unread`（只读，事后核对用）。"""
        row = self._row("SELECT noticeId, subject FROM notices WHERE noticeId=?", (notice_id,))
        if row is None:
            return None
        counts = self._row(
            "SELECT COUNT(*) AS delivered,"
            " COUNT(CASE WHEN readAt IS NOT NULL THEN 1 END) AS read FROM noticeDeliveries"
            " WHERE noticeId=?", (notice_id,))
        delivered = int(counts["delivered"])
        read = int(counts["read"])
        return {"noticeId": row["noticeId"], "subject": row["subject"],
                "delivered": delivered, "read": read, "unread": delivered - read}

    def mark_notices_read(self, account_id: str, notice_ids: Iterable[str],
                          at: int | None = None) -> int:
        """把这个账号的这几条通知投递行标已读；返回被改的行数（幂等、只前进）。"""
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

    def owner_unread_counts(self, team: str = "") -> dict[str, int]:
        """owner 还没看过的**用户来信**数，按线程。清单里标"新"用。

        只统计命中谓词的线程：团队自己的提交与测试机型（验收单）不再在清单里留一条
        永远清不掉的未读（P2-7 那条 `th_c98c7e26…` 的形状）。
        """
        rows = self._rows(
            "SELECT m.threadId AS threadId, COUNT(*) AS unread FROM feedbackMessages m"
            " JOIN feedbackThreads t ON t.threadId = m.threadId"
            " WHERE m.author='user' AND (t.ownerReadAt IS NULL OR m.createdAt > t.ownerReadAt)"
            f" AND {USER_LETTER_SQL_T}"
            " GROUP BY m.threadId", (team,))
        return {row["threadId"]: int(row["unread"]) for row in rows}

    def rebind_team_account(self, team: str, *, dry_run: bool = False) -> dict[str, Any]:
        """把旧的 `teamAccountId` 列按谓词补写一遍（**只**为回滚到旧包准备）。

        M1 之后本列不再读也不再写；旧包仍按它判断团队命中，所以回滚前必须补齐，
        否则旧包看不到停写之后收到的信。`dry_run` 只报数、不写库。
        """
        to_bind = [row["threadId"] for row in self._rows(
            f"SELECT threadId, teamAccountId FROM feedbackThreads WHERE {USER_LETTER_SQL}"
            " AND (teamAccountId IS NULL OR teamAccountId <> ?)", (team, team))]
        to_clear = [row["threadId"] for row in self._rows(
            f"SELECT threadId FROM feedbackThreads WHERE NOT {USER_LETTER_SQL}"
            " AND teamAccountId IS NOT NULL", (team,))]
        if not dry_run:
            with self._lock:
                self._conn.executemany(
                    "UPDATE feedbackThreads SET teamAccountId=? WHERE threadId=?",
                    [(team, thread_id) for thread_id in to_bind])
                self._conn.executemany(
                    "UPDATE feedbackThreads SET teamAccountId=NULL WHERE threadId=?",
                    [(thread_id,) for thread_id in to_clear])
                self._conn.commit()
        return {"team": team, "bound": len(to_bind), "cleared": len(to_clear),
                "dryRun": bool(dry_run)}

    def touch_owner_read(self, thread_id: str, at: int | None = None) -> bool:
        """记下 owner 读过这条线程；线程不存在返回 False。"""
        with self._lock:
            cursor = self._conn.execute("UPDATE feedbackThreads SET ownerReadAt=? WHERE threadId=?",
                                        (at or now_ms(), thread_id))
            self._conn.commit()
            return bool(cursor.rowcount)

    def list_feedback_threads(self, *, status: str | None = None, since_ms: int | None = None,
                              limit: int = 50, messages_per_thread: int = 0,
                              team: str = "") -> list[dict[str, Any]]:
        """owner 清单：按最近活动倒序的线程。默认不带留言——清单只要摘要。

        `team` 让每一行带上 `userLetter`（管理清单的 `--scope user|test` 直接用它，
        不另写一份"这是不是来信"的判定）。
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
            f"SELECT * FROM feedbackThreads{where}"
            " ORDER BY lastMessageAt DESC, threadId DESC LIMIT ?", params)
        return self.thread_payloads(rows, messages_per_thread, team=team)

    def delete_feedback_thread(self, thread_id: str) -> dict[str, Any]:
        """连线程、留言与**附件行**一起删；返回删掉的留言数与字节路径。

        字节本身不在这里删：存储层不认识磁盘布局（见 :mod:`attachments`），所以把
        `storedPath` 交回调用方，由它逐个 `unlink`。返回值形状：
        `{"messages": n, "attachmentPaths": [...]}`。
        """
        with self._lock:
            if self._conn.execute("SELECT threadId FROM feedbackThreads WHERE threadId=?",
                                  (thread_id,)).fetchone() is None:
                raise NotFound(f"feedback thread {thread_id} does not exist")
            paths = [row["storedPath"] for row in self._conn.execute(
                "SELECT storedPath FROM feedbackAttachments"
                " WHERE threadId=? AND storedPath IS NOT NULL", (thread_id,))]
            self._conn.execute("DELETE FROM feedbackAttachments WHERE threadId=?", (thread_id,))
            cursor = self._conn.execute("DELETE FROM feedbackMessages WHERE threadId=?", (thread_id,))
            self._conn.execute("DELETE FROM feedbackThreads WHERE threadId=?", (thread_id,))
            self._conn.commit()
            return {"messages": cursor.rowcount or 0, "attachmentPaths": paths}

    def feedback_digest(self, thread_ids: Iterable[str], *, excerpt_chars: int = 80
                        ) -> dict[str, dict[str, Any]]:
        """每条线程的**首条**留言摘要、主题、格式与**首条** owner 回信时间；只读。"""
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

    # ── 信件附件（v4：先传后发，按 clientRef 绑定）────────────────────────────
    #
    # 字节不在这里：本模块只管行。配额、幂等、状态迁移、绑定都只有这一份实现，
    # handler 不重算（"一个事实一个所有者"）。
    #
    #   草稿   = messageId IS NULL 的行（不进任何列表；7 天后由清扫回收）
    #   已绑定 = messageId 非空（提交时一次性写入；这是"已绑定"的唯一判据）

    def begin_attachment(self, *, draft_ref: str | None = None, slot: int | None = None,
                         file_name: str, content_type: str, byte_size: int, sha256: str,
                         limits: dict[str, int], thread_id: str | None = None,
                         notice_id: str | None = None, client_ref: str | None = None,
                         origin_device_id: str | None = None,
                         origin_account_id: str | None = None,
                         width: int | None = None, height: int | None = None,
                         at: int | None = None) -> dict[str, Any]:
        """登记一条 **pending** 附件（草稿）；幂等键是 `(draftRef, slot)`。

        - 同一 `(draftRef, slot)` 且 sha256/byteSize/contentType 一致 → 返回既有行
          （`created=False`）；不一致 → :class:`Conflict`（同一个 slot 不许换文件）。
        - 配额按 `draftRef` 归集（条数 → 合计），回信草稿再判单线程合计，最后判全库
          软上限；超了抛 :class:`QuotaExceeded`（`reason` 让调用方选 413/507）。
        """
        scope = "thread" if notice_id is None else "notice"
        stamp = at or now_ms()
        with self._lock:
            if draft_ref is not None and self._client_ref_committed(draft_ref):
                # 这封信已经提交过：不再接受新草稿（owner 裁定"提交即封口"，R5）。
                # 挡在源头，免得留下只能等 7 天 TTL 的孤儿草稿。
                raise SealedLetter(f"clientRef {draft_ref} has already been sent")
            if notice_id is not None and client_ref:
                existing = self._conn.execute(
                    f"{_ATTACHMENT_SELECT} WHERE noticeId=? AND clientRef=?",
                    (notice_id, client_ref)).fetchone()
                if existing is not None:
                    return {**dict(existing), "created": False}
            if draft_ref is not None and slot is not None:
                existing = self._conn.execute(
                    f"{_ATTACHMENT_SELECT} WHERE draftRef=? AND slot=?",
                    (draft_ref, slot)).fetchone()
                if existing is not None:
                    # 别人的 slot 不是"我的幂等命中"：一律冲突，且**不回显**任何字段
                    # （attachmentId / sha256 / byteSize 都不给，F-V4-3）。
                    if not self._draft_owned_by(existing, thread_id, origin_device_id,
                                                origin_account_id):
                        raise Conflict(
                            f"slot {slot} of draft {draft_ref} is taken by another letter")
                    same = (existing["sha256"] == sha256
                            and int(existing["byteSize"]) == int(byte_size)
                            and existing["contentType"] == content_type)
                    if not same:
                        raise Conflict(
                            f"slot {slot} of draft {draft_ref} already holds another file")
                    return {**dict(existing), "created": False}
            if draft_ref is not None:
                stats = self._row(
                    "SELECT COUNT(*) AS n, COALESCE(SUM(byteSize), 0) AS bytes"
                    " FROM feedbackAttachments"
                    " WHERE draftRef=? AND state <> 'lost'", (draft_ref,))
                if int(stats["n"]) >= int(limits["maxPerMessage"]):
                    raise QuotaExceeded("count")
                if int(stats["bytes"]) + int(byte_size) > int(limits["maxTotalBytes"]):
                    raise QuotaExceeded("message-bytes")
            if thread_id and self._attachment_bytes("threadId", thread_id) + int(byte_size) \
                    > int(limits["maxPerThreadBytes"]):
                raise QuotaExceeded("thread-bytes")
            if self.attachment_bytes_total() + int(byte_size) > int(limits["storageSoftBytes"]):
                raise QuotaExceeded("storage")
            attachment_id = new_id("fa")
            self._conn.execute(
                "INSERT INTO feedbackAttachments(attachmentId, scope, draftRef, slot, threadId,"
                " noticeId, originDeviceId, originAccountId, clientRef, fileName, contentType,"
                " byteSize, sha256, width, height, state, createdAt)"
                " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'pending',?)",
                (attachment_id, scope, draft_ref, slot, thread_id, notice_id,
                 origin_device_id, origin_account_id, client_ref, file_name, content_type,
                 int(byte_size), sha256, width, height, stamp))
            self._conn.commit()
            row = self._conn.execute(
                f"{_ATTACHMENT_SELECT} WHERE attachmentId=?", (attachment_id,)).fetchone()
        return {**dict(row), "created": True}

    def bind_draft_attachments(self, draft_ref: str, thread_id: str, message_id: str, *,
                               limits: dict[str, int], device_id: str | None = None,
                               account_id: str | None = None,
                               at: int | None = None,
                               usable: "Callable[[dict[str, Any]], bool] | None" = None) -> int:
        """把这一封信的已存草稿一次性绑到 `message_id`；返回绑定条数（幂等：第二次 0）。

        归属谓词（§3.1，**唯一实现**）：
        - 新信草稿：`threadId IS NULL` 且 origin 是本设备/本账号；
        - 回信草稿：`threadId` 就是这次要追加的线程。
        只动 `messageId IS NULL AND state='stored'`；绑定前在同一把锁里复核单封条数与
        合计、单线程合计（超了抛 :class:`QuotaExceeded`，一行都不绑）。**绑定不改
        `state` / `sha256`**。
        """
        with self._lock:
            bound = self._bind_locked(draft_ref, thread_id, message_id, limits=limits,
                                      device_id=device_id, account_id=account_id,
                                      at=at or now_ms(), usable=usable)
            self._conn.commit()
            return bound

    def _bind_locked(self, draft_ref: str, thread_id: str, message_id: str, *,
                     limits: dict[str, int], device_id: str | None,
                     account_id: str | None, at: int,
                     usable: "Callable[[dict[str, Any]], bool] | None" = None) -> int:
        """`bind_draft_attachments` 的事务内版本（调用方已持锁，不 commit）。

        两件前置事实：
        1. `message_id` 必须真的属于 `thread_id`：不属于就按冲突处理（一行都不绑），
           绝不把附件挂到别的线程的留言上（F-V4-1 第 2 条）。
        2. `usable(row)` 由调用方注入（只有 api 知道附件根）：返回 False 的行（文件不在
           或大小与登记不符）**不得被绑定**——按 `lost` 处理，不计入绑定数。
        """
        owner = self._conn.execute(
            "SELECT threadId FROM feedbackMessages WHERE messageId=?", (message_id,)).fetchone()
        if owner is None or owner["threadId"] != thread_id:
            raise Conflict(f"message {message_id} does not belong to thread {thread_id}")
        candidates = [dict(row) for row in self._conn.execute(
            _ATTACHMENT_SELECT +
            " WHERE draftRef=? AND messageId IS NULL AND state='stored'"
            " AND ( (threadId IS NULL AND (originDeviceId=?"
            "        OR (originAccountId IS NOT NULL AND originAccountId=?)))"
            "       OR threadId=?)"
            " ORDER BY slot, createdAt",
            (draft_ref, device_id, account_id, thread_id))]
        if not candidates:
            return 0
        if usable is not None:
            unusable = [row["attachmentId"] for row in candidates if not usable(row)]
            if unusable:
                self._conn.executemany(
                    "UPDATE feedbackAttachments SET state='lost' WHERE attachmentId=?"
                    " AND state='stored'", [(row_id,) for row_id in unusable])
                candidates = [row for row in candidates
                              if row["attachmentId"] not in set(unusable)]
            if not candidates:
                return 0
        existing_bound = self._row(
            "SELECT COUNT(*) AS n, COALESCE(SUM(byteSize), 0) AS bytes"
            " FROM feedbackAttachments WHERE messageId=? AND state <> 'lost'", (message_id,))
        candidate_bytes = sum(int(row["byteSize"]) for row in candidates)
        if int(existing_bound["n"]) + len(candidates) > int(limits["maxPerMessage"]):
            raise QuotaExceeded("count")
        if int(existing_bound["bytes"]) + candidate_bytes > int(limits["maxTotalBytes"]):
            raise QuotaExceeded("message-bytes")
        # 线程合计：草稿行若已经挂在回信线程上，它已经被 `threadId` 统计过，先扣掉。
        thread_bytes = self._conn.execute(
            "SELECT COALESCE(SUM(byteSize), 0) AS bytes FROM feedbackAttachments"
            " WHERE threadId=? AND state <> 'lost' AND NOT (messageId IS NULL AND draftRef=?)",
            (thread_id, draft_ref)).fetchone()["bytes"]
        if int(thread_bytes) + candidate_bytes > int(limits["maxPerThreadBytes"]):
            raise QuotaExceeded("thread-bytes")
        self._conn.executemany(
            "UPDATE feedbackAttachments SET threadId=?, messageId=?, boundAt=?"
            " WHERE attachmentId=? AND messageId IS NULL",
            [(thread_id, message_id, at, row["attachmentId"]) for row in candidates])
        return len(candidates)

    def _client_ref_committed(self, client_ref: str) -> bool:
        """这个 `clientRef` 是否已经落成一封信（线程或留言上出现过）——封口的判据。"""
        row = self._row(
            "SELECT 1 AS hit FROM feedbackThreads WHERE clientRef=?"
            " UNION ALL SELECT 1 AS hit FROM feedbackMessages WHERE clientRef=? LIMIT 1",
            (client_ref, client_ref))
        return row is not None

    @staticmethod
    def _draft_owned_by(row: dict[str, Any], thread_id: str | None,
                        device_id: str | None, account_id: str | None) -> bool:
        """这一行草稿是不是这次调用方的：回复草稿看线程，新信草稿看 origin 设备/账号。"""
        if row["threadId"] is not None or thread_id is not None:
            return row["threadId"] == thread_id
        if device_id and row["originDeviceId"] == device_id:
            return True
        return bool(account_id) and row["originAccountId"] == account_id

    def mark_attachment_stored(self, attachment_id: str, stored_path: str,
                               stored_at: int | None = None) -> bool:
        """`pending` → `stored`（字节已经落盘）；已经不是 pending 返回 False。"""
        with self._lock:
            cursor = self._conn.execute(
                "UPDATE feedbackAttachments SET state='stored', storedPath=?, storedAt=?"
                " WHERE attachmentId=? AND state='pending'",
                (stored_path, int(stored_at if stored_at is not None else now_ms()),
                 attachment_id))
            self._conn.commit()
            return bool(cursor.rowcount)

    def mark_attachments_lost(self, attachment_ids: Iterable[str]) -> int:
        """把"行在、文件没了/坏了"的行标成 `lost`（清扫用）；返回被标了几行。"""
        ids = list(dict.fromkeys(attachment_id for attachment_id in attachment_ids
                                 if attachment_id))
        if not ids:
            return 0
        marks = ",".join("?" * len(ids))
        with self._lock:
            cursor = self._conn.execute(
                f"UPDATE feedbackAttachments SET state='lost'"
                f" WHERE state='stored' AND attachmentId IN ({marks})", ids)
            self._conn.commit()
            return cursor.rowcount or 0

    def attachment(self, attachment_id: str) -> dict[str, Any] | None:
        """一条附件行（任何状态）；不存在返回 None。"""
        row = self._row(f"{_ATTACHMENT_SELECT} WHERE attachmentId=?", (attachment_id,))
        return None if row is None else dict(row)

    def feedback_message(self, message_id: str) -> dict[str, Any] | None:
        """一条留言行；附件要核"这条留言属于这条线程"时用。"""
        row = self._row("SELECT * FROM feedbackMessages WHERE messageId=?", (message_id,))
        return None if row is None else dict(row)

    def attachments_for_messages(self, message_ids: Iterable[str], *,
                                 states: tuple[str, ...] | None = ("stored",)
                                 ) -> dict[str, list[dict[str, Any]]]:
        """按留言分组取附件（只会有已绑定的行：`messageId IN (...)` 天然排除草稿）。

        排序是 `slot` 升序（没有 slot 的行——通知侧——退回 `createdAt`）：这就是
        "附件在信里的顺序"，客户端不再自己排。
        """
        ids = list(dict.fromkeys(value for value in message_ids if value))
        return self._grouped_attachments("messageId", ids, states)

    def attachments_for_notices(self, notice_ids: Iterable[str], *,
                                states: tuple[str, ...] | None = ("stored",)
                                ) -> dict[str, list[dict[str, Any]]]:
        ids = list(dict.fromkeys(value for value in notice_ids if value))
        return self._grouped_attachments("noticeId", ids, states)

    def attachments_for_notice(self, notice_id: str, *,
                               states: tuple[str, ...] | None = ("stored",)
                               ) -> list[dict[str, Any]]:
        return self.attachments_for_notices([notice_id], states=states).get(notice_id, [])

    def _grouped_attachments(self, column: str, ids: list[str],
                             states: tuple[str, ...] | None) -> dict[str, list[dict[str, Any]]]:
        """`column` 只由本模块的字面量给出（`messageId` / `noticeId`），不是用户输入。"""
        grouped: dict[str, list[dict[str, Any]]] = {}
        if not ids:
            return grouped
        for start in range(0, len(ids), 500):        # 参数个数上限之内分批，形状不变
            batch = ids[start:start + 500]
            marks = ",".join("?" * len(batch))
            sql = f"{_ATTACHMENT_SELECT} WHERE {column} IN ({marks})"
            params: list[Any] = list(batch)
            if states:
                sql += f" AND state IN ({','.join('?' * len(states))})"
                params.extend(states)
            sql += " ORDER BY COALESCE(slot, 2147483647), createdAt, attachmentId"
            for row in self._rows(sql, params):
                grouped.setdefault(row[column], []).append(dict(row))
        return grouped

    def attachment_bytes_total(self) -> int:
        """全库附件字节（不含 lost，**含未提交草稿**）——软上限的判据。"""
        return self._attachment_bytes(None)

    def thread_attachment_bytes(self, thread_id: str) -> int:
        """一条线程的附件字节（不含 lost；回信草稿已经挂在线上，计在内）。"""
        return self._attachment_bytes("threadId", thread_id)

    def draft_attachment_bytes(self, draft_ref: str) -> int:
        """一封信（`draftRef`）的草稿字节（不含 lost）——配额与展示共用。"""
        return self._attachment_bytes("draftRef", draft_ref)

    def _attachment_bytes(self, column: str | None, value: str | None = None) -> int:
        sql = ("SELECT COALESCE(SUM(byteSize), 0) AS bytes FROM feedbackAttachments"
               " WHERE state <> 'lost'")
        params: list[Any] = []
        if column:
            sql += f" AND {column}=?"
            params.append(value)
        return int(self._row(sql, params)["bytes"])

    def message_attachment_stats(self, message_id: str) -> dict[str, int]:
        """一条留言的附件条数与字节（不含 lost）；配额判定与展示共用。"""
        row = self._row(
            "SELECT COUNT(*) AS n, COALESCE(SUM(byteSize), 0) AS bytes"
            " FROM feedbackAttachments WHERE messageId=? AND state <> 'lost'", (message_id,))
        return {"count": int(row["n"]), "bytes": int(row["bytes"])}

    def attachment_counts_by_thread(self, thread_ids: Iterable[str]) -> dict[str, int]:
        """每条线程**已绑定且已存**的附件条数（清单里的回形针计数；草稿不算）。"""
        ids = list(dict.fromkeys(value for value in thread_ids if value))
        if not ids:
            return {}
        marks = ",".join("?" * len(ids))
        rows = self._rows(
            f"SELECT threadId, COUNT(*) AS n FROM feedbackAttachments"
            f" WHERE state='stored' AND messageId IS NOT NULL AND threadId IN ({marks})"
            f" GROUP BY threadId", ids)
        return {row["threadId"]: int(row["n"]) for row in rows}

    def expire_pending_attachments(self, older_than_ms: int) -> int:
        """删掉过期的 `pending` 行（上传中断留下的空记录，没有字节）；返回删了几行。"""
        with self._lock:
            cursor = self._conn.execute(
                "DELETE FROM feedbackAttachments WHERE state='pending' AND createdAt < ?",
                (int(older_than_ms),))
            self._conn.commit()
            return cursor.rowcount or 0

    def expire_draft_attachments(self, older_than_ms: int) -> list[str]:
        """删掉过期的**已存草稿**（`messageId IS NULL`），返回它们的 `storedPath`。

        字节由调用方删（存储层不认识磁盘布局）。已绑定的行永远不动。
        """
        with self._lock:
            rows = self._conn.execute(
                "SELECT attachmentId, storedPath FROM feedbackAttachments"
                " WHERE messageId IS NULL AND state='stored' AND createdAt < ?",
                (int(older_than_ms),)).fetchall()
            if not rows:
                return []
            self._conn.execute(
                "DELETE FROM feedbackAttachments"
                " WHERE messageId IS NULL AND state='stored' AND createdAt < ?",
                (int(older_than_ms),))
            self._conn.commit()
            return [row["storedPath"] for row in rows if row["storedPath"]]

    def delete_attachment(self, attachment_id: str) -> str | None:
        """删一行附件并返回它的 `storedPath`（`discard` 用；字节由调用方删）。

        只允许删**草稿**：已绑定的行由调用方先判并把 409 交给客户端，这里返回 None
        表示"没有可删的草稿行"。
        """
        with self._lock:
            row = self._conn.execute(
                f"{_ATTACHMENT_SELECT} WHERE attachmentId=? AND messageId IS NULL",
                (attachment_id,)).fetchone()
            if row is None:
                return None
            self._conn.execute(
                "DELETE FROM feedbackAttachments WHERE attachmentId=? AND messageId IS NULL",
                (attachment_id,))
            self._conn.commit()
            return row["storedPath"] or ""

    def child_attachment_paths(self, thread_id: str) -> list[str]:
        """一条线程里已经落盘的字节路径（删线程前取，交给调用方删文件）。"""
        return [row["storedPath"] for row in self._rows(
            "SELECT storedPath FROM feedbackAttachments"
            " WHERE threadId=? AND storedPath IS NOT NULL", (thread_id,))]

    def list_attachments(self, *, state: str | None = None, limit: int = 100,
                         offset: int = 0) -> list[dict[str, Any]]:
        """按登记顺序列附件行（清扫与 owner 统计用）；`state` 过滤是可选的一层。

        `offset` 给清扫翻页用（F4）：清扫要拿到**全部**已存行，不能只取一页。
        """
        sql = _ATTACHMENT_SELECT
        params: list[Any] = []
        if state:
            sql += " WHERE state=?"
            params.append(state)
        sql += " ORDER BY createdAt, attachmentId LIMIT ? OFFSET ?"
        params.extend([int(limit), int(offset)])
        return [dict(row) for row in self._rows(sql, params)]

    def _feedback_row_by(self, column: str, value: str) -> sqlite3.Row | None:
        """按线程表上的**固定列名**取一行；列名只由本模块的字面量给出，不是用户输入。"""
        return self._row(f"SELECT * FROM feedbackThreads WHERE {column}=?", (value,))

    @staticmethod
    def _feedback_source_matches(row: sqlite3.Row, device_id: str | None,
                                 account_id: str | None) -> bool:
        """这次提交是不是这条线程原来的来源（幂等重试的判据）。"""
        if row["deviceId"] is None and row["accountId"] is None:
            return True
        if device_id and row["deviceId"] == device_id:
            return True
        return bool(account_id) and row["accountId"] == account_id

    def _feedback_payload(self, row: sqlite3.Row, messages_per_thread: int = 50, *,
                          team: str = "", caller_account: str | None = None,
                          unread_counts: dict[str, int] | None = None) -> dict[str, Any]:
        """一行线程（含 `subject`，可为 None）+ 最近 N 条留言（按时间升序）
        + **两个原始未读计数** + 留言总数 + `mySide`。

        这里只产出事实、不产出投影：`ownerUnread` = 我们写的留言里用户还没读的条数
        （旧 wire 的 `unread`），`userUnread` = 用户写的留言里我们还没读的条数
        （旧 wire 的 `teamUnread`）。两个数来自同一次分组查询，不额外查库。

        `mySide` / `callerIsTeam` / `userLetter` 也在这里定（谓词 + 调用方身份）：
        v2 用 `mySide` 取"我这一侧"，v1 用它们把团队自有信的 `teamUnread` 归零
        （P0-2 的修复），但**不改变** v1 那两个字段的原始语义。
        """
        thread_id = row["threadId"]
        messages: list[dict[str, Any]] = []
        if messages_per_thread > 0:
            recent = self._rows(
                "SELECT * FROM feedbackMessages WHERE threadId=?"
                " ORDER BY createdAt DESC, rowid DESC LIMIT ?",
                (thread_id, int(messages_per_thread)))
            messages = [dict(message) for message in reversed(recent)]
            grouped = self.attachments_for_messages(
                [message["messageId"] for message in messages], states=None)
            for message in messages:
                message["attachments"] = grouped.get(message["messageId"], [])
        counts = unread_counts if unread_counts is not None \
            else self.unread_counts_by_thread([thread_id]).get(thread_id, {})
        count = self._row("SELECT COUNT(*) AS n FROM feedbackMessages WHERE threadId=?", (thread_id,))
        user_letter = is_user_letter(row["accountId"], row["deviceModel"], team)
        caller_is_team = bool(team) and caller_account == team
        return {**dict(row), "messages": messages, "messageCount": int(count["n"]),
                # 两个原始计数：authors 与读者的对应关系只有这一处声明。
                "ownerUnread": my_unread(counts, "user"),
                "userUnread": my_unread(counts, "owner"),
                "mySide": my_side(user_letter, caller_is_team),
                "callerIsTeam": caller_is_team, "userLetter": user_letter}
