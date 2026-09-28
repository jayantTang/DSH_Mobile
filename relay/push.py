"""APNs delivery for the relay: the "something happened on your computer" ping.

Why the relay sends this at all: the phone connects *out* to the relay, so when
the phone is away there is nothing to push a frame down. A terminal app that
cannot reach its user is a terminal app that appears to do nothing, so the relay
— which already keeps the device ledger and the auth surface — talks to Apple on
the phone's behalf. No separate push service, no second credential store.

Four properties this module is built around, in order of how much they cost to
get wrong:

1. **A misconfiguration must never touch forwarding.** ``from_env()`` returns a
   *disabled* sender for missing config or ``DLP_APNS_ENABLED=0``; it warns and
   never raises. Unconfigured, the relay behaves exactly as it did before this
   file existed.
2. **The payload carries no content.** Titles, messages, tool names, file paths,
   host names and error text never appear. The only visible words are
   ``title-loc-key`` pointers into the app's own string tables (two fixed
   reminders); ``sid``/``eid`` travel as non-displaying custom fields. Payloads
   are built in exactly one place — :func:`PushSender._payload` — so this promise
   has exactly one place to be audited.
3. **Nothing here writes to the database.** A dead token is reported back through
   the return value so the caller (which owns the store) decides to clear it.
4. **The HTTP client is injected.** ``httpx`` is not constructed at import time
   and not inside :meth:`send`: tests drive the whole thing with a stub, and the
   real transport is created lazily, once, by the process that needs it.

Signing is ES256 over a token key (a ``.p8``). One key covers every bundle and
both environments and does not expire on its own, which is why this is not the
certificate dance. The environment is *per device*, because a token is bound to
the environment that minted it: sending a sandbox token to production earns a
``BadDeviceToken`` and looks, from the phone, like push simply does not work.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import time
from dataclasses import dataclass, field
from typing import Any, Callable, Iterable, Mapping

LOGGER = logging.getLogger("relay.push")

#: Apple's two front doors. A device token is only valid at the one that matches
#: how the app was signed, so the host is chosen per device, never globally.
APNS_HOSTS = {
    "sandbox": "https://api.sandbox.push.apple.com",
    "production": "https://api.push.apple.com",
}

#: How long an already-minted provider JWT is reused. Apple rejects tokens older
#: than an hour and asks for no more than one refresh per 20 minutes; 50 minutes
#: sits between the two with room for clock skew.
JWT_TTL_S = 50 * 60

#: ``apns-collapse-id`` is capped at 64 bytes by Apple. A session id is short, but
#: truncating beats having the request rejected.
COLLAPSE_ID_MAX = 64

#: How long a reminder stays worth delivering. A "run finished" notice an hour
#: late is noise; an unanswered question is still actionable tomorrow.
EXPIRATION_S = {"turnEnd": 60 * 60, "attention": 24 * 60 * 60}

#: Fixed reminders, by kind. These are **localization keys, not text**: this
#: repository's strings tables use the Chinese original as the key
#: (``en.lproj/Localizable.strings`` / ``zh-Hans.lproj/Localizable.strings``), so
#: the phone renders them in the user's own language. Nothing else may ever be
#: added here — see the module docstring.
ALERT_KEYS = {"turnEnd": "运行结束", "attention": "需要你确认"}

#: APNs rejection reasons that mean "this token is dead, stop using it". 410 is
#: ``Unregistered`` (app uninstalled); ``BadDeviceToken`` is the token/environment
#: mismatch that shows up after a reinstall or a wrong ``apnsEnv``.
DEAD_TOKEN_REASONS = frozenset({"BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"})
DEAD_TOKEN_STATUSES = frozenset({410})


@dataclass
class PushResult:
    """What one delivery attempt produced, for logging and for the caller.

    ``ok``          Apple accepted it.
    ``status``/``reason``  APNs' own answer, kept verbatim: when push "just does
                    not arrive", this is the only thing that says why.
    ``dead_token``  the caller should clear this device's registration.
    ``skipped``     nothing was sent, and why (``disabled`` / ``throttled`` /
                    ``unknown-env`` / ``no-token`` / ``unsupported-kind``).
    """

    ok: bool = False
    status: int | None = None
    reason: str | None = None
    apns_id: str | None = None
    dead_token: bool = False
    skipped: str | None = None

    def as_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "status": self.status,
            "reason": self.reason,
            "apnsId": self.apns_id,
            "deadToken": self.dead_token,
            "skipped": self.skipped,
        }


@dataclass
class PushSender:
    """Sends APNs alerts. One instance per relay process.

    ``client`` is whatever has ``post(url, headers=..., content=...)`` returning
    an object with ``status_code`` / ``headers`` / ``text`` — an ``httpx.AsyncClient``
    in production, a stub in tests. ``now`` is injectable so throttling and JWT
    reuse are testable without sleeping.
    """

    key_path: str | None = None
    key_id: str | None = None
    team_id: str | None = None
    topic: str | None = None
    default_env: str = "sandbox"
    min_interval_s: float = 60.0
    enabled: bool = False
    client: Any = None
    now: Callable[[], float] = time.time
    owns_client: bool = False
    _jwt: str | None = field(default=None, init=False, repr=False)
    _jwt_iat: float = field(default=0.0, init=False, repr=False)
    _last_sent: dict[str, float] = field(default_factory=dict, init=False, repr=False)
    _lock: asyncio.Lock = field(default_factory=asyncio.Lock, init=False, repr=False)

    # ── construction ────────────────────────────────────────────────────────

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None, client: Any = None) -> "PushSender":
        """Build the sender this deployment asks for; never raises.

        Anything missing or switched off yields a disabled instance that logs one
        warning and then answers every :meth:`send` with ``skipped='disabled'``.
        That is the whole safety story: a half-configured relay keeps forwarding.
        """
        env = os.environ if env is None else env
        enabled = _truthy(env.get("DLP_APNS_ENABLED"))
        settings = {
            "key_path": _text(env.get("DLP_APNS_KEY_PATH")),
            "key_id": _text(env.get("DLP_APNS_KEY_ID")),
            "team_id": _text(env.get("DLP_APNS_TEAM_ID")),
            "topic": _text(env.get("DLP_APNS_TOPIC")),
        }
        default_env = (_text(env.get("DLP_APNS_ENV_DEFAULT")) or "sandbox").lower()
        if default_env not in APNS_HOSTS:
            default_env = "sandbox"
        min_interval = _number(env.get("DLP_APNS_MIN_INTERVAL_S"), 60.0)

        if not enabled:
            LOGGER.info("relay: APNs 未启用（DLP_APNS_ENABLED 未设或为 0），推送会被跳过")
            return cls(enabled=False, default_env=default_env, min_interval_s=min_interval)
        missing = [name for name, value in settings.items() if not value]
        if missing:
            LOGGER.warning(
                "relay: APNs 已启用但配置不全（缺 %s），推送不可用——转发不受影响；"
                "需要的是 DLP_APNS_KEY_PATH/KEY_ID/TEAM_ID/TOPIC",
                ", ".join(sorted(missing)))
            return cls(enabled=False, default_env=default_env, min_interval_s=min_interval)
        if not os.path.exists(settings["key_path"]):
            # 只打路径，不打内容：这是唯一能把"密钥放错目录"和"环境变量没生效"
            # 区分开的一行（unit 有 ProtectHome=yes，密钥不能放 /root·/home）。
            LOGGER.warning("relay: APNs 密钥文件不存在：%s（推送不可用，转发不受影响）",
                           settings["key_path"])
            return cls(enabled=False, default_env=default_env, min_interval_s=min_interval)

        LOGGER.info("relay: APNs 已配置（key %s…, topic %s, 默认环境 %s）",
                    settings["key_id"][:6], settings["topic"], default_env)
        return cls(enabled=True, default_env=default_env, min_interval_s=min_interval,
                   client=client, **settings)

    @classmethod
    def disabled(cls) -> "PushSender":
        return cls(enabled=False)

    # ── payload ─────────────────────────────────────────────────────────────

    def _payload(self, kind: str, sid: str, eid: str | None = None) -> dict[str, Any]:
        """The one and only place a push body is built (see module docstring).

        ``aps.alert`` carries **only** ``title-loc-key`` — no title, no body, not
        even a localized argument. The custom fields are the two identifiers the
        app needs to open the right session and to dedupe; neither is displayed.
        """
        alert: dict[str, Any] = {"title-loc-key": ALERT_KEYS[kind]}
        payload: dict[str, Any] = {
            "aps": {"alert": alert, "sound": "default", "thread-id": sid},
            "kind": kind,
            "sid": sid,
        }
        if eid:
            payload["eid"] = eid
        return payload

    # ── signing ─────────────────────────────────────────────────────────────

    def _token(self, *, force: bool = False) -> str:
        """A cached ES256 provider JWT; re-signed only when it is stale or forced."""
        stamp = self.now()
        if not force and self._jwt is not None and stamp - self._jwt_iat < JWT_TTL_S:
            return self._jwt
        import jwt  # imported here so an unconfigured relay never needs the dependency

        with open(self.key_path, "r", encoding="utf-8") as handle:
            key = handle.read()
        self._jwt = jwt.encode(
            {"iss": self.team_id, "iat": int(stamp)},
            key, algorithm="ES256", headers={"kid": self.key_id},
        )
        self._jwt_iat = stamp
        return self._jwt

    # ── sending ─────────────────────────────────────────────────────────────

    def _throttled(self, device_id: str) -> bool:
        """At most one push per device per ``min_interval_s``.

        In memory and per process on purpose: this exists to keep a burst of
        events from stacking up on a lock screen, not to be a durable rate limit.
        A relay restart earning one extra reminder is fine.
        """
        if self.min_interval_s <= 0:
            return False
        last = self._last_sent.get(device_id)
        return last is not None and self.now() - last < self.min_interval_s

    def reset_throttle(self, device_id: str | None = None) -> None:
        """Forget throttle state — ``push-test`` uses this to send on demand."""
        if device_id is None:
            self._last_sent.clear()
        else:
            self._last_sent.pop(device_id, None)

    async def _client(self) -> Any:
        if self.client is None:
            import httpx

            self.client = httpx.AsyncClient(http2=True, timeout=10.0)
            self.owns_client = True
        return self.client

    async def aclose(self) -> None:
        if self.client is not None and self.owns_client:
            await self.client.aclose()
            self.client = None
            self.owns_client = False

    async def send(self, *, device_id: str, token: str, env: str | None, kind: str,
                   sid: str, eid: str | None = None,
                   ignore_throttle: bool = False) -> PushResult:
        """Deliver one reminder. The single entry point (``notify`` and ``push-test``).

        Returns rather than raises: a push is best-effort and must never take the
        caller (the relay's routing path) down with it. ``dead_token=True`` in the
        result is the caller's cue to clear the registration.
        """
        if not self.enabled:
            return PushResult(skipped="disabled")
        if kind not in ALERT_KEYS:
            return PushResult(skipped="unsupported-kind")
        if not token:
            return PushResult(skipped="no-token")
        resolved = (env or self.default_env or "").lower()
        if resolved not in APNS_HOSTS:
            # A token whose environment we cannot name is not sendable: guessing
            # produces BadDeviceToken, which looks exactly like "push is broken".
            LOGGER.warning("relay: device %s reports apnsEnv=%r; not pushing", device_id, env)
            return PushResult(skipped="unknown-env")
        if not ignore_throttle and self._throttled(device_id):
            return PushResult(skipped="throttled")

        payload = json.dumps(self._payload(kind, sid, eid), ensure_ascii=False,
                             separators=(",", ":")).encode("utf-8")
        url = f"{APNS_HOSTS[resolved]}/3/device/{token}"

        result = await self._post(url, payload, kind, sid)
        if result.status == 403 and not ignore_throttle:
            # An expired or rotated provider token is the one failure a *retry*
            # can fix. Exactly once: a revoked key would otherwise loop forever.
            LOGGER.info("relay: APNs rejected the provider token (%s); re-signing once",
                        result.reason)
            async with self._lock:
                self._token(force=True)
            result = await self._post(url, payload, kind, sid)

        if result.ok:
            self._last_sent[device_id] = self.now()
        if result.reason in DEAD_TOKEN_REASONS or result.status in DEAD_TOKEN_STATUSES:
            result.dead_token = True
        return result

    async def _post(self, url: str, payload: bytes, kind: str, sid: str) -> PushResult:
        headers = {
            "authorization": f"bearer {self._token()}",
            "apns-topic": self.topic or "",
            "apns-push-type": "alert",
            "apns-priority": "10",
            "apns-collapse-id": sid[:COLLAPSE_ID_MAX],
            "apns-expiration": str(int(self.now()) + EXPIRATION_S.get(kind, 3600)),
        }
        client = await self._client()
        try:
            response = await client.post(url, headers=headers, content=payload)
        except Exception as error:  # noqa: BLE001 - best-effort: never break forwarding
            LOGGER.warning("relay: APNs request failed: %s", error)
            return PushResult(ok=False, reason=f"transport: {type(error).__name__}")

        status = int(getattr(response, "status_code", 0))
        apns_id = (getattr(response, "headers", {}) or {}).get("apns-id")
        body = (getattr(response, "text", "") or "").strip()
        if status == 200:
            return PushResult(ok=True, status=200, apns_id=apns_id)
        reason = _reason_of(body)
        LOGGER.warning("relay: APNs rejected the push (HTTP %s%s)", status,
                       f", reason={reason}" if reason else "")
        return PushResult(ok=False, status=status, reason=reason, apns_id=apns_id)

    async def send_many(self, targets: Iterable[Mapping[str, Any]], *, kind: str, sid: str,
                        eid: str | None = None,
                        ignore_throttle: bool = False) -> list[PushResult]:
        """Deliver to several devices concurrently; one failure never stops the rest.

        Used by the hub's ``notify`` branch (over ``create_task``, so the routing
        path never waits on Apple) and by ``push-test``.
        """
        async def one(target: Mapping[str, Any]) -> PushResult:
            try:
                return await self.send(
                    device_id=str(target["deviceId"]), token=str(target.get("apnsToken") or ""),
                    env=target.get("apnsEnv"), kind=kind, sid=sid, eid=eid,
                    ignore_throttle=ignore_throttle)
            except Exception as error:  # noqa: BLE001 - one bad row must not sink the rest
                LOGGER.warning("relay: push to %s failed: %s", target.get("deviceId"), error)
                return PushResult(ok=False, reason=f"unexpected: {type(error).__name__}")

        return list(await asyncio.gather(*(one(target) for target in targets)))


def _reason_of(body: str) -> str | None:
    """APNs' own ``reason`` string out of the error body, if there is one."""
    if not body:
        return None
    try:
        parsed = json.loads(body)
    except (ValueError, TypeError):
        return body[:200]
    if isinstance(parsed, dict):
        reason = parsed.get("reason")
        return str(reason) if reason else None
    return None


def _truthy(value: str | None) -> bool:
    return str(value or "").strip().lower() in {"1", "true", "yes", "on"}


def _text(value: str | None) -> str | None:
    text = str(value or "").strip()
    return text or None


def _number(value: str | None, fallback: float) -> float:
    try:
        return float(str(value).strip())
    except (TypeError, ValueError):
        return fallback
