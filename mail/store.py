"""mail 服务的存储：信件 4 张表与全部读写方法。

信件服务的存储层（DESIGN-20261015 从旧中转拆出）。与中转库的差异：

- 只有 feedbackThreads / feedbackMessages / notices / noticeDeliveries 四张表，
  没有账号/设备/配对/用量——那些归中转，mail 只按值引用 accountId/deviceId
  （不透明字符串，等值比较，无外键、不复制）。
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
from typing import Any, Iterable

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
                               subject: str | None = None, at: int | None = None) -> dict[str, Any]:
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
                " deviceModel, systemVersion, createdAt, lastMessageAt, status, clientRef, subject)"
                " VALUES(?,?,?,?,?,?,?,?,?,'open',?,?)",
                (thread_id, ticket_hash, account_id, device_id, app_version, device_model,
                 system_version, stamp, stamp, client_ref, clean_feedback_subject(subject)))
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
        return [{**dict(row), "read": row["readAt"] is not None} for row in page], more

    def notice_for_account(self, account_id: str, notice_id: str) -> dict[str, Any] | None:
        """某条通知的全文——**只按 (accountId, noticeId) 授权**，没这条投递返回 None。

        详情是正文的唯一所有者：列表只给摘要，正文在这里按需取（P1-4）。
        """
        row = self._row(self._NOTICE_SELECT + " WHERE d.accountId=? AND n.noticeId=?",
                        (account_id, notice_id))
        return None if row is None else {**dict(row), "read": row["readAt"] is not None}

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
