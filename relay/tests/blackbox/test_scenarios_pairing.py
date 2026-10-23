"""功能场景：用户实际走过的路径，跨多个端点串起来。

这些用例回答的是"整条链路还通不通"，断言仍然只用外部可观察结果：
HTTP 响应、帧序列、关闭码、设备列表。
"""

from __future__ import annotations

from . import support


async def test_invite_enroll_pair_and_talk_over_websockets(
        client: support.Client, relay) -> None:
    """邀请码登记 → 铸码 → 配对 → 两条 WS → 帧双向转发。

    这条路径就是新用户接入时走的全部步骤；管理面只出邀请码，其余全走协议。
    """
    invite = relay.admin("invite-mint", "--ttl-seconds", "600", "--note", "blackbox-e2e")
    enrolled = await client.post("/agents/enroll",
                                 json_body={"inviteCode": invite["code"], "name": "BLACKBOX-e2e-mac"})
    assert enrolled.status == 200, enrolled.text
    identity = enrolled.json()
    tenant = support.Tenant(account_id=identity["accountId"], agent_id=identity["agentId"],
                            agent_secret=identity["agentSecret"], name=identity["agentName"])

    minted = await support.mint_pair_code(client, tenant)
    claimed = await support.claim_code(client, minted["code"], name="BLACKBOX-e2e-phone")
    assert claimed.status == 200, claimed.text
    device = support.Device(device_id=claimed.json()["deviceId"],
                            device_token=claimed.json()["deviceToken"],
                            account_id=tenant.account_id, agent_id=tenant.agent_id,
                            reused=False)

    agent_ws = await client.ws(support.agent_socket_path(tenant), token=tenant.agent_token)
    device_ws = await client.ws(support.device_socket_path(device), token=device.token)
    try:
        assert (await support.read_frame(device_ws))["info"]["online"] is True
        assert (await support.read_frame(agent_ws))["t"] == "deviceAttach"

        await device_ws.send_str('{"t":"req","id":"e2e-1","method":"session/list"}')
        forwarded = await support.read_frame(agent_ws, what="转发到电脑的 req")
        assert forwarded["deviceId"] == device.device_id

        # 回程帧要带 deviceId（一条 agent socket 复用给多台设备，靠它寻址）；
        # 中转在交给设备之前会把它摘掉。
        await agent_ws.send_str(
            '{"t":"res","id":"e2e-1","ok":true,"value":{"sessions":[]},'
            f'"deviceId":"{device.device_id}"}}')
        reply = await support.read_frame(device_ws, what="回到手机的 res")
        assert reply["id"] == "e2e-1"
        assert reply["value"] == {"sessions": []}
        assert "deviceId" not in reply
    finally:
        await device_ws.close()
        await agent_ws.close()


async def test_revoking_a_live_device_closes_its_socket_and_tells_the_agent(
        client: support.Client, tenant: support.Tenant) -> None:
    """在线的设备被撤销：socket 收到 1001 关闭，电脑收到 ``reason="revoked"``。"""
    keeper = await support.pair_device(client, tenant, name="BLACKBOX-keeper")
    doomed = await support.pair_device(client, tenant, name="BLACKBOX-doomed")

    agent_ws = await client.ws(support.agent_socket_path(tenant), token=tenant.agent_token)
    device_ws = await client.ws(support.device_socket_path(doomed), token=doomed.token)
    try:
        assert (await support.read_frame(device_ws))["t"] == "hostStatus"
        assert (await support.read_frame(agent_ws))["t"] == "deviceAttach"

        revoked = await client.post("/devices/revoke", json_body={"deviceId": doomed.device_id},
                                    token=keeper.token)
        assert revoked.status == 200, revoked.text

        assert await support.wait_close_code(device_ws) == 1001

        detach = await support.read_frame(agent_ws, what="撤销后的 deviceDetach")
        assert detach["t"] == "deviceDetach"
        assert detach["deviceId"] == doomed.device_id
        assert detach["reason"] == "revoked"

        status = await support.ws_handshake_status(
            client, support.device_socket_path(doomed), token=doomed.token)
        assert status == 401
    finally:
        await device_ws.close()
        await agent_ws.close()


async def test_two_devices_of_one_account_can_be_online_together(
        client: support.Client, tenant: support.Tenant) -> None:
    """同一账户的两台设备（手机 + Web）同时在线，电脑各收到一条 ``deviceAttach``。"""
    phone = await support.pair_device(client, tenant, name="BLACKBOX-phone")
    web = await support.pair_device(client, tenant, name="BLACKBOX-web")

    agent_ws = await client.ws(support.agent_socket_path(tenant), token=tenant.agent_token)
    reader = support.FrameReader(agent_ws)
    phone_ws = await client.ws(support.device_socket_path(phone), token=phone.token)
    web_ws = await client.ws(support.device_socket_path(web), token=web.token)
    try:
        assert (await support.read_frame(phone_ws))["info"]["online"] is True
        assert (await support.read_frame(web_ws))["info"]["online"] is True

        seen = set()
        for _ in range(2):
            attach = await reader.until(support.is_frame_kind("deviceAttach"))
            assert attach["t"] == "deviceAttach"
            seen.add(attach["deviceId"])
        assert seen == {phone.device_id, web.device_id}

        listed = await client.get("/devices", token=phone.token)
        assert listed.status == 200, listed.text
        body = listed.json()
        assert body["pairedDevices"] == 2
        assert {row["deviceId"] for row in body["devices"]} == {phone.device_id, web.device_id}
    finally:
        await phone_ws.close()
        await web_ws.close()
        await agent_ws.close()
