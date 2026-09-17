"""DSH Link Protocol (DLP) v1 relay — WebSocket endpoints, app wiring, entrypoint.

  WS   /link/agent?agentId=<id>   PC connector, ``Bearer <agentSecret>``
  WS   /link/device?agentId=<id>  iOS device, ``Bearer <deviceToken>``

plus, from :mod:`api`, ``GET /healthz``, ``POST /pair/{claim,refresh,code}`` and
CORS preflight. Every route is served both at the root and under the optional
``--base-path`` prefix, because a front end may either strip the prefix (Caddy's
``handle_path``) or forward it verbatim. See ``docs/notes/relay.md`` §2c.
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import os
import signal
from typing import Any

from aiohttp import WSMsgType, web

import dlp
from api import bearer_token, cors_preflight, register_http_routes
from hub import Limits, RelayHub
from store import DEFAULT_DEVICE_TTL_MS, DEFAULT_PAIR_TTL_MS, Store

LOGGER = logging.getLogger("relay")


def normalize_base_path(raw: str | None) -> str:
    """Normalise a mount prefix to ``""`` or ``"/prefix"`` (no trailing slash).

    A front end may either strip the prefix (Caddy's ``handle_path``) or forward
    it verbatim; every route is registered under both forms, so both work.
    """
    text = str(raw or "").strip()
    if not text or text == "/":
        return ""
    if not text.startswith("/"):
        text = f"/{text}"
    return text.rstrip("/")


# ── WebSocket handlers ──────────────────────────────────────────────────────


def _make_socket(request: web.Request, limits: Limits) -> web.WebSocketResponse:
    return web.WebSocketResponse(
        max_msg_size=limits.max_frame_bytes,
        heartbeat=30.0,
        receive_timeout=None,
        autoping=True,
        compress=False,
    )


async def _agent_identity(request: web.Request) -> dict[str, Any]:
    store: Store = request.app["store"]
    token = bearer_token(request)
    if not token:
        raise web.HTTPUnauthorized(text="missing bearer token")
    agent = await asyncio.to_thread(store.agent_by_secret, token)
    if agent is None:
        raise web.HTTPUnauthorized(text="unknown or disabled agent token")
    wanted = request.query.get("agentId")
    if wanted and wanted != agent["agentId"]:
        raise web.HTTPForbidden(text="agentId does not match the bearer token")
    return agent


async def _device_identity(request: web.Request) -> dict[str, Any]:
    store: Store = request.app["store"]
    token = bearer_token(request)
    if not token:
        raise web.HTTPUnauthorized(text="missing bearer token")
    device = await asyncio.to_thread(store.device_by_token, token)
    if device is None:
        raise web.HTTPUnauthorized(text="unknown, revoked, or expired device token")
    wanted = request.query.get("agentId")
    if wanted and wanted != device["agentId"]:
        raise web.HTTPForbidden(text="agentId does not match the device token")
    return device


async def link_agent(request: web.Request) -> web.WebSocketResponse:
    hub: RelayHub = request.app["hub"]
    store: Store = request.app["store"]
    limits: Limits = request.app["limits"]
    agent = await _agent_identity(request)

    ws = _make_socket(request, limits)
    await ws.prepare(request)
    link = await hub.attach_agent(agent, ws)
    link.start()
    await asyncio.to_thread(store.touch_agent, agent["agentId"])
    try:
        async for msg in ws:
            if msg.type == WSMsgType.TEXT:
                try:
                    frame = dlp.parse_frame(msg.data)
                except dlp.FrameError as error:
                    LOGGER.debug("relay: bad frame from %s: %s", link.label, error)
                    continue
                problem = dlp.validate_from_agent(frame)
                if problem is not None:
                    LOGGER.debug("relay: invalid frame from %s: %s", link.label, problem)
                    continue
                await hub.route_from_agent(link, frame)
            elif msg.type == WSMsgType.BINARY:
                link.enqueue_frame(dlp.error_frame(
                    "protocol/binary-unsupported", "binary frames are reserved for DLP v2"))
            elif msg.type == WSMsgType.ERROR:
                LOGGER.info("relay: agent socket error: %s", ws.exception())
                break
    finally:
        await hub.detach_agent(link)
    return ws


async def link_device(request: web.Request) -> web.WebSocketResponse:
    hub: RelayHub = request.app["hub"]
    store: Store = request.app["store"]
    limits: Limits = request.app["limits"]
    device = await _device_identity(request)

    # The budget is checked before the upgrade: a client that is refused should
    # get a clean close, not a socket that opens and then dies.
    #
    # A device reconnecting is not a new device, and the relay may still be
    # tearing its previous socket down when the new one arrives — so the budget
    # counts *other* live devices, never the same id twice. Treating our own id
    # as one of the slots would lock a phone out of its own relay.
    if limits.max_devices_per_agent:
        agent = hub.agents.get(device["agentId"])
        if agent is not None:
            mine = device["deviceId"]
            attached = [link for link in agent.devices.values()
                        if not link.closed and link.device_id != mine]
            if len(attached) >= limits.max_devices_per_agent:
                LOGGER.warning("relay: refusing device %s — agent %s is at its device budget (%d)",
                               device["deviceId"], device["agentId"], limits.max_devices_per_agent)
                raise web.HTTPForbidden(text="device limit reached for this host")

    ws = _make_socket(request, limits)
    await ws.prepare(request)
    link = await hub.attach_device(device, ws)
    link.start()
    await asyncio.to_thread(store.touch_device, device["deviceId"])
    try:
        async for msg in ws:
            if msg.type == WSMsgType.TEXT:
                try:
                    frame = dlp.parse_frame(msg.data)
                except dlp.FrameError as error:
                    link.enqueue_frame(dlp.error_frame("protocol/bad-frame", str(error)))
                    continue
                problem = dlp.validate_from_device(frame)
                if problem is not None:
                    link.enqueue_frame(dlp.error_frame("protocol/bad-frame", problem))
                    continue
                await hub.route_from_device(link, frame)
            elif msg.type == WSMsgType.BINARY:
                link.enqueue_frame(dlp.error_frame(
                    "protocol/binary-unsupported", "binary frames are reserved for DLP v2"))
            elif msg.type == WSMsgType.ERROR:
                LOGGER.info("relay: device socket error: %s", ws.exception())
                break
    finally:
        await hub.detach_device(link, reason="socket closed")
    return ws


# ── application ─────────────────────────────────────────────────────────────


def create_app(*, store: Store, limits: Limits | None = None,
               pair_ttl_ms: int = DEFAULT_PAIR_TTL_MS,
               device_ttl_ms: int = DEFAULT_DEVICE_TTL_MS,
               base_path: str = "",
               logger: logging.Logger | None = None) -> web.Application:
    limits = limits or Limits()
    base_path = normalize_base_path(base_path)
    app = web.Application(client_max_size=limits.max_frame_bytes, middlewares=[cors_preflight])
    app["store"] = store
    app["limits"] = limits
    app["pair_ttl_ms"] = pair_ttl_ms
    app["device_ttl_ms"] = device_ttl_ms
    app["base_path"] = base_path
    app["hub"] = RelayHub(store, logger=logger or LOGGER, limits=limits)

    def route(method: str, path: str, handler: Any) -> None:
        """Register one route, and its prefixed twin when a base path is set."""
        app.router.add_route(method, path, handler)
        if base_path:
            app.router.add_route(method, f"{base_path}{path}", handler)

    register_http_routes(app, route, base_path)
    route("GET", "/link/agent", link_agent)
    route("GET", "/link/device", link_device)

    async def _cleanup(_app: web.Application) -> None:
        await _app["hub"].shutdown()

    app.on_cleanup.append(_cleanup)
    return app


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="relay.py", description="DSH Link Protocol v1 relay")
    parser.add_argument("--host", default=os.environ.get("DLP_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("DLP_PORT", "8787")))
    parser.add_argument("--db", default=os.environ.get("DLP_DB", os.path.join(os.path.dirname(
        os.path.abspath(__file__)), "state.db")))
    parser.add_argument("--pair-ttl-seconds", type=int, default=DEFAULT_PAIR_TTL_MS // 1000)
    parser.add_argument("--device-ttl-days", type=int, default=DEFAULT_DEVICE_TTL_MS // 86_400_000)
    parser.add_argument("--queue-depth", type=int, default=512)
    parser.add_argument("--max-devices-per-agent", type=int,
                        default=int(os.environ.get("DLP_MAX_DEVICES_PER_AGENT", "0")),
                        help="how many devices one agent may keep attached (0 = unlimited)")
    parser.add_argument("--device-rate-kbps", type=float,
                        default=float(os.environ.get("DLP_DEVICE_RATE_KBPS", "0")),
                        help="per-device egress pacing in kilobits per second (0 = no pacing). "
                             "On a fixed-bandwidth host this is what keeps one device's large "
                             "frames from occupying the whole pipe")
    parser.add_argument("--device-daily-mb", type=float,
                        default=float(os.environ.get("DLP_DEVICE_DAILY_MB", "0")),
                        help="per-device egress allowance per UTC day, in megabytes (0 = unlimited)")
    parser.add_argument("--base-path", default=os.environ.get("DLP_BASE_PATH", ""),
                        help="optional mount prefix, e.g. /dsh-link; both the prefixed and the "
                             "already-stripped forms are served")
    parser.add_argument("--log-level", default=os.environ.get("DLP_LOG_LEVEL", "INFO"))
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(
        level=getattr(logging, str(args.log_level).upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    store = Store(args.db)
    app = create_app(
        store=store,
        limits=Limits(
            queue_depth=int(args.queue_depth),
            max_devices_per_agent=int(args.max_devices_per_agent),
            device_bytes_per_second=float(args.device_rate_kbps) * 1000 / 8,
            device_daily_bytes=int(float(args.device_daily_mb) * 1024 * 1024),
        ),
        pair_ttl_ms=int(args.pair_ttl_seconds) * 1000,
        device_ttl_ms=int(args.device_ttl_days) * 86_400_000,
        base_path=args.base_path,
    )

    async def _run() -> None:
        runner = web.AppRunner(app, access_log=None)
        await runner.setup()
        await web.TCPSite(runner, args.host, args.port).start()
        LOGGER.info("relay: listening on http://%s:%s%s (db=%s)", args.host, args.port,
                    normalize_base_path(args.base_path) or "/", args.db)
        stop = asyncio.Event()
        for sig in (signal.SIGINT, signal.SIGTERM):
            try:
                asyncio.get_running_loop().add_signal_handler(sig, stop.set)
            except NotImplementedError:  # pragma: no cover - Windows
                pass
        try:
            await stop.wait()
        finally:
            LOGGER.info("relay: shutting down")
            await runner.cleanup()
            store.close()

    try:
        asyncio.run(_run())
    except KeyboardInterrupt:  # pragma: no cover - interactive
        return 130
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
