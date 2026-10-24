"""WebSocket 契约：鉴权、首帧、错误帧、关闭码、重连替换与设备上限。

帧类型与关闭码依据现有实现（``hub.py`` 的 ``CLOSE_*``、``dlp.py`` 的帧类型），
用例只通过帧序列观察，不读中转内存。
"""

from __future__ import annotations

from . import support

#: 设备上限拒连的关闭码（``hub.CLOSE_DEVICE_LIMIT``）。
CLOSE_DEVICE_LIMIT = 4012


# ── 鉴权 ────────────────────────────────────────────────────────────────────


async def test_the_agent_socket_without_a_token_is_refused(client: support.Client,
                                                           tenant: support.Tenant) -> None:
    status = await support.ws_handshake_status(client, support.agent_socket_path(tenant))
    assert status == 401


async def test_the_device_socket_without_a_token_is_refused(client: support.Client,
                                                            device: support.Device) -> None:
    status = await support.ws_handshake_status(client, support.device_socket_path(device))
    assert status == 401


async def test_a_revoked_device_token_cannot_open_a_socket(
        client: support.Client, tenant: support.Tenant) -> None:
    keeper = await support.pair_device(client, tenant, name="BLACKBOX-keeper")
    doomed = await support.pair_device(client, tenant, name="BLACKBOX-doomed")
    revoked = await client.post("/devices/revoke", json_body={"deviceId": doomed.device_id},
                                token=keeper.token)
    assert revoked.status == 200, revoked.text

    status = await support.ws_handshake_status(client, support.device_socket_path(doomed),
                                              token=doomed.token)
    assert status == 401


# ── 首帧与转发 ──────────────────────────────────────────────────────────────


async def test_a_device_learns_the_host_is_online_and_the_agent_learns_the_device(
        client: support.Client, tenant: support.Tenant, device: support.Device) -> None:
    """设备首帧是 ``hostStatus``；电脑收到的是 ``deviceAttach``（以现有实现为准）。"""
    agent_ws = await client.ws(support.agent_socket_path(tenant), token=tenant.agent_token)
    device_ws = await client.ws(support.device_socket_path(device), token=device.token)
    try:
        host = await support.read_frame(device_ws, what="设备首帧")
        assert host["t"] == "hostStatus", host
        assert host["info"]["online"] is True
        assert host["info"]["agentId"] == tenant.agent_id
        assert host["info"]["name"] == tenant.name

        attach = await support.read_frame(agent_ws, what="电脑首帧")
        assert attach["t"] == "deviceAttach", attach
        assert attach["deviceId"] == device.device_id
        assert attach["device"]["name"] == "BLACKBOX-iPhone"

        await device_ws.send_str('{"t":"ping","ts":41}')
        pong = await support.read_frame(device_ws, what="pong")
        assert pong == {"t": "pong", "ts": 41}

        await device_ws.close()
        detach = await support.read_frame(agent_ws, what="deviceDetach")
        assert detach["t"] == "deviceDetach", detach
        assert detach["deviceId"] == device.device_id
        assert detach["reason"] == "socket closed"
    finally:
        await device_ws.close()
        await agent_ws.close()


async def test_a_device_without_the_connector_is_told_the_host_is_offline(
        client: support.Client, device: support.Device) -> None:
    device_ws = await client.ws(support.device_socket_path(device), token=device.token)
    try:
        host = await support.read_frame(device_ws, what="设备首帧")
        assert host["t"] == "hostStatus", host
        assert host["info"]["online"] is False
        assert host["info"]["agentId"] == device.agent_id
    finally:
        await device_ws.close()


async def test_a_device_request_is_forwarded_and_the_reply_comes_back(
        client: support.Client, tenant: support.Tenant, device: support.Device) -> None:
    """设备 → 电脑的帧被盖上 ``deviceId``；回程帧不带这个中转内部键。"""
    agent_ws = await client.ws(support.agent_socket_path(tenant), token=tenant.agent_token)
    device_ws = await client.ws(support.device_socket_path(device), token=device.token)
    try:
        assert (await support.read_frame(device_ws))["t"] == "hostStatus"
        assert (await support.read_frame(agent_ws))["t"] == "deviceAttach"

        await device_ws.send_str('{"t":"req","id":"r1","method":"session/list"}')
        forwarded = await support.read_frame(agent_ws, what="转发的 req")
        assert forwarded["t"] == "req"
        assert forwarded["id"] == "r1"
        assert forwarded["method"] == "session/list"
        assert forwarded["deviceId"] == device.device_id

        # 回程必须带 deviceId：一条 agent socket 复用给多台设备，中转靠它寻址
        # （连接器的 resultFrame 也是这么封的）。
        await agent_ws.send_str(
            '{"t":"res","id":"r1","ok":true,"value":{"sessions":[]},'
            f'"deviceId":"{device.device_id}"}}')
        reply = await support.read_frame(device_ws, what="回程 res")
        assert reply == {"t": "res", "id": "r1", "ok": True, "value": {"sessions": []}}
        assert "deviceId" not in reply
    finally:
        await device_ws.close()
        await agent_ws.close()


