"""HTTP 契约：方法、路径、鉴权、状态码、错误码与 JSON 形状。

这些断言是"两版实现必须逐字一致"的部分，依据是现有实现的实际行为
（读代码得到的值，不是猜的）：错误码见 ``relay/api.py`` 的 ``json_error`` 调用点。
"""

from __future__ import annotations

import time

import pytest

from . import support

#: 受保护端点：无 token 时必须是 401，并且带错误信封。
#: 错误码差异是契约的一部分——``/pair/refresh`` 区分"没给令牌"与"令牌无效"。
PROTECTED_ENDPOINTS = [
    ("GET", "/devices", "auth/invalid-token"),
    ("POST", "/devices/revoke", "auth/invalid-token"),
    ("GET", "/account/state", "auth/invalid-token"),
    ("PUT", "/account/state", "auth/invalid-token"),
    ("POST", "/pair/refresh", "auth/missing-token"),
    ("POST", "/pair/code", "auth/invalid-agent"),
    ("PUT", "/files/up?sessionId=s&name=n&bid=b&bytes=1", "auth/invalid-token"),
    ("GET", "/files/down?scopeId=s&path=p", "auth/invalid-token"),
]


# ── 健康检查与运维面 ────────────────────────────────────────────────────────


async def test_healthz_reports_ok_and_the_protocol_version(client: support.Client) -> None:
    response = await client.get("/healthz")
    assert response.status == 200, response.text
    body = response.json()
    assert body["ok"] is True
    assert body["version"] == 1, "DLP v1 的协议版本号是 1"
    assert isinstance(body.get("capabilities"), list)


async def test_stats_answers_a_loopback_caller(client: support.Client) -> None:
    response = await client.get("/stats")
    assert response.status == 200, response.text
    body = response.json()
    assert body["ok"] is True
    for key in ("limits", "load", "traffic", "deviceRecords", "today"):
        assert key in body, f"/stats 缺字段 {key}"


async def test_an_unknown_path_answers_404(client: support.Client) -> None:
    response = await client.get("/no-such-route")
    assert response.status == 404


# ── 鉴权 ────────────────────────────────────────────────────────────────────


@pytest.mark.parametrize("method,path,code", PROTECTED_ENDPOINTS,
                         ids=[f"{m} {p}" for m, p, _ in PROTECTED_ENDPOINTS])
async def test_a_protected_endpoint_without_a_token_answers_401(
        client: support.Client, method: str, path: str, code: str) -> None:
    body = {} if method in ("POST", "PUT") else None
    response = await client.request(method, path, json_body=body)
    support.assert_error_envelope(response, status=401, code=code)


async def test_the_error_envelope_has_the_documented_shape(client: support.Client) -> None:
    """错误信封只有一种形状；``message`` 必须是一句能给人看的话。"""
    response = await client.post("/pair/claim", json_body={"pairCode": ""})
    payload = support.assert_error_envelope(response, status=400, code="pair/bad-request")
    # 信封本身只承诺 {"ok": false, "error": {"code", "message"}}；多出来的顶层字段
    # 不算违约（Go 版若要加 requestId 之类，不该被这条用例挡住）。
    assert {"ok", "error"} <= set(payload)
    assert set(payload["error"]) <= {"code", "message", "details"}


# ── 配对 ────────────────────────────────────────────────────────────────────


async def test_pair_claim_returns_a_device_token(client: support.Client,
                                                 tenant: support.Tenant) -> None:
    minted = await support.mint_pair_code(client, tenant)
    response = await support.claim_code(client, minted["code"], name="BLACKBOX-iPhone")

    assert response.status == 200, response.text
    body = response.json()
    assert body["ok"] is True
    assert body["agentId"] == tenant.agent_id
    assert body["accountId"] == tenant.account_id
    assert isinstance(body["deviceId"], str) and body["deviceId"]
    assert isinstance(body["deviceToken"], str) and body["deviceToken"]
    assert body["reused"] is False
    assert body["expiresAt"] > int(time.time() * 1000)


async def test_an_unknown_pair_code_answers_404_pair_invalid_code(
        client: support.Client) -> None:
    response = await support.claim_code(client, "ZZZZ-ZZZZ")
    support.assert_error_envelope(response, status=404, code="pair/invalid-code")


