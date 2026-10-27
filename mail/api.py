"""mail 的公网接口：信件端点（四条老路由 + 通知正文的按需入口）。

与中转版的差异只有一处：`_caller` 不再读本库的设备表（mail 没有身份数据），
而是经 `app["resolve_device"]`（生产实现是 :mod:`internal` 的中转内部接口客户端）
把设备令牌换成归属；解析不到就是匿名，与中转版"坏令牌当匿名"的语义逐字一致。

四条老路由的契约、限流、校验与旧实现保持逐字一致（老 App 零改动），
`POST /feedback/notice` 是 2026-10-27 整改（M2）新增的正文入口：v2 的列表只给摘要。

收件箱有两种投影（`_inbox_v1` / `_inbox_v2`），由请求的 `inboxVersion` 选择；
两者共用同一次取数与同一份未读聚合，v1 只是同一批行的旧形状。
"""

from __future__ import annotations

import asyncio
import ipaddress
import json
import logging
import re
import secrets
from typing import Any

from aiohttp import web

from store import (DEFAULT_FEEDBACK_FORMAT, MAX_SUBJECT_CHARS, Conflict, Store,
                   StoreError, clean_feedback_format, is_user_letter, my_side, my_unread,
                   page_thread_rows, sha256_hex)

LOGGER = logging.getLogger("mail.http")

#: 服务端强制的全部上限**只有这一份**（v1 与 v2 读同一个字典；客户端用 v2 下发的值）。
#:
#: `textBytes` / `maxTicketPairs` / `_MAX_BODY_BYTES` 是一个**耦合三元组**：
#: 每对凭据实测约 102 B（`th_`+18 位、`fk_`+43 位），200 对就是 20,413 B；
#: 只抬条数会把 400 变成 413（整个收件箱照样打不开），必须一起改。
LIMITS = {
    "textChars": 4000,
    "textBytes": 12000,
    "subjectChars": MAX_SUBJECT_CHARS,
    "maxTicketPairs": 200,
    "threadPageDefault": 30,
    "threadPageMax": 100,
    "noticePageDefault": 40,
    "noticePageMax": 100,
    "messagesPerThreadDefault": 6,
}

#: 请求体上限：40 KB（200 对凭据 20,413 B + 一次 read 最坏的 id 数组 ≈9.6 KB，留余量；
#: 低于 aiohttp 的 `client_max_size=64 KB`）。413 文案跟着它走，不另写一个数。
_MAX_BODY_BYTES = 40 * 1024
_MAX_TECH_CHARS = 64
_MAX_CLIENT_REF_CHARS = 64
_MAX_IDS = 200
_MAX_MESSAGES_PER_THREAD = 200
#: v1 的留言窗口缺省（老 App 一直显式传 50，这里保持一致）；v2 用 LIMITS 里的 6。
_LEGACY_MESSAGES_PER_THREAD = 50
#: v1 的通知窗口（v2 用游标翻页）。
_LEGACY_NOTICE_WINDOW = 200

#: 取件凭据 = `fk_` + 43 字符 base64url（32 随机字节），与 data-model.md 一致。
_TICKET_PREFIX = "fk_"
_TICKET_BYTES = 32

_CLIENT_REF_RE = re.compile(r"^[A-Za-z0-9._-]+$")

#: 写入按来源与设备各一桶（换网络也该被算上），读取用更宽的一桶。
_WRITE_LIMIT = 30
_WRITE_DEVICE_LIMIT = 60
_READ_LIMIT = 120
_LIMIT_WINDOW_S = 10 * 60

_JSON_OBJECT = "body must be a JSON object"

CORS_HEADERS = {
    "access-control-allow-origin": "*",
    "access-control-allow-methods": "GET, POST, OPTIONS",
    "access-control-allow-headers": "authorization, content-type, range",
    "access-control-max-age": "600",
}

_FORWARDED_FOR = "X-Forwarded-For"


# ── 从旧中转复制的鉴权/限流工具（mail 不 import 中转的模块） ────────────

def is_loopback(value: str | None) -> bool:
    text = (value or "").strip()
    if not text:
        return False
    try:
        return ipaddress.ip_address(text).is_loopback
    except ValueError:
        return text in ("localhost",)


def bearer_token(request: web.Request) -> str | None:
    header = request.headers.get("Authorization", "")
    scheme, _, value = header.partition(" ")
    if scheme.lower() != "bearer" or not value.strip():
        return None
    return value.strip()


def json_error(status: int, code: str, message: str, **extra: Any) -> web.Response:
    payload: dict[str, Any] = {"ok": False, "error": {"code": code, "message": message}}
    if extra:
        payload["error"]["details"] = extra
    return web.json_response(payload, status=status)


