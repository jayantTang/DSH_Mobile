"""The relay must serve both the prefixed and the already-stripped path forms.

Caddy's ``handle_path /dsh-link/*`` strips the prefix, so the relay normally
sees ``/healthz``. A plain ``reverse_proxy`` (or any other front end) forwards
``/dsh-link/healthz`` verbatim. Both must work.
"""

from __future__ import annotations

import json
import pathlib
from urllib.parse import urlsplit

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


def test_normalize_base_path_matches_the_shared_vectors():
    """The Python half of `test/contract/relay-base-path-vectors.json`.

    Four implementations join a relay-relative path onto a configured base: this
    one (`normalize_base_path`), iOS's `LinkConfiguration.appending(path:to:)`,
    the connector's `dlp.js:joinRelayPath`, and the test harness's
    `test/tools/relaypair.mjs:route`. All four read the same file.

    This end only covers the **normalisation** step — the relay never appends a
    suffix itself; routing composes `f"{base_path}{path}"` at request time
    (`relay.py`), and that half is pinned by the end-to-end cases above. The
    vectors say so in their `notes`.
    """
    repo_root = pathlib.Path(__file__).resolve().parents[2]
    vectors = json.loads(
        (repo_root / "test" / "contract" / "relay-base-path-vectors.json").read_text("utf-8"))
    assert "只覆盖它有的那一步" in " ".join(vectors["notes"])

    expectations = {
        "https://host": "",
        "https://host/": "",
        "https://host/dsh-link": "/dsh-link",
        "https://host/dsh-link/": "/dsh-link",
        "https://host/a/b/": "/a/b",
        "http://127.0.0.1:8787": "",
    }
    # 每个 base 都必须出现在向量里，且归一化结果与本端一致。
    for base, expected in expectations.items():
        assert any(case["base"] == base for case in vectors["cases"]), f"向量里缺 base {base}"
        raw = urlsplit(base).path  # "/", "/dsh-link", "/a/b/" …
        assert relay_module.normalize_base_path(raw) == expected, base
