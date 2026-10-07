"""Relay registry and routing.

One :class:`AgentLink` per ``agentId`` (a new connection supersedes the old
one) and one :class:`DeviceLink` per device WebSocket. Frames from a device are
stamped with that device's ``deviceId`` before they reach the agent, because the
agent's single WebSocket multiplexes every device; frames from the agent must
carry the same key so the relay knows where to deliver them.

Backpressure follows spec §5: each device owns two bounded queues (relay ->
device and device -> agent) capped at ``queue_depth`` frames. Overflow drops
that one device instead of growing relay memory. The agent link has its own,
much larger bound because losing it would drop every device at once.
"""

from __future__ import annotations

import asyncio
import logging
import os
import time
from typing import Any, Callable, Iterable

import dlp

#: WebSocket close codes used by the relay (application range).
#: Reserved method the phone calls once per connection. The connector answers
#: it; the relay only reads the arguments, because they carry the client's own
#: build — the one place it travels after pairing.
HELLO_METHOD = "_link/hello"

CLOSE_SUPERSEDED = 4001
CLOSE_BACKPRESSURE = 4008
CLOSE_RATE_LIMITED = 4009
CLOSE_AGENT_OFFLINE = 4010
CLOSE_QUOTA_EXCEEDED = 4011
#: The agent is at its device budget. Reported as a DLP ``error`` frame on an
#: accepted socket (see ``relay._refuse_upgrade``) rather than as a bare HTTP
#: 403 before the upgrade, so the phone can tell the person what happened.
CLOSE_DEVICE_LIMIT = 4012

#: Longest string handed to the WebSocket in one call while a device is over its
#: rate. ~1 MB of JSON: small enough that pacing is visible on the wire, large
#: enough that chunking costs almost nothing on a normal frame.
_CHUNK_CHARS = 512 * 1024


import store as store_module  # noqa: E402 - 与 store 同目录，relay.py 也是这样导入的


class TokenBucket:
    """Bytes-per-second allowance for one device.

    The relay runs on a **fixed-bandwidth** host, and that bandwidth is shared by
    every device on it. A single device uploading or downloading a few large
    frames — ten screenshots is 27 MB — would otherwise occupy the whole pipe for
    tens of seconds and slow down everybody else's session. That is not a
    malicious act, it is a normal one, so the fix is a plain token bucket rather
    than a ban.

    The bucket starts **full** with at least a small burst allowance, so an
    ordinary turn (a handful of small frames) never waits at all; only sustained
    volume is paced. Pacing happens in the link's writer, not by dropping: the
    frames still arrive, just spread over time, which is what a video-style
    stream should look like to the client.
    """

    __slots__ = ("rate", "burst", "tokens", "updated")

    def __init__(self, *, rate: float, burst: float | None = None, now: float | None = None):
        #: bytes per second; ``0`` or less disables pacing entirely.
        self.rate = max(0.0, float(rate))
        self.burst = float(burst if burst is not None else max(self.rate, 64 * 1024))
        self.tokens = self.burst
        self.updated = time.monotonic() if now is None else now

    @property
    def enabled(self) -> bool:
        return self.rate > 0

    def _refill(self, now: float) -> None:
        if now <= self.updated:
            return
        self.tokens = min(self.burst, self.tokens + (now - self.updated) * self.rate)
        self.updated = now

    def take(self, amount: int) -> float:
        """Charge ``amount`` bytes; return seconds to wait *before* sending them.

        A positive return means the caller is over its allowance and should sleep
        that long first. The charge is taken immediately either way, so a burst
        of small frames queues up in the same order it was written.
        """
        if not self.enabled:
            return 0.0
        now = time.monotonic()
        self._refill(now)
        self.tokens -= amount
        if self.tokens >= 0:
            return 0.0
        return -self.tokens / self.rate


class DailyQuota:
    """A per-device byte allowance for one **local** day.

    Rate pacing bounds how *fast* one device can move bytes; this bounds how many
    in a day, which is what protects a metered or fixed-bandwidth host from one
    device that simply runs all day.

    The count has to be the *day's*, not the *connection's*: a phone reconnects on
    a network change, after a background suspension, or because the relay was
    restarted, and a budget that resets each time bounds a connection rather than
    a day — which is not what "2 GB per day" says. The baseline therefore comes
    from ``usageDaily`` (via :meth:`RelayHub._quota_for`), and ``used`` here is
    that stored row plus whatever this connection has sent on top of it.

    The day is the **local** one from :func:`store.local_day`, the same function
    the accounting uses. The two used to be computed separately (local day for
    the report, UTC for the allowance), so "today's traffic" and "today's
    allowance" quietly described different days for anyone not on UTC.
    """

    __slots__ = ("limit", "used", "day")

    def __init__(self, *, limit: int, used: int = 0, day: int | None = None):
        self.limit = max(0, int(limit))
        today = store_module.local_day()
        # A baseline from a previous day is yesterday's news: start fresh.
        self.used = max(0, int(used)) if day is None or day == today else 0
        self.day = today

    @property
    def enabled(self) -> bool:
        return self.limit > 0

    def charge(self, amount: int, *, now: float | None = None) -> bool:
        """Account ``amount`` bytes; ``False`` means the day's allowance is gone."""
        if not self.enabled:
            return True
        today = store_module.local_day(now)
        if today != self.day:
            self.day = today
            self.used = 0
        self.used += amount
        return self.used <= self.limit

    def remaining(self) -> int:
        return max(0, self.limit - self.used) if self.enabled else -1


#: Raised by :meth:`RelayHub.attach_device` when an agent is already at its
#: device budget. The caller answers with a close instead of an accepted socket.
class DeviceLimitReached(Exception):
    pass


class Limits:
    """Tunables for the hub; the spec's numbers are the defaults."""

    def __init__(self, *, max_frame_bytes: int = dlp.MAX_FRAME_BYTES, queue_depth: int = 512,
                 agent_queue_depth: int = 4096, max_devices_per_agent: int = 0,
                 device_bytes_per_second: float = 0.0, device_daily_bytes: int = 0):
        self.max_frame_bytes = max_frame_bytes
        self.queue_depth = queue_depth
        self.agent_queue_depth = agent_queue_depth
        #: How many devices one agent may keep attached. ``0`` means unlimited.
        self.max_devices_per_agent = max(0, int(max_devices_per_agent))
        #: Per-device egress pacing, in bytes per second. ``0`` disables it.
        self.device_bytes_per_second = max(0.0, float(device_bytes_per_second))
        #: Per-device egress allowance per **local** day, in bytes. ``0`` disables
        #: it. The day is ``store.local_day()`` — the same one the accounting and
        #: the operator's report use (see :class:`DailyQuota`).
        self.device_daily_bytes = max(0, int(device_daily_bytes))

    def describe(self) -> dict[str, Any]:
        """The limits as they should appear in an operator-facing report."""
        return {
            "maxFrameBytes": self.max_frame_bytes,
            "queueDepth": self.queue_depth,
            "agentQueueDepth": self.agent_queue_depth,
            "maxDevicesPerAgent": self.max_devices_per_agent or None,
            "deviceBytesPerSecond": self.device_bytes_per_second or None,
            "deviceDailyBytes": self.device_daily_bytes or None,
        }