async def read_json(request: web.Request) -> dict[str, Any] | None:
    """Parse a JSON object body, tolerating a missing or odd content type."""
    try:
        raw = await request.text()
        body = json.loads(raw) if raw.strip() else {}
    except (ValueError, UnicodeDecodeError):
        return None
    return body if isinstance(body, dict) else None


def client_identifier(request: web.Request) -> str:
    """限流桶的键：前置反代（Caddy）替换式转发 `X-Forwarded-For`，取最左一条。

    与中转的同名函数同语义（mail 也部署在同一台 Caddy 后面）：
    对端是 loopback 且头里有地址 → 最左那条；否则只信 socket 对端。
    """
    peer = (request.remote or "").strip()
    if is_loopback(peer):
        forwarded = request.headers.get(_FORWARDED_FOR, "")
        first = forwarded.split(",")[0].strip()
        if first:
            return first
    return peer or "unknown"


class ClaimLimiter:
    """In-memory budget keyed by whatever bucket the caller chose（与中转同实现）。"""

    def __init__(self, *, limit: int, window_s: int):
        self.limit = limit
        self.window_s = window_s
        self._hits: dict[str, list[float]] = {}

    @staticmethod
    def _now() -> float:
        try:
            return asyncio.get_running_loop().time()
        except RuntimeError:
            import time
            return time.monotonic()

    def blocked(self, key: str) -> bool:
        now = self._now()
        hits = [at for at in self._hits.get(key, []) if now - at < self.window_s]
        self._hits[key] = hits
        return len(hits) >= self.limit

    def count_failure(self, key: str) -> None:
        self._hits.setdefault(key, []).append(self._now())


@web.middleware
async def cors_preflight(request: web.Request, handler: Any) -> web.StreamResponse:
    if request.method == "OPTIONS":
        return web.Response(status=204, headers=CORS_HEADERS)
    return await handler(request)


# ── 信件接口本体 ───────────────────────────────────────────────────────────

def _not_found() -> web.Response:
    """"线程不存在"与"凭据不匹配"**共用这一个响应**：逐字节相同，不泄露线程是否存在。"""
    return json_error(404, "feedback/not-found", "thread not found")


def _limiter(app: web.Application, key: str, limit: int) -> ClaimLimiter:
    limiter = app.get(key)
    if limiter is None:
        limiter = ClaimLimiter(limit=limit, window_s=_LIMIT_WINDOW_S)
        app[key] = limiter
    return limiter


def _charge(request: web.Request, kind: str, device: dict[str, Any] | None) -> web.Response | None:
    """把这次调用记到调用方的预算上；预算用尽返回 429。"""
    write = kind == "write"
    buckets = [(f"feedback_{kind}_limiter", client_identifier(request),
                _WRITE_LIMIT if write else _READ_LIMIT)]
    if write and device is not None:
        buckets.append(("feedback_write_device_limiter", device["deviceId"], _WRITE_DEVICE_LIMIT))
    for name, key, limit in buckets:
        if _limiter(request.app, name, limit).blocked(key):
            return json_error(429, "feedback/rate-limited",
                              "too many feedback requests; try again later")
    for name, key, _limit in buckets:
        _limiter(request.app, name, _limit).count_failure(key)
    return None


async def _json_body(request: web.Request) -> tuple[dict[str, Any] | None, web.Response | None]:
    """按 40 KB 上限读 JSON 体，超限直接 413（不沿用 WS 帧的上限）。

    四条路由共用这一处判定；正文长度另有 4000 字符 / 12000 字节的判定（先于 413 生效）。
    """
    raw = await request.read()
    if len(raw) > _MAX_BODY_BYTES:
        return None, json_error(413, "feedback/too-large",
                                f"the request body may be at most {_MAX_BODY_BYTES // 1024} KB")
    body = await read_json(request)
    if body is None:
        return None, json_error(400, "feedback/bad-request", _JSON_OBJECT)
    return body, None


def _text_of(body: dict[str, Any]) -> tuple[str | None, web.Response | None]:
    text = body.get("text")
    if not isinstance(text, str):
        return None, json_error(400, "feedback/bad-request", "text is required")
    trimmed = text.strip()
    if not trimmed:
        return None, json_error(400, "feedback/bad-request", "text must not be blank")
    if len(trimmed) > LIMITS["textChars"] \
            or len(trimmed.encode("utf-8")) > LIMITS["textBytes"]:
        return None, json_error(400, "feedback/too-long",
                                f"text may be at most {LIMITS['textChars']} characters"
                                f" / {LIMITS['textBytes']} bytes")
    return trimmed, None


