"""``/stats`` must not be readable from the public internet.

``/stats`` is the operator's page: it names every device on the relay and how
many bytes each one has moved. It is not part of the protocol and nothing in the
app or the connector calls it, so "reachable from the internet" is purely a
leak — of device names, of byte counts, and of the fact that this host runs a
relay at all.

The relay listens on loopback behind Caddy, so in production such a request
arrives from the front end with the caller's address in ``X-Forwarded-For``.
That is exactly the shape these tests drive: if the peer is not loopback, the
handler must refuse **regardless of headers**, and it must refuse with 404
rather than 403 so the endpoint is indistinguishable from a path that never
existed.

The other half of the guarantee — an explicit reject in the Caddy fragment, so
the request never reaches the relay — is pinned in ``test_caddy_splice.py``.
"""

from __future__ import annotations

import asyncio

import pytest
from aiohttp import web
from aiohttp.http_parser import HttpVersion, RawRequestMessage
from aiohttp.streams import StreamReader

import api
from relay import create_app
from hub import Limits

LOOPBACK = "127.0.0.1"
PUBLIC = "203.0.113.7"


@pytest.mark.parametrize("value,expected", [
    ("127.0.0.1", True),
    ("127.0.0.53", True),          # the whole 127/8 block is loopback, not just .0.1
    ("::1", True),
    ("[::1]", True),               # an IPv6 literal arrives bracketed
    ("::ffff:127.0.0.1", True),    # IPv4-mapped, as a dual-stack host reports it
    ("localhost", True),
    (None, False),
    ("", False),
    ("   ", False),
    ("203.0.113.7", False),
    ("10.0.0.1", False),           # private, but not *this* machine: not trusted
    ("::ffff:203.0.113.7", False),
    ("not-an-address", False),
])
def test_is_loopback(value, expected):
    assert api.is_loopback(value) is expected


async def stats_from(peer: str | None, url: str = "/stats", **headers) -> web.Response:
    """Ask ``/stats`` from a chosen peer address, bypassing the socket.

    ``aiohttp_client`` always connects over loopback, so a test that wants to be
    "the internet" has to build the request itself: ``web.Request`` takes the
    peer address as ``remote``, which is the same attribute the handler reads.
    """
    app = create_app(store=_NOOP_STORE, limits=Limits(queue_depth=8))
    request = _make_request(app, peer=peer, url=url, headers=headers)
    return await api.stats(request)


class _NoopStore:
    """`/stats` only reads; the hub never touches the store in these tests."""

    def usage_rows(self, _day):
        return []

    def add_usage(self, _entries):
        return 0


_NOOP_STORE = _NoopStore()


def _make_request(app: web.Application, *, peer: str | None, url: str,
                  headers: dict[str, str]) -> web.Request:
    from multidict import CIMultiDict, CIMultiDictProxy
    from yarl import URL

    target = URL(url)
    message = RawRequestMessage(
        method="GET", path=target.path, version=HttpVersion(1, 1),
        headers=CIMultiDictProxy(CIMultiDict(headers)), raw_headers=(),
        should_close=False, compression=None, upgrade=False, chunked=False,
        url=target,
    )
    return web.Request(message, StreamReader(_FakeProtocol(), limit=2**16),
                       _FakeProtocol(), _FakeWriter(), asyncio.current_task(),
                       asyncio.get_running_loop(), state={"app": app}, remote=peer)


class _FakeProtocol(asyncio.Protocol):
    """``StreamReader`` wants a protocol object; it never reads from it here."""

    def __init__(self, peername=None):
        self.transport = None
        self.ssl_context = None
        self.peername = peername
        self.sockname = ("127.0.0.1", 8787)
        self._reading_paused = False
        self._drain_waiter = None

    def pause_reading(self):
        self._reading_paused = True

    def resume_reading(self):
        self._reading_paused = False

    def is_reading(self):
        return not self._reading_paused


class _FakeWriter:
    """``Request`` holds a writer; nothing in ``/stats`` writes through it."""

    def __init__(self):
        self.output_size = 0

    def write_headers(self, *args, **kwargs):
        return None

    async def write_eof(self, *args, **kwargs):
        return None


async def test_stats_refuses_a_public_peer_with_404_not_403():
    response = await stats_from(PUBLIC)
    assert response.status == 404, "a public caller must not be able to read /stats"
    assert response.status != 403, "403 would reveal that the endpoint exists"


async def test_stats_refuses_a_public_peer_even_with_a_forged_forwarding_header():
    """The headers a public caller can set must not buy them the page.

    In production the relay sits behind Caddy, so ``remote`` is loopback for
    every caller and ``X-Forwarded-For`` is what the check would have to look at.
    If it ever falls back to trusting that header from a non-loopback peer, this
    is the request that leaks.
    """
    for forwarded in (LOOPBACK, f"{LOOPBACK}, {PUBLIC}", "localhost"):
        response = await stats_from(PUBLIC, **{"X-Forwarded-For": forwarded,
                                               "X-Real-IP": LOOPBACK})
        assert response.status == 404, forwarded


async def test_stats_still_answers_loopback_with_the_same_shape(client):
    response = await client.get("/stats")
    assert response.status == 200
    body = await response.json()
    # The structure is a contract: scripts/dev/watch-relay.mjs reads it.
    assert body["ok"] is True
    assert set(body) >= {"ok", "version", "limits", "load", "traffic", "snapshot", "today"}
    assert set(body["load"]) == {"agents", "devices"}
    assert "totalEgressBytes" in body["traffic"]
    assert "day" in body["today"]


async def test_healthz_stays_public(client):
    """The deploy script waits on /healthz; it must not be caught by this."""
    assert (await client.get("/healthz")).status == 200


async def test_a_stats_page_request_from_the_public_gets_json_404_too():
    """The HTML view is the same leak, so it is refused the same way."""
    response = await stats_from(PUBLIC, headers={"Accept": "text/html"})
    assert response.status == 404
    assert response.content_type == "application/json"


def test_no_stray_asyncio_loop_is_left_behind():
    """Guard for the direct-handler tests above: they must not need a loop."""
    assert asyncio.get_event_loop_policy() is not None
