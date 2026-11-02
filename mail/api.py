"""mail 的公网接口：信件端点（四条老路由 + 通知正文的按需入口）。

与中转版的差异只有一处：`_caller` 不再读本库的设备表（mail 没有身份数据），
而是经 `app["resolve_device"]`（生产实现是 :mod:`internal` 的中转内部接口客户端）
把设备令牌换成归属；解析不到就是匿名，与中转版"坏令牌当匿名"的语义逐字一致。

四条老路由的契约、限流、校验与旧实现保持逐字一致（老 App 零改动），
`POST /feedback/notice` 是 2026-10-27 整改（M2）新增的正文入口：v2 的列表只给摘要。

收件箱有两种投影（`_inbox_v1` / `_inbox_v2`），由请求的 `inboxVersion` 选择；
两者共用同一次取数与同一份未读聚合，v1 只是同一批行的旧形状。

附件（2026-11-02）是**三条新路由**：`begin` / `upload` / `fetch`。上传体是原始
字节流（`request.content`，不经 `_json_body`，因此不受 40 KB / 64 KB 限制），
上限与字节桶都是附件自己的；授权沿用 append 那一份三选一（:func:`_authorize_thread`）。
v1 投影一个附件字段都不加，附件只出现在 v2。
"""

from __future__ import annotations

import asyncio
import codecs
import ipaddress
import json
import logging
import os
import re
import secrets
import time
from typing import Any
from urllib.parse import quote

from aiohttp import web

import attachments as attachment_files
from store import (DEFAULT_FEEDBACK_FORMAT, MAX_SUBJECT_CHARS, Conflict, EmptyLetter,
                   QuotaExceeded, SealedLetter, Store, StoreError, clean_feedback_format,
                   is_user_letter, my_side, my_unread, page_thread_rows, sha256_hex)

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
    # 附件（2026-11-02，设计 §3.3）：前三个与 `types` 会下发给客户端（v2
    # `limits.attachments`），其余是服务端内部口径（线程合计、全库软上限、字节桶）。
    "attachments": {
        "maxPerMessage": 8,
        "maxFileBytes": 8 * 1024 * 1024,
        "maxTotalBytes": 24 * 1024 * 1024,
        "maxPerThreadBytes": 48 * 1024 * 1024,
        "storageSoftBytes": 2 * 1024 * 1024 * 1024,
        "uploadBytesPerIp": 100 * 1024 * 1024,
        "uploadBytesPerDevice": 200 * 1024 * 1024,
        "uploadBytesPerDeviceDay": 500 * 1024 * 1024,
        "types": ["jpeg", "png", "heic", "pdf", "txt", "log", "csv", "json"],
    },
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
_SHA256_RE = re.compile(r"^[0-9a-fA-F]{64}$")

#: 附件白名单：声明的 MIME → 种类（种类就是 v2 `limits.attachments.types` 里的值）。
#: 约定见设计 §3.4：图片、PDF、纯文本族；视频 / SVG / HTML / 压缩包 / Office 一律不收。
ATTACHMENT_CONTENT_TYPES = {
    "image/jpeg": "jpeg",
    "image/png": "png",
    "image/heic": "heic",
    "image/heif": "heic",
    "application/pdf": "pdf",
    "text/plain": "txt",
    "text/log": "log",
    "text/x-log": "log",
    "text/csv": "csv",
    "application/json": "json",
}
#: 原始文件名的上限（设计 §3.1：≤120 字符，去掉路径分隔符与控制字符）。
MAX_ATTACHMENT_NAME_CHARS = 120
_ONE_DAY_S = 24 * 60 * 60

#: 魔数（设计 §3.4）：声明的 MIME 与实际字节不符即 415。纯文本族没有魔数，
#: 改判"前 64 KiB 可按 UTF-8 解码且没有 NUL 字节"。
ATTACHMENT_MAGIC = {
    "image/jpeg": (b"\xff\xd8\xff",),
    "image/png": (b"\x89PNG\r\n\x1a\n",),
    "application/pdf": (b"%PDF",),
}
#: HEIC 的判定：偏移 4 起是 `ftyp`，品牌（偏移 8）在这四个里。
HEIF_BRANDS = (b"heic", b"heix", b"hevc", b"mif1")
TEXT_CONTENT_TYPES = {"text/plain", "text/log", "text/x-log", "text/csv", "application/json"}

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


class ByteBudget:
    """按字节累加的滑动窗口（附件上传的带宽/磁盘封口）。

    与 :class:`ClaimLimiter` **并列**而不是替换：次数桶保护请求频率，字节桶保护
    带宽与磁盘，两者量纲不同，合成一个数会同时失去两种精度（设计 §3.3）。
    与次数桶一样是进程内内存：本服务单进程，重启清零（风险表里写明）。
    """

    def __init__(self, *, limit: int, window_s: float):
        self.limit = limit
        self.window_s = window_s
        self._spent: dict[str, list[tuple[float, int]]] = {}

    @staticmethod
    def _now() -> float:
        try:
            return asyncio.get_running_loop().time()
        except RuntimeError:
            import time
            return time.monotonic()

    def spent(self, key: str) -> int:
        """当前窗口内这个键已经用掉的字节数（顺手裁掉过期记录）。"""
        now = self._now()
        kept = [(at, size) for at, size in self._spent.get(key, [])
                if now - at < self.window_s]
        self._spent[key] = kept
        return sum(size for _, size in kept)

    def blocked(self, key: str, amount: int = 0) -> bool:
        """再用 `amount` 字节会不会超（`amount=0` 就是"现在是否已经超了"）。"""
        return self.spent(key) + int(amount) > self.limit

    def charge(self, key: str, amount: int) -> None:
        if amount <= 0:
            return
        self._spent.setdefault(key, []).append((self._now(), int(amount)))