def _subject_of(body: dict[str, Any]) -> tuple[str | None, web.Response | None]:
    value = body.get("subject")
    if value is None:
        return None, None
    if not isinstance(value, str):
        return None, json_error(400, "feedback/bad-request", "subject must be a string")
    trimmed = value.strip()
    if not trimmed:
        return None, None
    if len(trimmed) > LIMITS["subjectChars"]:
        return None, json_error(400, "feedback/too-long",
                                f"subject may be at most {LIMITS['subjectChars']} characters")
    return trimmed, None


def _tech_of(body: dict[str, Any], key: str) -> tuple[str | None, web.Response | None]:
    value = body.get(key)
    if value is None:
        return None, None
    if not isinstance(value, str):
        return None, json_error(400, "feedback/bad-request", f"{key} must be a string")
    if len(value) > _MAX_TECH_CHARS:
        return None, json_error(400, "feedback/too-long",
                                f"{key} may be at most {_MAX_TECH_CHARS} characters")
    return value or None, None


def _format_of(body: dict[str, Any]) -> tuple[str | None, web.Response | None]:
    if body.get("format") is None:
        return None, None
    try:
        return clean_feedback_format(body.get("format")), None
    except StoreError:
        return None, json_error(400, "feedback/bad-request", "format must be text or html")


def _client_ref_of(body: dict[str, Any]) -> tuple[str | None, web.Response | None]:
    value = body.get("clientRef")
    if value is None or value == "":
        return None, None
    if not isinstance(value, str) or len(value) > _MAX_CLIENT_REF_CHARS \
            or not _CLIENT_REF_RE.match(value):
        return None, json_error(400, "feedback/bad-request",
                                "clientRef may be at most 64 characters of [A-Za-z0-9._-]")
    return value, None


def _ticket_pairs(body: dict[str, Any]) -> tuple[list[tuple[str, str]] | None, web.Response | None]:
    raw = body.get("tickets")
    if raw is None:
        return [], None
    if not isinstance(raw, list) or len(raw) > LIMITS["maxTicketPairs"]:
        return None, json_error(400, "feedback/bad-request",
                                f"tickets may hold at most {LIMITS['maxTicketPairs']} entries")
    pairs: list[tuple[str, str]] = []
    for item in raw:
        if not isinstance(item, dict):
            return None, json_error(400, "feedback/bad-request",
                                    "each ticket needs threadId and ticketKey")
        thread_id, ticket = item.get("threadId"), item.get("ticketKey")
        if not isinstance(thread_id, str) or not thread_id \
                or not isinstance(ticket, str) or not ticket:
            return None, json_error(400, "feedback/bad-request",
                                    "each ticket needs threadId and ticketKey")
        pairs.append((thread_id, ticket))
    return pairs, None


def _id_list(body: dict[str, Any], key: str) -> tuple[list[str] | None, web.Response | None]:
    raw = body.get(key)
    if raw is None:
        return [], None
    if not isinstance(raw, list) or len(raw) > _MAX_IDS \
            or not all(isinstance(item, str) and item for item in raw):
        return None, json_error(400, "feedback/bad-request", f"{key} must be a list of ids")
    return list(dict.fromkeys(raw)), None


def _messages_limit(body: dict[str, Any], default: int) -> tuple[int | None, web.Response | None]:
    raw = body.get("messagesPerThread", default)
    if not isinstance(raw, int) or isinstance(raw, bool) or raw < 1:
        return None, json_error(400, "feedback/bad-request",
                                "messagesPerThread must be a positive integer")
    return min(raw, _MAX_MESSAGES_PER_THREAD), None


def _inbox_version(body: dict[str, Any]) -> int:
    """响应用哪种投影：只有请求显式声明 `inboxVersion: 2` 才走 v2，其余逐字走 v1。

    不做版本嗅探（不按 appVersion 猜形状）：形状只由请求声明，测试才可预期。
    """
    raw = body.get("inboxVersion")
    return 2 if isinstance(raw, int) and not isinstance(raw, bool) and raw == 2 else 1


def _page_request(body: dict[str, Any], key: str, *, default: int, maximum: int,
                  time_key: str, id_key: str
                  ) -> tuple[dict[str, Any] | None, web.Response | None]:
    """一页的请求形状：`{"limit": n, "before": {time, id}}`，缺省就是第一页。

    两条列表（线程、通知）共用这一份解析与同一种游标形状，不写第二套分页。
    """
    raw = body.get(key)
    if raw is None:
        return {"limit": default, "before": None}, None
    if not isinstance(raw, dict):
        return None, json_error(400, "feedback/bad-request", f"{key} must be an object")
    limit = raw.get("limit", default)
    if not isinstance(limit, int) or isinstance(limit, bool) or not 1 <= limit <= maximum:
        return None, json_error(400, "feedback/bad-request",
                                f"{key}.limit must be an integer between 1 and {maximum}")
    before = raw.get("before")
    if before is not None:
        if not isinstance(before, dict):
            return None, json_error(400, "feedback/bad-request",
                                    f"{key}.before must be an object")
        stamp, ident = before.get(time_key), before.get(id_key)
        if not isinstance(stamp, int) or isinstance(stamp, bool) \
                or not isinstance(ident, str) or not ident:
            return None, json_error(400, "feedback/bad-request",
                                    f"{key}.before needs {time_key} and {id_key}")
        before = {time_key: stamp, id_key: ident}
    return {"limit": limit, "before": before}, None


