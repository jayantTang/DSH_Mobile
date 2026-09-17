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
from typing import Any

PROTOCOL_VERSION = 1

#: Hard frame ceiling, aligned with DSH's image-attachment limit.
MAX_FRAME_BYTES = 32 * 1024 * 1024

DEVICE_TO_AGENT = frozenset({"req", "open", "cancel", "eventResult", "ping", "hello"})
AGENT_TO_DEVICE = frozenset({"res", "item", "end", "streamError", "event", "hostStatus", "pong", "error"})
RELAY_TO_AGENT = frozenset({"deviceAttach", "deviceDetach"})

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