@web.middleware
async def cors_preflight(request: web.Request, handler: Any) -> web.StreamResponse:
    if request.method == "OPTIONS":
        return web.Response(status=204, headers=CORS_HEADERS)
    return await handler(request)


# ── 信件接口本体 ───────────────────────────────────────────────────────────

def _now_ms() -> int:
    """毫秒时间戳（与库里 `createdAt` / `storedAt` 同单位）。"""
    return int(time.time() * 1000)


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


def _attachment_limits(request: web.Request) -> dict[str, Any]:
    """这次请求生效的附件上限：默认值来自 `LIMITS`，`create_app(attachment_limits=…)` 可覆盖。"""
    return request.app["attachment_limits"]


def _byte_budget(app: web.Application, name: str, limit: int,
                 window_s: float) -> ByteBudget:
    budget = app.get(name)
    if budget is None:
        budget = ByteBudget(limit=limit, window_s=window_s)
        app[name] = budget
    return budget


def _upload_budgets(request: web.Request, device: dict[str, Any] | None
                    ) -> list[tuple[ByteBudget, str]]:
    """上传字节桶的键：来源 IP / 设备（10 分钟）/ 设备（按天）。"""
    limits = _attachment_limits(request)
    buckets = [(_byte_budget(request.app, "feedback_attachment_bytes_ip",
                             int(limits["uploadBytesPerIp"]), _LIMIT_WINDOW_S),
                client_identifier(request))]
    if device is not None:
        buckets.append((_byte_budget(request.app, "feedback_attachment_bytes_device",
                                     int(limits["uploadBytesPerDevice"]), _LIMIT_WINDOW_S),
                        device["deviceId"]))
        buckets.append((_byte_budget(request.app, "feedback_attachment_bytes_device_day",
                                     int(limits["uploadBytesPerDeviceDay"]), _ONE_DAY_S),
                        device["deviceId"]))
    return buckets


def _check_upload_bytes(request: web.Request, device: dict[str, Any] | None,
                        amount: int) -> web.Response | None:
    """这一笔字节还抬得动吗？抬不动回 429（与次数桶同一个码）。"""
    for budget, key in _upload_budgets(request, device):
        if budget.blocked(key, amount):
            return json_error(429, "feedback/rate-limited",
                              "too much attachment traffic; try again later")
    return None


def _charge_upload_bytes(request: web.Request, device: dict[str, Any] | None,
                         amount: int) -> None:
    for budget, key in _upload_budgets(request, device):
        budget.charge(key, amount)


def _abort(response: web.Response) -> web.Response:
    """不回话就把连接关掉：拒绝大上传时**不读请求体**（读了就等于替攻击者搬字节）。"""
    response.force_close()
    return response


def _quota_error(quota: QuotaExceeded, limits: dict[str, Any]) -> web.Response:
    """附件配额不足的统一映射：全库软上限 507，其余（单封/单线程）413。"""
    if quota.reason == "storage":
        return json_error(507, "feedback/storage-full",
                          "the mail service is out of attachment storage")
    return json_error(413, "feedback/too-large",
                      f"this letter may hold at most {int(limits['maxPerMessage'])}"
                      f" attachments / {int(limits['maxTotalBytes'])} bytes")


def _empty_letter() -> web.Response:
    return json_error(400, "feedback/bad-request",
                      "a letter needs text or at least one stored attachment")


def _conflict() -> web.Response:
    return json_error(409, "feedback/attachment-conflict",
                      "this attachment already holds different bytes")


def _attachment_name_of(body: dict[str, Any]) -> tuple[str | None, web.Response | None]:
    """原始文件名：去掉路径分隔符与控制字符（不承载用户内容的那部分才落盘）。"""
    value = body.get("name")
    if not isinstance(value, str):
        return None, json_error(400, "feedback/bad-request", "name is required")
    cleaned = "".join(ch for ch in value.replace("\\", "/").split("/")[-1]
                      if ch >= " " and ch != "\x7f").strip()
    if not cleaned:
        return None, json_error(400, "feedback/bad-request", "name must not be blank")
    if len(cleaned) > MAX_ATTACHMENT_NAME_CHARS:
        return None, json_error(400, "feedback/bad-request",
                                f"name may be at most {MAX_ATTACHMENT_NAME_CHARS} characters")
    return cleaned, None


def _attachment_type_of(body: dict[str, Any]) -> tuple[str | None, web.Response | None]:
    value = body.get("contentType")
    if not isinstance(value, str):
        return None, json_error(400, "feedback/bad-request", "contentType is required")
    if value.strip().lower() not in ATTACHMENT_CONTENT_TYPES:
        return None, json_error(415, "feedback/attachment-type",
                                "contentType must be one of: "
                                + ", ".join(sorted(ATTACHMENT_CONTENT_TYPES)))
    return value.strip().lower(), None