def _limits_payload(messages_per_thread: int, threads_limit: int, notices_limit: int) -> dict:
    """v2 下发的上限：客户端只认这些数，编译期常量只作旧服务端回退（P0-3）。"""
    return {"textChars": LIMITS["textChars"], "textBytes": LIMITS["textBytes"],
            "subjectChars": LIMITS["subjectChars"],
            "maxTicketPairs": LIMITS["maxTicketPairs"],
            "messagesPerThread": messages_per_thread,
            "threadPageSize": threads_limit, "noticePageSize": notices_limit}


def _team_account(request: web.Request) -> str:
    """团队账号（部署配置 MAIL_TEAM_ACCOUNT；空 = 团队收件箱关闭）。"""
    return str(request.app.get("team_account") or "")


def _is_team_side(request: web.Request, device: dict[str, Any] | None,
                  thread: dict[str, Any] | None = None) -> bool:
    """这次调用是不是团队那一侧：设备归属团队账号，且（给了线程时）线程是**用户来信**。

    只按账号判（设备令牌经中转解析，伪造不了），不引入新的凭据。线程那一半走
    派生谓词：团队自己的提交与测试机型不算来信，对它们补充/回信一律按 `user` 落库。
    """
    team = _team_account(request)
    if not team or device is None or device.get("accountId") != team:
        return False
    if thread is None:
        return True
    return is_user_letter(thread.get("accountId"), thread.get("deviceModel"), team)


async def _caller(request: web.Request) -> dict[str, Any] | None:
    """可选令牌背后的设备；``None`` 就是匿名。

    **与中转版的唯一差异**：归属不读本库（mail 没有设备表），经
    ``app["resolve_device"]``（async 可调用，token → 设备 dict）向中转换。
    解析不到（未知/撤销/过期/中转不可达）都变成"匿名"，**不是错误**——
    与中转版 `_caller` 的降级语义一致（DESIGN-20261015 I-1）。生产实现
    （internal.py）自己就吞掉网络错误；这里再兜一层，保证**任何**解析器
    实现的意外异常都不会把一次提交变成 500——匿名降级是这条边界的行为契约。
    """
    token = bearer_token(request)
    if not token:
        return None
    resolve = request.app["resolve_device"]
    try:
        return await resolve(token)
    except Exception:  # noqa: BLE001 —— 边界契约：解析失败一律匿名，不让用户买单
        LOGGER.exception("mail: device resolve raised; treating as anonymous")
        return None


def _public_thread(thread: dict[str, Any], *, v2: bool = False,
                   team: str = "") -> dict[str, Any]:
    """线程的契约字段。v1 与 v2 是**同一批行的两种投影**，不是第二份数据。

    两个原始未读计数在 payload 里各归其位，投影只挑不重算：

    - v1（**兼容视图，语义不动**）：`unread` = 我们写的、用户还没读的条数（`ownerUnread`）；
      `teamUnread` = 用户写的、我们还没读的条数（`userUnread`）。唯一例外是团队
      **自有信**的 `teamUnread` 归 0（P0-2 的修复：老 App 的角标不再把自己的信算成来信）。
    - v2：`unread` = **我这一侧**（`mySide=="owner"` 取 `userUnread`，否则 `ownerUnread`），
      并去掉只服务 v1 的 `teamUnread` / `source.teamBound`。
    """
    own_letter = thread["callerIsTeam"] and not thread["userLetter"]
    source = {
        "kind": "device" if (thread.get("deviceId") or thread.get("accountId")) else "anonymous",
        "deviceModel": thread.get("deviceModel"),
        "appVersion": thread.get("appVersion"),
        "systemVersion": thread.get("systemVersion"),
        "accountHint": (thread.get("accountId") or "")[:12] or None,
    }
    messages = [
        {"messageId": message["messageId"], "author": message["author"],
         "body": message["body"],
         "format": message.get("format") or DEFAULT_FEEDBACK_FORMAT,
         "createdAt": message["createdAt"]}
        for message in thread.get("messages", [])
    ]
    # v1 的键序与拆分前一致（unread / teamUnread 在 source 之前）；v2 在后面追加 mySide。
    payload: dict[str, Any] = {
        "threadId": thread["threadId"],
        "subject": thread.get("subject"),
        "status": thread["status"],
        "createdAt": thread["createdAt"],
        "lastMessageAt": thread["lastMessageAt"],
        "unread": (thread["userUnread"] if thread["mySide"] == "owner"
                   else thread["ownerUnread"]) if v2 else thread["ownerUnread"],
    }
    if not v2:
        payload["teamUnread"] = 0 if own_letter else thread["userUnread"]
    payload["source"] = source
    payload["messages"] = messages
    if v2:
        payload["mySide"] = thread["mySide"]
    else:
        # 派生值：这封是不是"给团队的用户来信"（M1 起不再读 teamAccountId 列）。
        payload["source"]["teamBound"] = bool(team) and bool(thread["userLetter"])
    return payload


