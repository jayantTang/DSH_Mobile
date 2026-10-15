"""mail 服务的存储：信件 4 张表与全部读写方法。

从 relay/store.py 抽出（DESIGN-20261015 M2，双轨期复制不删除）。与中转的差异：

- 只有 feedbackThreads / feedbackMessages / notices / noticeDeliveries 四张表，
  没有账号/设备/配对/用量——那些归中转，mail 只按值引用 accountId/deviceId
  （不透明字符串，等值比较，无外键、不复制）。
- 没有版本化迁移：这是新服务的新库；生产数据由 M3 的迁移脚本从中转
  state.db 按列拷入，列序与本文件的建表语句逐列一致（有测试钉住）。
- 方法体与 relay/store.py 的同名方法保持逐字一致（只改 docstring 里的指代），
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
from typing import Any, Iterable

MAX_SUBJECT_CHARS = 80
FEEDBACK_FORMATS = ("text", "html")

#: 测试台来源的机型（团队收件箱的过滤口径，与 relay/admin.py 同一份名单）：
#: 这些来源的提交是验收单，不是用户来信，不进团队收件箱。
TEST_DEVICE_MODELS = {"arm64", "x86_64", "deploy-check", "Node", "simulator", "test-harness"}
DEFAULT_FEEDBACK_FORMAT = "text"

SCHEMA = """
-- 列序与 relay/store.py 的同名表一致：迁移脚本按列名拷贝，且「迁移库 vs 新建库
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
  -- 团队收件箱（2026-10-15）：非团队提交的线程都绑到团队账号，团队（= owner 的
  -- 开发者账号）由此在自己的收件箱里看到用户来信并直接回信。同样留在表末。
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
  clientRef  TEXT UNIQUE,
  format     TEXT NOT NULL DEFAULT 'text'
);
CREATE INDEX IF NOT EXISTS feedbackMessagesByThread ON feedbackMessages(threadId, createdAt);

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
"""


class StoreError(Exception):
    """Base class for store-level failures."""

class NotFound(StoreError):
    """The requested row does not exist."""

class Conflict(StoreError):
    """The requested write violates a uniqueness invariant."""


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
                               subject: str | None = None, team_account_id: str | None = None,
                               at: int | None = None) -> dict[str, Any]:
        """建一条线程，并把用户原文作为线程里的第一条留言。

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
                " deviceModel, systemVersion, createdAt, lastMessageAt, status, clientRef, subject,"
                " teamAccountId) VALUES(?,?,?,?,?,?,?,?,?,'open',?,?,?)",
                (thread_id, ticket_hash, account_id, device_id, app_version, device_model,
                 system_version, stamp, stamp, client_ref, clean_feedback_subject(subject),
                 team_account_id))
            self._conn.execute(
                "INSERT INTO feedbackMessages(messageId, threadId, author, body, format, createdAt)"
                " VALUES(?,?,'user',?,'text',?)", (new_id("fm"), thread_id, text, stamp))
            self._conn.commit()
        return {"threadId": thread_id, "createdAt": stamp, "lastMessageAt": stamp, "created": True}

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
                                at: int | None = None) -> dict[str, Any] | None:
        """线程里加一条留言；线程不存在返回 None。

        `author='user'`（手机补充）把线程拨回 `open`，`author='owner'`（回信）置
        `replied`。`clientRef` 命中唯一索引时返回既有那条、不重复写。带设备时顺带
        补上匿名线程的绑定：匿名提交后来配对了，这台设备也能找回来。
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
                        messages_per_thread: int = 50) -> dict[str, Any] | None:
        """一条线程（最近 N 条留言 + 用户侧未读 + 留言总数）；取不到返回 None。

        `ticket_hash` 给了就必须匹配，否则和"线程不存在"一样返回 None——不泄露
        线程是否存在。传 None 是内部/owner 路径。
        """
        row = self._row("SELECT * FROM feedbackThreads WHERE threadId=?", (thread_id,))
        if row is None:
            return None
        if ticket_hash is not None and not secrets.compare_digest(row["ticketHash"], ticket_hash):
            return None
        return self._feedback_payload(row, messages_per_thread)

    def feedback_threads_by_tickets(self, pairs: Iterable[tuple[str, str]], *,
                                    messages_per_thread: int = 50) -> list[dict[str, Any]]:
        """凭据命中的线程；对子里是 `(threadId, ticketHash)`。同一个线程只出现一次。"""
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
        "重装后重新配对即可找回"靠的就是这一条。
        """
        # 团队绑定（teamAccountId）是第三条命中路径：团队账号由此看到用户的来信
        # （2026-10-15 团队收件箱）。用户自己的可见性不受影响——teamAccountId 只会
        # 等于团队账号，不会撞上普通用户的账号。
        rows = self._rows(
            "SELECT * FROM feedbackThreads WHERE deviceId=?"
            " OR (accountId IS NOT NULL AND accountId=?)"
            " OR (teamAccountId IS NOT NULL AND teamAccountId=?)"
            " ORDER BY lastMessageAt DESC",
            (device_id, account_id, account_id))
        return [self._feedback_payload(row, messages_per_thread) for row in rows]

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

    def notices_for_account(self, account_id: str, *, limit: int = 200) -> list[dict[str, Any]]:
        """投给这个账号的通知，最近的在前；`read` 是**账号级**已读。"""
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
        """owner 清单：按最近活动倒序的线程。默认不带留言——清单只要摘要。"""
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
        """连线程带它的留言一起删（响应隐私删除请求）；返回删掉的留言数。"""
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

    def _feedback_payload(self, row: sqlite3.Row, messages_per_thread: int = 50) -> dict[str, Any]:
        """一行线程（含 `subject`，可为 None）+ 最近 N 条留言（按时间升序）
        + 用户侧未读 + 留言总数。"""
        thread_id = row["threadId"]
        messages: list[dict[str, Any]] = []
        if messages_per_thread > 0:
            recent = self._rows(
                "SELECT * FROM feedbackMessages WHERE threadId=?"
                " ORDER BY createdAt DESC, rowid DESC LIMIT ?",
                (thread_id, int(messages_per_thread)))
            messages = [dict(message) for message in reversed(recent)]
        read_at = row["userReadAt"]
        unread = self._row(
            "SELECT COUNT(*) AS n FROM feedbackMessages WHERE threadId=? AND author='owner'"
            " AND (? IS NULL OR createdAt > ?)", (thread_id, read_at, read_at))
        owner_at = row["ownerReadAt"]
        team_unread = self._row(
            "SELECT COUNT(*) AS n FROM feedbackMessages WHERE threadId=? AND author='user'"
            " AND (? IS NULL OR createdAt > ?)", (thread_id, owner_at, owner_at))
        count = self._row("SELECT COUNT(*) AS n FROM feedbackMessages WHERE threadId=?", (thread_id,))
        return {**dict(row), "messages": messages, "messageCount": int(count["n"]),
                "unread": int(unread["n"]), "teamUnread": int(team_unread["n"])}
