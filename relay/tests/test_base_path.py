"""The relay must serve both the prefixed and the already-stripped path forms.

Caddy's ``handle_path /dsh-link/*`` strips the prefix, so the relay normally
sees ``/healthz``. A plain ``reverse_proxy`` (or any other front end) forwards
``/dsh-link/healthz`` verbatim. Both must work.
"""

from __future__ import annotations

import pytest

import relay as relay_module
from hub import Limits
from conftest import agent_headers


@pytest.fixture
async def prefixed_client(aiohttp_client, store):
    app = relay_module.create_app(store=store, limits=Limits(queue_depth=8),
                                 pair_ttl_ms=60_000, base_path="/dsh-link")
    return await aiohttp_client(app)


@pytest.mark.parametrize("raw,expected", [
    (None, ""),
    ("", ""),
    ("/", ""),
    ("dsh-link", "/dsh-link"),
    ("/dsh-link", "/dsh-link"),
    ("/dsh-link/", "/dsh-link"),
    ("  /dsh-link/  ", "/dsh-link"),
    ("/a/b/", "/a/b"),
])
def test_normalize_base_path(raw, expected):
    assert relay_module.normalize_base_path(raw) == expected


async def test_healthz_is_served_with_and_without_the_prefix(prefixed_client):
    for path in ("/healthz", "/dsh-link/healthz"):
        response = await prefixed_client.get(path)
        assert response.status == 200, path
        assert await response.json() == {"ok": True, "version": 1}


async def test_pair_claim_works_under_the_prefix(prefixed_client, store, provisioned):
    response = await prefixed_client.post("/dsh-link/pair/claim", json={
        "pairCode": provisioned["code"]["code"], "deviceName": "iPhone",
    })
    assert response.status == 200
    body = await response.json()
    assert body["ok"] is True and body["deviceToken"].startswith("dt_")


async def test_pair_code_and_refresh_work_under_the_prefix(prefixed_client, provisioned):
    minted = await prefixed_client.post("/dsh-link/pair/code", json={"ttlMs": 60_000},
                                        headers=agent_headers(provisioned["agent"]))
    assert minted.status == 200
    code = (await minted.json())["code"]

    claim = await prefixed_client.post("/dsh-link/pair/claim",
                                       json={"pairCode": code, "deviceName": "iPhone"})
    token = (await claim.json())["deviceToken"]
    refresh = await prefixed_client.post("/dsh-link/pair/refresh", json={"deviceToken": token})
    assert refresh.status == 200
    assert (await refresh.json())["deviceToken"] != token


async def test_websockets_work_under_the_prefix(prefixed_client, provisioned, store):
    # A device connects through the prefixed path while the agent is offline.
    claim = await prefixed_client.post("/dsh-link/pair/claim", json={
        "pairCode": provisioned["code"]["code"], "deviceName": "iPhone"})
    device = await claim.json()
    device_ws = await prefixed_client.ws_connect(
        f"/dsh-link/link/device?agentId={device['agentId']}",
        headers={"Authorization": f"Bearer {device['deviceToken']}"})
    status = await device_ws.receive_json()
    assert status == {"t": "hostStatus", "info": {"online": False, "agentId": device["agentId"]}}

    agent_ws = await prefixed_client.ws_connect(
        f"/dsh-link/link/agent?agentId={provisioned['agent']['agentId']}",
        headers=agent_headers(provisioned["agent"]))
    attach = await agent_ws.receive_json()
    assert attach["t"] == "deviceAttach" and attach["deviceId"] == device["deviceId"]
    assert (await device_ws.receive_json())["info"]["online"] is True

    await device_ws.send_str('{"t":"req","id":"1","method":"session/list","args":{"_request":{}}}')
    forwarded = await agent_ws.receive_json()
    assert forwarded["id"] == "1" and forwarded["deviceId"] == device["deviceId"]

    await device_ws.close()
    await agent_ws.close()


async def test_unprefixed_paths_still_work_on_a_prefixed_app(prefixed_client):
    """Both forms are live at once, so a front end may do either."""
    assert (await prefixed_client.get("/healthz")).status == 200
    assert (await prefixed_client.get("/dsh-link/healthz")).status == 200
    # And unknown paths stay 404 rather than being swallowed by the prefix.
    assert (await prefixed_client.get("/dsh-link/nope")).status == 404
    assert (await prefixed_client.get("/nope")).status == 404


async def test_options_preflight_works_under_the_prefix(prefixed_client):
    response = await prefixed_client.options("/dsh-link/pair/claim",
                                             headers={"Origin": "https://relay.example.com"})
    assert response.status == 204
    assert response.headers["access-control-allow-origin"] == "*"


async def test_default_app_has_no_prefixed_routes(client):
    assert (await client.get("/healthz")).status == 200
    assert (await client.get("/dsh-link/healthz")).status == 404
