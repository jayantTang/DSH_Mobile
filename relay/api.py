"""Plain-HTTP surface: ``/healthz``, CORS preflight and the ``/pair/*`` calls.

Everything here answers a normal request/response; the two WebSocket endpoints
live in :mod:`relay`. Splitting them keeps both files focused (and under the
size budget) with a one-way import: ``relay`` imports ``api``, never the reverse.
"""

from __future__ import annotations

import asyncio
import ipaddress
import json
import logging
import time
from typing import Any

from aiohttp import web

import dlp
from store import InviteRejected, PairCodeRejected, Store, StoreError, hash_invite_code

LOGGER = logging.getLogger("relay.api")

#: Concurrent scrypt verifications. Pairing codes are deliberately expensive to
#: verify, so an unbounded number of claims would be a cheap CPU denial.
_SCRYPT_SLOTS = asyncio.Semaphore(2)

#: Per-client failed-claim budget. "Client" means whatever
#: :func:`client_identifier` returns — not the socket peer, which behind a front
#: end is the front end itself and would put every caller in one bucket.
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


#: The header the front end is required to set. Caddy's ``header_up X-Real-IP
#: {remote_host}`` in ``deploy/Caddyfile.snippet`` is the deployed instance of it.
_FORWARDED_FOR = "X-Forwarded-For"


def is_loopback(value: str | None) -> bool:
    """Is ``value`` a loopback address?

    This single predicate is the relay's **trust boundary**. Everything that
    depends on "did this request really come from our own front end?" — the
    ``X-Forwarded-For`` header, and the operator-only ``/stats`` page — asks this
    and nothing else. Keeping it in one place is what stops the two answers from
    drifting apart.
    """
    if not value:
        return False
    text = value.strip()
    if text.startswith("[") and text.endswith("]"):
        text = text[1:-1]          # an IPv6 literal arrives bracketed
    if text.startswith("::ffff:"):
        text = text[len("::ffff:"):]   # IPv4-mapped IPv6, as a dual-stack host reports it
    try:
        return ipaddress.ip_address(text).is_loopback
    except ValueError:
        # aiohttp normally hands over a bare address, but a unix socket peer or
        # a hostname is not something we can call trusted.
        return text in ("localhost",)


def client_identifier(request: web.Request) -> str:
    """The address a rate-limit bucket is keyed on.

    Behind a front end every request arrives from ``127.0.0.1``, so ``remote``
    alone would put the whole internet in one bucket — one attacker could then
    exhaust everybody's budget, and a second attacker would be invisible.

    ``X-Forwarded-For`` fixes that, but only for the requests our own front end
    forwarded: a client can send the header itself. Caddy's ``header_up``
    **replaces** the header with the real peer (measured on v2.11.4; it does
    *not* append), so what arrives from our front end carries exactly one
    address and a client-supplied value never survives. The rule is therefore:

    * the peer is loopback **and** the header carries a usable address → the
      **leftmost** entry, which under replacement semantics is the only one;
    * anything else → the socket peer, and the header is ignored outright.

    Being wrong in the first direction lets one client escape its own budget;
    being wrong in the second lets anyone spend someone else's. The second is
    the one worth being strict about.

    .. warning::
       The leftmost entry is safe *because* the deployed front end replaces the
       header. Swap in a gateway that appends instead and this must become the
       **last** entry (or ``X-Real-IP``), otherwise the leftmost value is
       attacker-chosen.
    """
    peer = (request.remote or "").strip()
    if is_loopback(peer):
        forwarded = request.headers.get(_FORWARDED_FOR, "")
        first = forwarded.split(",")[0].strip()
        if first:
            return first
    return peer or "unknown"