def _public_notice(notice: dict[str, Any], *, v2: bool = False) -> dict[str, Any]:
    """通知的契约字段：v1 内联正文，v2 只给摘要（正文走 `POST /feedback/notice`）。"""
    # v1 的键序与拆分前一致（body 在 format 之前）；v2 只给摘要。
    payload: dict[str, Any] = {"noticeId": notice["noticeId"], "subject": notice["subject"]}
    if not v2:
        payload["body"] = notice["body"]
    payload["format"] = notice.get("format") or DEFAULT_FEEDBACK_FORMAT
    payload["createdAt"] = notice["createdAt"]
    payload["read"] = bool(notice["read"])
    return payload


def _next_before(rows: list[dict[str, Any]], time_key: str, id_key: str) -> dict[str, Any] | None:
    """`nextBefore` 取本页最后一条的键；空页没有下一页。"""
    if not rows:
        return None
    last = rows[-1]
    return {time_key: int(last[time_key]), id_key: str(last[id_key])}


async def _visible_threads(store: Store, pairs: list[tuple[str, str]],
                          device: dict[str, Any] | None, *, team: str) -> list[Any]:
    """这一次调用能看到的全部线程行（**不带**留言与未读）；可见性只有 store 那一份实现。"""
    hashed = [(thread_id, sha256_hex(ticket)) for thread_id, ticket in pairs]
    return await asyncio.to_thread(
        store.visible_thread_rows, hashed,
        device["deviceId"] if device else None,
        device["accountId"] if device else None, team_account=team or None)


def _thread_sides(rows: list[Any], team: str, caller: str | None) -> dict[str, str]:
    """每线程的 `mySide`：谓词判"是不是用户来信"，`my_side` 判"我是不是 owner 侧"。"""
    caller_is_team = bool(team) and caller == team
    return {row["threadId"]: my_side(
        is_user_letter(row["accountId"], row["deviceModel"], team), caller_is_team)
        for row in rows}


async def _collect(store: Store, pairs: list[tuple[str, str]], device: dict[str, Any] | None,
                   messages_per_thread: int, *, with_notices: bool = True,
                   team_account: str = "",
                   threads_page: dict[str, Any] | None = None,
                   notice_page: dict[str, Any] | None = None) -> dict[str, Any]:
    """这一次请求的全部事实：线程窗口、通知窗口、未读合计、每线程 `mySide`。

    顺序固定为「取全部可见线程行 → 一次分组查询算两侧未读 → 切页 → 只给当页构造
    payload」：未读合计覆盖**全部可见线程**，与当页容量无关（角标不受窗口影响），
    而留言只为当页那几条取。

    未读 = Σ(全部可见线程**我这一侧**的未读) + 该账号未读通知数（SQL 聚合）。
    v1 与 v2 走同一段代码（v1 的 `threads_page=None` = 可见集合即全部），因此同一次
    请求的 `unreadCount` 与 `feedback_read` 回包永远是同一个数。

    `team_account` 为空 = 团队收件箱关闭：团队那条命中路径整条不参与
    （见 :meth:`Store.visible_thread_rows`），而不是把来信按用户视角发出去。

    性能取舍：可见行每请求都取（无留言、无未读，实测团队账号 165 行），换"可见性
    只有一份实现 + 未读合计不受窗口影响"；留言与正文只按当页/当次取。
    """
    team = team_account.strip()
    caller = device["accountId"] if device else None
    rows = await _visible_threads(store, pairs, device, team=team)

    unread_by_thread = await asyncio.to_thread(
        store.unread_counts_by_thread, [row["threadId"] for row in rows])
    sides = _thread_sides(rows, team, caller)
    unread = sum(my_unread(unread_by_thread.get(thread_id, {}), side)
                 for thread_id, side in sides.items())

    page_rows, threads_more = page_thread_rows(
        rows,
        limit=threads_page["limit"] if threads_page else None,
        before=threads_page["before"] if threads_page else None)
    threads = await asyncio.to_thread(store.thread_payloads, page_rows, messages_per_thread,
                                      team=team, caller_account=caller,
                                      unread=unread_by_thread)

    notices: list[dict[str, Any]] = []
    notices_more = False
    if with_notices and device is not None:
        notices, notices_more = await asyncio.to_thread(
            store.notice_page, device["accountId"],
            limit=notice_page["limit"] if notice_page else _LEGACY_NOTICE_WINDOW,
            before=notice_page["before"] if notice_page else None)
    if device is not None:
        # 未读通知数是 SQL 聚合：`notices:false`（不返回列表）也照算，且与窗口无关。
        unread += await asyncio.to_thread(store.unread_notice_count, device["accountId"])

    return {
        "team": team,
        "threads": threads,
        "threadsMore": threads_more,
        "threadsNextBefore": _next_before(threads, "lastMessageAt", "threadId"),
        "notices": notices,
        "noticesMore": notices_more,
        "noticesNextBefore": _next_before(notices, "createdAt", "noticeId"),
        "unreadCount": unread,
        "teamPerspective": bool(team and caller == team),
    }