def _attachment_size_of(body: dict[str, Any], limits: dict[str, Any]
                        ) -> tuple[int | None, web.Response | None]:
    value = body.get("byteSize")
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        return None, json_error(400, "feedback/bad-request",
                                "byteSize must be a positive integer")
    if value > int(limits["maxFileBytes"]):
        return None, json_error(413, "feedback/too-large",
                                f"a file may be at most {int(limits['maxFileBytes'])} bytes")
    return value, None


def _attachment_digest_of(body: dict[str, Any]) -> tuple[str | None, web.Response | None]:
    value = body.get("sha256")
    if not isinstance(value, str) or not _SHA256_RE.match(value):
        return None, json_error(400, "feedback/bad-request",
                                "sha256 must be 64 hexadecimal characters")
    return value.lower(), None


def _attachment_bytes_match(content_type: str, head: bytes) -> bool:
    """声明的类型与收到的开头字节对不对得上（设计 §3.4 的魔数嗅探）。

    纯文本族没有魔数，判据是"前 64 KiB 能按 UTF-8 解码且没有 NUL 字节"；
    断言不成立就是"声明与实际不符"，调用方回 415。
    """
    if content_type in TEXT_CONTENT_TYPES:
        try:
            codecs.getincrementaldecoder("utf-8")().decode(head, False)
        except UnicodeDecodeError:
            return False
        return b"\x00" not in head
    if content_type in ("image/heic", "image/heif"):
        return len(head) >= 12 and head[4:8] == b"ftyp" and head[8:12] in HEIF_BRANDS
    signatures = ATTACHMENT_MAGIC.get(content_type, ())
    return any(head.startswith(signature) for signature in signatures)


def _attachment_side_of(body: dict[str, Any], key: str) -> tuple[int | None, web.Response | None]:
    value = body.get(key)
    if value is None:
        return None, None
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        return None, json_error(400, "feedback/bad-request",
                                f"{key} must be a positive integer")
    return value, None


def _letter_text_of(body: dict[str, Any]) -> tuple[str | None, web.Response | None]:
    """正文（**v4 起允许为空**）；空正文能不能算一封信由绑定结果判（见 store）。

    类型与长度仍在这里判：`text` 必须是字符串、不超过既有字数/字节上限。空串返回
    `""`（不是 None）——"没写字"和"没给这个字段"在 v4 里是同一件事。
    """
    text = body.get("text", "")
    if not isinstance(text, str):
        return None, json_error(400, "feedback/bad-request", "text must be a string")
    trimmed = text.strip()
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


def _limits_payload(messages_per_thread: int, threads_limit: int, notices_limit: int,
                    attachment_limits: dict[str, Any]) -> dict:
    """v2 下发的上限：客户端只认这些数，编译期常量只作旧服务端回退（P0-3）。

    `attachments` 缺失 = 附件功能关闭（旧服务端 / 运维方关停）；客户端不得用编译期
    常量兜底去猜"应该支持"，只按这里下发的值显示入口与口径（设计 §3.2e）。
    """
    return {"textChars": LIMITS["textChars"], "textBytes": LIMITS["textBytes"],
            "subjectChars": LIMITS["subjectChars"],
            "maxTicketPairs": LIMITS["maxTicketPairs"],
            "messagesPerThread": messages_per_thread,
            "threadPageSize": threads_limit, "noticePageSize": notices_limit,
            "attachments": {
                "maxPerMessage": int(attachment_limits["maxPerMessage"]),
                "maxFileBytes": int(attachment_limits["maxFileBytes"]),
                "maxTotalBytes": int(attachment_limits["maxTotalBytes"]),
                "types": list(attachment_limits["types"])}}


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


def _public_attachment(row: dict[str, Any]) -> dict[str, Any]:
    """附件在 wire 上的形状（v2 的留言、通知与通知详情共用这一份）。

    只列**已存**的附件：`pending`（还没传完）与 `lost`（行在文件没了）都不上线，
    客户端不该看到"发不出去的附件"。
    """
    return {"attachmentId": row["attachmentId"], "name": row["fileName"],
            "contentType": row["contentType"], "byteSize": int(row["byteSize"]),
            "sha256": row["sha256"], "width": row["width"], "height": row["height"],
            "createdAt": int(row["createdAt"])}


def _stored_attachments(message: dict[str, Any]) -> list[dict[str, Any]]:
    """只列**已绑定**（`messageId` 非空）且 `stored` 的行：草稿不进任何投影。"""
    return [_public_attachment(row) for row in message.get("attachments", [])
            if _is_stored(row) and row.get("messageId")]


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
    messages = []
    for message in thread.get("messages", []):
        item = {"messageId": message["messageId"], "author": message["author"],
                "body": message["body"],
                "format": message.get("format") or DEFAULT_FEEDBACK_FORMAT,
                "createdAt": message["createdAt"]}
        if v2:
            item["attachments"] = _stored_attachments(message)
        messages.append(item)
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


