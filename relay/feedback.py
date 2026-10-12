"""Feedback channel: the four append-only HTTP endpoints (014).

``POST /feedback/submit`` — 新建线程（另收可选的 ``subject``，≤80 字符，界面重做后
「写反馈」里的那一行标题），返回一次性的取件凭据（`ticketKey` 只在这里出现）。
``POST /feedback/inbox``  — 拉取线程与通知，**不改任何已读状态**。
``POST /feedback/append`` — 用户在已有线程下补充，线程回到 ``open``。
``POST /feedback/read``   — 标记已读；线程按凭据或设备授权，通知只按设备。

鉴权是可选的（``Authorization: Bearer <deviceToken>``）：有效就绑定设备与账号；
**无效（撤销、过期、乱填）不返回 401，按匿名处理**——一块过期的设备令牌不该让用户
提交不了意见。四个接口都是这条口径。

限流：``submit``/``append`` 按来源（``client_identifier``）与设备令牌各一桶，
``inbox``/``read`` 用更宽的读桶；命中限流**不写库**。正文、字段与请求体的上限见下面的
常量，与 ``specs/014-feedback-channel/contracts/feedback-http.md`` 逐字一致。

正文格式（FR-034）：**我们**发出的正文（owner 回信、通知）自带 ``format``，取值只认
``store.FEEDBACK_FORMATS``（``text`` 由手机按 Markdown 渲染 / ``html`` 走锁死的容器），
非法取值按契约回 400；用户自己提交的正文永远是 ``text``，不进这条分支。

SQL 全在 :mod:`store` 里（本模块只管 HTTP、校验与授权）。
"""

from __future__ import annotations

import asyncio
import logging
import re
import secrets
from typing import Any

from aiohttp import web

from api import ClaimLimiter, bearer_token, client_identifier, json_error, read_json
from store import (DEFAULT_FEEDBACK_FORMAT, MAX_SUBJECT_CHARS, Conflict, Store, StoreError,
                   clean_feedback_format, sha256_hex)

LOGGER = logging.getLogger("relay.feedback")

#: 与 data-model.md 的"校验规则（服务端强制的部分）"逐字一致。
_MAX_TEXT_CHARS = 4000
_MAX_TEXT_BYTES = 8000
_MAX_BODY_BYTES = 16 * 1024
_MAX_TECH_CHARS = 64
# 主题的上限只有一处定义（`store.MAX_SUBJECT_CHARS`）：接口层与 owner 侧命令
# （`feedback-reply --subject`）必须同一条线，这里 import 而不是再写一个 80。
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


def _not_found() -> web.Response:
    """"线程不存在"与"凭据不匹配"**共用这一个响应**：逐字节相同，不泄露线程是否存在。"""
    return json_error(404, "feedback/not-found", "thread not found")


def _limiter(app: web.Application, key: str, limit: int) -> ClaimLimiter:
    """这个 app 上属于某个桶的限流器，第一次用到时建。

    建在这里而不是 ``api.register_http_routes``，是为了让那边的改动只剩四行注册；
    按 app 而不是模块级，是为了两个 app（测试每个用例建一个）不共用预算。
    """
    limiter = app.get(key)
    if limiter is None:
        limiter = ClaimLimiter(limit=limit, window_s=_LIMIT_WINDOW_S)
        app[key] = limiter
    return limiter


def _charge(request: web.Request, kind: str, device: dict[str, Any] | None) -> web.Response | None:
    """把这次调用记到调用方的预算上；预算用尽返回 429。

    ``count_failure`` 的全局失败计数是给配对接口看的，反馈的每一次调用都要计数
    （不是失败），所以这里传 ``total=False``，不去污染那个数字。
    """
    write = kind == "write"
    buckets = [(f"feedback_{kind}_limiter", client_identifier(request),
                _WRITE_LIMIT if write else _READ_LIMIT)]
    if write and device is not None:
        buckets.append(("feedback_write_device_limiter", device["deviceId"], _WRITE_DEVICE_LIMIT))
    for name, key, limit in buckets:
        if _limiter(request.app, name, limit).blocked(key):
            return json_error(429, "feedback/rate-limited",
                              "too many feedback requests; try again later")
    for name, key, limit in buckets:
        _limiter(request.app, name, limit).count_failure(key, total=False)
    return None


async def _json_body(request: web.Request) -> tuple[dict[str, Any] | None, web.Response | None]:
    """按 16 KB 上限读 JSON 体，超限直接 413。

    app 自己的 ``client_max_size`` 是 WebSocket 帧的大小（几十 MB），对公开写入接口
    太宽；``files_up`` 那种流式读取更是完全不看它。所以这里显式计数。
    """
    raw = await request.read()
    if len(raw) > _MAX_BODY_BYTES:
        return None, json_error(413, "feedback/too-large", "the request body may be at most 16 KB")
    body = await read_json(request)
    if body is None:
        return None, json_error(400, "feedback/bad-request", _JSON_OBJECT)
    return body, None


def _text_of(body: dict[str, Any]) -> tuple[str | None, web.Response | None]:
    """用户正文（去首尾空白）；空、类型不对、超长按契约分别拒绝。"""
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
    """可选主题（≤80 字符）：去首尾空白，空白按未填处理（不是错误）。

    类型不对按契约回 `feedback/bad-request`，超长回 `feedback/too-long`——与 `text`
    分开判定：主题超长不该把整封反馈说成"正文太长"。
    """
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
    """自动附带的技术信息（版本/机型/iOS）；各 64 字符上限。"""
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
    """请求体里可选的 ``format``；非法取值按契约回 400，缺字段回 ``None``。

    契约里带 ``format`` 的是**我们发出**的正文（回信与通知），用户提交的正文永远是
    ``text``：所以这里的返回值只用来校验，写入路径两处都是写死的 ``text``。给一个
    我们不认的值（"rtf"、数字、空白以外的东西）在这里就按 400 拒掉，而不是存进库、
    等 App 的渲染分支去猜。

    规范化（去首尾空白、空 → 默认）走 :func:`store.clean_feedback_format`，与 owner
    侧命令、两张表的默认值共用同一份取值定义。
    """
    if body.get("format") is None:
        return None, None
    try:
        return clean_feedback_format(body.get("format")), None
    except StoreError:
        return None, json_error(400, "feedback/bad-request", "format must be text or html")


