"""``/internal/*`` 契约：只认环回来源的两个服务间端点。

* ``POST /internal/tokens/resolve``：信件服务拿设备令牌换 ``deviceId/accountId/expiresAt``；
  未知 / 撤销 / 过期一律 404，不给调用方区分「已撤销」与「不存在」。
* ``POST /internal/account-state/touch``：已读落库后借中转给同账号在线设备扇一帧
  ``accountState``；不写任何状态。

环回判定用的是 **socket peer**（``api.is_loopback``），不是请求头；本机黑盒客户端
从 ``127.0.0.1`` 发起，所以这里只能覆盖「环回成功路径」。非环回 404 需要独立网络
命名空间或真实前置，未覆盖（见 README）。
"""

from __future__ import annotations

from . import support


# ── /internal/tokens/resolve ────────────────────────────────────────────────


async def test_token_resolve_returns_the_device_ownership(client: support.Client,
                                                          device: support.Device) -> None:
    response = await client.post("/internal/tokens/resolve",
                                 json_body={"token": device.token})
    assert response.status == 200, response.text
    body = response.json()
    assert body["deviceId"] == device.device_id
    assert body["accountId"] == device.account_id
    assert isinstance(body["expiresAt"], int) and body["expiresAt"] > 0
    assert set(body) == {"deviceId", "accountId", "expiresAt"}


async def test_token_resolve_treats_revoked_and_unknown_alike(
        client: support.Client, tenant: support.Tenant) -> None:
    keeper = await support.pair_device(client, tenant, name="BLACKBOX-keeper")
    doomed = await support.pair_device(client, tenant, name="BLACKBOX-doomed")
    revoked = await client.post("/devices/revoke", json_body={"deviceId": doomed.device_id},
                                token=keeper.token)
    assert revoked.status == 200, revoked.text

    gone = await client.post("/internal/tokens/resolve", json_body={"token": doomed.token})
    support.assert_error_envelope(gone, status=404, code="internal/not-found")

    unknown = await client.post("/internal/tokens/resolve",
                                json_body={"token": "dt_never-issued"})
    support.assert_error_envelope(unknown, status=404, code="internal/not-found")
    assert gone.text == unknown.text, "撤销与不存在必须逐字节相同"


async def test_token_resolve_rejects_a_malformed_body(client: support.Client) -> None:
    for body in ({}, {"token": ""}, {"token": 5}, {"token": None}):
        response = await client.post("/internal/tokens/resolve", json_body=body)
        support.assert_error_envelope(response, status=400, code="internal/bad-request")

    # 纯空白不是"缺字段"：它被当成一个令牌去查，结果与任何未知令牌相同（404）。
    whitespace = await client.post("/internal/tokens/resolve", json_body={"token": "  "})
    support.assert_error_envelope(whitespace, status=404, code="internal/not-found")


# ── /internal/account-state/touch ───────────────────────────────────────────


async def test_account_state_touch_notifies_the_accounts_online_device(
        client: support.Client, tenant: support.Tenant, device: support.Device) -> None:
    device_ws = await client.ws(support.device_socket_path(device), token=device.token)
    try:
        assert (await support.read_frame(device_ws))["t"] == "hostStatus"

        response = await client.post("/internal/account-state/touch",
                                     json_body={"accountId": device.account_id,
                                                "keys": ["feedback"]})
        assert response.status == 200, response.text
        assert response.json() == {"ok": True, "notified": 1}
        frame = await support.read_frame(device_ws, what="accountState")
        assert frame == {"t": "accountState", "keys": ["feedback"]}
    finally:
        await device_ws.close()


async def test_account_state_touch_defaults_to_the_feedback_key(
        client: support.Client, device: support.Device) -> None:
    device_ws = await client.ws(support.device_socket_path(device), token=device.token)
    try:
        assert (await support.read_frame(device_ws))["t"] == "hostStatus"
        response = await client.post("/internal/account-state/touch",
                                     json_body={"accountId": device.account_id})
        assert response.status == 200, response.text
        assert response.json()["notified"] == 1
        frame = await support.read_frame(device_ws, what="accountState")
        assert frame["t"] == "accountState"
        assert frame["keys"] == ["feedback"], "缺 keys 时按 feedback 通知"
    finally:
        await device_ws.close()


async def test_account_state_touch_with_no_online_device_notifies_nobody(
        client: support.Client, tenant: support.Tenant, device: support.Device) -> None:
    response = await client.post("/internal/account-state/touch",
                                 json_body={"accountId": device.account_id,
                                            "keys": ["feedback"]})
    assert response.status == 200, response.text
    assert response.json() == {"ok": True, "notified": 0}

    unknown = await client.post("/internal/account-state/touch",
                                json_body={"accountId": "acc_does-not-exist"})
    assert unknown.status == 200
    assert unknown.json()["notified"] == 0


async def test_account_state_touch_rejects_a_malformed_body(client: support.Client) -> None:
    response = await client.post("/internal/account-state/touch", json_body={})
    support.assert_error_envelope(response, status=400, code="internal/bad-request")

    bad_type = await client.post("/internal/account-state/touch",
                                 json_body={"accountId": 5})
    support.assert_error_envelope(bad_type, status=400, code="internal/bad-request")
