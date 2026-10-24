"""两道与"量"有关的契约：``/pair/claim`` 的失败预算与设备的每日流量额度。

配对限流是**按来源**的：同一来源连续认领失败 10 次后，第 11 次回 429；换一个来源
（这里用 ``X-Forwarded-For``，与线上 Caddy 的语义一致）就是另一个桶。

每日额度是**按设备**的：设备在 WS 上收到的字节计入 ``quota/device-daily``；超限时
先收到一帧 ``error``（带 ``details.limitBytes``），随后 socket 以 4011 关闭，而不是
静默断线。额度值由 ``--device-daily-mb`` 设定，本文件的进程用 0.25 MB（262144 字节），
数据量完全可控。
"""

from __future__ import annotations

import json

import pytest

from . import support
from .conftest import RelayProcess

#: 与 ``--device-daily-mb 0.25`` 对应的字节数。
QUOTA_LIMIT_BYTES = int(0.25 * 1024 * 1024)
#: ``/pair/claim`` 的失败预算（``api._CLAIM_FAILURES``）。
CLAIM_FAILURE_BUDGET = 10
#: 配额拒连的关闭码（``hub.CLOSE_QUOTA_EXCEEDED``）。
CLOSE_QUOTA_EXCEEDED = 4011


@pytest.fixture(scope="module")
def quota_relay(tmp_path_factory: pytest.TempPathFactory):
    """每设备每日 0.25 MB 的中转：配额用例专用，避免影响其它用例。"""
    instance = RelayProcess(tmp_path_factory.mktemp("blackbox-quota"),
                            extra_args=("--device-daily-mb", "0.25"),
                            label="quota")
    instance.start()
    try:
        instance.wait_ready()
        yield instance
    finally:
        instance.stop()


def claim(client: support.Client, code: str, *, name: str = "BLACKBOX-rate",
          headers: dict[str, str] | None = None) -> object:
    return client.post("/pair/claim",
                       json_body={"pairCode": code, "deviceName": name},
                       headers=headers)


# ── /pair/claim 限流 ────────────────────────────────────────────────────────


async def test_pair_claim_is_rate_limited_after_ten_failures(quota_relay) -> None:
    """同一来源失败 10 次后回 429；桶按来源分，换来源不受影响。

    用独立的 ``quota_relay`` 进程：会话级中转的库里已经攒了很多未使用的配对码，
    而未知码的 scrypt 校验会逐行验证，用例耗时会被前面的用例牵着走。
    """
    async with support.Client(quota_relay.base) as client:
        tenant = await support.enroll(client, quota_relay.admin,
                                      name="BLACKBOX-claim-limit")
        origin = {"X-Forwarded-For": "198.51.100.77"}
        for _ in range(CLAIM_FAILURE_BUDGET):
            response = await claim(client, "ZZZZ-ZZZZ", headers=origin)
            support.assert_error_envelope(response, status=404, code="pair/invalid-code")

        blocked = await claim(client, "ZZZZ-ZZZZ", headers=origin)
        support.assert_error_envelope(blocked, status=429, code="pair/rate-limited")

        # 被限的是来源桶，不是这个码：换一个来源用**合法的码**照常认领。
        minted = await support.mint_pair_code(client, tenant)
        other_origin = await claim(client, minted["code"], name="BLACKBOX-other-origin",
                                   headers={"X-Forwarded-For": "198.51.100.78"})
        assert other_origin.status == 200, other_origin.text

        # 同一个被限的来源带着合法码也进不来——限流检查发生在验证码之前。
        still_blocked = await claim(client, minted["code"], headers=origin)
        support.assert_error_envelope(still_blocked, status=429, code="pair/rate-limited")


# ── 每日额度 ────────────────────────────────────────────────────────────────