def _public_notice(notice: dict[str, Any], *, v2: bool = False,
                   with_attachments: bool | None = None) -> dict[str, Any]:
    """通知的契约字段：v1 内联正文，v2 只给摘要（正文走 `POST /feedback/notice`）。"""
    # v1 的键序与拆分前一致（body 在 format 之前）；v2 只给摘要。
    payload: dict[str, Any] = {"noticeId": notice["noticeId"], "subject": notice["subject"]}
    if not v2:
        payload["body"] = notice["body"]
    payload["format"] = notice.get("format") or DEFAULT_FEEDBACK_FORMAT
    payload["createdAt"] = notice["createdAt"]
    payload["read"] = bool(notice["read"])
    # v2 摘要带附件；`/feedback/notice`（详情）在没有版本声明的情况下也带——
    # 它本来就是"按需取全文"的新入口，不是 v1 快照的一部分。
    wants_attachments = v2 if with_attachments is None else with_attachments
    if wants_attachments:
        payload["attachments"] = [_public_attachment(row)
                                  for row in notice.get("attachments", [])
                                  if _is_stored(row)]
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
    text, error = _letter_text_of(body)
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
    limits = _attachment_limits(request)
    usable = _stored_bytes_usable(request.app["attachments_root"])
    try:
        thread = await asyncio.to_thread(
            store.create_feedback_thread,
            ticket_hash=sha256_hex(ticket), text=text, client_ref=client_ref, subject=subject,
            device_id=device["deviceId"] if device else None,
            account_id=account_id, limits=limits, usable=usable, **fields)
    except EmptyLetter:
        return _empty_letter()
    except QuotaExceeded as quota:
        return _quota_error(quota, limits)
    except Conflict:
        return json_error(400, "feedback/bad-request", "clientRef has already been used")
    except StoreError:
        LOGGER.exception("mail: storing a feedback thread failed")
        return json_error(500, "feedback/store-error", "the mail service could not store the feedback")
    # 新信进了团队收件箱：团队的其他设备（含主人自己的手机）当场就知道，不必等前台刷新。
    await _notify_account_state(request, team if reaches_team else None)
    return web.json_response({"ok": True, "threadId": thread["threadId"],
                              "ticketKey": ticket, "createdAt": thread["createdAt"],
                              "messageId": thread["messageId"],
                              "attachmentsBound": int(thread["attachmentsBound"])})


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
            limit, threads_page["limit"], notice_page["limit"],
            _attachment_limits(request))))
    return web.json_response(_inbox_v1(snapshot))


async def _authorize_thread(request: web.Request, store: Store, thread_id: str,
                            ticket: str | None, device: dict[str, Any] | None
                            ) -> tuple[dict[str, Any] | None, bool]:
    """线程的授权：取件凭据 / 设备绑定 / 团队侧，三选一（与 append 同一份实现）。

    返回 `(线程行, 是不是团队侧)`；三种都不成立时返回 `(None, False)`，调用方回
    与"线程不存在"逐字节相同的 404（不泄露线程是否存在）。

    **给了但错的凭据不因为兜底而放行**：凭据没命中时才按设备/团队判。
    """
    ticket_hash = sha256_hex(ticket) if ticket else None
    thread = None
    ticket_ok = False
    if ticket_hash is not None:
        thread = await asyncio.to_thread(store.feedback_thread, thread_id, ticket_hash,
                                         messages_per_thread=0)
        ticket_ok = thread is not None
    if thread is None:
        thread = await asyncio.to_thread(store.feedback_thread, thread_id, None,
                                         messages_per_thread=0)
    device_bound = bool(
        thread is not None and device is not None
        and (thread.get("deviceId") == device["deviceId"]
             or (device.get("accountId") and thread.get("accountId") == device["accountId"])))
    team_side = _is_team_side(request, device, thread)
    if not (ticket_ok or device_bound or team_side):
        return None, False
    return thread, team_side


def _stored_bytes_usable(root: str) -> Any:
    """给 store 的绑定用的判据：文件在、且大小与登记的 `byteSize` 一致。

    存储层不认识磁盘布局（设计的所有权划分），所以"能不能用"由这一层注入；不可用的
    行会被 store 直接标成 `lost`，不计入 `attachmentsBound`（避免"发出去了但取不到"）。
    """
    def usable(row: dict[str, Any]) -> bool:
        try:
            path = attachment_files.path_for(root, row["storedPath"] or "")
        except attachment_files.AttachmentPathError:
            return False
        return os.path.isfile(path) and os.path.getsize(path) == int(row["byteSize"])
    return usable


def _identities(device_id: str | None, account_id: str | None) -> set[tuple[str, str]]:
    """把"设备 + 账号"归一成身份集合（丢弃空值），供归属求交。"""
    pairs = (("device", device_id), ("account", account_id))
    return {(kind, value) for kind, value in pairs if value}


def _draft_owner_ok(row: dict[str, Any], device: dict[str, Any] | None) -> bool:
    """新信草稿（`threadId` 缺）只对它签发时的设备/账号开放（§2.4）。

    判据是**身份集合求交**：行允许的身份（origin 设备/账号）与调用者的身份（设备/
    账号）有交集即成立；行没有 origin 时允许集为空，交集必空。
    `clientRef` 不是凭据：拿到它取不到字节、也绑不走别人的草稿。
    """
    caller = _identities(device["deviceId"] if device else None,
                         device.get("accountId") if device else None)
    allowed = _identities(row.get("originDeviceId"), row.get("originAccountId"))
    return bool(caller & allowed)