def _client_ref_of(body: dict[str, Any]) -> tuple[str | None, web.Response | None]:
    """幂等键：≤64 且只允许 ``[A-Za-z0-9._-]``（空字符串等于没带）。"""
    value = body.get("clientRef")
    if value is None or value == "":
        return None, None
    if not isinstance(value, str) or len(value) > _MAX_CLIENT_REF_CHARS \
            or not _CLIENT_REF_RE.match(value):
        return None, json_error(400, "feedback/bad-request",
                                "clientRef may be at most 64 characters of [A-Za-z0-9._-]")
    return value, None


def _ticket_pairs(body: dict[str, Any]) -> tuple[list[tuple[str, str]] | None, web.Response | None]:
    """``tickets`` 里的 ``(threadId, ticketKey)`` 对，最多 50 对。"""
    raw = body.get("tickets")
    if raw is None:
        return [], None
    if not isinstance(raw, list) or len(raw) > _MAX_TICKETS:
        return None, json_error(400, "feedback/bad-request",
                                f"tickets may hold at most {_MAX_TICKETS} entries")
    pairs: list[tuple[str, str]] = []
    for item in raw:
        if not isinstance(item, dict):
            return None, json_error(400, "feedback/bad-request", "each ticket needs threadId and ticketKey")
        thread_id, ticket = item.get("threadId"), item.get("ticketKey")
        if not isinstance(thread_id, str) or not thread_id \
                or not isinstance(ticket, str) or not ticket:
            return None, json_error(400, "feedback/bad-request", "each ticket needs threadId and ticketKey")
        pairs.append((thread_id, ticket))
    return pairs, None


def _id_list(body: dict[str, Any], key: str) -> tuple[list[str] | None, web.Response | None]:
    """一串 id（去重、限长）；缺字段等于空表。"""
    raw = body.get(key)
    if raw is None:
        return [], None
    if not isinstance(raw, list) or len(raw) > _MAX_IDS \
            or not all(isinstance(item, str) and item for item in raw):
        return None, json_error(400, "feedback/bad-request", f"{key} must be a list of ids")
    return list(dict.fromkeys(raw)), None


def _messages_limit(body: dict[str, Any]) -> tuple[int | None, web.Response | None]:
    """``messagesPerThread`` 默认 50，上限 200（超出取最近的 200 条）。"""
    raw = body.get("messagesPerThread", _DEFAULT_MESSAGES_PER_THREAD)
    if not isinstance(raw, int) or isinstance(raw, bool) or raw < 1:
        return None, json_error(400, "feedback/bad-request",
                                "messagesPerThread must be a positive integer")
    return min(raw, _MAX_MESSAGES_PER_THREAD), None


async def _caller(request: web.Request) -> dict[str, Any] | None:
    """可选令牌背后的设备；``None`` 就是匿名。

    撤销、过期、乱填的令牌在这里都变成"匿名"，**不是错误**（见模块 docstring）。
    """
    token = bearer_token(request)
    if not token:
        return None
    return await asyncio.to_thread(request.app["store"].device_by_token, token)


def _public_thread(thread: dict[str, Any]) -> dict[str, Any]:
    """只留契约里的字段：``ticketHash`` 与来源信息这类内部列不得出网。

    ``subject`` 是可选主题，没填就是 ``null``——服务端不替客户端补正文首句。
    ``messages[].format`` 是那条留言的正文格式（FR-034）；缺列按 ``text`` 兜底，
    老 App 拿到它也不会比拿不到更糟。
    """
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
    """调用方看得到的线程（凭据命中 ∪ 设备命中，去重）与未读计数。"""
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
        notices = await asyncio.to_thread(store.notices_for_device, device["deviceId"])
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
    # 用户提交的正文永远是 `text`（见 `_format_of`）：这里只把不合法的取值挡在 400。
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
        # 这个 clientRef 已经属于别的来源：不新建，也不把那条线程交出去。
        return json_error(400, "feedback/bad-request", "clientRef has already been used")
    except StoreError:
        LOGGER.exception("relay: storing a feedback thread failed")
        return json_error(500, "feedback/store-error", "the relay could not store the feedback")
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
    # 与 `submit` 同一条：用户补充的正文永远是 `text`，只校验取值合不合法。
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
        LOGGER.exception("relay: storing a feedback message failed")
        return json_error(500, "feedback/store-error", "the relay could not store the message")
    if message is None:                      # 与上面同一条 404：不泄露线程是否存在
        return _not_found()
    return web.json_response({"ok": True, "threadId": thread_id,
                              "messageId": message["messageId"], "createdAt": message["createdAt"]})


async def feedback_read(request: web.Request) -> web.Response:
    """标记已读；只有调用方能证明的线程才标得动，notice 只按设备标。"""
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
        await asyncio.to_thread(store.mark_notices_read, device["deviceId"], notice_ids)
    payload = await _collect(store, pairs, device, 0)
    return web.json_response({"ok": True, "unreadCount": payload["unreadCount"]})
