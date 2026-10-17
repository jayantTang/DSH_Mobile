"""DLP v1 frame codec and validation.

The relay is a *transparent* forwarder: it never interprets DSH semantics. It
only needs enough structure to know which direction a frame travels and which
device it belongs to. Everything else is passed through verbatim, including
frame types this version does not know (``t`` is forward-compatible by design).

Wire summary (see ``docs/RELAY-PROTOCOL.md`` §3):

  device -> agent   req / open / cancel / eventResult / ping / hello
  agent  -> device  res / item / end / streamError / event / hostStatus / pong / error

Two frame families are relay-internal control frames (they never cross to the
other side): ``deviceAttach`` / ``deviceDetach`` (relay -> agent) describe a
device's lifecycle so the agent can open and tear down that device's ``$events``
streams. The relay also stamps ``deviceId`` onto every forwarded frame, because
one agent WebSocket multiplexes every device.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any

PROTOCOL_VERSION = 1

#: Hard frame ceiling, aligned with DSH's image-attachment limit.
MAX_FRAME_BYTES = 32 * 1024 * 1024

DEVICE_TO_AGENT = frozenset({"req", "open", "cancel", "eventResult", "ping", "hello"})
#: 朝设备方向走的帧。`accountState` 由**中转自己**发出（032：账户级状态变了），
#: 与连接器发的那些同属这一类；契约表 `docs/relay-contract.json` 是同一份口径。
AGENT_TO_DEVICE = frozenset({"res", "item", "end", "streamError", "event", "hostStatus", "pong", "error",
                            "accountState"})
RELAY_TO_AGENT = frozenset({"deviceAttach", "deviceDetach"})

#: Agent-side control frames: connector → relay, **never forwarded to a device**
#: (they are not DLP; a phone neither sends nor receives them). ``notify`` is the
#: "a run finished / something needs you" ping the relay turns into an APNs push
#: when the device is offline (R-1 C-02/C-06).
AGENT_CONTROL = frozenset({
    "notify",
    "fsPutBegin", "fsPutChunk", "fsPutEnd", "fsPutAck", "fsPutDone",
    "fsGetBegin", "fsGetChunk", "fsGetEnd", "fsGetAck",
    "fsErr",
})

#: Control frames the **relay sends to the agent** for a download bridge. Same
#: family as ``AGENT_CONTROL`` but the other direction, so it cannot live in
#: that set: that one is what the relay accepts *from* a connector. Not part of
#: DLP either — a phone neither sends nor receives these.
RELAY_TO_AGENT_CONTROL = frozenset({"fsGetCancel"})

#: Frame types that carry a unary request and therefore need an ``id``.
_ID_FRAMES = frozenset({"req", "open", "cancel", "res", "item", "end", "streamError", "eventResult"})


class FrameError(ValueError):
    """A frame that cannot be routed (not JSON, not an object, no usable ``t``)."""


def parse_frame(raw: str | bytes) -> dict[str, Any]:
    """Decode one WebSocket text payload into a frame object.

    Raises :class:`FrameError` for anything that is not a JSON object with a
    non-empty string ``t``. Unknown ``t`` values are *not* an error here; the
    caller decides whether to forward or ignore them.
    """
    if isinstance(raw, (bytes, bytearray, memoryview)):
        try:
            text = bytes(raw).decode("utf-8")
        except UnicodeDecodeError as error:
            raise FrameError("frame is not valid UTF-8") from error
    else:
        text = raw
    if len(text) > MAX_FRAME_BYTES:
        raise FrameError(f"frame exceeds {MAX_FRAME_BYTES} bytes")
    try:
        value = json.loads(text)
    except (ValueError, TypeError) as error:
        raise FrameError("frame is not JSON") from error
    if not isinstance(value, dict):
        raise FrameError("frame must be a JSON object")
    frame_type = value.get("t")
    if not isinstance(frame_type, str) or not frame_type:
        raise FrameError("frame is missing a non-empty string `t`")
    return value


def encode_frame(frame: dict[str, Any]) -> str:
    """Encode a frame. ``ensure_ascii`` keeps the payload byte-exact across hops."""
    return json.dumps(frame, ensure_ascii=False, separators=(",", ":"))


# ── UTF-16 代理项（2026-10-17 生产事故的修复点）──────────────────────────────
#
# JSON 允许 `"\ud83d"` 这种**没有配对**的转义，`json.loads` 会原样交出一个落单的
# 代理项字符。它没法按 UTF-8 编码，于是 `text.encode("utf-8")` 抛
# `UnicodeEncodeError`：中转算流量的那一句把整个 agent 链路带崩，手机卡在"连接中"。
# 为什么会切出落单代理项见 `relay/monitor.py` 的记录（诊断字段能回答"是不是卡在帧
# 尾部"）。
#
# 这里的约定：**中转永远不因为一个坏字符丢掉整条链路**。落单代理项换成 U+FFFD
# （Unicode 的"读不出来"），照常计费、照常转发。

#: 任何落单的 UTF-16 代理项。配对的两个在 `json.loads` 阶段已经合并成一个字符，
#: 所以 str 里出现代理项时一定是坏的。用 raw 串，让正则自己解释 `\uXXXX`。
SURROGATE_PATTERN = re.compile(r"[\ud800-\udfff]")

#: 落单代理项的替身。U+FFFD 是合法字符，iOS 照常解码，只显示成一个方块。
REPLACEMENT_CHARACTER = "\ufffd"

#: 诊断记录里保留多长的上下文。够看出被切开的是什么（emoji、中文、JSON 转义），
#: 又不至于把用户内容写进日志。
_CONTEXT_CHARS = 24


@dataclass(frozen=True)
class SurrogateDamage:
    """一处（或几处）落单代理项的形态与位置——只用于排障。

    字段刻意都是"位置"而不是"内容"：这个类只在真的遇到坏字符时构造，进的是运维
    告警，所以**不**带正文，只带 `context` 那一小段。
    """

    count: int
    total_chars: int
    first_index: int
    trailing_chars: int
    kinds: str
    context: str

    def as_details(self) -> dict[str, Any]:
        return {
            "count": self.count,
            "totalChars": self.total_chars,
            "firstIndex": self.first_index,
            "trailingChars": self.trailing_chars,
            "kinds": self.kinds,
            "context": self.context,
        }


def _describe_damage(text: str) -> SurrogateDamage:
    """扫描一遍坏文本，算出第一处落单代理项的位置与周围上下文。"""
    matches = list(SURROGATE_PATTERN.finditer(text))
    first = matches[0]
    high = sum(1 for m in matches if "\ud800" <= m.group() <= "\udbff")
    low = len(matches) - high
    kinds = "high" if low == 0 else "low" if high == 0 else "mixed"
    start = max(0, first.start() - _CONTEXT_CHARS)
    end = min(len(text), first.end() + _CONTEXT_CHARS)
    snippet = SURROGATE_PATTERN.sub(REPLACEMENT_CHARACTER, text[start:end])
    return SurrogateDamage(
        count=len(matches),
        total_chars=len(text),
        first_index=first.start(),
        trailing_chars=len(text) - first.end(),
        kinds=kinds,
        context=snippet,
    )


def prepare_outbound(text: str) -> tuple[str, int, SurrogateDamage | None]:
    """Make ``text`` sendable and return ``(clean_text, utf8_size, damage)``.

    ``utf8_size`` is the length of what will actually go on the wire, which is
    also what the daily allowance is charged. The fast path is one ``encode`` —
    the same call the relay already made, so the common case costs nothing extra.
    """
    try:
        return text, len(text.encode("utf-8")), None
    except UnicodeEncodeError:
        damage = _describe_damage(text)
        clean = SURROGATE_PATTERN.sub(REPLACEMENT_CHARACTER, text)
        return clean, len(clean.encode("utf-8")), damage


def utf8_len(text: str) -> int:
    """Byte length on the wire, never raising (see :func:`prepare_outbound`)."""
    return prepare_outbound(text)[1]


def frame_type(frame: dict[str, Any]) -> str:
    return str(frame.get("t"))


def has_id(frame: dict[str, Any]) -> bool:
    value = frame.get("id")
    return isinstance(value, str) and len(value) > 0


def validate_from_device(frame: dict[str, Any]) -> str | None:
    """Return an error string when a device frame is structurally unusable."""
    kind = frame_type(frame)
    if kind in DEVICE_TO_AGENT and kind in _ID_FRAMES and not has_id(frame):
        return f"{kind}: missing `id`"
    if kind == "req" and not isinstance(frame.get("method"), str):
        return "req: missing `method`"
    if kind == "open" and not isinstance(frame.get("endpoint"), str):
        return "open: missing `endpoint`"
    return None


def validate_from_agent(frame: dict[str, Any]) -> str | None:
    """Return an error string when an agent frame is structurally unusable."""
    kind = frame_type(frame)
    if kind in AGENT_TO_DEVICE and kind in _ID_FRAMES and not has_id(frame):
        return f"{kind}: missing `id`"
    return None


def device_id_of(frame: dict[str, Any]) -> str | None:
    value = frame.get("deviceId")
    return value if isinstance(value, str) and value else None


def addressing_device(frame: dict[str, Any]) -> dict[str, Any] | None:
    """Return a copy addressed at one device, dropping the relay-internal key."""
    device_id = device_id_of(frame)
    if device_id is None:
        return None
    addressed = dict(frame)
    addressed.pop("deviceId", None)
    addressed["deviceId"] = device_id
    return addressed


def strip_device_id(frame: dict[str, Any]) -> dict[str, Any]:
    """Copy of ``frame`` without the relay-internal ``deviceId`` key."""
    if "deviceId" not in frame:
        return frame
    out = dict(frame)
    out.pop("deviceId", None)
    return out


def host_status(*, online: bool, agent_id: str | None = None, name: str | None = None,
                version: str | None = None, extra: dict[str, Any] | None = None) -> dict[str, Any]:
    """Build the ``hostStatus`` frame the relay pushes to devices."""
    info: dict[str, Any] = {"online": online}
    if agent_id is not None:
        info["agentId"] = agent_id
    if name is not None:
        info["name"] = name
    if version is not None:
        info["version"] = version
    if extra:
        info.update(extra)
    return {"t": "hostStatus", "info": info}


def error_frame(code: str, message: str, *, fatal: bool = False,
                details: dict[str, Any] | None = None) -> dict[str, Any]:
    frame: dict[str, Any] = {"t": "error", "code": code, "message": message}
    if fatal:
        frame["fatal"] = True
    if details:
        frame["details"] = details
    return frame


def device_attach_frame(device_id: str, *, name: str | None = None,
                        model: str | None = None, agent_id: str | None = None) -> dict[str, Any]:
    frame: dict[str, Any] = {"t": "deviceAttach", "deviceId": device_id}
    info: dict[str, Any] = {}
    if name is not None:
        info["name"] = name
    if model is not None:
        info["model"] = model
    if agent_id is not None:
        info["agentId"] = agent_id
    if info:
        frame["device"] = info
    return frame


def device_detach_frame(device_id: str, *, reason: str | None = None) -> dict[str, Any]:
    frame: dict[str, Any] = {"t": "deviceDetach", "deviceId": device_id}
    if reason:
        frame["reason"] = reason
    return frame