async def _attachment_access(request: web.Request, store: Store, row: dict[str, Any],
                             ticket: str | None, device: dict[str, Any] | None) -> bool:
    """附件的两段授权（`begin`/`upload`/`fetch`/`discard` 共用这一份）：

    - 行上有 `threadId`（回信草稿或已绑定）→ 与 append 相同的线程三选一；
    - 行上没有 `threadId`（新信草稿）→ 只认 `originDeviceId` / `originAccountId`。
    """
    if row.get("threadId"):
        thread, _team_side = await _authorize_thread(request, store, row["threadId"],
                                                     ticket, device)
        return thread is not None
    return _draft_owner_ok(row, device)


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
    text, error = _letter_text_of(body)
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
    # 判据本身在 `_authorize_thread` 一处（附件三个路由共用，不写第二份）。
    thread, team_side = await _authorize_thread(request, store, thread_id, ticket, device)
    if thread is None:
        return _not_found()
    limits = _attachment_limits(request)
    try:
        message = await asyncio.to_thread(
            store.append_feedback_message, thread_id, text,
            author="owner" if team_side else "user", client_ref=client_ref,
            bind_device_id=device["deviceId"] if device and not team_side else None,
            bind_account_id=device["accountId"] if device and not team_side else None,
            limits=limits, usable=_stored_bytes_usable(request.app["attachments_root"]))
    except EmptyLetter:
        return _empty_letter()
    except Conflict:
        # 这个 clientRef 属于另一条线程（或那条留言不属于这条线程）：不复用、不重绑。
        return json_error(409, "feedback/attachment-conflict",
                          "this clientRef already belongs to another letter")
    except QuotaExceeded as quota:
        return _quota_error(quota, limits)
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
                              "messageId": message["messageId"],
                              "createdAt": message["createdAt"],
                              "attachmentsBound": int(message["attachmentsBound"])})


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
        if not row:
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
    return web.json_response({"ok": True, "notice": _public_notice(
        notice, with_attachments=True)})


async def feedback_attachment_begin(request: web.Request) -> web.Response:
    """登记一条附件**草稿**（v4：先传后发）：授权 → 校验 → 配额 → 写 `pending` 行。

    幂等键是 `(clientRef, slot)`：同一封信的同一序号重来、且文件相同 → 返回既有行；
    同一个 slot 换文件 → 409。新信草稿（不给 `threadId`）必须有设备令牌——没有归属
    的调用方不能先传，"无主字节"因此不存在；回信草稿走线程三选一。
    """
    store: Store = request.app["store"]
    body, error = await _json_body(request)
    if error is not None:
        return error
    if body.get("messageId") is not None:
        # v4 删掉了"先 submit 拿 messageId 再传附件"的旧顺序；这里硬拒，免得旧客户端
        # 静默把附件挂到别处。
        return json_error(400, "feedback/bad-request",
                          "attachment begin no longer takes messageId; pass clientRef and slot")
    client_ref, error = _client_ref_of(body)
    if error is not None:
        return error
    if not client_ref:
        return json_error(400, "feedback/bad-request", "clientRef is required")
    slot = body.get("slot")
    if not isinstance(slot, int) or isinstance(slot, bool) or slot < 0:
        return json_error(400, "feedback/bad-request",
                          "slot must be a non-negative integer")
    thread_id = body.get("threadId")
    if thread_id is not None and (not isinstance(thread_id, str) or not thread_id):
        return json_error(400, "feedback/bad-request",
                          "threadId must be a non-empty string")
    ticket = body.get("ticketKey")
    if ticket is not None and (not isinstance(ticket, str) or not ticket):
        return json_error(400, "feedback/bad-request", "ticketKey must be a non-empty string")
    name, error = _attachment_name_of(body)
    if error is not None:
        return error
    limits = _attachment_limits(request)
    content_type, error = _attachment_type_of(body)
    if error is not None:
        return error
    byte_size, error = _attachment_size_of(body, limits)
    if error is not None:
        return error
    digest, error = _attachment_digest_of(body)
    if error is not None:
        return error
    width, error = _attachment_side_of(body, "width")
    if error is not None:
        return error
    height, error = _attachment_side_of(body, "height")
    if error is not None:
        return error
    if slot >= int(limits["maxPerMessage"]):
        return json_error(413, "feedback/too-large",
                          f"slot must be below {int(limits['maxPerMessage'])}")

    device = await _caller(request)
    error = _charge(request, "write", device)
    if error is not None:
        return error
    # 只查"现在是否已经超了"（amount=0）：真正的字节在 upload 落盘时按实收累加。
    error = _check_upload_bytes(request, device, 0)
    if error is not None:
        return error
    if thread_id is not None:
        thread, _team_side = await _authorize_thread(request, store, thread_id, ticket, device)
        if thread is None:
            return _not_found()
    elif device is None:
        return json_error(400, "feedback/bad-request",
                          "a draft attachment needs a device token")
    try:
        row = await asyncio.to_thread(
            store.begin_attachment, draft_ref=client_ref, slot=slot, thread_id=thread_id,
            file_name=name, content_type=content_type, byte_size=byte_size, sha256=digest,
            width=width, height=height, limits=limits,
            origin_device_id=None if thread_id else device["deviceId"],
            origin_account_id=None if thread_id else device.get("accountId"))
    except SealedLetter:
        # 这封信已经提交过：不再接受新草稿（owner 裁定"提交即封口"，R5）。
        return json_error(409, "feedback/attachment-conflict",
                          "this letter has already been sent")
    except Conflict:
        # 同一 slot 换文件、或这个 slot 属于别人的那封信：都不回显任何字段（F-V4-3）。
        return json_error(409, "feedback/attachment-conflict",
                          "this slot is already taken by another file or letter")
    except QuotaExceeded as quota:
        return _quota_error(quota, limits)
    except StoreError:
        LOGGER.exception("mail: registering an attachment failed")
        return json_error(500, "feedback/store-error",
                          "the mail service could not store the attachment")
    return web.json_response({"ok": True, "attachmentId": row["attachmentId"],
                              "state": row["state"], "byteSize": int(row["byteSize"]),
                              "sha256": row["sha256"], "createdAt": int(row["createdAt"])})