class Link:
    """A WebSocket plus one bounded outbound queue and its writer task."""

    def __init__(self, ws: Any, *, label: str, queue_depth: int, logger: logging.Logger):
        self.ws = ws
        self.label = label
        self.logger = logger
        self.closed = False
        self.reason: str | None = None
        self._queue: asyncio.Queue[str | None] = asyncio.Queue(maxsize=queue_depth)
        self._writer: asyncio.Task[None] | None = None
        self.dropped = 0

    def start(self) -> None:
        if self._writer is None:
            self._writer = asyncio.create_task(self._pump())

    async def _pump(self) -> None:
        try:
            while True:
                text = await self._queue.get()
                if text is None:
                    return
                await self._send(text)
        except asyncio.CancelledError:
            raise
        except Exception as error:  # socket gone; the reader loop handles teardown
            self.logger.debug("relay: %s writer stopped: %s", self.label, error)

    async def _send(self, text: str) -> None:
        """Put one frame on the wire. Subclasses may pace or account for it."""
        await self.ws.send_str(text)

    def enqueue_text(self, text: str) -> bool:
        """Queue one frame; ``False`` means the peer is too slow and must be dropped."""
        if self.closed:
            return False
        try:
            self._queue.put_nowait(text)
            return True
        except asyncio.QueueFull:
            self.dropped += 1
            return False

    def enqueue_frame(self, frame: dict[str, Any]) -> bool:
        return self.enqueue_text(dlp.encode_frame(frame))

    def pending(self) -> int:
        return self._queue.qsize()

    async def close(self, code: int = 1000, reason: str = "") -> None:
        if self.closed:
            return
        self.closed = True
        self.reason = reason or None
        if self._writer is not None:
            self._writer.cancel()
            try:
                await self._writer
            except (asyncio.CancelledError, Exception):  # noqa: B014 - cancellation is expected
                pass
            self._writer = None
        try:
            await self.ws.close(code=code, message=(reason or "").encode("utf-8")[:120])
        except Exception as error:
            self.logger.debug("relay: %s close failed: %s", self.label, error)

class DeviceLink(Link):
    """One device WebSocket, with per-device backpressure in both directions."""

    def __init__(self, ws: Any, *, device: dict[str, Any], logger: logging.Logger, limits: Limits):
        super().__init__(ws, label=f"device {device['deviceId']}", queue_depth=limits.queue_depth, logger=logger)
        self.device_id: str = device["deviceId"]
        self.agent_id: str = device["agentId"]
        self.account_id: str = device.get("accountId") or ""
        self.name: str = device["name"]
        self.model: str | None = device.get("model")
        self.app_version: str | None = device.get("appVersion")
        self.agent: AgentLink | None = None
        self._to_agent: asyncio.Queue[str | None] = asyncio.Queue(maxsize=limits.queue_depth)
        self._agent_pump: asyncio.Task[None] | None = None
        # Egress accounting and pacing. Both are per device, so one device that
        # moves a lot of bytes cannot slow down the others sharing the host's
        # fixed bandwidth (see TokenBucket).
        self.bucket = TokenBucket(rate=limits.device_bytes_per_second)
        self.quota = DailyQuota(limit=limits.device_daily_bytes)
        self.egress_bytes = 0
        self.paced_seconds = 0.0
        #: 记账回调（`RelayHub` 在 attach 时挂上）：每发出一段字节，hub 顺手累加进
        #: "今天这台设备用了多少"。放回调而不是让 link 自己写库，是因为这一刻在发送
        #: 热路径上——只做一次字典加法，写库留给周期冲盘。
        self.on_egress: Callable[[DeviceLink, int], None] | None = None

    def start(self) -> None:
        super().start()
        if self._agent_pump is None:
            self._agent_pump = asyncio.create_task(self._pump_to_agent())

    async def _send(self, text: str) -> None:
        """Send one frame, paced by this device's allowance.

        The bucket is charged **here**, in the writer, and the sender is left
        alone: a device that is merely over its rate still gets its frames, just
        spread over time. Charging at enqueue instead would let pacing fill the
        queue and turn "slow down" into "you are dropped for backpressure"
        (``4008``), which is a different and much worse message.

        A frame bigger than ``_CHUNK_CHARS`` is sent as several WebSocket
        messages so the socket is never handed megabytes in one call — a 2.7 MB
        screenshot used to be written in one burst no matter what the bucket
        said. The frame's bytes are charged against the allowance one chunk at a
        time, so the pacing stays smooth and nothing is charged twice.

        **The client has to put those messages back together**, and that is not
        free: WebSocket messages are not a byte stream, so a client that parses
        each ``receive()`` as one frame drops the first fragment as malformed
        JSON and the rest as garbage, and the call behind them never answers.
        The iOS app does reassemble them (``DSHKit/FrameAssembler.swift``); a
        connector or a future client must too. Writing the pieces as WebSocket
        *continuation* frames instead would remove the requirement entirely.
        """
        size = len(text.encode("utf-8"))
        if size <= _CHUNK_CHARS:
            await self.pace(size)
            await self.ws.send_str(text)
            self._count_egress(size)
            return

        # A long frame goes out in pieces so the socket is never handed megabytes
        # in one call — but every byte is charged against the allowance **once**.
        # Charging the whole frame first and then each chunk again took the
        # bucket negative by the frame's size twice, which is why a 20 Mbit
        # allowance delivered about 10.
        for start in range(0, len(text), _CHUNK_CHARS):
            chunk = text[start:start + _CHUNK_CHARS]
            chunk_bytes = len(chunk.encode("utf-8"))
            await self.pace(chunk_bytes)
            await self.ws.send_str(chunk)
            self._count_egress(chunk_bytes)

    async def pace(self, size: int) -> None:
        """Wait out this device's rate allowance for ``size`` bytes.

        **The one place pacing happens**, shared by the WebSocket writer above and
        by the relay's streaming `GET /files/down` response (R-1 C-19). The
        download path writes bytes into an HTTP body rather than a WebSocket
        message, so it cannot reuse `_send` — but it must charge the *same*
        bucket, or the new route would be a way around the per-device rate and
        the daily allowance. Extracted rather than copied for exactly that
        reason: two implementations would drift.
        """
        wait = self.bucket.take(size)
        if wait > 0:
            await asyncio.sleep(wait)
            self.paced_seconds += wait

    def charge_daily(self, size: int) -> bool:
        """Account ``size`` bytes against the day's allowance; ``False`` = spent.

        Callers decide what to do about it: the WebSocket path tells the device
        and closes it, the HTTP download ends the response with an error. What
        must not differ is the number.
        """
        if not self.quota.enabled:
            return True
        return self.quota.charge(size)

    def _count_egress(self, size: int) -> None:
        self.egress_bytes += size
        agent = self.agent
        if agent is not None:
            agent.egress_bytes += size
        if self.on_egress is not None:
            self.on_egress(self, size)

    def over_daily_quota(self) -> bool:
        return self.quota.enabled and self.quota.remaining() == 0

    async def _pump_to_agent(self) -> None:
        try:
            while True:
                text = await self._to_agent.get()
                if text is None:
                    return
                agent = self.agent
                if agent is None or not agent.enqueue_text(text):
                    # The agent is gone or saturated; the reader loop will
                    # observe the close and clean this device up.
                    self.logger.warning("relay: dropping %s (agent unavailable or saturated)", self.label)
                    asyncio.create_task(self.close(CLOSE_AGENT_OFFLINE, "agent unavailable"))
                    return
        except asyncio.CancelledError:
            raise
        except Exception as error:
            self.logger.debug("relay: %s agent pump stopped: %s", self.label, error)

    def enqueue_to_agent(self, frame: dict[str, Any]) -> bool:
        if self.closed:
            return False
        try:
            self._to_agent.put_nowait(dlp.encode_frame(frame))
            return True
        except asyncio.QueueFull:
            return False

    async def close(self, code: int = 1000, reason: str = "") -> None:
        if self._agent_pump is not None:
            self._agent_pump.cancel()
            try:
                await self._agent_pump
            except (asyncio.CancelledError, Exception):  # noqa: B014
                pass
            self._agent_pump = None
        await super().close(code, reason)