class ClaimLimiter:
    """In-memory failure budget keyed by whatever bucket the caller chose.

    ``/pair/claim`` keys on the client address alone and that bucket *does* admit
    or refuse. ``/agents/enroll`` keeps two — the code hash (the gate) and the
    client address (a record that never vetoes a valid code); see
    :func:`agents_enroll` for why they differ. Deciding *what a client is* is
    :func:`client_identifier`'s job, not this class's — the trust boundary lives
    in one place.
    """

    def __init__(self, *, limit: int = _CLAIM_FAILURES, window_s: int = _CLAIM_WINDOW_S):
        self.limit = limit
        self.window_s = window_s
        self._hits: dict[str, list[float]] = {}
        self._failures_total = 0

    @property
    def failures_total(self) -> int:
        """Every failure this limiter has recorded, across all buckets.

        Exposed because the counts are kept for accounting as well as for
        enforcement: ``/agents/enroll`` no longer refuses a *valid* code on the
        strength of its bucket alone (see :func:`agents_enroll`), so this counter
        is what still shows an operator how much guessing is going on.
        """
        return self._failures_total

    @staticmethod
    def _now() -> float:
        """Monotonic seconds.

        The event loop's clock when there is one — that is the norm, and it keeps
        the window honest under a loaded loop — and ``time.monotonic`` otherwise.
        The fallback is not decoration: the store enforces the same budgets from
        the worker thread that runs ``claim_invite`` (there is no running loop
        there), so a clock that only exists inside the loop would make a check
        from that thread raise instead of answering.
        """
        try:
            return asyncio.get_running_loop().time()
        except RuntimeError:
            return time.monotonic()

    def blocked(self, key: str) -> bool:
        now = self._now()
        hits = [at for at in self._hits.get(key, []) if now - at < self.window_s]
        self._hits[key] = hits
        return len(hits) >= self.limit

    def record_failure(self, key: str) -> None:
        self._record(key)
        self._failures_total += 1

    def count_failure(self, key: str, *, total: bool = True) -> None:
        """Record one failure against ``key``, optionally off the global tally.

        ``total=False`` is for the caller that counts the same failure against a
        second bucket. One request is one failure, however many budgets it is
        charged to, so the *first* bucket counts it towards
        :attr:`failures_total` and any further bucket merely records it. Without
        this, two buckets would double every number an operator reads.
        """
        self._record(key)
        if total:
            self._failures_total += 1

    def _record(self, key: str) -> None:
        self._hits.setdefault(key, []).append(self._now())

    def reset(self, key: str) -> None:
        self._hits.pop(key, None)


async def healthz(_request: web.Request) -> web.Response:
    return web.json_response({"ok": True, "version": dlp.PROTOCOL_VERSION})


async def stats(request: web.Request) -> web.Response:
    """Live load and traffic accounting, for the operator.

    Not part of the protocol: nothing in the app or the connector calls it. It
    exists because the relay runs on a **fixed-bandwidth** host, where the
    question that matters is "which device is using the pipe", and the host's own
    interface counters cannot answer it (they mix in SSH, OTA downloads and
    everything else on the machine).

    Serving a page as well as JSON keeps it to one command on the server:
    ``curl -s localhost:8787/stats | head`` for a number, or open the same URL in
    a browser for a self-refreshing view.

    **Reachable from loopback only, and that takes two independent halves.**
    This handler refuses anything whose peer is not loopback (see
    :func:`is_loopback`), and ``deploy/Caddyfile.snippet`` carries an explicit
    reject for the public path so such a request never reaches the relay at all.
    Neither half is sufficient alone: a front end that forwards everything would
    make this page public, and losing this check would do the same the moment a
    deployment moved the relay off loopback (``--host 0.0.0.0``). The page names
    devices and their byte counts, so this is not a cosmetic distinction.

    A refusal answers **404**, never 403: a probe should not be able to tell this
    endpoint apart from a path that never existed.
    """
    if not is_loopback(request.remote):
        LOGGER.info("relay: refused /stats for non-loopback peer %s", request.remote)
        return json_error(404, "not-found", "not found")

    hub = request.app["hub"]
    limits = request.app["limits"]
    payload = {
        "ok": True,
        "version": dlp.PROTOCOL_VERSION,
        "limits": limits.describe(),
        "load": {
            "agents": len(hub.agents),
            "devices": len(hub.all_devices()),
        },
        "traffic": hub.traffic(),
        "snapshot": hub.snapshot(),
        # 今天（服务器本地日）按账号与按设备的出口字节。库里那份 + 还没冲盘的那部分
        # 合起来才是"此刻为止"；完整历史用 `relay/admin.py usage --days 7`。
        "today": hub.usage_today(),
    }
    if "text/html" in (request.headers.get("Accept") or ""):
        return web.Response(text=_stats_page(payload), content_type="text/html")
    return web.json_response(payload)