async def _upload_chunks(request: web.Request):
    """把原始请求体当字节流读（`readany()` 不经 `client_max_size`，自己数字节）。"""
    while True:
        chunk = await request.content.readany()
        if not chunk:
            return
        yield chunk


#: 附件的状态集合：判断"这一行是什么"只查这两个集合，不再到处写字面量比较。
STORED_STATES = frozenset({"stored"})
LOST_STATES = frozenset({"lost"})

#: 附件端点的**策略表（唯一事实）**：`(行状态, 阶段)` → 动作名。
#: 阶段由 :func:`_attachment_phase` 合成（草稿 / 已发出 / 丢了）；表里没有的组合
#: 一律按 `not-found`（与"附件不存在"逐字节相同）。新增端点或状态只改这张表。
ATTACHMENT_POLICY: dict[str, dict[tuple[str, str], str]] = {
    "upload": {
        ("pending", "draft"): "store-bytes",    # 没传完的草稿：收字节
        ("stored", "draft"): "verify-bytes",    # 已传完的草稿：核 sha，幂等
        ("stored", "sent"): "verify-bytes",     # 已发出的信：只允许幂等重传
    },
    "fetch": {
        ("stored", "draft"): "serve-bytes",     # 草稿：只有签发它的设备能取
        ("stored", "sent"): "serve-bytes",      # 已绑定：同线程可取
    },
    "discard": {
        ("pending", "draft"): "drop-draft",
        ("stored", "draft"): "drop-draft",
        ("stored", "sent"): "reject-sent",      # 已发出的信不许删附件
    },
}

#: 策略里"当场给答案"的动作 → Response 工厂；能继续走处理流程的动作不在这张表里。
ATTACHMENT_ACTION_RESPONSES: dict[str, Any] = {
    "not-found": _not_found,
    "reject-sent": lambda: json_error(409, "feedback/attachment-conflict",
                                      "a sent letter keeps its attachments"),
}


def _is_stored(row: dict[str, Any]) -> bool:
    """这一行是不是"已存好"的附件（投影与清扫共用同一个集合判据）。"""
    return row.get("state") in STORED_STATES


def _attachment_phase(row: dict[str, Any]) -> str:
    """一行附件此刻的阶段：`lost` / `sent`（已绑定）/ `draft`（还没提交）。

    `state` 与 `messageId` 的合成只在这一处；其余地方只读阶段名。
    """
    if row.get("state") in LOST_STATES:
        return "lost"
    return "sent" if row.get("messageId") is not None else "draft"


def _attachment_action(endpoint: str, row: dict[str, Any]) -> str:
    """这个端点对这样一行该做什么——查策略表，不在 handler 里写状态判断。"""
    return ATTACHMENT_POLICY[endpoint].get((row.get("state"), _attachment_phase(row)),
                                           "not-found")


def _attachment_action_response(action: str) -> web.Response | None:
    """策略表里"当场给答案"的动作 → Response；`store-bytes` 这类能继续的动作 → None。"""
    factory = ATTACHMENT_ACTION_RESPONSES.get(action)
    return None if factory is None else factory()


def _upload_length_guard(row: dict[str, Any], length: int | None,
                         limits: dict[str, Any]) -> web.Response | None:
    """`Content-Length` 必须在读体之前等于登记的 `byteSize`（不替攻击者搬字节）。

    只对"还没传完"的行调用：已 `stored` 的行要读完体核 sha256（F1），由
    :func:`_confirm_stored_upload` 决定 200/409。
    """
    declared = int(row["byteSize"])
    if length is None or length != declared or declared > int(limits["maxFileBytes"]):
        return _abort(json_error(
            413, "feedback/too-large",
            f"Content-Length must equal the declared byteSize ({declared})"))
    return None


async def _confirm_stored_upload(request: web.Request, row: dict[str, Any],
                                 written: dict[str, Any], declared: int) -> web.Response:
    """已 `stored` 行的重传：**读完体、核 sha256**，相同才 200（F1）。

    - 字节或长度与行内登记值不符 → 409 `feedback/attachment-conflict`（旧字节不动）；
    - 相同但落盘文件不见了（外部误删）→ 把这次收到的字节补回去再回 200，仍是同一个
      `storedPath`（F5 第二条：不许回一个"事实不成立"的 200）；
    - `storedPath` 坏掉 → 与不存在同一条 404（F3 的同一条口径）。
    """
    temp = written["tempPath"]
    if written["byteSize"] != declared or written["sha256"] != row["sha256"]:
        attachment_files.delete(temp)
        return _abort(_conflict())
    if not row["storedPath"]:
        attachment_files.delete(temp)
        return _not_found()
    root = request.app["attachments_root"]
    try:
        final = attachment_files.path_for(root, row["storedPath"])
    except attachment_files.AttachmentPathError:
        attachment_files.delete(temp)
        return _not_found()
    # "文件可用"要两个条件：在、且大小等于登记的 byteSize（F9）。被截断/写坏的文件
    # 视同不可用——这一笔收到的字节本来就与行内摘要相符，直接补写回同一个路径。
    usable = await asyncio.to_thread(os.path.isfile, final) \
        and await asyncio.to_thread(os.path.getsize, final) == declared
    if usable:
        attachment_files.delete(temp)
    else:
        await asyncio.to_thread(attachment_files.finish, temp, final)
    return web.json_response({"ok": True, "attachmentId": row["attachmentId"],
                              "state": "stored", "byteSize": declared,
                              "sha256": row["sha256"],
                              "storedAt": int(row["storedAt"] or 0)})