class AgentLink(Link):
    """The PC connector's WebSocket for one ``agentId``."""

    def __init__(self, ws: Any, *, agent: dict[str, Any], logger: logging.Logger, limits: Limits):
        super().__init__(ws, label=f"agent {agent['agentId']}", queue_depth=limits.agent_queue_depth,
                          logger=logger)
        self.agent_id: str = agent["agentId"]
        self.account_id: str = agent["accountId"]
        self.name: str = agent["name"]
        self.superseded = False
        self.devices: dict[str, DeviceLink] = {}
        #: Bytes this agent's devices have received since the relay started. Kept
        #: so an operator can answer "who is using the bandwidth" without a
        #: packet capture — the host's interface counters mix in SSH and OTA
        #: traffic and say nothing about which computer is responsible.
        self.egress_bytes = 0

    def broadcast(self, frame: dict[str, Any]) -> list[str]:
        """Send to every attached device; returns the ids that overflowed."""
        dropped: list[str] = []
        for device in list(self.devices.values()):
            if not device.enqueue_frame(frame):
                dropped.append(device.device_id)
        return dropped

class FileBridge:
    """One in-flight background upload, as seen from the relay.

    The HTTP request and the connector's `fs*` replies are two different
    conversations: this is the join between them. The request side awaits
    :meth:`wait`; :meth:`deliver` is called from the agent's socket handler.

    Deliberately **not** a queue and not durable: an upload that is interrupted
    is retried by the app from the beginning (the whole file goes again, with the
    same ``bid``, which the connector overwrites). Keeping partial state here
    would only invent a resumption protocol neither end has.
    """

    def __init__(self, *, bid: str, agent_id: str, logger: logging.Logger):
        self.bid = bid
        self.agent_id = agent_id
        self.logger = logger
        self.acknowledged = asyncio.Event()
        self.done: asyncio.Future[dict[str, Any]] = asyncio.get_running_loop().create_future()
        self.error: str | None = None

    def deliver(self, kind: str, frame: dict[str, Any]) -> bool:
        """One reply from the connector.

        Always ``True``: an upload bridge has no reader that can walk away
        mid-transfer — the request body is pushed by the caller and every reply
        lands in the same future, so no frame here is worth cancelling. The
        boolean exists so the shared routing layer can call both bridge kinds
        the same way; only :class:`FileFetchBridge` can report a reader that is
        gone.
        """
        if kind == "fsPutAck":
            self.acknowledged.set()
            return True
        if self.done.done():
            return True
        if kind == "fsPutDone":
            self.done.set_result(frame)
            self.acknowledged.set()
            return True
        if kind == "fsErr":
            # The connector answers with the same `{code, message}` shape it uses
            # for everything else; carry it through so the phone's error text is
            # the connector's, not a generic "upload failed".
            self.done.set_result({
                "error": frame.get("code") or "file/rejected",
                "message": frame.get("message") or "the connector refused the upload",
            })
            # A failure **is** an answer: a connector that rejects the transfer at
            # `fsPutBegin` never sends an ack, so without this the caller would sit
            # out the full ack deadline and report "connector too old" for what is
            # really "the connector said no".
            self.acknowledged.set()
        return True

    def fail(self, reason: str) -> None:
        """The agent went away (or the bridge was abandoned)."""
        self.error = reason
        self.acknowledged.set()
        if not self.done.done():
            self.done.set_result({"error": "host/offline", "message": reason})

    async def wait_ack(self, timeout: float) -> bool:
        """Wait for the connector to accept the transfer.

        A connector that predates these frames **silently ignores them** (unknown
        frame types are ignored by design), so "no ack" is the only signal that
        the far end is too old — hence a deadline rather than an open wait. The
        caller turns this into a 501 that says exactly that.
        """
        try:
            await asyncio.wait_for(self.acknowledged.wait(), timeout)
            return True
        except asyncio.TimeoutError:
            return False


class FileFetchBridge:
    """One in-flight background download (`GET /files/down`), R-1 C-19.

    Same join as :class:`FileBridge`, opposite direction, and one real
    difference: an upload is *pushed* by the request loop and only needs a final
    answer, while a download is *pulled* one window at a time and the HTTP
    response has to write each window **as it arrives**. So this one carries a
    queue of frames rather than a single future: the agent's socket handler
    appends, the response loop awaits, and neither ever holds more than the
    chunks already in flight.

    The queue is bounded. A phone that stops reading (or an HTTP client that
    walked away) must not let the connector fill the relay's memory with windows
    nobody will ever write — the response loop stops draining, the queue fills,
    and :meth:`deliver` reports it so the request can be abandoned.
    """

    #: How many `fsGetChunk` frames may sit un-consumed before the pull side is
    #: declared gone. Two windows is enough to keep the pipe full over a slow
    #: hop without letting a stalled reader accumulate a file.
    QUEUE_DEPTH = 8

    def __init__(self, *, bid: str, agent_id: str, logger: logging.Logger):
        self.bid = bid
        self.agent_id = agent_id
        self.logger = logger
        self.acknowledged = asyncio.Event()
        self.frames: asyncio.Queue[dict[str, Any] | None] = asyncio.Queue(
            maxsize=self.QUEUE_DEPTH)
        self.abandoned = False
        self.error: str | None = None
        #: Whether an `fsGetCancel` has already been sent for this bridge. Set
        #: once and never cleared: the connector ignores a cancel for a run it
        #: does not know, so a repeat is harmless, but sending one per stale
        #: frame would turn a superseded run into a burst of frames.
        self.cancel_requested = False
        #: The file's total size, from the connector's stat. `None` means the
        #: connector could not tell us — the response then has no total, exactly
        #: as before P-13b.
        self.size: int | None = None
        #: The file's version, from the same stat. `None` means no `ETag`, and so
        #: no `If-Range` check on a resume.
        self.version: str | None = None
        #: What the connector's `fsGetAck` said about the file: `size` and
        #: `version` when it could stat it, `{}` when it could not (P-13b).
        #:
        #: Read by the response loop to build a **resumable** answer: the total
        #: becomes `Content-Length` and a full `Content-Range`, and the version
        #: becomes the `ETag` an `If-Range` on a retry is checked against. A
        #: connector too old to send either leaves this empty and the route falls
        #: back to the streaming answer it has always given — the download still
        #: works, it just cannot be resumed by the system.

    def deliver(self, kind: str, frame: dict[str, Any]) -> bool:
        """One reply from the connector; ``False`` means the reader is gone.

        A ``False`` here is not an error to report — it means the HTTP request
        already gave up (the phone hung up, or the quota cut it off), and the
        connector's remaining windows have nowhere to go. The caller stops
        feeding them.
        """
        if kind == "fsGetAck":
            # `size`/`version` are what make the response resumable; both are
            # optional and a connector that omits them must not fail here.
            #
            # The ack is also the one reply a bridge accepts **after** being
            # abandoned. That is not laxness: the `If-Range` restart abandons a
            # run whose ack may still be in flight, and an ack carries only
            # metadata — it cannot corrupt the body the way a stale window can.
            # Data frames get no such grace, because a chunk from a superseded
            # run is exactly the corruption this class exists to refuse.
            size = frame.get("size")
            if isinstance(size, int) and size >= 0 and not isinstance(size, bool):
                self.size = size
            version = frame.get("version")
            if isinstance(version, str) and version:
                self.version = version
            self.acknowledged.set()
            return True
        if self.abandoned:
            return False
        if kind == "fsErr":
            # Same shape the upload bridge keeps: the phone must see the
            # connector's own code (`workspace-file/not-found`) so it can tell
            # "not worth retrying" from "the network hiccuped".
            self.end({
                "error": frame.get("code") or "file/rejected",
                "message": frame.get("message") or "the connector refused the download",
            })
            return True
        if kind == "fsGetChunk":
            try:
                self.frames.put_nowait(frame)
            except asyncio.QueueFull:
                self.logger.warning("relay: download %s is not being read; giving up", self.bid)
                self.abandoned = True
                return False
            return True
        if kind == "fsGetEnd":
            self.end(frame)
            return True
        return True

    def end(self, frame: dict[str, Any]) -> None:
        """Put the terminal frame behind every chunk already queued."""
        self.acknowledged.set()
        try:
            self.frames.put_nowait({**frame, "_terminal": True})
        except asyncio.QueueFull:
            # The reader is gone; dropping the terminal frame is fine, there is
            # nobody to tell.
            self.abandoned = True

    def fail(self, reason: str) -> None:
        """The agent went away (or the bridge was abandoned)."""
        self.error = reason
        self.end({"error": "host/offline", "message": reason})

    async def wait_ack(self, timeout: float) -> bool:
        """Wait for the connector to accept the fetch, same rule as uploads."""
        try:
            await asyncio.wait_for(self.acknowledged.wait(), timeout)
            return True
        except asyncio.TimeoutError:
            return False

    async def next_frame(self) -> dict[str, Any] | None:
        """The next chunk, or ``None`` when the response loop should stop."""
        if self.abandoned:
            return None
        return await self.frames.get()

    def abandon(self) -> None:
        """The reader stopped: stop accepting windows for this transfer."""
        self.abandoned = True


