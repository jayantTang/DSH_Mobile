"""HTTP surface tests: /healthz, CORS, /pair/claim, /pair/refresh, /pair/code."""

from __future__ import annotations

import pytest

from conftest import agent_headers


async def test_healthz_matches_the_spec_contract(client):
    response = await client.get("/healthz")
    assert response.status == 200
    assert await response.json() == {"ok": True, "version": 1}


async def test_options_preflight(client):
    response = await client.options("/pair/claim", headers={"Origin": "https://relay.example.com"})
    assert response.status == 204
    assert response.headers["access-control-allow-origin"] == "*"
    assert "authorization" in response.headers["access-control-allow-headers"].lower()


async def test_pair_claim_happy_path(client, provisioned):
    response = await client.post("/pair/claim", json={
        "pairCode": provisioned["code"]["code"],
        "deviceName": "Example iPhone",
        "deviceModel": "iPhone17,1",
        "appVersion": "1.0.0",
    })
    assert response.status == 200
    body = await response.json()
    assert body["ok"] is True
    assert body["agentId"] == provisioned["agent"]["agentId"]
    assert body["accountId"] == provisioned["account"]["accountId"]
    assert body["agentName"] == "test mac"
    assert body["deviceToken"].startswith("dt_")
    assert body["expiresAt"] > 0


async def test_pair_claim_is_one_time(client, provisioned):
    payload = {"pairCode": provisioned["code"]["code"], "deviceName": "iPhone"}
    assert (await client.post("/pair/claim", json=payload)).status == 200
    second = await client.post("/pair/claim", json=payload)
    assert second.status == 404
    assert (await second.json())["error"]["code"] == "pair/invalid-code"


@pytest.mark.parametrize("payload", [
    {},
    {"pairCode": ""},
    {"pairCode": "AAAA-AAAA"},
])
async def test_pair_claim_rejects_bad_input(client, payload):
    response = await client.post("/pair/claim", json=payload)
    assert response.status in (400, 404)
    assert (await response.json())["ok"] is False


async def test_pair_claim_rejects_non_json(client):
    response = await client.post("/pair/claim", data=b"not json",
                                 headers={"content-type": "application/json"})
    assert response.status == 400


async def test_pair_claim_tolerates_an_odd_content_type(client):
    """A client without a JSON content type must not turn into a 500."""
    no_type = await client.post("/pair/claim", data=b'{"pairCode":"AAAA-AAAA"}')
    assert no_type.status == 404
    assert (await no_type.json())["error"]["code"] == "pair/invalid-code"

    text_type = await client.post("/pair/claim", data=b"pairCode=nope",
                                 headers={"content-type": "text/plain"})
    assert text_type.status == 400


async def test_pair_claim_is_rate_limited(client, store):
    account = store.create_account("a")
    store.register_agent(account["accountId"], "mac")
    for _ in range(10):
        assert (await client.post("/pair/claim", json={"pairCode": "ZZZZ-ZZZZ"})).status == 404
    blocked = await client.post("/pair/claim", json={"pairCode": "ZZZZ-ZZZZ"})
    assert blocked.status == 429
    assert (await blocked.json())["error"]["code"] == "pair/rate-limited"


async def test_pair_code_requires_agent_auth(client, provisioned):
    assert (await client.post("/pair/code", json={})).status == 401
    assert (await client.post("/pair/code", json={},
                              headers={"Authorization": "Bearer as_nope"})).status == 401
    mismatch = await client.post("/pair/code", json={"agentId": "agt_other"},
                                 headers=agent_headers(provisioned["agent"]))
    assert mismatch.status == 403


async def test_pair_code_mints_a_claimable_code(client, provisioned):
    response = await client.post("/pair/code", json={"ttlMs": 60_000},
                                 headers=agent_headers(provisioned["agent"]))
    assert response.status == 200
    minted = await response.json()
    assert minted["ok"] is True
    assert len(minted["code"]) == 9 and minted["code"][4] == "-"
    claim = await client.post("/pair/claim", json={"pairCode": minted["code"], "deviceName": "iPhone"})
    assert claim.status == 200
    assert (await claim.json())["agentId"] == provisioned["agent"]["agentId"]