async def feedback_attachment_upload(request: web.Request) -> web.Response:
    """原始字节流 → 临时件 → 复核 sha256 → 落盘（`os.replace`）。

    `Content-Length` 必须先与登记的 `byteSize` 相等：不等就直接 413，**不读请求体**，
    并把连接关掉（`_abort`）。边写边数，超声明立刻停并删临时件。
    """
    store: Store = request.app["store"]
    attachment_id = (request.query.get("attachmentId") or "").strip()
    if not attachment_id:
        return json_error(400, "feedback/bad-request", "attachmentId is required")
    # 计数必须在**任何查库与鉴权之前**（与 fetch 同序）：否则伪造的 attachmentId
    # 走的就是"404 且不计数"的路，写桶对这个端点等于没有（R1）。
    # 代价是"合法但不存在"的 404 也计入预算——与 append/fetch 的口径一致，
    # 30 次 / 10 min 的写入桶对正常客户端（一封信最多 8 个附件）足够宽。
    device = await _caller(request)
    error = _charge(request, "write", device)
    if error is not None:
        return error
    row = await asyncio.to_thread(store.attachment, attachment_id)
    if not row:
        return _not_found()
    ticket = request.headers.get("X-Feedback-Ticket") or None
    if not await _attachment_access(request, store, row, ticket, device):
        return _not_found()
    limits = _attachment_limits(request)
    action = _attachment_action("upload", row)
    blocked = _attachment_action_response(action)
    if blocked is not None:
        return blocked
    verify_only = action == "verify-bytes"       # 已 stored 的行只做幂等复核（F1）
    declared = int(row["byteSize"])
    if not verify_only:
        error = _upload_length_guard(row, request.content_length, limits)
        if error is not None:
            return error
    error = _check_upload_bytes(request, device, declared)
    if error is not None:
        return error

    root = request.app["attachments_root"]
    temp = attachment_files.temp_path(root)
    try:
        written = await attachment_files.write_stream(
            temp, _upload_chunks(request), declared_bytes=declared)
    except attachment_files.AttachmentTooLarge:
        if verify_only:
            return _abort(_conflict())
        return _abort(json_error(413, "feedback/too-large",
                                 f"the upload exceeded the declared {declared} bytes"))
    # 读进来多少字节就记多少账：这条通路只在这里写一次字节桶（不重复计数）。
    _charge_upload_bytes(request, device, written["byteSize"])
    if verify_only:
        return await _confirm_stored_upload(request, row, written, declared)
    if not _attachment_bytes_match(row["contentType"], written["head"]):
        attachment_files.delete(written["tempPath"])
        return json_error(415, "feedback/attachment-type",
                          f"the bytes do not look like {row['contentType']}")
    if written["byteSize"] != declared or written["sha256"] != row["sha256"]:
        attachment_files.delete(written["tempPath"])
        return json_error(400, "feedback/bad-request",
                          "the uploaded bytes do not match the declared size and sha256")
    stored_at = _now_ms()
    final = attachment_files.final_path(root, stored_at, attachment_id)
    relative = attachment_files.stored_path(stored_at, attachment_id)
    await asyncio.to_thread(attachment_files.finish, written["tempPath"], final)
    marked = await asyncio.to_thread(store.mark_attachment_stored, attachment_id,
                                     relative, stored_at)
    if not marked:
        # 行在这次上传期间被清扫删掉了：没人认领的字节不许留在磁盘上，也不许回
        # 一个"已存好"的 200（F5）。
        attachment_files.delete(final)
        return _not_found()
    # 上传**不**通知对端：附件在提交前是草稿，对端不该被 ping；同一次发送里 8 个附件
    # 也不该变成 8 次扇出。真正的"信到了"由 submit/append 成功时那一次通知负责。
    return web.json_response({"ok": True, "attachmentId": attachment_id, "state": "stored",
                              "byteSize": declared, "sha256": row["sha256"],
                              "storedAt": stored_at})