def _inbox_v1(snapshot: dict[str, Any]) -> dict[str, Any]:
    """老 App 的形状：字段名、语义、200 条窗口一个都不动（形状快照有测试钉住）。"""
    team = snapshot["team"]
    return {
        "ok": True,
        "threads": [_public_thread(thread, team=team) for thread in snapshot["threads"]],
        "notices": [_public_notice(notice) for notice in snapshot["notices"]],
        "unreadCount": snapshot["unreadCount"],
        "teamPerspective": snapshot["teamPerspective"],
    }


def _inbox_v2(snapshot: dict[str, Any], limits: dict[str, Any]) -> dict[str, Any]:
    """新形状：摘要 + 游标 + 一页容量 + 每线程 `mySide`；正文与 teamUnread 不再下发。"""
    return {
        "ok": True,
        "inboxVersion": 2,
        "teamPerspective": snapshot["teamPerspective"],
        "threads": [_public_thread(thread, v2=True) for thread in snapshot["threads"]],
        "threadsPage": {"more": snapshot["threadsMore"],
                        "nextBefore": snapshot["threadsNextBefore"]},
        "notices": [_public_notice(notice, v2=True) for notice in snapshot["notices"]],
        "noticesPage": {"more": snapshot["noticesMore"],
                        "nextBefore": snapshot["noticesNextBefore"]},
        "unreadCount": snapshot["unreadCount"],
        "limits": limits,
    }


async def _authorized_threads(store: Store, pairs: list[tuple[str, str]],
                              device: dict[str, Any] | None,
                              team_account: str = "") -> dict[str, Any]:
    """这次调用可以标记的线程：可见集合（凭据命中 ∪ 设备/账号命中 ∪ 团队命中）。

    与收件箱同一个实现（:meth:`Store.visible_thread_rows`），返回 `threadId → 行`
    以便顺手判"这条是哪一侧"。`team_account` 为空时团队命中路径不参与。
    """
    rows = await _visible_threads(store, pairs, device, team=team_account.strip())
    return {row["threadId"]: row for row in rows}


async def _notify_account_state(request: web.Request, account_id: str | None) -> None:
    """告诉中转"这个账户的信件状态变了"，让它借在线连接扇一帧（032 FR-009）。

    `notify_account_state` 是生产实现（环回 POST 到中转）；失败语义全在它里面：短超时、
    不重试、不抛错。这里只负责"该不该发、发给谁"——信件状态变了却不发，另一台设备就只能
    等到下次前台刷新，这正是角标慢一拍的原因。
    """
    notifier = request.app.get("notify_account_state")
    if notifier is None or not account_id:
        return
    await notifier(account_id)


async def feedback_submit(request: web.Request) -> web.Response:
    """新建一条线程并把取件凭据返回一次（库里只留它的 SHA-256）。"""
    store: Store = request.app["store"]
    body, error = await _json_body(request)
    if error is not None:
        return error
    text, error = _text_of(body)
    if error is not None:
        return error
    subject, error = _subject_of(body)
    if error is not None:
        return error
    _, error = _format_of(body)
    if error is not None:
        return error
    fields: dict[str, str | None] = {}
    for key, column in (("appVersion", "app_version"), ("deviceModel", "device_model"),
                        ("systemVersion", "system_version")):
        fields[column], error = _tech_of(body, key)
        if error is not None:
            return error
    client_ref, error = _client_ref_of(body)
    if error is not None:
        return error
    device = await _caller(request)
    error = _charge(request, "write", device)
    if error is not None:
        return error

    # 团队收件箱（2026-10-15）：归属**不落库**，由派生谓词回答"这封会不会进团队收件箱"
    # （P2-7：开关为空期间收到的信，开关恢复后自动出现，不需要回填）。
    team = _team_account(request)
    account_id = device["accountId"] if device else None
    reaches_team = bool(team) and is_user_letter(account_id, fields.get("device_model"), team)

    ticket = f"{_TICKET_PREFIX}{secrets.token_urlsafe(_TICKET_BYTES)}"
    try:
        thread = await asyncio.to_thread(
            store.create_feedback_thread,
            ticket_hash=sha256_hex(ticket), text=text, client_ref=client_ref, subject=subject,
            device_id=device["deviceId"] if device else None,
            account_id=account_id, **fields)
    except Conflict:
        return json_error(400, "feedback/bad-request", "clientRef has already been used")
    except StoreError:
        LOGGER.exception("mail: storing a feedback thread failed")
        return json_error(500, "feedback/store-error", "the mail service could not store the feedback")
    # 新信进了团队收件箱：团队的其他设备（含主人自己的手机）当场就知道，不必等前台刷新。
    await _notify_account_state(request, team if reaches_team else None)
    return web.json_response({"ok": True, "threadId": thread["threadId"],
                              "ticketKey": ticket, "createdAt": thread["createdAt"]})


