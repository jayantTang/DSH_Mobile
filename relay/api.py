"""Plain-HTTP surface: ``/healthz``, CORS preflight and the ``/pair/*`` calls.

Everything here answers a normal request/response; the two WebSocket endpoints
live in :mod:`relay`. Splitting them keeps both files focused (and under the
size budget) with a one-way import: ``relay`` imports ``api``, never the reverse.
"""

from __future__ import annotations

import asyncio
import json
import logging
from typing import Any

from aiohttp import web

import dlp
from store import InviteRejected, Store, StoreError, hash_invite_code

LOGGER = logging.getLogger("relay.api")

#: Concurrent scrypt verifications. Pairing codes are deliberately expensive to
#: verify, so an unbounded number of claims would be a cheap CPU denial.
_SCRYPT_SLOTS = asyncio.Semaphore(2)

#: Per-IP failed-claim budget.
_CLAIM_FAILURES = 10
_CLAIM_WINDOW_S = 300

CORS_HEADERS = {
    "access-control-allow-origin": "*",
    "access-control-allow-methods": "GET, POST, OPTIONS",
    "access-control-allow-headers": "authorization, content-type",
    "access-control-max-age": "600",
}


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


class ClaimLimiter:
    """In-memory failure budget for ``/pair/claim``, keyed by client IP."""

    def __init__(self, *, limit: int = _CLAIM_FAILURES, window_s: int = _CLAIM_WINDOW_S):
        self.limit = limit
        self.window_s = window_s
        self._hits: dict[str, list[float]] = {}

    def blocked(self, key: str) -> bool:
        now = asyncio.get_running_loop().time()
        hits = [at for at in self._hits.get(key, []) if now - at < self.window_s]
        self._hits[key] = hits
        return len(hits) >= self.limit

    def record_failure(self, key: str) -> None:
        self._hits.setdefault(key, []).append(asyncio.get_running_loop().time())

    def reset(self, key: str) -> None:
        self._hits.pop(key, None)


async def healthz(_request: web.Request) -> web.Response:
    return web.json_response({"ok": True, "version": dlp.PROTOCOL_VERSION})


@web.middleware
async def cors_preflight(request: web.Request, handler: Any) -> web.StreamResponse:
    """Answer ``OPTIONS`` for every path (spec §2).

    A middleware rather than a catch-all route, so an unknown path still answers
    404 instead of a confusing 405.
    """
    if request.method == "OPTIONS":
        return web.Response(status=204, headers=CORS_HEADERS)
    return await handler(request)


async def pair_claim(request: web.Request) -> web.Response:
    store: Store = request.app["store"]
    limiter: ClaimLimiter = request.app["claim_limiter"]
    body = await read_json(request)
    if body is None:
        return json_error(400, "pair/bad-request", "body must be a JSON object")
    code = body.get("pairCode")
    if not isinstance(code, str) or not code.strip():
        return json_error(400, "pair/bad-request", "pairCode is required")
    peer = request.remote or "unknown"
    if limiter.blocked(peer):
        return json_error(429, "pair/rate-limited", "too many failed pairing attempts; try again later")
    device_name = body.get("deviceName")
    model = body.get("deviceModel")
    app_version = body.get("appVersion")
    try:
        async with _SCRYPT_SLOTS:
            result = await asyncio.to_thread(
                store.claim_pair_code,
                code,
                device_name=device_name if isinstance(device_name, str) and device_name else "iOS device",
                model=model if isinstance(model, str) else None,
                app_version=app_version if isinstance(app_version, str) else None,
                ttl_ms=int(request.app["device_ttl_ms"]),
            )
    except StoreError as error:
        limiter.record_failure(peer)
        LOGGER.info("relay: pair claim rejected from %s: %s", peer, error)
        return json_error(404, "pair/invalid-code", str(error))
    limiter.reset(peer)
    LOGGER.info("relay: paired device %s for agent %s", result["deviceId"], result["agentId"])
    return web.json_response({
        "ok": True,
        "agentId": result["agentId"],
        "agentName": result["agentName"],
        "accountId": result["accountId"],
        "deviceId": result["deviceId"],
        "deviceToken": result["deviceToken"],
        "expiresAt": result["expiresAt"],
    })


async def pair_refresh(request: web.Request) -> web.Response:
    store: Store = request.app["store"]
    body = await read_json(request) or {}
    token = bearer_token(request) or body.get("deviceToken")
    if not isinstance(token, str) or not token:
        return json_error(401, "auth/missing-token", "device token is required")
    try:
        result = await asyncio.to_thread(store.refresh_device, token, int(request.app["device_ttl_ms"]))
    except StoreError as error:
        return json_error(401, "auth/invalid-token", str(error))
    return web.json_response(result)


async def pair_code(request: web.Request) -> web.Response:
    """Mint a one-time pairing code for the authenticated agent (docs/notes/relay.md §2)."""
    store: Store = request.app["store"]
    body = await read_json(request) or {}
    token = bearer_token(request)
    agent = await asyncio.to_thread(store.agent_by_secret, token) if token else None
    if agent is None:
        return json_error(401, "auth/invalid-agent", "a valid agent bearer token is required")
    wanted = body.get("agentId")
    if isinstance(wanted, str) and wanted and wanted != agent["agentId"]:
        return json_error(403, "auth/agent-mismatch", "token does not belong to that agent")
    ttl_ms = body.get("ttlMs")
    if not isinstance(ttl_ms, int) or ttl_ms <= 0:
        ttl_ms = int(request.app["pair_ttl_ms"])
    ttl_ms = min(ttl_ms, 60 * 60 * 1000)
    minted = await asyncio.to_thread(store.mint_pair_code, agent["agentId"], ttl_ms)
    return web.json_response({"ok": True, **minted})