async def feedback_attachment_fetch(request: web.Request) -> web.Response:
    """凭据换字节：行必须 `stored`，`scope` 那一侧的权限必须过；404 统一。

    响应头固定四件（Content-Type / Content-Length / Content-Disposition / nosniff）
    外加 `Cache-Control: private, max-age=0, no-transform`：内容按 id 不变，但权限
    可能被撤销，所以不进中间层缓存；客户端按 sha256 自己缓存。
    """
    store: Store = request.app["store"]
    body, error = await _json_body(request)
    if error is not None:
        return error
    attachment_id = body.get("attachmentId")
    if not isinstance(attachment_id, str) or not attachment_id:
        return json_error(400, "feedback/bad-request", "attachmentId is required")
    ticket = body.get("ticketKey")
    if ticket is not None and (not isinstance(ticket, str) or not ticket):
        return json_error(400, "feedback/bad-request", "ticketKey must be a non-empty string")
    device = await _caller(request)
    error = _charge(request, "read", device)
    if error is not None:
        return error
    row = await asyncio.to_thread(store.attachment, attachment_id)
    if not row:
        return _not_found()
    if row["scope"] == "notice":
        # 通知附件只对"这条通知投给这个账号"的人开放（没有账号 = 匿名 = 404）。
        if device is None:
            return _not_found()
        notice = await asyncio.to_thread(store.notice_for_account, device["accountId"],
                                         row["noticeId"])
        if notice is None:
            return _not_found()
    elif not await _attachment_access(request, store, row, ticket, device):
        return _not_found()
    blocked = _attachment_action_response(_attachment_action("fetch", row))
    if blocked is not None:
        return blocked
    if not row["storedPath"]:
        return _not_found()
    try:
        path = attachment_files.path_for(request.app["attachments_root"], row["storedPath"])
    except attachment_files.AttachmentPathError:
        # 库里的路径坏掉时仍然是"取不到"，与不存在同一条 404（F3；不泄露根目录布局）。
        return _not_found()
    if not await asyncio.to_thread(os.path.isfile, path):
        return _not_found()          # 行在文件没了：清扫负责标 lost，这里只如实 404
    if await asyncio.to_thread(os.path.getsize, path) != int(row["byteSize"]):
        # 大小与登记不符（被截断/写坏）：不许按登记的 Content-Length 送残缺字节，
        # 否则客户端会挂在那条长度上（F9）。与不存在同一条 404。
        return _not_found()
    response = web.StreamResponse(headers={
        "Content-Type": row["contentType"],
        "Content-Length": str(int(row["byteSize"])),
        "Content-Disposition": f"attachment; filename*=UTF-8''{quote(row['fileName'])}",
        "X-Content-Type-Options": "nosniff",
        "Cache-Control": "private, max-age=0, no-transform",
    })
    await response.prepare(request)
    async for chunk in attachment_files.open_stream(path):
        await response.write(chunk)
    await response.write_eof()
    return response


async def feedback_attachment_discard(request: web.Request) -> web.Response:
    """删一条**草稿**附件（取消/放弃这封信时立即回收字节）。

    只允许 `messageId IS NULL` 的行：已发出的信不许客户端删附件（409）。请求里的
    `clientRef` 必须等于行内 `draftRef`（不等 → 404，防拿错 id 删别人的草稿）。
    """
    store: Store = request.app["store"]
    body, error = await _json_body(request)
    if error is not None:
        return error
    attachment_id = body.get("attachmentId")
    if not isinstance(attachment_id, str) or not attachment_id:
        return json_error(400, "feedback/bad-request", "attachmentId is required")
    client_ref = body.get("clientRef")
    if not isinstance(client_ref, str) or not client_ref:
        return json_error(400, "feedback/bad-request", "clientRef is required")
    ticket = body.get("ticketKey")
    if ticket is not None and (not isinstance(ticket, str) or not ticket):
        return json_error(400, "feedback/bad-request", "ticketKey must be a non-empty string")
    device = await _caller(request)
    error = _charge(request, "write", device)
    if error is not None:
        return error
    row = await asyncio.to_thread(store.attachment, attachment_id)
    if not row:
        return _not_found()
    # 归属判定在"是否已发出"之前：否则匿名调用方能靠 409 分出"这封信已经发出"还是
    # "仍是草稿"，等于泄漏别人的信件状态（F-V4-2）。未授权一律 404。
    if not await _attachment_access(request, store, row, ticket, device):
        return _not_found()
    blocked = _attachment_action_response(_attachment_action("discard", row))
    if blocked is not None:
        return blocked
    if client_ref != row["draftRef"]:
        return _not_found()
    stored_path = await asyncio.to_thread(store.delete_attachment, attachment_id)
    if stored_path is None:                       # 并发里已经被删掉了
        return _not_found()
    if stored_path:
        try:
            path = attachment_files.path_for(request.app["attachments_root"], stored_path)
        except attachment_files.AttachmentPathError:
            path = None
        if path is not None:
            attachment_files.delete(path)
    return web.json_response({"ok": True, "attachmentId": attachment_id, "deleted": True})


def register_mail_routes(app: web.Application, route: Any) -> None:
    """挂信件路由（`route` 负责带前缀/去前缀的双注册，见 mail.py）。

    四条老路由的契约不变；`/feedback/notice` 是通知正文的按需入口（M2）；
    四个 `/feedback/attachment/*` 是附件通路（2026-11-02；v4 加 `discard`），与老
    路由同一个 origin、同一份鉴权、同一个 Caddy handle（不需要新块）。
    """
    route("POST", "/feedback/submit", feedback_submit)
    route("POST", "/feedback/inbox", feedback_inbox)
    route("POST", "/feedback/append", feedback_append)
    route("POST", "/feedback/read", feedback_read)
    route("POST", "/feedback/notice", feedback_notice)
    route("POST", "/feedback/attachment/begin", feedback_attachment_begin)
    route("POST", "/feedback/attachment/upload", feedback_attachment_upload)
    route("POST", "/feedback/attachment/fetch", feedback_attachment_fetch)
    route("POST", "/feedback/attachment/discard", feedback_attachment_discard)