def _stats_page(payload: dict[str, Any]) -> str:
    """The same numbers as a small self-refreshing page."""
    limits = payload["limits"]
    load = payload["load"]
    rows = []
    for device in payload["traffic"]["devices"]:
        quota = device["quotaRemainingBytes"]
        rows.append(
            "<tr><td>{name}</td><td class=mono>{deviceId}</td><td class=num>{mb:.2f} MB</td>"
            "<td class=num>{paced:.1f}s</td><td class=num>{quota}</td></tr>".format(
                name=device["name"] or "—",
                deviceId=device["deviceId"],
                mb=device["egressBytes"] / 1024 / 1024,
                paced=device["pacedSeconds"],
                quota="不限" if quota < 0 else f"{quota / 1024 / 1024:.1f} MB",
            ))
    if not rows:
        rows.append('<tr><td colspan="5" class=muted>当前没有设备连着</td></tr>')
    return f"""<!doctype html>
<html lang="zh"><head><meta charset="utf-8"><title>DLP relay</title>
<meta http-equiv="refresh" content="5">
<style>
 body {{ font: 14px/1.6 -apple-system, "PingFang SC", sans-serif; margin: 2rem; color: #1c1c1e; }}
 h1 {{ font-size: 1.1rem; }} table {{ border-collapse: collapse; width: 100%; }}
 th, td {{ border-bottom: 1px solid #e5e5ea; padding: .4rem .6rem; text-align: left; }}
 th {{ color: #6c6c70; font-weight: 600; }}
 .num {{ text-align: right; }} .mono {{ font-family: ui-monospace, monospace; font-size: 12px; }}
 .muted {{ color: #8e8e93; }} .big {{ font-size: 1.4rem; font-weight: 600; }}
</style></head><body>
<h1>DLP relay — 实时负载与流量</h1>
<p>agent <span class=big>{load['agents']}</span> 个 · 连接设备 <span class=big>{load['devices']}</span> 台 ·
   本次启动累计出口 <span class=big>{payload['traffic']['totalEgressBytes'] / 1024 / 1024:.2f} MB</span>
   <span class=muted>（页面每 5 秒自刷新；数字是 relay 自己算的，不含 SSH 与 OTA 流量）</span></p>
<p class=muted>限制：每设备 {limits['deviceBytesPerSecond'] or '不限'} B/s ·
   每日 {limits['deviceDailyBytes'] or '不限'} B · 每 agent 设备数 {limits['maxDevicesPerAgent'] or '不限'}</p>
<table><thead><tr><th>设备</th><th>deviceId</th><th class=num>本次出口</th>
<th class=num>被限速时长</th><th class=num>今日剩余额度</th></tr></thead>
<tbody>{''.join(rows)}</tbody></table>
</body></html>"""


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
    peer = client_identifier(request)
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
    """Mint a one-time pairing code for the authenticated agent (docs/RELAY-NOTES.md §2)."""
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