async def feedback_inbox(request: web.Request) -> web.Response:
    """拉取；**只读**，离线或只打开列表页时调用它不会把未读清掉（FR-012）。

    形状由请求声明：带 `inboxVersion: 2` 拿 v2（摘要 + 游标 + `mySide`），
    不带就是今天那份 v1 响应（逐字不变，老 App 零改动）。
    """
    store: Store = request.app["store"]
    body, error = await _json_body(request)
    if error is not None:
        return error
    version = _inbox_version(body)
    pairs, error = _ticket_pairs(body)
    if error is not None:
        return error
    limit, error = _messages_limit(
        body, LIMITS["messagesPerThreadDefault"] if version == 2 else _LEGACY_MESSAGES_PER_THREAD)
    if error is not None:
        return error
    threads_page = notice_page = None
    if version == 2:
        threads_page, error = _page_request(
            body, "threadsPage", default=LIMITS["threadPageDefault"],
            maximum=LIMITS["threadPageMax"], time_key="lastMessageAt", id_key="threadId")
        if error is not None:
            return error
        notice_page, error = _page_request(
            body, "noticePage", default=LIMITS["noticePageDefault"],
            maximum=LIMITS["noticePageMax"], time_key="createdAt", id_key="noticeId")
        if error is not None:
            return error
    device = await _caller(request)
    error = _charge(request, "read", device)
    if error is not None:
        return error
    snapshot = await _collect(store, pairs, device, limit,
                              with_notices=bool(body.get("notices", True)),
                              team_account=_team_account(request),
                              threads_page=threads_page, notice_page=notice_page)
    if version == 2:
        return web.json_response(_inbox_v2(snapshot, _limits_payload(
            limit, threads_page["limit"], notice_page["limit"])))
    return web.json_response(_inbox_v1(snapshot))


async def feedback_append(request: web.Request) -> web.Response:
    """用户在已有线程下补充一句（异步留言，不是即时对话）。"""
    store: Store = request.app["store"]
    body, error = await _json_body(request)
    if error is not None:
        return error
    thread_id, ticket = body.get("threadId"), body.get("ticketKey")
    if not isinstance(thread_id, str) or not thread_id:
        return json_error(400, "feedback/bad-request", "threadId is required")
    if ticket is not None and (not isinstance(ticket, str) or not ticket):
        return json_error(400, "feedback/bad-request", "ticketKey must be a non-empty string")
    text, error = _text_of(body)
    if error is not None:
        return error
    _, error = _format_of(body)
    if error is not None:
        return error
    client_ref, error = _client_ref_of(body)
    if error is not None:
        return error
    device = await _caller(request)
    error = _charge(request, "write", device)
    if error is not None:
        return error

    # 授权二选一（团队收件箱 2026-10-15 放宽了第二条）：
    # 1. 取件凭据命中（老路径，匿名提交者与既有 App 的唯一手段）；
    # 2. 设备授权：线程绑这台设备/这个账号，或调用方是线程的团队侧——团队在
    #    App 里直接回信、以及用户换机重配后凭账号找回线程，都走这条。
    ticket_hash = sha256_hex(ticket) if ticket else None
    thread = None
    ticket_ok = False
    if ticket_hash is not None:
        thread = await asyncio.to_thread(store.feedback_thread, thread_id, ticket_hash,
                                         messages_per_thread=0)
        ticket_ok = thread is not None
    if thread is None:
        # 凭据没给或没命中时才按设备/团队判——**给了但错的凭据不因为兜底而放行**，
        # 与"线程不存在"共用同一个 404，不泄露线程是否存在。
        thread = await asyncio.to_thread(store.feedback_thread, thread_id, None,
                                         messages_per_thread=0)
    device_bound = bool(
        thread is not None and device is not None
        and (thread.get("deviceId") == device["deviceId"]
             or (device.get("accountId") and thread.get("accountId") == device["accountId"])))
    team_side = _is_team_side(request, device, thread)
    if not (ticket_ok or device_bound or team_side):
        return _not_found()
    try:
        message = await asyncio.to_thread(
            store.append_feedback_message, thread_id, text,
            author="owner" if team_side else "user", client_ref=client_ref,
            bind_device_id=device["deviceId"] if device and not team_side else None,
            bind_account_id=device["accountId"] if device and not team_side else None)
    except StoreError:
        LOGGER.exception("mail: storing a feedback message failed")
        return json_error(500, "feedback/store-error", "the mail service could not store the message")
    if message is None:                      # 与上面同一条 404：不泄露线程是否存在
        return _not_found()
    # 收信方 = 写的人对面那一方：团队回信 → 通知来信账户；用户/匿名补一句 → 通知团队收件箱。
    await _notify_account_state(
        request,
        thread.get("accountId") if team_side else _team_account(request))
    return web.json_response({"ok": True, "threadId": thread_id,
                              "messageId": message["messageId"], "createdAt": message["createdAt"]})


