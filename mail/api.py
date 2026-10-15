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

from store import (DEFAULT_FEEDBACK_FORMAT, MAX_SUBJECT_CHARS, Conflict, Store, StoreError,
                   clean_feedback_format, sha256_hex)

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
                   messages_per_thread: int, *, with_notices: bool = True) -> dict[str, Any]:
    """调用方看得到的线程（凭据命中 ∪ 设备/账号命中，去重）与未读计数。"""
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
    unread = sum(thread["unread"] for thread in threads) + sum(1 for row in notices if not row["read"])
    return {"threads": [_public_thread(thread) for thread in threads],
            "notices": [_public_notice(notice) for notice in notices],
            "unreadCount": unread}


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

    ticket = f"{_TICKET_PREFIX}{secrets.token_urlsafe(_TICKET_BYTES)}"
    try:
        thread = await asyncio.to_thread(
            store.create_feedback_thread,
            ticket_hash=sha256_hex(ticket), text=text, client_ref=client_ref, subject=subject,
            device_id=device["deviceId"] if device else None,
            account_id=device["accountId"] if device else None, **fields)
    except Conflict:
        return json_error(400, "feedback/bad-request", "clientRef has already been used")
    except StoreError:
        LOGGER.exception("mail: storing a feedback thread failed")
        return json_error(500, "feedback/store-error", "the mail service could not store the feedback")
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
                             with_notices=bool(body.get("notices", True)))
    return web.json_response({"ok": True, **payload})


async def feedback_append(request: web.Request) -> web.Response:
    """用户在已有线程下补充一句（异步留言，不是即时对话）。"""
    store: Store = request.app["store"]
    body, error = await _json_body(request)
    if error is not None:
        return error
    thread_id, ticket = body.get("threadId"), body.get("ticketKey")
    if not isinstance(thread_id, str) or not thread_id \
            or not isinstance(ticket, str) or not ticket:
        return json_error(400, "feedback/bad-request", "threadId and ticketKey are required")
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

    thread = await asyncio.to_thread(store.feedback_thread, thread_id, sha256_hex(ticket),
                                     messages_per_thread=0)
    if thread is None:
        return _not_found()
    try:
        message = await asyncio.to_thread(
            store.append_feedback_message, thread_id, text, author="user", client_ref=client_ref,
            bind_device_id=device["deviceId"] if device else None,
            bind_account_id=device["accountId"] if device else None)
    except StoreError:
        LOGGER.exception("mail: storing a feedback message failed")
        return json_error(500, "feedback/store-error", "the mail service could not store the message")
    if message is None:                      # 与上面同一条 404：不泄露线程是否存在
        return _not_found()
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
        if thread_id in allowed:
            await asyncio.to_thread(store.mark_thread_read, thread_id)
    if device is not None and notice_ids:
        await asyncio.to_thread(store.mark_notices_read, device["accountId"], notice_ids)
    payload = await _collect(store, pairs, device, 0)
    return web.json_response({"ok": True, "unreadCount": payload["unreadCount"]})


def register_mail_routes(app: web.Application, route: Any) -> None:
    """挂四条信件路由（`route` 负责带前缀/去前缀的双注册，见 mail.py）。"""
    route("POST", "/feedback/submit", feedback_submit)
    route("POST", "/feedback/inbox", feedback_inbox)
    route("POST", "/feedback/append", feedback_append)
    route("POST", "/feedback/read", feedback_read)