async def test_pair_refresh_rotates_and_invalidates(client, provisioned):
    claim = await client.post("/pair/claim", json={
        "pairCode": provisioned["code"]["code"], "deviceName": "iPhone"})
    token = (await claim.json())["deviceToken"]

    refresh = await client.post("/pair/refresh", json={"deviceToken": token})
    assert refresh.status == 200
    rotated = await refresh.json()
    assert rotated["deviceToken"] != token

    assert (await client.post("/pair/refresh", json={"deviceToken": token})).status == 401
    assert (await client.post("/pair/refresh", json={})).status == 401

    header_style = await client.post("/pair/refresh", headers={"Authorization": f"Bearer {rotated['deviceToken']}"})
    assert header_style.status == 200


async def test_websocket_rejects_unknown_tokens(client):
    response = await client.get("/link/device", headers={"Authorization": "Bearer dt_nope"})
    assert response.status == 401
    response = await client.get("/link/agent", headers={"Authorization": "Bearer as_nope"})
    assert response.status == 401
    response = await client.get("/link/agent")
    assert response.status == 401


# ── Device management ──────────────────────────────────────────────────────
#
# A phone lists and revokes its own pairings with its device token. It must not
# be able to see or touch anyone else's — otherwise any paired phone could
# unpair every other phone on the relay.


async def _paired_device(client, provisioned, name="iPhone"):
    claim = await client.post("/pair/claim", json={
        "pairCode": provisioned["code"]["code"],
        "deviceName": name,
        "model": "iPhone17,1",
        "appVersion": "1.0",
    })
    assert claim.status == 200, await claim.text()
    return (await claim.json())["deviceToken"]


async def test_devices_list_returns_own_devices(client, provisioned):
    token = await _paired_device(client, provisioned)
    response = await client.get("/devices", headers={"Authorization": f"Bearer {token}"})
    assert response.status == 200, await response.text()
    body = await response.json()
    assert body["ok"] is True
    assert len(body["devices"]) == 1
    assert body["devices"][0]["deviceId"] == body["currentDeviceId"]
    assert body["devices"][0]["name"] == "iPhone"
    assert body["devices"][0]["revoked"] is False


async def test_devices_list_needs_a_device_token(client, provisioned):
    assert (await client.get("/devices")).status == 401
    response = await client.get("/devices", headers={"Authorization": "Bearer nope"})
    assert response.status == 401


async def test_devices_revoke_removes_the_pairing(client, provisioned):
    # Two pairings for the same computer, which is the real case: the new phone
    # unpairs the old one. Revoking with the doomed device's own token would
    # invalidate that token, leaving nothing to verify with.
    old_token = await _paired_device(client, provisioned, "old phone")
    fresh_code = client.app["store"].mint_pair_code(
        provisioned["agent"]["agentId"], ttl_ms=60_000,
    )
    new_token = await _paired_device(client, {"code": fresh_code}, "new phone")

    listed = await (await client.get("/devices", headers={"Authorization": f"Bearer {new_token}"})).json()
    assert len(listed["devices"]) == 2
    doomed = next(d for d in listed["devices"] if d["name"] == "old phone")

    response = await client.post(
        "/devices/revoke",
        json={"deviceId": doomed["deviceId"]},
        headers={"Authorization": f"Bearer {new_token}"},
    )
    assert response.status == 200, await response.text()

    after = await (await client.get("/devices", headers={"Authorization": f"Bearer {new_token}"})).json()
    assert [d["name"] for d in after["devices"]] == ["new phone"]

    # And the revoked token stops working, which is the point of revoking.
    stale = await client.get("/devices", headers={"Authorization": f"Bearer {old_token}"})
    assert stale.status == 401


async def test_devices_revoke_refuses_another_agents_device(client, store, provisioned):
    # A second account with its own agent and device.
    other_account = store.create_account("someone else")
    other_agent = store.register_agent(other_account["accountId"], "their mac")
    other_code = store.mint_pair_code(other_agent["agentId"], ttl_ms=60_000)
    other_token = await _paired_device(client, {"code": other_code}, "their phone")

    mine = await _paired_device(client, provisioned, "my phone")
    listed = await (await client.get("/devices", headers={"Authorization": f"Bearer {mine}"})).json()
    mine_id = listed["devices"][0]["deviceId"]

    # Their token must not be able to revoke mine.
    response = await client.post(
        "/devices/revoke",
        json={"deviceId": mine_id},
        headers={"Authorization": f"Bearer {other_token}"},
    )
    assert response.status == 403

    # And my device is still there.
    still = await (await client.get("/devices", headers={"Authorization": f"Bearer {mine}"})).json()
    assert len(still["devices"]) == 1


async def test_devices_revoke_rejects_an_unknown_id(client, provisioned):
    token = await _paired_device(client, provisioned)
    response = await client.post(
        "/devices/revoke",
        json={"deviceId": "dev_nope"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status == 404
