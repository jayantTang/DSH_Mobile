"""mail 的公网接口：信件四条路由（从 relay/feedback.py 移植，DESIGN-20261015 M2）。

与中转版的差异只有一处：`_caller` 不再读本库的设备表（mail 没有身份数据），
而是经 `app["resolve_device"]`（生产实现是 :mod:`internal` 的中转内部接口客户端）
把设备令牌换成归属；解析不到就是匿名，与中转版"坏令牌当匿名"的语义逐字一致。

路由、契约、限流、校验与 relay/feedback.py 保持逐字一致——App 侧零改动是这次
拆分的验收标准之一，移植时不动行为。
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

from store import (DEFAULT_FEEDBACK_FORMAT, MAX_SUBJECT_CHARS, TEST_DEVICE_MODELS, Conflict, Store,
                   StoreError, clean_feedback_format, sha256_hex)

LOGGER = logging.getLogger("mail.http")

#: 与 data-model.md 的"校验规则（服务端强制的部分）"逐字一致。
_MAX_TEXT_CHARS = 4000
_MAX_TEXT_BYTES = 8000
_MAX_BODY_BYTES = 16 * 1024
_MAX_TECH_CHARS = 64
_MAX_CLIENT_REF_CHARS = 64
_MAX_TICKETS = 50
_MAX_IDS = 200
_MAX_MESSAGES_PER_THREAD = 200
_DEFAULT_MESSAGES_PER_THREAD = 50

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


# ── 从 relay/api.py 复制的鉴权/限流工具（mail 不 import 中转的模块） ────────────

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

    与 relay/api.py 的同名函数同语义（mail 也部署在同一台 Caddy 后面）：
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
    """按 16 KB 上限读 JSON 体，超限直接 413（与中转版同口径，不沿用 WS 帧的上限）。"""
    raw = await request.read()
    if len(raw) > _MAX_BODY_BYTES:
        return None, json_error(413, "feedback/too-large", "the request body may be at most 16 KB")
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
    if len(trimmed) > _MAX_TEXT_CHARS or len(trimmed.encode("utf-8")) > _MAX_TEXT_BYTES:
        return None, json_error(400, "feedback/too-long",
                                f"text may be at most {_MAX_TEXT_CHARS} characters"
                                f" / {_MAX_TEXT_BYTES} bytes")
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
    if len(trimmed) > MAX_SUBJECT_CHARS:
        return None, json_error(400, "feedback/too-long",
                                f"subject may be at most {MAX_SUBJECT_CHARS} characters")
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
    if not isinstance(raw, list) or len(raw) > _MAX_TICKETS:
        return None, json_error(400, "feedback/bad-request",
                                f"tickets may hold at most {_MAX_TICKETS} entries")
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


def _messages_limit(body: dict[str, Any]) -> tuple[int | None, web.Response | None]:
    raw = body.get("messagesPerThread", _DEFAULT_MESSAGES_PER_THREAD)
    if not isinstance(raw, int) or isinstance(raw, bool) or raw < 1:
        return None, json_error(400, "feedback/bad-request",
                                "messagesPerThread must be a positive integer")
    return min(raw, _MAX_MESSAGES_PER_THREAD), None


def _team_account(request: web.Request) -> str:
    """团队账号（部署配置 MAIL_TEAM_ACCOUNT；空 = 团队收件箱关闭）。"""
    return str(request.app.get("team_account") or "")


def _is_team_side(request: web.Request, device: dict[str, Any] | None,
                  thread: dict[str, Any] | None = None) -> bool:
    """这次调用是不是团队那一侧：设备归属团队账号，且（给了线程时）线程绑定了团队。

    只按账号判（设备令牌经中转解析，伪造不了），不引入新的凭据。
    """
    team = _team_account(request)
    if not team or device is None or device.get("accountId") != team:
        return False
    if thread is None:
        return True
    return bool(thread.get("teamAccountId")) and thread["teamAccountId"] == team


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


def _public_thread(thread: dict[str, Any]) -> dict[str, Any]:
    """只留契约里的字段：``ticketHash`` 与来源信息这类内部列不得出网。"""
    return {
        "threadId": thread["threadId"],
        "subject": thread.get("subject"),
        "status": thread["status"],
        "createdAt": thread["createdAt"],
        "lastMessageAt": thread["lastMessageAt"],
        "unread": thread["unread"],
        "teamUnread": thread.get("teamUnread", 0),
        # 发件人标识（团队收件箱 2026-10-15）：用户自己的线程看到的是自己；
        # 团队账号看到的是来信人。取件凭据等内部列仍然不出网。
        "source": {
            "kind": "device" if (thread.get("deviceId") or thread.get("accountId")) else "anonymous",
            "deviceModel": thread.get("deviceModel"),
            "appVersion": thread.get("appVersion"),
            "systemVersion": thread.get("systemVersion"),
            "accountHint": (thread.get("accountId") or "")[:12] or None,
            "teamBound": bool(thread.get("teamAccountId")),
        },
        "messages": [
            {"messageId": message["messageId"], "author": message["author"],
             "body": message["body"],
             "format": message.get("format") or DEFAULT_FEEDBACK_FORMAT,
             "createdAt": message["createdAt"]}
            for message in thread.get("messages", [])
        ],
    }


def _public_notice(notice: dict[str, Any]) -> dict[str, Any]:
    return {"noticeId": notice["noticeId"], "subject": notice["subject"], "body": notice["body"],
            "format": notice.get("format") or DEFAULT_FEEDBACK_FORMAT,
            "createdAt": notice["createdAt"], "read": bool(notice["read"])}


async def _collect(store: Store, pairs: list[tuple[str, str]], device: dict[str, Any] | None,
                   messages_per_thread: int, *, with_notices: bool = True,
                   team_account: str = "") -> dict[str, Any]:
    """调用方看得到的线程（凭据命中 ∪ 设备/账号/团队命中，去重）与未读计数。

    未读分侧（团队收件箱 2026-10-15）：团队账号数**用户来信**未读（teamUnread），
    其余数**团队回信**未读（unread）——同一次响应里两个口径都给，`unreadCount`
    按调用方是哪一侧取对应的那个。
    """
    hashed = [(thread_id, sha256_hex(ticket)) for thread_id, ticket in pairs]
    threads = await asyncio.to_thread(store.feedback_threads_by_tickets, hashed,
                                      messages_per_thread=messages_per_thread)
    if device is not None:
        bound = await asyncio.to_thread(store.feedback_threads_by_device, device["deviceId"],
                                        device["accountId"],
                                        messages_per_thread=messages_per_thread)
        seen = {thread["threadId"] for thread in threads}
        threads.extend(thread for thread in bound if thread["threadId"] not in seen)
    threads.sort(key=lambda thread: thread["lastMessageAt"], reverse=True)
    notices = []
    if with_notices and device is not None:
        notices = await asyncio.to_thread(store.notices_for_account, device["accountId"])
    team_side = bool(team_account and device and device["accountId"] == team_account)
    side_key = "teamUnread" if team_side else "unread"
    unread = sum(thread.get(side_key, 0) for thread in threads) \
        + sum(1 for row in notices if not row["read"])
    return {"threads": [_public_thread(thread) for thread in threads],
            "notices": [_public_notice(notice) for notice in notices],
            "unreadCount": unread,
            # 调用方是不是团队那一侧（团队收件箱 2026-10-15）：App 由此知道该按
            # 哪个视角排收件/已发送——teamBound 是线程的属性，两侧都看得到，
            # 视角只能由服务端按调用方账号给。
            "teamPerspective": team_side}


async def _authorized_threads(store: Store, pairs: list[tuple[str, str]],
                              device: dict[str, Any] | None) -> set[str]:
    """这次调用可以标记的线程：凭据命中 ∪ 设备（或账号）命中。"""
    allowed: set[str] = set()
    for thread_id, ticket in pairs:
        thread = await asyncio.to_thread(store.feedback_thread, thread_id, sha256_hex(ticket),
                                         messages_per_thread=0)
        if thread is not None:
            allowed.add(thread_id)
    if device is not None:
        bound = await asyncio.to_thread(store.feedback_threads_by_device, device["deviceId"],
                                        device["accountId"], messages_per_thread=0)
        allowed.update(thread["threadId"] for thread in bound)
    return allowed


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

    # 团队收件箱（2026-10-15）：非团队账号的提交（含匿名）都绑到团队账号，
    # 团队由此在收件箱看到来信；测试台机型与团队自己的测试提交不绑。
    team = _team_account(request)
    team_binding = None
    if team and (device is None or device["accountId"] != team):
        model = str(fields.get("device_model") or "")
        if model not in TEST_DEVICE_MODELS:
            team_binding = team

    ticket = f"{_TICKET_PREFIX}{secrets.token_urlsafe(_TICKET_BYTES)}"
    try:
        thread = await asyncio.to_thread(
            store.create_feedback_thread,
            ticket_hash=sha256_hex(ticket), text=text, client_ref=client_ref, subject=subject,
            device_id=device["deviceId"] if device else None,
            account_id=device["accountId"] if device else None,
            team_account_id=team_binding, **fields)
    except Conflict:
        return json_error(400, "feedback/bad-request", "clientRef has already been used")
    except StoreError:
        LOGGER.exception("mail: storing a feedback thread failed")
        return json_error(500, "feedback/store-error", "the mail service could not store the feedback")
    # 新信进了团队收件箱：团队的其他设备（含主人自己的手机）当场就知道，不必等前台刷新。
    await _notify_account_state(request, team_binding)
    return web.json_response({"ok": True, "threadId": thread["threadId"],
                              "ticketKey": ticket, "createdAt": thread["createdAt"]})


async def feedback_inbox(request: web.Request) -> web.Response:
    """拉取；**只读**，离线或只打开列表页时调用它不会把未读清掉（FR-012）。"""
    store: Store = request.app["store"]
    body, error = await _json_body(request)
    if error is not None:
        return error
    pairs, error = _ticket_pairs(body)
    if error is not None:
        return error
    limit, error = _messages_limit(body)
    if error is not None:
        return error
    device = await _caller(request)
    error = _charge(request, "read", device)
    if error is not None:
        return error
    payload = await _collect(store, pairs, device, limit,
                             with_notices=bool(body.get("notices", True)),
                             team_account=_team_account(request))
    return web.json_response({"ok": True, **payload})


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

    allowed = await _authorized_threads(store, pairs, device)
    for thread_id in thread_ids:
        if thread_id not in allowed:
            continue
        # 已读分侧（团队收件箱 2026-10-15）：团队读用户来信推 ownerReadAt，
        # 用户读团队回信推 userReadAt——同一次调用里逐线程判定。
        thread = await asyncio.to_thread(store.feedback_thread, thread_id, None,
                                         messages_per_thread=0)
        if _is_team_side(request, device, thread):
            await asyncio.to_thread(store.mark_team_thread_read, thread_id)
        else:
            await asyncio.to_thread(store.mark_thread_read, thread_id)
    if device is not None and notice_ids:
        await asyncio.to_thread(store.mark_notices_read, device["accountId"], notice_ids)
    # 032 FR-009：已读落库后通知同账户的其他在线设备。只是"去看看信件"的一声招呼，
    # 失败不重试（同账户另一台最迟在下次前台刷新时对齐）；匿名调用没有账户，跳过。
    await _notify_account_state(request, device.get("accountId") if device else None)
    payload = await _collect(store, pairs, device, 0, team_account=_team_account(request))
    return web.json_response({"ok": True, "unreadCount": payload["unreadCount"]})


def register_mail_routes(app: web.Application, route: Any) -> None:
    """挂四条信件路由（`route` 负责带前缀/去前缀的双注册，见 mail.py）。"""
    route("POST", "/feedback/submit", feedback_submit)
    route("POST", "/feedback/inbox", feedback_inbox)
    route("POST", "/feedback/append", feedback_append)
    route("POST", "/feedback/read", feedback_read)