def _reconcile_interval_from_env() -> float:
    """``DLP_REVOKE_RECONCILE_S``, seconds; anything unparsable falls back to 5."""
    try:
        return float(os.environ.get("DLP_REVOKE_RECONCILE_S", "5"))
    except ValueError:
        return 5.0


class RelayHub:
    """Registry of live agents and devices plus the routing rules between them."""

    def __init__(self, store: Any, *, logger: logging.Logger | None = None, limits: Limits | None = None):
        self.store = store
        self.logger = logger or logging.getLogger("relay.hub")
        self.limits = limits or Limits()
        self.agents: dict[str, AgentLink] = {}
        self._devices: dict[str, DeviceLink] = {}
        # 由同步调用方（撤销设备的 HTTP handler）排下的 detach 任务，见
        # `schedule_detach`。持着引用，免得任务在半路被回收。
        self._detach_tasks: set[asyncio.Task[None]] = set()
        # 推送投递任务（见 `_notify`）：只为了持有引用，别让任务被回收。
        self._push_tasks: set[asyncio.Task[None]] = set()
        #: APNs 投递器（`push.py`）。默认 None = 不发推送（未配置的部署就是这样）。
        self.push: Any = None
        #: 进行中的 HTTP 上传桥（`bid → FileBridge`，见 `open_bridge`）。
        self._bridges: dict[str, FileBridge] = {}
        # 按天按设备的用量，攒在内存里、周期冲盘（见 `flush_usage`）。
        # 键是 (本地日, deviceId)，值是这一批的增量；库里那份是"已经加上去的"。
        self._usage: dict[tuple[int, str], dict[str, Any]] = {}
        self._usage_day = store_module.local_day()
        self._usage_bytes_since_flush = 0
        self._usage_task: asyncio.Task[None] | None = None
        self.usage_flush_interval = 30.0
        self.usage_flush_bytes = 1 << 20
        # 「库已撤销但 socket 还活着」的对账周期（见 reconcile_revoked_devices）。
        # 0 或负数 = 关掉（只给测试与极端场景用）。
        self.revoked_reconcile_interval = _reconcile_interval_from_env()
        self._reconcile_task: asyncio.Task[None] | None = None

    # ── agent lifecycle ─────────────────────────────────────────────────────

    async def attach_agent(self, agent: dict[str, Any], ws: Any) -> AgentLink:
        previous = self.agents.get(agent["agentId"])
        link = AgentLink(ws, agent=agent, logger=self.logger, limits=self.limits)
        self.agents[agent["agentId"]] = link
        if previous is not None and previous is not link:
            previous.superseded = True
            self.logger.info("relay: agent %s superseded by a new connection", agent["agentId"])
            await previous.close(CLOSE_SUPERSEDED, "superseded by a new agent connection")
        # Devices survive an agent outage (they are told the host is offline and
        # simply wait), so every live device of this agent is re-adopted here —
        # whether it was attached to a superseded connection or to nothing.
        for device in list(self._devices.values()):
            if device.agent_id != agent["agentId"] or device.closed:
                continue
            device.agent = link
            link.devices[device.device_id] = device
            link.enqueue_frame(dlp.device_attach_frame(
                device.device_id, name=device.name, model=device.model, agent_id=agent["agentId"]))
            device.enqueue_frame(dlp.host_status(
                online=True, agent_id=link.agent_id, name=agent["name"]))
        if previous is not None and previous is not link:
            previous.devices.clear()
        await self._tell_agent_about_the_gone(link, agent)
        self.logger.info("relay: agent %s connected (%s), %d device(s) re-adopted",
                         agent["agentId"], agent["name"], len(link.devices))
        return link

    async def _tell_agent_about_the_gone(self, link: AgentLink, agent: dict[str, Any]) -> None:
        """告诉刚连上的连接器：这些设备永远回不来了，把它们的值班流放掉。

        连接器可能还留着一些设备记录（上一次 relay 运行期间 attach 过，然后
        relay 重启 / 手机再也没回来），而 relay 这边根本不知道它们还在——那些
        记录各自挂着一条 `$events` 值班流。库里凡是已撤销、或配对已满 365 天
        （`expiresAt` 过去）的设备，都已经不可能回来了（`device_by_token` 把两种
        都拒掉），所以在这里逐条告知「放下」。连接器对它没持有的设备是空操作
        （`plugins/mobile-link/lib/router.js` 的 `if (!record) return`），所以这里
        是安全的广播：不需要连接器上报它持有哪些设备。

        只报**不在线**的那些：仍然握在 `_devices` 里的设备，撤销那一半马上会被
        对账踢掉（重复告知也幂等），但过期那一半**不许**因此被打断——见
        :meth:`reconcile_revoked_devices` 的理由。
        """
        revoked = await asyncio.to_thread(
            self.store.list_devices, agent["agentId"], include_revoked=True)
        expired = await asyncio.to_thread(
            self.store.expired_ids_of_agent, agent["agentId"])
        live = set(self._devices)
        gone = sorted(
            {row["deviceId"] for row in revoked if row.get("revokedAt")} | expired)
        stale = [device_id for device_id in gone if device_id not in live]
        for device_id in stale:
            link.enqueue_frame(dlp.device_detach_frame(device_id, reason="revoked"))
        if stale:
            self.logger.info(
                "relay: told the connector about %d device(s) that can never come back",
                len(stale))
            if len(stale) > 200:
                self.logger.warning(
                    "relay: agent %s has %d dead device records; that is a lot — "
                    "`admin.py device-list --all` shows them",
                    agent["agentId"], len(stale))

    async def detach_agent(self, link: AgentLink) -> None:
        if self.agents.get(link.agent_id) is not link:
            return
        del self.agents[link.agent_id]
        await link.close(1001, "agent disconnected")
        if link.superseded:
            return
        self.logger.info("relay: agent %s disconnected", link.agent_id)
        # 挂在这台电脑上的上传立刻失败：不然 HTTP 请求会等到自己的超时，
        # 手机上看起来是"一直在传"，而不是"传失败了"。
        await self._drop_agent_bridges(link.agent_id, "the PC connector disconnected")
        for device in list(link.devices.values()):
            device.agent = None
            device.enqueue_frame(dlp.host_status(online=False, agent_id=link.agent_id))

    # ── device lifecycle ────────────────────────────────────────────────────

    def _other_live_devices(self, agent: AgentLink, device_id: str) -> list[DeviceLink]:
        """The agent's live devices other than ``device_id``.

        A reconnecting device is not a *new* device, and the relay may still be
        tearing its previous socket down when the new one arrives — so a phone
        never counts against its own slot. Treating our own id as one of the slots
        would lock a phone out of its own relay.
        """
        return [link for link in agent.devices.values()
                if not link.closed and link.device_id != device_id]

    def device_budget_exceeded(self, agent: AgentLink, device_id: str) -> bool:
        """Would attaching ``device_id`` put this agent over its device budget?

        The single definition of that rule. Both the pre-upgrade check in
        ``relay.link_device`` (which can answer cleanly, before a socket is
        prepared) and :meth:`attach_device` (the last line of defence) call this,
        so a change to the rule cannot be applied to only one of them.
        """
        if not self.limits.max_devices_per_agent:
            return False
        return len(self._other_live_devices(agent, device_id)) >= self.limits.max_devices_per_agent

    async def attach_device(self, device: dict[str, Any], ws: Any) -> DeviceLink:
        agent = self.agents.get(device["agentId"])
        # One computer, one user: a device budget per agent is what keeps a
        # single leaked device token (or a script that pairs in a loop) from
        # filling the relay with sockets that all multiplex onto one connector.
        # One check, in one place: the route-level pre-upgrade check in
        # `relay.link_device` asks `device_budget_exceeded` rather than repeating
        # the rule, so the two can never disagree about when a phone is full.
        if agent is not None and self.device_budget_exceeded(agent, device["deviceId"]):
            attached = self._other_live_devices(agent, device["deviceId"])
            raise DeviceLimitReached(
                f"agent {agent.agent_id} already has {len(attached)} devices "
                f"(limit {self.limits.max_devices_per_agent})")
        link = DeviceLink(ws, device=device, logger=self.logger, limits=self.limits)
        link.agent = agent
        link.on_egress = self._note_egress
        link.quota = self._quota_for(device["deviceId"])
        self._devices[device["deviceId"]] = link
        self._note_usage(link, connection=True)
        if agent is None:
            link.enqueue_frame(dlp.host_status(online=False, agent_id=device["agentId"]))
        else:
            agent.devices[device["deviceId"]] = link
            link.enqueue_frame(dlp.host_status(
                online=True, agent_id=agent.agent_id, name=agent.name, version=None))
            agent.enqueue_frame(dlp.device_attach_frame(
                device["deviceId"], name=link.name, model=link.model, agent_id=agent.agent_id))
        self.logger.info("relay: device %s (%s) attached to agent %s",
                         device["deviceId"], link.name, device["agentId"])
        return link

    async def detach_device(self, link: DeviceLink, *, reason: str | None = None,
                            code: int = 1001) -> None:
        if self._devices.get(link.device_id) is link:
            del self._devices[link.device_id]
        agent = self.agents.get(link.agent_id)
        if agent is not None and agent.devices.get(link.device_id) is link:
            del agent.devices[link.device_id]
            agent.enqueue_frame(dlp.device_detach_frame(link.device_id, reason=reason))
        await link.close(code, reason or "device disconnected")
        self.logger.info("relay: device %s detached (%s)", link.device_id, reason or "closed")
        # 断开时冲一次：这一批的尾巴不留在内存里，运维命令跑完就是准的。
        await self.flush_usage()

    def schedule_detach(self, link: DeviceLink, *, reason: str | None = None) -> None:
        """Detach a device from a **synchronous** caller (e.g. an HTTP handler).

        :meth:`detach_device` is the real thing; this only exists because the
        revoke handler is a normal request/response and nothing there can await
        a socket close. It keeps the returned task referenced until it settles so
        it cannot be collected mid-flight, and a failure is logged rather than
        lost.
        """
        task = asyncio.create_task(self.detach_device(link, reason=reason))
        self._detach_tasks.add(task)
        task.add_done_callback(self._detach_tasks.discard)
        task.add_done_callback(self._note_detach_failure)

    def _note_detach_failure(self, task: asyncio.Task[None]) -> None:
        if task.cancelled():
            return
        error = task.exception()
        if error is not None:
            self.logger.warning("relay: detaching a device failed: %r", error)

    # ── routing ─────────────────────────────────────────────────────────────

    async def route_from_device(self, link: DeviceLink, frame: dict[str, Any]) -> None:
        """Handle one validated device frame."""
        kind = dlp.frame_type(frame)
        if kind == "ping":
            link.enqueue_frame({"t": "pong", "ts": frame.get("ts")})
            return
        if kind == "req" and frame.get("method") == HELLO_METHOD:
            # The phone's own build rides this call. Recording it here is what
            # lets `device-list` answer "did that phone update?" instead of
            # repeating whatever it was running the day it paired.
            await self._note_client_build(link, frame.get("args"))

        if kind == "hello":
            wanted = frame.get("agentId")
            if isinstance(wanted, str) and wanted and wanted != link.agent_id:
                link.enqueue_frame(dlp.error_frame(
                    "auth/agent-mismatch", "hello names a different agent", fatal=True))
                await self.detach_device(link, reason="agent mismatch")
            return
        agent = self.agents.get(link.agent_id)
        if agent is None or agent.closed:
            link.enqueue_frame(dlp.error_frame(
                "host/offline", "the PC connector is not connected", fatal=False))
            link.enqueue_frame(dlp.host_status(online=False, agent_id=link.agent_id))
            return
        forwarded = dict(frame)
        forwarded["deviceId"] = link.device_id
        if not link.enqueue_to_agent(forwarded):
            self.logger.warning("relay: device %s exceeded %d queued frames; dropping",
                                link.device_id, self.limits.queue_depth)
            await self.detach_device(link, reason="backpressure", code=CLOSE_BACKPRESSURE)

    async def _note_client_build(self, link: DeviceLink, args: Any) -> None:
        """Keep the device row's `appVersion` current, without a write per frame."""
        if not isinstance(args, dict):
            return
        parts = [args.get("clientVersion"), args.get("clientBuild")]
        reported = " ".join(str(part) for part in parts if isinstance(part, str) and part) or None
        if not reported:
            return
        # 记进当天那行要在"和上次一样就跳过"之前：重连时设备行里已经是这个构建号，
        # 早退的话当天那行的 lastBuild 永远是空的。
        self._note_usage(link, build=reported)
        if reported == link.app_version:
            return
        link.app_version = reported
        try:
            await asyncio.to_thread(self.store.set_device_app_version, link.device_id, reported)
        except Exception:  # noqa: BLE001 - a bookkeeping write must not drop the link
            self.logger.warning("relay: could not record the client build for %s", link.device_id)
            return
        self.logger.info("relay: device %s reports build %s", link.device_id, reported)

    async def route_from_agent(self, link: AgentLink, frame: dict[str, Any]) -> None:
        """Handle one validated agent frame."""
        kind = dlp.frame_type(frame)
        if kind == "ping":
            link.enqueue_frame({"t": "pong", "ts": frame.get("ts")})
            return
        if kind == "pong":
            return
        if kind == "notify":
            # 「这台电脑上有事发生」：**不转发给设备**（它根本不是 DLP 帧），而是
            # 交给 push 层——只有"此刻不在线"的手机才需要被推（在线那台 App 自己
            # 会弹本地通知，再推一次就是两条提醒一起响）。见 `_notify`。
            self._notify(link, frame)
            return
        if self._route_bridge_frame(link, kind, frame):
            # `fsPutAck`/`fsPutDone`/`fsErr`：后台上传桥的回复，**不跨到设备**。
            # 它们在 `device_id is None` 那条 debug 丢弃分支之前就被收走了。
            return
        device_id = dlp.device_id_of(frame)
        if device_id is None:
            if kind == "hostStatus":
                for dropped in link.broadcast(frame):
                    await self._drop_device(dropped, "backpressure")
                return
            self.logger.debug("relay: dropping unaddressed %s frame from agent %s", kind, link.agent_id)
            return
        device = link.devices.get(device_id)
        if device is None:
            self.logger.debug("relay: agent %s sent %s for unknown device %s", link.agent_id, kind, device_id)
            return
        # The relay's own addressing key never reaches the device.
        text = dlp.encode_frame(dlp.strip_device_id(frame))
        # The daily allowance is charged on what actually goes to the phone, and
        # the phone is told why it stopped instead of silently going quiet: a
        # client that keeps reconnecting into a spent quota is worse than one
        # that shows "today's traffic allowance is used up".
        if not device.charge_daily(len(text.encode("utf-8"))):
            self.logger.warning("relay: device %s exceeded its daily allowance (%d bytes)",
                                device_id, device.quota.limit)
            device.enqueue_frame(dlp.error_frame(
                "quota/device-daily", "this device reached its daily traffic allowance",
                fatal=False, details={"limitBytes": device.quota.limit}))
            await self._drop_device(device_id, "daily quota", code=CLOSE_QUOTA_EXCEEDED)
            return
        if not device.enqueue_text(text):
            await self._drop_device(device_id, "backpressure")

    # ── push notifications (R-1) ────────────────────────────────────────────

    def set_push_sender(self, sender: Any) -> None:
        """Install the APNs sender. Called at startup; a no-op stub is fine.

        Injected rather than constructed here so ``hub`` does not depend on
        ``push`` (tests run the whole routing surface without a push stack) and so
        an unconfigured relay simply never sends.
        """
        self.push = sender

    def _notify(self, link: AgentLink, frame: dict[str, Any]) -> None:
        """Turn an agent's ``notify`` into APNs pushes for the devices that need one.

        Four conditions, all of which must hold (``02-design.md`` §5.4). The first
        one is the whole reason this lives in the relay and not in the connector:
        **only the relay knows whether a device is connected right now**, and a
        device that is connected gets the event over its own socket and raises a
        local notification — pushing as well would make the phone buzz twice.

        The store read runs in a thread (the handler is on the routing path) and
        delivery runs on a task: nothing here waits on Apple, and a push that
        fails is a log line, never a broken forward.
        """
        sender = self.push
        kind = frame.get("kind")
        sid = frame.get("sid")
        if sender is None or not getattr(sender, "enabled", False):
            return
        if kind not in ("turnEnd", "attention") or not isinstance(sid, str) or not sid:
            self.logger.debug("relay: ignoring malformed notify from agent %s", link.agent_id)
            return

        async def deliver() -> None:
            try:
                rows = await asyncio.to_thread(self.store.push_targets, link.agent_id)
            except Exception as error:  # noqa: BLE001 - a lookup must not break routing
                self.logger.warning("relay: could not read push targets for %s: %s",
                                    link.agent_id, error)
                return
            wanted = [row for row in rows if self._should_push(link, row, kind)]
            if not wanted:
                return
            results = await sender.send_many(
                wanted, kind=kind, sid=sid, eid=frame.get("eid"))
            for row, result in zip(wanted, results):
                if result.ok:
                    self.logger.info("relay: pushed %s to %s", kind, row["deviceId"])
                    continue
                if result.dead_token:
                    # Apple's verdict is the only automatic cleanup this system
                    # has: the app is gone or reinstalled, so the registration is
                    # stale until it comes back and registers again.
                    self.logger.info("relay: device %s push token is dead (%s); clearing it",
                                     row["deviceId"], result.reason)
                    try:
                        await asyncio.to_thread(self.store.clear_push, row["deviceId"])
                    except Exception as error:  # noqa: BLE001
                        self.logger.warning("relay: could not clear push for %s: %s",
                                            row["deviceId"], error)
                elif result.skipped:
                    self.logger.debug("relay: push to %s skipped (%s)",
                                      row["deviceId"], result.skipped)
                else:
                    self.logger.warning("relay: push to %s failed (HTTP %s, %s)",
                                        row["deviceId"], result.status, result.reason)

        task = asyncio.create_task(deliver())
        self._push_tasks.add(task)
        task.add_done_callback(self._push_tasks.discard)

    def _should_push(self, link: AgentLink, device_row: dict[str, Any], kind: str) -> bool:
        """Whether one device should receive this reminder.

        Split out so each condition is testable on its own, and so ``push-test``
        can deliberately bypass the first one (during the transition period a
        phone is usually "online" because of the keep-alive, which would make the
        operator command useless for its main purpose: telling sandbox from
        production).
        """
        device_id = device_row["deviceId"]
        # ① 此刻不在线。在线的手机自己会弹本地通知（`$events` → App），再推就是重复。
        if device_id in link.devices:
            return False
        # ② 有推送登记（令牌与环境都有效；store 已经把撤销/过期的滤掉了）。
        if not device_row.get("apnsToken") or not device_row.get("apnsEnv"):
            return False
        # ③ 用户开着这一类提醒。
        column = "pushTurnEnd" if kind == "turnEnd" else "pushAttention"
        if not device_row.get(column):
            return False
        return True

    # ── background-transfer bridge (R-1 C-17) ───────────────────────────────

    def open_bridge(self, bid: str, agent_id: str) -> "FileBridge":
        """Register one in-flight `PUT /files/up` so the connector's replies find it.

        Correlation is by ``bid`` alone: the connector's bridge replies carry no
        ``deviceId`` (it does not know which phone is uploading, and should not),
        so this table is what turns "some file finished" back into "that HTTP
        request may now answer 200".
        """
        bridge = FileBridge(bid=bid, agent_id=agent_id, logger=self.logger)
        self._bridges[bid] = bridge
        return bridge

    def open_fetch(self, bid: str, agent_id: str) -> "FileFetchBridge":
        """Register one in-flight `GET /files/down`, same table and same rule.

        Sharing ``_bridges`` is deliberate: a bridge id is minted by whoever
        drives the transfer, and the two families never mix (a ``fsGetChunk`` can
        only answer a fetch). One table means one place that has to be cleaned up
        when an agent disconnects.
        """
        bridge = FileFetchBridge(bid=bid, agent_id=agent_id, logger=self.logger)
        self._bridges[bid] = bridge
        return bridge

    def close_bridge(self, bid: str) -> None:
        self._bridges.pop(bid, None)

    def _route_bridge_frame(self, link: AgentLink, kind: str, frame: dict[str, Any]) -> bool:
        """Hand a bridge reply to its waiting request. True when it was one."""
        if kind not in dlp.AGENT_CONTROL:
            return False
        bid = frame.get("bid")
        bridge = self._bridges.get(bid) if isinstance(bid, str) else None
        if bridge is None:
            # A late reply after the request gave up (client went away, or the
            # 5-second ack deadline already fired). Nothing to do but say so.
            self.logger.debug("relay: no bridge waiting for %s (bid=%r)", kind, bid)
            return True
        # **The return value is the entire point of this method existing in the
        # routing layer.** `deliver` answers `False` for a frame that reached a
        # bridge nobody is reading any more — the queue full because the phone
        # hung up, or a bridge already abandoned. That is the only signal the
        # relay has that a run should stop, and dropping it on the floor meant a
        # connector kept reading a whole file for a reader that was gone. The
        # `fsGetCancel` is what acts on it.
        if not bridge.deliver(kind, frame):
            self._cancel_fetch(link, bridge)
        return True

    def _cancel_fetch(self, link: AgentLink, bridge: "FileFetchBridge") -> None:
        """Tell the connector to stop reading for a bridge that is no longer read.

        Sent on every path that discovers a dead bridge: the queue filled, the
        reader left, a newer request superseded this one. The connector answers a
        cancel for a run it does not know by doing nothing, so a duplicate is
        harmless — which is what makes it safe to send from more than one place.

        Written into the same per-connection queue as every other frame, so it
        cannot overtake the ``fsGetBegin`` whose run it means to stop.
        """
        if bridge.cancel_requested:
            return
        bridge.cancel_requested = True
        sent = link.enqueue_frame({"t": "fsGetCancel", "bid": bridge.bid})
        self.logger.debug("relay: cancelling download %s (delivered=%s)",
                          bridge.bid, sent)

    async def _drop_agent_bridges(self, agent_id: str, reason: str) -> None:
        """Fail every waiting transfer of an agent that just went away.

        Without this the HTTP request would sit until its own timeout with the
        connector gone — the phone would look like "uploading forever" instead of
        "upload failed", and the user would wait on nothing. Applies to both
        directions: an upload waiting for its acks and a download waiting for its
        first window.
        """
        for bridge in list(self._bridges.values()):
            if bridge.agent_id == agent_id:
                bridge.fail(reason)

    async def _drop_device(self, device_id: str, reason: str, *,
                           code: int = CLOSE_BACKPRESSURE) -> None:
        link = self._devices.get(device_id)
        if link is None:
            return
        self.logger.warning("relay: dropping device %s (%s)", device_id, reason)
        await self.detach_device(link, reason=reason, code=code)

    # ── daily usage accounting ──────────────────────────────────────────────

    def _quota_for(self, device_id: str) -> DailyQuota:
        """A daily allowance for one device, seeded with what it already spent.

        The baseline is read **once, at attach**, from the same ``usageDaily`` row
        the operator's report reads. Reading it per frame would put a SQLite
        query on the forwarding path; reading it *again* at flush time would
        double-count the bytes that flush just wrote, quietly halving the day.
        In between, :class:`DailyQuota` counts this connection's own traffic on
        top of that number.

        A store that cannot answer must not take the relay down with it: the
        allowance falls back to 0 (a fresh day) and the failure is logged. That is
        the safe direction — it grants an allowance rather than refusing a device
        its day over a bookkeeping error.
        """
        limit = self.limits.device_daily_bytes
        if limit <= 0:
            return DailyQuota(limit=0)
        today = store_module.local_day()
        used = 0
        try:
            used = self._stored_egress_today(device_id, today)
        except Exception:  # noqa: BLE001 - 记账读不出来不该挡住连接
            self.logger.warning("relay: could not read today's usage for %s; "
                                "starting its allowance from zero", device_id, exc_info=True)
        return DailyQuota(limit=limit, used=used, day=today)

    def _stored_egress_today(self, device_id: str, day: int) -> int:
        """`usageDaily` 里这台设备今天已经用掉的出口字节。"""
        for row in self.store.usage_rows(day):
            if row["deviceId"] == device_id:
                return max(0, int(row["egressBytes"]))
        return 0

    def _note_egress(self, link: DeviceLink, size: int) -> None:
        """发送热路径上的记账：只做一次字典加法，不碰磁盘。"""
        self._note_usage(link, egress_bytes=size)

    def _note_usage(self, link: DeviceLink, *, egress_bytes: int = 0,
                    connection: bool = False, build: str | None = None) -> None:
        day = self._usage_day
        key = (day, link.device_id)
        entry = self._usage.get(key)
        if entry is None:
            entry = {
                "day": day,
                "deviceId": link.device_id,
                "agentId": link.agent_id,
                "accountId": link.account_id,
                "egressBytes": 0,
                "connections": 0,
                "at": store_module.now_ms(),
                "lastBuild": None,
            }
            self._usage[key] = entry
        if egress_bytes:
            entry["egressBytes"] += egress_bytes
            self._usage_bytes_since_flush += egress_bytes
        if connection:
            entry["connections"] += 1
        if build:
            entry["lastBuild"] = build
        entry["at"] = store_module.now_ms()

    async def flush_usage(self) -> None:
        """把内存里攒的用量写进 `usageDaily`。

        调用时机：每 `usage_flush_interval` 秒、单次运行累计超过 `usage_flush_bytes`、
        设备断开、跨本地日、进程收尾。写失败时把这批放回内存等下次——账不能因为
        一次写库异常就丢了。
        """
        self._usage_bytes_since_flush = 0
        # 只写有内容的行：字节、连接数、构建号任一有值。构建号也算内容——它可能是在
        # 这一天已经冲过一次盘之后才报上来的（重连），只按字节过滤会把它丢掉。
        entries = [dict(entry) for entry in self._usage.values()
                   if entry["egressBytes"] or entry["connections"] or entry["lastBuild"]]
        if not entries:
            return
        self._usage.clear()
        try:
            await asyncio.to_thread(self.store.add_usage, entries)
        except Exception:  # noqa: BLE001 - 记账失败不能影响转发
            self.logger.warning("relay: could not write usage rows; keeping them in memory",
                                exc_info=True)
            for entry in entries:
                key = (entry["day"], entry["deviceId"])
                kept = self._usage.get(key)
                if kept is None:
                    self._usage[key] = entry
                else:
                    kept["egressBytes"] += entry["egressBytes"]
                    kept["connections"] += entry["connections"]
                    kept["lastBuild"] = entry["lastBuild"] or kept["lastBuild"]
                    kept["at"] = max(kept["at"], entry["at"])

    def start_usage_flush(self) -> None:
        """起周期冲盘任务（由 app 启动钩子调用）。"""
        if self._usage_task is None:
            self._usage_task = asyncio.create_task(self._usage_flush_loop())

    def start_revoke_reconcile(self) -> None:
        """起「撤销对账」周期任务（由 app 启动钩子调用）。幂等。"""
        if self._reconcile_task is None and self.revoked_reconcile_interval > 0:
            self.logger.info("relay: revoke reconcile loop every %ss (0 = off)",
                             self.revoked_reconcile_interval)
            self._reconcile_task = asyncio.create_task(self._revoke_reconcile_loop())

    async def reconcile_revoked_devices(self) -> list[str]:
        """让在线世界与「库里已撤销」这条唯一事实来源保持一致。

        为什么需要：撤销可能来自 relay 够不着的地方（`admin.py` 直接写库、
        运维手工改库）。socket 一旦留在「库已撤、自己还在线」这种状态，那台手机
        **永远回不来**（令牌已被 `device_by_token` 否掉），而连接器会一直替它留着
        `$events` 值班流（`plugins/mobile-link/lib/router.js`）——没人会来拿。

        只处理**在线**设备，且只因为「已撤销」。令牌过期（配对满 365 天）的设备
        不在这一臂里：在线 socket 不做重新鉴权，踢它等于打断一条此刻仍能正常
        工作的连接，那是产品行为变更。过期的残留由 `attach_agent` 那一段收
        （见 :meth:`_tell_agent_about_the_gone`）。

        返回被踢的设备 id，供日志与测试断言。
        """
        live = list(self._devices.keys())
        if not live:
            return []                       # 没人在线就不查库
        stale = await asyncio.to_thread(self.store.revoked_ids_among, live)
        detached: list[str] = []
        for device_id in sorted(stale):
            link = self._devices.get(device_id)
            if link is None:
                continue                    # 竞态：这一轮里它自己断开了
            self.logger.info(
                "relay: device %s was revoked in the database but still connected; "
                "detaching (reason=revoked)", device_id)
            self.schedule_detach(link, reason="revoked")
            detached.append(device_id)
        return detached

    async def _revoke_reconcile_loop(self) -> None:
        # 注意：try/except 在**循环体内**（与 `_usage_flush_loop` 不同，那里
        # 一次异常就把循环打死了）。这里是撤销唯一的兜底，一次数据库抖动
        # 绝不能让对账停摆。
        while True:
            try:
                await asyncio.sleep(self.revoked_reconcile_interval)
                await self.reconcile_revoked_devices()
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001 - 对账失败不能把中转带下去
                self.logger.warning("relay: revoke reconcile tick failed", exc_info=True)

    async def _usage_flush_loop(self) -> None:
        try:
            while True:
                await asyncio.sleep(self.usage_flush_interval)
                today = store_module.local_day()
                if today != self._usage_day:
                    # 跨日：先把上一天的尾巴写掉，再换账本。
                    await self.flush_usage()
                    self._usage_day = today
                    continue
                if self._usage_bytes_since_flush >= self.usage_flush_bytes:
                    await self.flush_usage()
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 - 冲盘任务不能把中转带下去
            self.logger.warning("relay: usage flush loop stopped", exc_info=True)

    def usage_today(self) -> dict[str, Any]:
        """今天（本地日）的用量：库里已经冲下去的 + 还在内存里的。

        放在 hub 而不是直接查库，是因为最近 30 秒的字节还在内存里；
        两边合起来才是"此刻为止"。
        """
        day = store_module.local_day()
        devices: dict[str, dict[str, Any]] = {}
        try:
            for row in self.store.usage_rows(day):
                devices[row["deviceId"]] = {
                    "deviceId": row["deviceId"],
                    "agentId": row["agentId"],
                    "accountId": row["accountId"],
                    "egressBytes": row["egressBytes"],
                    "connections": row["connections"],
                    "lastBuild": row["lastBuild"],
                }
        except Exception:  # noqa: BLE001 - /stats 不该因为一次查询失败而 500
            self.logger.warning("relay: could not read today's usage", exc_info=True)
        for entry in self._usage.values():
            if entry["day"] != day:
                continue
            row = devices.get(entry["deviceId"])
            if row is None:
                devices[entry["deviceId"]] = {
                    "deviceId": entry["deviceId"],
                    "agentId": entry["agentId"],
                    "accountId": entry["accountId"],
                    "egressBytes": entry["egressBytes"],
                    "connections": entry["connections"],
                    "lastBuild": entry["lastBuild"],
                }
                continue
            row["egressBytes"] += entry["egressBytes"]
            row["connections"] += entry["connections"]
            row["lastBuild"] = entry["lastBuild"] or row["lastBuild"]
        accounts: dict[str, dict[str, Any]] = {}
        for row in devices.values():
            bucket = accounts.setdefault(row["accountId"], {
                "accountId": row["accountId"], "egressBytes": 0, "devices": 0,
            })
            bucket["egressBytes"] += row["egressBytes"]
            bucket["devices"] += 1
        return {
            "day": day,
            "totalEgressBytes": sum(row["egressBytes"] for row in devices.values()),
            "devices": sorted(devices.values(), key=lambda row: row["egressBytes"], reverse=True),
            "accounts": sorted(accounts.values(), key=lambda row: row["egressBytes"], reverse=True),
        }

    # ── introspection ───────────────────────────────────────────────────────

    def device_count(self, agent_id: str | None = None) -> int:
        if agent_id is None:
            return len(self._devices)
        return len(self.agents[agent_id].devices) if agent_id in self.agents else 0

    def snapshot(self) -> dict[str, Any]:
        return {
            "agents": [
                {
                    "agentId": link.agent_id,
                    "name": link.name,
                    "devices": [device.device_id for device in link.devices.values()],
                    "pending": link.pending(),
                    "egressBytes": link.egress_bytes,
                }
                for link in self.agents.values()
            ],
            "devices": [
                {
                    "deviceId": link.device_id,
                    "agentId": link.agent_id,
                    "name": link.name,
                    "pending": link.pending(),
                    "hostOnline": link.agent is not None and not link.agent.closed,
                    "egressBytes": link.egress_bytes,
                    "pacedSeconds": round(link.paced_seconds, 3),
                    "quotaRemainingBytes": link.quota.remaining(),
                }
                for link in self._devices.values()
            ],
        }

    def traffic(self) -> dict[str, Any]:
        """Egress accounting, most useful first.

        The host's own interface counters cannot answer "which computer is using
        the bandwidth" — they mix in SSH, OTA downloads and everything else on
        the machine. These numbers are the relay's own, so they are the ones to
        look at when deciding whether a device needs a smaller allowance.
        """
        devices = sorted(self._devices.values(), key=lambda link: link.egress_bytes, reverse=True)
        return {
            "totalEgressBytes": sum(link.egress_bytes for link in self._devices.values()),
            "devices": [
                {
                    "deviceId": link.device_id,
                    "agentId": link.agent_id,
                    "name": link.name,
                    "egressBytes": link.egress_bytes,
                    "pacedSeconds": round(link.paced_seconds, 3),
                    "quotaRemainingBytes": link.quota.remaining(),
                }
                for link in devices
            ],
        }

    async def shutdown(self, *, reason: str = "relay shutting down") -> None:
        if self._usage_task is not None:
            self._usage_task.cancel()
            self._usage_task = None
        if self._reconcile_task is not None:
            self._reconcile_task.cancel()
            self._reconcile_task = None
        # 先把账写掉再断开：进程收尾也是"今天"的一部分。
        await self.flush_usage()
        for link in list(self._devices.values()):
            await link.close(1001, reason)
        self._devices.clear()
        for link in list(self.agents.values()):
            await link.close(1001, reason)
        self.agents.clear()

    def all_devices(self) -> Iterable[DeviceLink]:
        return list(self._devices.values())