async def test_an_expired_pair_code_answers_404_pair_expired_code(
        client: support.Client, relay, tenant: support.Tenant) -> None:
    # 只有管理面铸得出"一出生就过期"的码（HTTP 的 ttlMs 必须为正数）。
    minted = relay.admin("code-mint", "--agent", tenant.agent_id, "--ttl-seconds", "0")
    response = await support.claim_code(client, minted["code"])
    support.assert_error_envelope(response, status=404, code="pair/expired-code")


async def test_a_revoked_pair_code_answers_404_pair_revoked_code(
        client: support.Client, relay, tenant: support.Tenant) -> None:
    minted = relay.admin("code-mint", "--agent", tenant.agent_id, "--ttl-seconds", "600")
    regenerated = await client.post("/pair/code/regenerate", json_body={},
                                    token=tenant.agent_token)
    assert regenerated.status == 200, regenerated.text
    assert regenerated.json()["revoked"] >= 1

    response = await support.claim_code(client, minted["code"])
    support.assert_error_envelope(response, status=404, code="pair/revoked-code")


async def test_a_persistent_pair_code_can_be_claimed_again(
        client: support.Client, tenant: support.Tenant) -> None:
    """持久码不是一次性的：两枚令牌对应两台设备（App 重装、加一台 Web 都走这里）。"""
    minted = await support.mint_pair_code(client, tenant)
    assert minted["persistent"] is True
    assert minted["expiresAt"] is None

    first = await support.claim_code(client, minted["code"], name="BLACKBOX-one")
    second = await support.claim_code(client, minted["code"], name="BLACKBOX-two")
    assert first.status == 200 and second.status == 200
    assert first.json()["deviceId"] != second.json()["deviceId"]


async def test_a_device_key_reuses_the_same_device_row(client: support.Client,
                                                       tenant: support.Tenant) -> None:
    """带同一 ``deviceKey`` 回来是"同一台设备换了令牌"，不占新名额。"""
    first = await support.pair_device(client, tenant, name="BLACKBOX-one",
                                      device_key="blackbox-key-0001")
    second = await support.pair_device(client, tenant, name="BLACKBOX-one",
                                       device_key="blackbox-key-0001")
    assert second.device_id == first.device_id
    assert second.reused is True
    assert second.device_token != first.device_token


async def test_pair_refresh_rotates_the_token(client: support.Client,
                                              device: support.Device) -> None:
    response = await client.post("/pair/refresh", json_body={}, token=device.token)
    assert response.status == 200, response.text
    body = response.json()
    assert body["ok"] is True
    assert body["deviceId"] == device.device_id
    assert body["deviceToken"] != device.token

    stale = await client.get("/devices", token=device.token)
    support.assert_error_envelope(stale, status=401, code="auth/invalid-token")

    fresh = await client.get("/devices", token=body["deviceToken"])
    assert fresh.status == 200, fresh.text


async def test_pair_refresh_with_an_invalid_token_answers_401(
        client: support.Client) -> None:
    response = await client.post("/pair/refresh", json_body={}, token="dt_not-a-real-token")
    support.assert_error_envelope(response, status=401, code="auth/invalid-token")


async def test_pair_code_needs_an_agent_token(client: support.Client) -> None:
    response = await client.post("/pair/code", json_body={})
    support.assert_error_envelope(response, status=401, code="auth/invalid-agent")


async def test_pair_code_returns_a_persistent_code_and_the_paired_count(
        client: support.Client, tenant: support.Tenant) -> None:
    response = await client.post("/pair/code", json_body={}, token=tenant.agent_token)
    assert response.status == 200, response.text
    body = response.json()
    assert body["ok"] is True
    assert body["agentId"] == tenant.agent_id
    assert body["persistent"] is True and body["expiresAt"] is None
    assert body["maxPairedDevices"] == 8
    assert body["pairedDevices"] == 0


# ── 设备列表与撤销 ──────────────────────────────────────────────────────────


async def test_devices_list_reports_the_calling_device(client: support.Client,
                                                       device: support.Device) -> None:
    response = await client.get("/devices", token=device.token)
    assert response.status == 200, response.text
    body = response.json()
    assert body["ok"] is True
    assert body["currentDeviceId"] == device.device_id
    assert body["maxPairedDevices"] == 8
    assert body["pairedDevices"] == 1
    rows = {row["deviceId"]: row for row in body["devices"]}
    assert rows[device.device_id]["revoked"] is False
    assert rows[device.device_id]["name"] == "BLACKBOX-iPhone"


