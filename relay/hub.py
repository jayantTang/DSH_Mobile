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
from typing import Any, Iterable

import dlp

#: WebSocket close codes used by the relay (application range).
CLOSE_SUPERSEDED = 4001
CLOSE_BACKPRESSURE = 4008
CLOSE_AGENT_OFFLINE = 4010

class Limits:
    """Tunables for the hub; the spec's numbers are the defaults."""

    def __init__(self, *, max_frame_bytes: int = dlp.MAX_FRAME_BYTES, queue_depth: int = 512,
                 agent_queue_depth: int = 4096):
        self.max_frame_bytes = max_frame_bytes
        self.queue_depth = queue_depth
        self.agent_queue_depth = agent_queue_depth

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
                await self.ws.send_str(text)
        except asyncio.CancelledError:
            raise
        except Exception as error:  # socket gone; the reader loop handles teardown
            self.logger.debug("relay: %s writer stopped: %s", self.label, error)

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

    def start(self) -> None:
        super().start()
        if self._agent_pump is None:
            self._agent_pump = asyncio.create_task(self._pump_to_agent())

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
        link = DeviceLink(ws, device=device, logger=self.logger, limits=self.limits)
        agent = self.agents.get(device["agentId"])
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
        if not device.enqueue_text(dlp.encode_frame(dlp.strip_device_id(frame))):
            await self._drop_device(device_id, "backpressure")

    async def _drop_device(self, device_id: str, reason: str) -> None:
        link = self._devices.get(device_id)
        if link is None:
            return
        self.logger.warning("relay: dropping device %s (%s)", device_id, reason)
        code = CLOSE_BACKPRESSURE if reason == "backpressure" else 1001
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
                }
                for link in self._devices.values()
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