async def feedback_read(request: web.Request) -> web.Response:
    """标记已读；只有调用方能证明的线程才标得动，notice 按账号标。"""
    store: Store = request.app["store"]
    body, error = await _json_body(request)
    if error is not None:
        return error
    thread_ids, error = _id_list(body, "threadIds")
    if error is not None:
        return error
    notice_ids, error = _id_list(body, "noticeIds")
    if error is not None:
        return error
    pairs, error = _ticket_pairs(body)
    if error is not None:
        return error
    device = await _caller(request)
    error = _charge(request, "read", device)
    if error is not None:
        return error

    allowed = await _authorized_threads(store, pairs, device, _team_account(request))
    for thread_id in thread_ids:
        row = allowed.get(thread_id)
        if row is None:
            continue
        # 已读分侧（团队收件箱 2026-10-15）：团队读用户来信推 ownerReadAt，
        # 用户读团队回信推 userReadAt——同一次调用里逐线程判定（判据在 `_is_team_side`）。
        if _is_team_side(request, device, {"accountId": row["accountId"],
                                          "deviceModel": row["deviceModel"]}):
            await asyncio.to_thread(store.mark_team_thread_read, thread_id)
        else:
            await asyncio.to_thread(store.mark_thread_read, thread_id)
    if device is not None and notice_ids:
        await asyncio.to_thread(store.mark_notices_read, device["accountId"], notice_ids)
    # 032 FR-009：已读落库后通知同账户的其他在线设备。只是"去看看信件"的一声招呼，
    # 失败不重试（同账户另一台最迟在下次前台刷新时对齐）；匿名调用没有账户，跳过。
    await _notify_account_state(request, device.get("accountId") if device else None)
    # 只要一个未读数：通知列表不必取（未读数是 SQL 聚合，与窗口无关）。
    snapshot = await _collect(store, pairs, device, 0, with_notices=False,
                              team_account=_team_account(request))
    return web.json_response({"ok": True, "unreadCount": snapshot["unreadCount"]})


async def feedback_notice(request: web.Request) -> web.Response:
    """取一条通知的正文（v2 列表不再内联正文）。

    授权只按 `(accountId, noticeId)`：匿名 / 这个账号没有这条投递 / 通知不存在，
    三者与线程那条 404 **逐字节相同**，不泄露通知是否存在。计入读限流桶。
    """
    store: Store = request.app["store"]
    body, error = await _json_body(request)
    if error is not None:
        return error
    notice_id = body.get("noticeId")
    if not isinstance(notice_id, str) or not notice_id:
        return json_error(400, "feedback/bad-request", "noticeId is required")
    device = await _caller(request)
    error = _charge(request, "read", device)
    if error is not None:
        return error
    if device is None:
        return _not_found()
    notice = await asyncio.to_thread(store.notice_for_account, device["accountId"], notice_id)
    if notice is None:
        return _not_found()
    return web.json_response({"ok": True, "notice": _public_notice(notice)})


def register_mail_routes(app: web.Application, route: Any) -> None:
    """挂信件路由（`route` 负责带前缀/去前缀的双注册，见 mail.py）。

    四条老路由的契约不变；`/feedback/notice` 是通知正文的按需入口（M2）。
    """
    route("POST", "/feedback/submit", feedback_submit)
    route("POST", "/feedback/inbox", feedback_inbox)
    route("POST", "/feedback/append", feedback_append)
    route("POST", "/feedback/read", feedback_read)
    route("POST", "/feedback/notice", feedback_notice)
