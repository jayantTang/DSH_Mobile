"""设备子协议认证（``dsh.device.<token>``）与能力广告。

浏览器无法在 WebSocket 握手时设置 ``Authorization``，所以设备接入额外接受
``Sec-WebSocket-Protocol: dsh.device.<deviceToken>`` 形式凭据；实现回显被接受的
子协议。已有的头认证保持优先：头有效、子协议乱填时仍按头认证。

``/healthz`` 的 ``capabilities`` 必须带 ``device-subprotocol-auth``——老客户端据此
决定能不能用子协议（读不到就当"中转需升级"，不静默降级）。
"""

from __future__ import annotations

from . import support

#: 与 ``api.DEVICE_SUBPROTOCOL_PREFIX`` 一致的公开前缀。
SUBPROTOCOL_PREFIX = "dsh.device."


async def test_a_device_authenticates_with_the_subprotocol(
        client: support.Client, device: support.Device) -> None:
    offered = f"{SUBPROTOCOL_PREFIX}{device.token}"
    ws = await client.ws(support.device_socket_path(device), subprotocols=[offered])
    try:
        assert ws.protocol == offered, "服务端应回显被接受的子协议"
        first = await support.read_frame(ws, what="子协议认证后的首帧")
        assert first["t"] == "hostStatus"
        assert first["info"]["agentId"] == device.agent_id
    finally:
        await ws.close()


async def test_a_bad_subprotocol_token_is_refused(client: support.Client,
                                                   device: support.Device) -> None:
    status = await support.ws_handshake_status(
        client, support.device_socket_path(device),
        subprotocols=[f"{SUBPROTOCOL_PREFIX}dt_not-a-real-token"])
    assert status == 401


async def test_the_authorization_header_wins_over_the_subprotocol(
        client: support.Client, device: support.Device) -> None:
    """头有效、子协议乱填：按头认证，不因为多带的一行就拒绝。"""
    ws = await client.ws(support.device_socket_path(device), token=device.token,
                         subprotocols=[f"{SUBPROTOCOL_PREFIX}dt_not-a-real-token"])
    try:
        assert (await support.read_frame(ws))["t"] == "hostStatus"
    finally:
        await ws.close()


async def test_subprotocol_auth_still_checks_the_agent_id(
        client: support.Client, device: support.Device) -> None:
    offered = f"{SUBPROTOCOL_PREFIX}{device.token}"
    status = await support.ws_handshake_status(
        client, "/link/device?agentId=agt_somebody-else", subprotocols=[offered])
    assert status == 403


async def test_healthz_advertises_the_subprotocol_capability(
        client: support.Client) -> None:
    response = await client.get("/healthz")
    assert response.status == 200, response.text
    capabilities = response.json()["capabilities"]
    assert "device-subprotocol-auth" in capabilities
