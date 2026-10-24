"""``POST /internal/tokens/resolve``：拆分后信件服务对中转的唯一运行时依赖。

契约（maintainers/design/DESIGN-20261015-mail-service-split.md I-1）：

- loopback-only：公网对端（无论伪造什么转发头）一律 404，且是 404 不是 403——
  与 /stats 同一道守卫、同一个"探测者不该分辨端点存在"的理由。
- 只读、幂等：返回 ``{deviceId, accountId, expiresAt}``；未知 / 撤销 / 过期 /
  格式不对一律 404，不给调用方区分"撤销"与"不存在"。
- 恶意体（非对象、缺 token）回 400。

公开路径的另一半保证（Caddy 片段显式拒绝）归 test_caddy_splice.py /
test_caddy_runtime.py 的口径，这里只钉中转自己的行为。
"""

from __future__ import annotations

import asyncio

import pytest
from aiohttp import web
from aiohttp.http_parser import HttpVersion, RawRequestMessage
from aiohttp.streams import StreamReader
from multidict import CIMultiDict, CIMultiDictProxy
from yarl import URL

import api

LOOPBACK = "127.0.0.1"
PUBLIC = "203.0.113.7"


async def paired_token(client, agent_id: str) -> tuple[str, dict]:
    """配一台临时设备，返回 (deviceToken, 设备行)。"""
    code = client.app["store"].mint_pair_code(agent_id, ttl_ms=60_000)
    claim = await client.post("/pair/claim", json={
        "pairCode": code["code"], "deviceName": "DSH-Test", "model": "iPhone17,1"})
    assert claim.status == 200, await claim.text()
    body = await claim.json()
    device = client.app["store"].device_by_token(body["deviceToken"])
    assert device is not None
    return body["deviceToken"], device


async def resolve_from(peer: str | None, **headers) -> web.Response:
    """直接以选定的对端地址调 handler（绕过 socket），测 loopback 守卫。"""
    request = _make_request(peer=peer, headers=headers)
    return await api.internal_token_resolve(request)


class _FakeProtocol(asyncio.Protocol):
    def __init__(self):
        self.transport = None
        self.ssl_context = None
        self.peername = None
        self.sockname = (LOOPBACK, 8787)
        self._reading_paused = False
        self._drain_waiter = None

    def pause_reading(self):
        self._reading_paused = True

    def resume_reading(self):
        self._reading_paused = False

    def is_reading(self):
        return not self._reading_paused


class _FakeWriter:
    def __init__(self):
        self.output_size = 0

    def write_headers(self, *args, **kwargs):
        return None

    async def write_eof(self, *args, **kwargs):
        return None


def _make_request(*, peer: str | None, headers: dict[str, str]) -> web.Request:
    target = URL("/internal/tokens/resolve")
    message = RawRequestMessage(
        method="POST", path=target.path, version=HttpVersion(1, 1),
        headers=CIMultiDictProxy(CIMultiDict(headers)), raw_headers=(),
        should_close=False, compression=None, upgrade=False, chunked=False,
        url=target,
    )
    # 守卫在读 body 之前就返回，所以这里不需要喂 payload。
    return web.Request(message, StreamReader(_FakeProtocol(), limit=2**16),
                       _FakeProtocol(), _FakeWriter(), asyncio.current_task(),
                       asyncio.get_running_loop(), state={}, remote=peer)


async def test_loopback_peer_with_a_valid_token_gets_the_binding(client, provisioned):
    token, device = await paired_token(client, provisioned["agent"]["agentId"])
    response = await client.post("/internal/tokens/resolve", json={"token": token})
    assert response.status == 200, await response.text()
    body = await response.json()
    assert body == {
        "deviceId": device["deviceId"],
        "accountId": provisioned["account"]["accountId"],
        "expiresAt": device["expiresAt"],
    }


async def test_unknown_token_is_a_plain_404(client):
    response = await client.post("/internal/tokens/resolve",
                                 json={"token": "dev_does_not_exist"})
    assert response.status == 404


async def test_revoked_token_is_the_same_404(client, provisioned):
    token, device = await paired_token(client, provisioned["agent"]["agentId"])
    client.app["store"].revoke_device(device["deviceId"])
    response = await client.post("/internal/tokens/resolve", json={"token": token})
    assert response.status == 404


async def test_bad_body_is_a_400_not_a_500(client):
    for payload in ({}, {"token": ""}, {"token": 42}, {"other": "x"}):
        response = await client.post("/internal/tokens/resolve", json=payload)
        assert response.status == 400, payload


async def test_a_public_peer_is_refused_with_404_regardless_of_headers():
    """公网对端必须拿 404；伪造的转发头买不到任何东西（与 /stats 同理由）。"""
    for forwarded in (LOOPBACK, f"{LOOPBACK}, {PUBLIC}", "localhost"):
        response = await resolve_from(PUBLIC, **{"X-Forwarded-For": forwarded,
                                                 "X-Real-IP": LOOPBACK})
        assert response.status == 404, forwarded
        assert response.status != 403, "403 会暴露这个端点存在"


async def test_the_route_is_registered_under_the_base_path_too(store):
    """route() 会同时注册带前缀与去前缀两种形式——mail 走的也是这个约定。"""
    import relay as relay_module
    from hub import Limits

    app = relay_module.create_app(store=store, limits=Limits(queue_depth=8),
                                  base_path="/dsh-link")
    registered = {r.resource.canonical for r in app.router.routes()}
    assert "/internal/tokens/resolve" in registered
    assert "/dsh-link/internal/tokens/resolve" in registered