async def _open_pair(client: support.Client, tenant: support.Tenant,
                     device: support.Device):
    agent_ws = await client.ws(support.agent_socket_path(tenant), token=tenant.agent_token)
    device_ws = await client.ws(support.device_socket_path(device), token=device.token)
    assert (await support.read_frame(device_ws, what="设备首帧"))["t"] == "hostStatus"
    assert (await support.read_frame(agent_ws, what="deviceAttach"))["t"] == "deviceAttach"
    return agent_ws, device_ws


def delivery_frame(device: support.Device, *, marker: str, size: int) -> str:
    """一帧从电脑发往手机的业务帧，``value.text`` 撑到指定量级。"""
    return json.dumps({"t": "res", "id": marker, "deviceId": device.device_id,
                       "value": {"text": "x" * size}}, ensure_ascii=False)


async def test_the_daily_quota_answers_an_error_frame_then_closes_4011(
        quota_relay) -> None:
    async with support.Client(quota_relay.base) as client:
        tenant = await support.enroll(client, quota_relay.admin, name="BLACKBOX-quota-mac")
        device = await support.pair_device(client, tenant, name="BLACKBOX-quota-phone")
        agent_ws, device_ws = await _open_pair(client, tenant, device)
        try:
            # 额度内的帧照常送达。
            await agent_ws.send_str(delivery_frame(device, marker="under-quota", size=1000))
            delivered = await support.read_frame(device_ws, what="额度内的帧")
            assert delivered["id"] == "under-quota"

            # 再把额度撑爆：先 error 帧，再 4011。
            await agent_ws.send_str(delivery_frame(device, marker="over-quota", size=300_000))
            error = await support.read_frame(device_ws, what="配额错误帧")
            assert error["t"] == "error", error
            assert error["code"] == "quota/device-daily"
            assert error["details"]["limitBytes"] == QUOTA_LIMIT_BYTES
            assert error.get("fatal") is not True, "配额不是致命协议错误"
            assert await support.read_close(device_ws) == CLOSE_QUOTA_EXCEEDED

            detach = await support.read_frame(agent_ws, what="配额断开的 deviceDetach")
            assert detach["t"] == "deviceDetach"
            assert detach["deviceId"] == device.device_id
            assert detach["reason"] == "daily quota"
        finally:
            await device_ws.close()
            await agent_ws.close()


async def test_the_quota_is_per_device_not_per_account(quota_relay) -> None:
    """一台设备用光额度，同账户的另一台仍然能收帧。"""
    async with support.Client(quota_relay.base) as client:
        tenant = await support.enroll(client, quota_relay.admin, name="BLACKBOX-quota-mac")
        greedy = await support.pair_device(client, tenant, name="BLACKBOX-greedy")
        frugal = await support.pair_device(client, tenant, name="BLACKBOX-frugal")

        agent_ws = await client.ws(support.agent_socket_path(tenant), token=tenant.agent_token)
        greedy_ws = await client.ws(support.device_socket_path(greedy), token=greedy.token)
        frugal_ws = await client.ws(support.device_socket_path(frugal), token=frugal.token)
        try:
            assert (await support.read_frame(greedy_ws))["t"] == "hostStatus"
            assert (await support.read_frame(frugal_ws))["t"] == "hostStatus"
            attached = {support.frame_field(await support.read_frame(agent_ws), "deviceId")
                        for _ in range(2)}
            assert attached == {greedy.device_id, frugal.device_id}

            await agent_ws.send_str(delivery_frame(greedy, marker="greedy-over",
                                                   size=QUOTA_LIMIT_BYTES + 1000))
            error = await support.read_frame(greedy_ws, what="贪心设备的配额错误帧")
            assert error["code"] == "quota/device-daily"
            assert await support.read_close(greedy_ws) == CLOSE_QUOTA_EXCEEDED

            await agent_ws.send_str(delivery_frame(frugal, marker="frugal-fine", size=1000))
            fine = await support.read_frame(frugal_ws, what="另一台设备的帧")
            assert fine["id"] == "frugal-fine"
        finally:
            await greedy_ws.close()
            await frugal_ws.close()
            await agent_ws.close()