#: How many failed enrollments a code may absorb before it is frozen for the rest
#: of the window. A code is 20 characters of high-entropy alphabet, so this is not
#: a brute-force defence in the way the pairing limiter is; it is there to stop an
#: online attacker from turning the relay into a code-guessing oracle at full
#: speed. ``/agents/enroll`` also keeps a per-client bucket, but that one only
#: records failures — it must never refuse a *valid* code (owner's ruling,
#: 2026-09-25; see the handler and ``docs/RELAY-PROTOCOL.md`` §5.2).
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
    # Two buckets are kept, and they do different jobs:
    #
    #   * the **code** bucket (`hash_invite_code(code)`) is the *gate*: it stops
    #     an online attacker from turning one invite into a guessing oracle at
    #     full speed. Five failures against a code and that code is frozen.
    #   * the **client** bucket (the caller's address) is a *record*: it
    #     accumulates that source's failures so an operator can see who is
    #     guessing. It does not admit and it does not veto.
    #
    # These are deliberately *not* combined into one `client|code` key, which
    # would hand every new code a fresh allowance and make the code budget
    # meaningless.
    #
    # **The client bucket never vetoes a valid code.** Owner's ruling,
    # 2026-09-25: an invite is the operator's decision to admit someone, and a
    # history of failures is grounds for watching, not for overriding it. So a
    # caller who has failed five times still gets in by producing a real code.
    # That is why nothing below consults the client bucket before trying the
    # redemption: the only admitted-and-refusing check here is the code bucket.
    #
    # What that gives up, and it is the whole of it: the client dimension no
    # longer bounds how fast a source can *fail* — after five bad guesses the
    # next bad guess is tried rather than refused, and a caller moving from code
    # to code gets five fresh guesses per code. It bounds nothing about how fast
    # one can fail; it is kept so the failures are visible. See
    # ``docs/RELAY-PROTOCOL.md`` §5.2.
    code_key = hash_invite_code(code)
    client_key = client_identifier(request)

    # The code bucket is the gate, and consulting it before the store call is
    # what makes "five failures against one code" mean five: the sixth request
    # naming it, and every one after, is refused without being charged again.
    if limiter.blocked(code_key):
        return json_error(429, "enroll/rate-limited",
                          "too many failed attempts for that invite code; try again later")

    # The store charges both buckets itself, inside its lock and only once the
    # attempt is known to have failed, so a concurrent burst cannot slip past a
    # budget that the other requests have not filled yet. It reads ``client_key``
    # purely to record against it.
    try:
        result = await asyncio.to_thread(
            store.claim_invite, code, agent_name, limiter,
            count_key=code_key, client_key=client_key)
    except PairCodeRejected:
        # A concurrent request against the same code filled the bucket first.
        LOGGER.info("relay: invite rate-limited (%d failures so far)", limiter.failures_total)
        return json_error(429, "enroll/rate-limited",
                          "too many failed attempts for that invite code; try again later")
    except InviteRejected as error:
        LOGGER.info("relay: invite rejected (%s)", error.reason)
        return json_error(404, f"enroll/{error.reason}", str(error))
    except StoreError as error:
        # Account/agent creation failed after the invite looked fine: the
        # transaction rolled back, so the code is still redeemable.
        LOGGER.warning("relay: invite redemption failed: %s", error)
        return json_error(500, "enroll/store-error", "the relay could not complete the enrollment")

    limiter.reset(code_key)
    limiter.reset(client_key)
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
    route("GET", "/stats", stats)
    route("POST", "/pair/claim", pair_claim)
    route("POST", "/pair/refresh", pair_refresh)
    route("POST", "/pair/code", pair_code)
    route("GET", "/devices", devices_list)
    route("POST", "/devices/revoke", devices_revoke)
    route("POST", "/agents/enroll", agents_enroll)
    app["claim_limiter"] = ClaimLimiter()
    app["enroll_limiter"] = ClaimLimiter(limit=_ENROLL_FAILURES, window_s=_ENROLL_WINDOW_S)
    app["base_path"] = base_path