async def test_revoking_a_device_makes_its_token_useless(client: support.Client,
                                                         tenant: support.Tenant) -> None:
    keeper = await support.pair_device(client, tenant, name="BLACKBOX-keeper")
    doomed = await support.pair_device(client, tenant, name="BLACKBOX-doomed")

    response = await client.post("/devices/revoke", json_body={"deviceId": doomed.device_id},
                                 token=keeper.token)
    assert response.status == 200, response.text
    assert response.json() == {"ok": True, "deviceId": doomed.device_id}

    stale = await client.get("/devices", token=doomed.token)
    support.assert_error_envelope(stale, status=401, code="auth/invalid-token")


async def test_revoking_an_unknown_device_answers_404(client: support.Client,
                                                      device: support.Device) -> None:
    response = await client.post("/devices/revoke", json_body={"deviceId": "dev_does-not-exist"},
                                 token=device.token)
    support.assert_error_envelope(response, status=404, code="request/unknown-device")


async def test_revoking_another_agents_device_is_forbidden(client: support.Client,
                                                           relay, device: support.Device,
                                                           tenant: support.Tenant) -> None:
    other = await support.enroll(client, relay.admin, name="BLACKBOX-other")
    other_device = await support.pair_device(client, other, name="BLACKBOX-other-phone")

    response = await client.post("/devices/revoke", json_body={"deviceId": device.device_id},
                                 token=other_device.token)
    support.assert_error_envelope(response, status=403, code="auth/agent-mismatch")


# ── 账户状态 ────────────────────────────────────────────────────────────────


async def test_account_state_round_trips(client: support.Client,
                                         device: support.Device) -> None:
    stamp = int(time.time() * 1000)
    written = await client.put("/account/state", token=device.token, json_body={"entries": [
        {"key": "alertPrefs", "value": {"turnEnd": False, "attention": True}, "updatedAt": stamp},
        {"key": "lastSession", "value": "session-1", "updatedAt": stamp},
    ]})
    assert written.status == 200, written.text
    body = written.json()
    assert body["applied"] == ["alertPrefs", "lastSession"]
    assert body["entries"]["alertPrefs"]["updatedAt"] == stamp

    read = await client.get("/account/state", token=device.token)
    assert read.status == 200, read.text
    entries = read.json()["entries"]
    assert entries["alertPrefs"]["value"] == {"turnEnd": False, "attention": True}
    assert entries["lastSession"]["value"] == "session-1"
    assert entries["alertPrefs"]["updatedByDeviceId"] == device.device_id

    filtered = await client.get("/account/state?keys=alertPrefs", token=device.token)
    assert filtered.status == 200
    assert set(filtered.json()["entries"]) == {"alertPrefs"}


async def test_account_state_rejects_an_empty_entry_list(client: support.Client,
                                                         device: support.Device) -> None:
    response = await client.put("/account/state", token=device.token,
                                json_body={"entries": []})
    support.assert_error_envelope(response, status=400, code="account-state/bad-request")


async def test_account_state_rejects_more_than_64_entries(client: support.Client,
                                                          device: support.Device) -> None:
    entries = [{"key": f"k{index}", "value": index, "updatedAt": 1000 + index}
               for index in range(65)]
    response = await client.put("/account/state", token=device.token,
                                json_body={"entries": entries})
    support.assert_error_envelope(response, status=400, code="account-state/bad-request")


async def test_a_single_entry_over_8kb_answers_413(client: support.Client,
                                                   device: support.Device) -> None:
    response = await client.put("/account/state", token=device.token, json_body={"entries": [
        {"key": "tooBig", "value": "x" * 9000, "updatedAt": int(time.time() * 1000)},
    ]})
    support.assert_error_envelope(response, status=413, code="account-state/too-large")


async def test_an_entry_needs_a_positive_integer_updated_at(client: support.Client,
                                                            device: support.Device) -> None:
    response = await client.put("/account/state", token=device.token, json_body={"entries": [
        {"key": "badStamp", "value": 1, "updatedAt": 0},
    ]})
    support.assert_error_envelope(response, status=400, code="account-state/bad-request")