async def devices_list(request: web.Request) -> web.Response:
    """List the devices paired to the caller's own agent.

    Authenticated with a device token rather than an operator credential: a
    phone should be able to see and manage its own pairings without the person
    running the relay, and it must not be able to see anyone else's.
    """
    store: Store = request.app["store"]
    token = bearer_token(request)
    device = await asyncio.to_thread(store.device_by_token, token) if token else None
    if device is None:
        return json_error(401, "auth/invalid-token", "a valid device token is required")
    devices = await asyncio.to_thread(store.list_devices, device["agentId"])
    return web.json_response({
        "ok": True,
        "currentDeviceId": device["deviceId"],
        "devices": [
            {
                "deviceId": row["deviceId"],
                "name": row.get("name"),
                "model": row.get("model"),
                "createdAt": row.get("createdAt"),
                "lastSeenAt": row.get("lastSeenAt"),
                "revoked": bool(row.get("revokedAt")),
            }
            for row in devices
        ],
    })


async def devices_revoke(request: web.Request) -> web.Response:
    """Revoke one device belonging to the caller's own agent.

    Scoped to the caller's agent on purpose: without that check any valid device
    token could unpair every phone on the relay.
    """
    store: Store = request.app["store"]
    body = await read_json(request) or {}
    token = bearer_token(request)
    device = await asyncio.to_thread(store.device_by_token, token) if token else None
    if device is None:
        return json_error(401, "auth/invalid-token", "a valid device token is required")

    target = body.get("deviceId")
    if not isinstance(target, str) or not target:
        return json_error(400, "request/device-id", "deviceId is required")

    row = await asyncio.to_thread(store.device_by_id, target)
    if row is None:
        return json_error(404, "request/unknown-device", "no such device")
    if row["agentId"] != device["agentId"]:
        return json_error(403, "auth/agent-mismatch", "that device belongs to another agent")

    await asyncio.to_thread(store.revoke_device, target)
    return web.json_response({"ok": True, "deviceId": target})


#: How many failed enrollments one invite code may absorb before it is frozen
#: for the rest of the window. A code is 20 characters of high-entropy
#: alphabet, so this is not a brute-force defence like the pairing limiter —
#: it is there to stop an online attacker from turning the relay into a
#: code-guessing oracle at full speed.
_ENROLL_FAILURES = 5
_ENROLL_WINDOW_S = 900


async def agents_enroll(request: web.Request) -> web.Response:
    """Redeem an invite code for a fresh ``agentId`` / ``agentSecret``.

    This is how someone else's computer joins the relay without the operator
    touching the database: they install DSH plus this project's connector, paste
    an invite code, and the connector calls this once. Closed by construction —
    no valid, unused, unexpired invite, no identity.

    The plaintext secret is returned exactly once. Only its hash is stored, so a
    leaked database cannot be replayed, and a lost secret means re-enrolling
    with a new invite rather than recovering the old one.
    """
    store: Store = request.app["store"]
    body = await read_json(request)
    if body is None:
        return json_error(400, "enroll/bad-request", "body must be a JSON object")

    code = body.get("inviteCode")
    if not isinstance(code, str) or not code.strip():
        return json_error(400, "enroll/bad-request", "inviteCode is required")
    name = body.get("name")
    agent_name = name.strip() if isinstance(name, str) and name.strip() else "My computer"

    limiter: ClaimLimiter = request.app["enroll_limiter"]
    key = hash_invite_code(code)
    if limiter.blocked(key):
        return json_error(429, "enroll/rate-limited",
                          "too many failed attempts for that invite code; try again later")

    try:
        result = await asyncio.to_thread(store.claim_invite, code, agent_name)
    except InviteRejected as error:
        limiter.record_failure(key)
        LOGGER.info("relay: invite rejected (%s)", error.reason)
        return json_error(404, f"enroll/{error.reason}", str(error))
    except StoreError as error:
        # Account/agent creation failed after the invite looked fine: the
        # transaction rolled back, so the code is still redeemable.
        LOGGER.warning("relay: invite redemption failed: %s", error)
        return json_error(500, "enroll/store-error", "the relay could not complete the enrollment")

    limiter.reset(key)
    LOGGER.info("relay: enrolled agent %s from an invite", result["agentId"])
    return web.json_response({
        "ok": True,
        "agentId": result["agentId"],
        "agentSecret": result["agentSecret"],
        "agentName": result["agentName"],
        "accountId": result["accountId"],
    })


def register_http_routes(app: web.Application, route: Any, base_path: str) -> None:
    """Attach the plain-HTTP routes (``route`` registers both path forms)."""
    route("GET", "/healthz", healthz)
    route("POST", "/pair/claim", pair_claim)
    route("POST", "/pair/refresh", pair_refresh)
    route("POST", "/pair/code", pair_code)
    route("GET", "/devices", devices_list)
    route("POST", "/devices/revoke", devices_revoke)
    route("POST", "/agents/enroll", agents_enroll)
    app["claim_limiter"] = ClaimLimiter()
    app["enroll_limiter"] = ClaimLimiter(limit=_ENROLL_FAILURES, window_s=_ENROLL_WINDOW_S)
    app["base_path"] = base_path
