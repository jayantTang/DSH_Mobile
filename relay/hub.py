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
import time
from typing import Any, Iterable

import dlp

#: WebSocket close codes used by the relay (application range).
CLOSE_SUPERSEDED = 4001
CLOSE_BACKPRESSURE = 4008
CLOSE_RATE_LIMITED = 4009
CLOSE_AGENT_OFFLINE = 4010
CLOSE_QUOTA_EXCEEDED = 4011

#: Longest string handed to the WebSocket in one call while a device is over its
#: rate. ~1 MB of JSON: small enough that pacing is visible on the wire, large
#: enough that chunking costs almost nothing on a normal frame.
_CHUNK_CHARS = 512 * 1024


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
    """A per-device byte allowance that resets at UTC midnight.

    Rate pacing bounds how *fast* one device can move bytes; this bounds how many
    in a day, which is what protects a metered or fixed-bandwidth host from one
    device that simply runs all day. The reset is by UTC day so that every device
    and the operator's own daily accounting agree on when "today" ends.
    """

    __slots__ = ("limit", "used", "day")

    def __init__(self, *, limit: int, now: float | None = None):
        self.limit = max(0, int(limit))
        self.used = 0
        self.day = self._day_of(time.time() if now is None else now)

    @staticmethod
    def _day_of(stamp: float) -> int:
        return int(stamp // 86_400)

    @property
    def enabled(self) -> bool:
        return self.limit > 0

    def charge(self, amount: int, *, now: float | None = None) -> bool:
        """Account ``amount`` bytes; ``False`` means the day's allowance is gone."""
        if not self.enabled:
            return True
        stamp = time.time() if now is None else now
        today = self._day_of(stamp)
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
        #: Per-device egress allowance per UTC day, in bytes. ``0`` disables it.
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
        messages while the device is over its rate, because ``send_str`` hands
        the whole payload to the transport in one call — a 2.7 MB screenshot
        would otherwise be written to the socket in one burst no matter what the
        bucket says.

        **The client has to put those messages back together**, and that is not
        free: WebSocket messages are not a byte stream, so a client that parses
        each ``receive()`` as one frame drops the first fragment as malformed
        JSON and the rest as garbage, and the call behind them never answers.
        The iOS app does reassemble them (``DSHKit/FrameAssembler.swift``); a
        connector or a future client must too. Writing the pieces as WebSocket
        *continuation* frames instead would remove the requirement entirely.
        """
        size = len(text.encode("utf-8"))
        wait = self.bucket.take(size)
        if wait > 0:
            await asyncio.sleep(wait)
            self.paced_seconds += wait
        if size <= _CHUNK_CHARS or self.bucket.tokens >= 0:
            await self.ws.send_str(text)
            self._count_egress(size)
            return
        for start in range(0, len(text), _CHUNK_CHARS):
            chunk = text[start:start + _CHUNK_CHARS]
            step = self.bucket.take(len(chunk.encode("utf-8")))
            if step > 0:
                await asyncio.sleep(step)
                self.paced_seconds += step
            await self.ws.send_str(chunk)
            self._count_egress(len(chunk.encode("utf-8")))

    def _count_egress(self, size: int) -> None:
        self.egress_bytes += size
        agent = self.agent
        if agent is not None:
            agent.egress_bytes += size

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

class RelayHub:
    """Registry of live agents and devices plus the routing rules between them."""

    def __init__(self, store: Any, *, logger: logging.Logger | None = None, limits: Limits | None = None):
        self.store = store
        self.logger = logger or logging.getLogger("relay.hub")
        self.limits = limits or Limits()
        self.agents: dict[str, AgentLink] = {}
        self._devices: dict[str, DeviceLink] = {}

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
        self.logger.info("relay: agent %s connected (%s), %d device(s) re-adopted",
                         agent["agentId"], agent["name"], len(link.devices))
        return link

    async def detach_agent(self, link: AgentLink) -> None:
        if self.agents.get(link.agent_id) is not link:
            return
        del self.agents[link.agent_id]
        await link.close(1001, "agent disconnected")
        if link.superseded:
            return
        self.logger.info("relay: agent %s disconnected", link.agent_id)
        for device in list(link.devices.values()):
            device.agent = None
            device.enqueue_frame(dlp.host_status(online=False, agent_id=link.agent_id))

    # ── device lifecycle ────────────────────────────────────────────────────

    async def attach_device(self, device: dict[str, Any], ws: Any) -> DeviceLink:
        agent = self.agents.get(device["agentId"])
        # One computer, one user: a device budget per agent is what keeps a
        # single leaked device token (or a script that pairs in a loop) from
        # filling the relay with sockets that all multiplex onto one connector.
        # Refusing here — rather than after the socket is prepared — means the
        # client gets a plain close instead of a half-open link.
        if agent is not None and self.limits.max_devices_per_agent:
            # Same rule as the route-level check: a reconnecting device does not
            # occupy a second slot, even while its old link is still closing.
            attached = [link for link in agent.devices.values()
                        if not link.closed and link.device_id != device["deviceId"]]
            if len(attached) >= self.limits.max_devices_per_agent:
                raise DeviceLimitReached(
                    f"agent {agent.agent_id} already has {len(attached)} devices "
                    f"(limit {self.limits.max_devices_per_agent})")
        link = DeviceLink(ws, device=device, logger=self.logger, limits=self.limits)
        link.agent = agent
        self._devices[device["deviceId"]] = link
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

    # ── routing ─────────────────────────────────────────────────────────────

    async def route_from_device(self, link: DeviceLink, frame: dict[str, Any]) -> None:
        """Handle one validated device frame."""
        kind = dlp.frame_type(frame)
        if kind == "ping":
            link.enqueue_frame({"t": "pong", "ts": frame.get("ts")})
            return
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

    async def route_from_agent(self, link: AgentLink, frame: dict[str, Any]) -> None:
        """Handle one validated agent frame."""
        kind = dlp.frame_type(frame)
        if kind == "ping":
            link.enqueue_frame({"t": "pong", "ts": frame.get("ts")})
            return
        if kind == "pong":
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
        if device.quota.enabled and not device.quota.charge(len(text.encode("utf-8"))):
            self.logger.warning("relay: device %s exceeded its daily allowance (%d bytes)",
                                device_id, device.quota.limit)
            device.enqueue_frame(dlp.error_frame(
                "quota/device-daily", "this device reached its daily traffic allowance",
                fatal=False, details={"limitBytes": device.quota.limit}))
            await self._drop_device(device_id, "daily quota", code=CLOSE_QUOTA_EXCEEDED)
            return
        if not device.enqueue_text(text):
            await self._drop_device(device_id, "backpressure")

    async def _drop_device(self, device_id: str, reason: str, *,
                           code: int = CLOSE_BACKPRESSURE) -> None:
        link = self._devices.get(device_id)
        if link is None:
            return
        self.logger.warning("relay: dropping device %s (%s)", device_id, reason)
        await self.detach_device(link, reason=reason, code=code)

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
        for link in list(self._devices.values()):
            await link.close(1001, reason)
        self._devices.clear()
        for link in list(self.agents.values()):
            await link.close(1001, reason)
        self.agents.clear()

    def all_devices(self) -> Iterable[DeviceLink]:
        return list(self._devices.values())