async def test_a_malformed_device_frame_gets_an_error_frame(
        client: support.Client, device: support.Device) -> None:
    """坏帧有错误码可依，且不会把 socket 弄断；二进制帧单独一个码。"""
    device_ws = await client.ws(support.device_socket_path(device), token=device.token)
    try:
        assert (await support.read_frame(device_ws))["t"] == "hostStatus"

        await device_ws.send_str("this is not json")
        bad_json = await support.read_frame(device_ws, what="坏 JSON 的错误帧")
        assert bad_json["t"] == "error"
        assert bad_json["code"] == "protocol/bad-frame"

        await device_ws.send_str('{"t":"req"}')
        missing_id = await support.read_frame(device_ws, what="缺 id 的错误帧")
        assert missing_id["t"] == "error"
        assert missing_id["code"] == "protocol/bad-frame"
        assert "id" in missing_id["message"]

        await device_ws.send_bytes(b"\x00\x01")
        binary = await support.read_frame(device_ws, what="二进制帧的错误帧")
        assert binary["t"] == "error"
        assert binary["code"] == "protocol/binary-unsupported"

        await device_ws.send_str('{"t":"ping","ts":9}')
        assert (await support.read_frame(device_ws, what="pong"))["t"] == "pong"
    finally:
        await device_ws.close()


async def test_an_unknown_frame_type_is_forwarded_verbatim(
        client: support.Client, tenant: support.Tenant, device: support.Device) -> None:
    """未知 ``t`` 不是错误：DLP 的 ``t`` 向前兼容，中转按原样转发。

    ``protocol/bad-frame`` 只留给结构坏掉的帧（上一条用例）；把"不认识的类型"
    也判成错误会让未来新增的帧在旧中转上直接失效。
    """
    agent_ws = await client.ws(support.agent_socket_path(tenant), token=tenant.agent_token)
    device_ws = await client.ws(support.device_socket_path(device), token=device.token)
    try:
        assert (await support.read_frame(device_ws))["t"] == "hostStatus"
        assert (await support.read_frame(agent_ws))["t"] == "deviceAttach"

        await device_ws.send_str('{"t":"futureFrame","id":"f1","extra":{"a":1}}')
        forwarded = await support.read_frame(agent_ws, what="未知类型的帧")
        assert forwarded["t"] == "futureFrame"
        assert forwarded["extra"] == {"a": 1}
        assert forwarded["deviceId"] == device.device_id
    finally:
        await device_ws.close()
        await agent_ws.close()


async def test_reconnecting_a_device_replaces_the_previous_socket(
        client: support.Client, tenant: support.Tenant, device: support.Device) -> None:
    """同一台设备再开一条：新 socket 接管，旧 socket 关闭时不再通知电脑。"""
    agent_ws = await client.ws(support.agent_socket_path(tenant), token=tenant.agent_token)
    reader = support.FrameReader(agent_ws)
    first = await client.ws(support.device_socket_path(device), token=device.token)
    try:
        assert (await support.read_frame(first))["t"] == "hostStatus"
        assert (await reader.until(support.is_frame_kind("deviceAttach")))["t"] == "deviceAttach"

        second = await client.ws(support.device_socket_path(device), token=device.token)
        try:
            assert (await support.read_frame(second))["t"] == "hostStatus"
            replaced = await reader.until(support.is_frame_kind("deviceAttach"))
            assert replaced["deviceId"] == device.device_id

            await second.send_str('{"t":"ping","ts":2}')
            assert (await support.read_frame(second, what="新 socket 的 pong"))["ts"] == 2

            # 旧 socket 关闭：它已经不是登记项，电脑不应收到 deviceDetach。
            await first.close()
            await reader.quiet(seconds=0.8)
            assert not any(support.is_frame_kind("deviceDetach")(frame)
                           for frame in reader.buffer), reader.buffer
        finally:
            await second.close()
        detach = await reader.until(support.is_frame_kind("deviceDetach"))
        assert detach["deviceId"] == device.device_id
    finally:
        await first.close()
        await agent_ws.close()


# ── 设备上限 ────────────────────────────────────────────────────────────────


async def test_the_device_limit_is_an_error_frame_then_close_4012(
        device_limit_relay) -> None:
    """满额拒连必须给出 ``limit/devices`` 帧和 4012，而不是一次裸断。"""
    async with support.Client(device_limit_relay.base) as client:
        tenant = await support.enroll(client, device_limit_relay.admin,
                                      name="BLACKBOX-limited-mac")
        first = await support.pair_device(client, tenant, name="BLACKBOX-first")
        second = await support.pair_device(client, tenant, name="BLACKBOX-second")

        agent_ws = await client.ws(support.agent_socket_path(tenant), token=tenant.agent_token)
        first_ws = await client.ws(support.device_socket_path(first), token=first.token)
        try:
            assert (await support.read_frame(first_ws))["t"] == "hostStatus"
            assert (await support.read_frame(agent_ws))["t"] == "deviceAttach"

            refused = await client.ws(support.device_socket_path(second), token=second.token)
            refusal = await support.read_frame(refused, what="拒连帧")
            assert refusal["t"] == "error", refusal
            assert refusal["code"] == "limit/devices"
            assert refusal["fatal"] is True
            assert refusal["details"]["maxDevicesPerAgent"] == 1
            assert await support.read_close(refused) == CLOSE_DEVICE_LIMIT
        finally:
            await first_ws.close()
            await agent_ws.close()
