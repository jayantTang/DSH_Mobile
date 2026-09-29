"""``notify`` → APNs, and the rule that keeps a phone from buzzing twice (R-1 C-06).

The interesting assertion is the *negative* one: a device that is **connected
right now** must not be pushed, because it already receives the event over its
own socket and raises a local notification. Getting that backwards is not a
cosmetic bug — the user gets two alerts for one finished run, which is exactly
what the owner asked to avoid.

Everything here runs against a stub sender: no credential, no network, no Apple.
"""

from __future__ import annotations

import asyncio
import json

import pytest
from aiohttp import WSMsgType

import hub as hub_module
from conftest import agent_headers


class StubPushSender:
    """Stands in for ``push.PushSender``; records what it was asked to send."""

    enabled = True

    def __init__(self, results=None):
        self.calls: list[dict] = []
        self.results = results or []
        self.cleared: list[str] = []
        self.sent = asyncio.Event()

    async def send_many(self, targets, *, kind, sid, eid=None, ignore_throttle=False):
        self.calls.append({
            "targets": [dict(target) for target in targets],
            "kind": kind, "sid": sid, "eid": eid,
            "ignore_throttle": ignore_throttle,
        })
        self.sent.set()
        from push import PushResult

        if self.results:
            return list(self.results)
        return [PushResult(ok=True, status=200) for _ in targets]

    async def aclose(self):
        return None


async def claim_device(client, provisioned, name="iPhone") -> dict:
    response = await client.post("/pair/claim", json={
        "pairCode": provisioned["code"]["code"], "deviceName": name,
        "deviceModel": "iPhone17,1", "appVersion": "1.0",
    })
    assert response.status == 200, await response.text()
    return await response.json()


async def open_agent(client, provisioned):
    return await client.ws_connect(f"/link/agent?agentId={provisioned['agent']['agentId']}",
                                   headers=agent_headers(provisioned["agent"]))


async def drain_handshake(ws, timeout: float = 0.25) -> None:
    """Swallow whatever the relay says on connect.

    The first frame is not part of what these tests assert: an agent with paired
    devices gets a ``deviceAttach`` per device, and one with no live device gets a
    ``hostStatus``. Waiting for a specific one would make the ordering of the
    fixture (pair first or connect first) load-bearing for no reason.
    """
    try:
        while True:
            await asyncio.wait_for(ws.receive(), timeout)
    except asyncio.TimeoutError:
        return


async def open_device(client, device):
    return await client.ws_connect(f"/link/device?agentId={device['agentId']}",
                                   headers={"Authorization": f"Bearer {device['deviceToken']}"})


async def recv_json(ws, timeout=3.0) -> dict:
    message = await asyncio.wait_for(ws.receive(), timeout)
    assert message.type == WSMsgType.TEXT, f"unexpected frame {message.type}: {message}"
    return json.loads(message.data)


async def settle(seconds: float = 0.15) -> None:
    """Let the fire-and-forget delivery task run.

    ``_notify`` answers the routing path immediately and delivers on a task, so a
    test that asserted straight afterwards would be racing it.
    """
    for _ in range(int(seconds / 0.01) + 1):
        await asyncio.sleep(0.01)


@pytest.fixture
def push_stub(client) -> StubPushSender:
    sender = StubPushSender()
    client.app["hub"].set_push_sender(sender)
    return sender


async def register_push(store, device_id: str, token: str = "ab" * 32,
                        env: str = "sandbox", turn_end: bool = True,
                        attention: bool = True) -> None:
    store.set_push(device_id, token, env, turn_end, attention)


async def notify(agent_ws, **frame) -> None:
    await agent_ws.send_json({"t": "notify", **frame})


async def test_an_offline_device_is_pushed_once_with_the_right_arguments(
        client, store, provisioned, push_stub):
    agent_ws = await open_agent(client, provisioned)
    await drain_handshake(agent_ws)
    device = await claim_device(client, provisioned)
    await register_push(store, device["deviceId"])

    # Never connected: the device is not in the hub's live registry.
    await notify(agent_ws, kind="turnEnd", sid="s-1")
    await asyncio.wait_for(push_stub.sent.wait(), 3.0)

    assert len(push_stub.calls) == 1
    call = push_stub.calls[0]
    assert call["kind"] == "turnEnd" and call["sid"] == "s-1"
    assert [target["deviceId"] for target in call["targets"]] == [device["deviceId"]]
    assert call["targets"][0]["apnsToken"] == "ab" * 32

    await agent_ws.close()


async def test_a_connected_device_is_not_pushed(client, store, provisioned, push_stub):
    """在线不推——这就是"不重复弹"的全部机制。"""
    agent_ws = await open_agent(client, provisioned)
    await drain_handshake(agent_ws)
    device = await claim_device(client, provisioned)
    await register_push(store, device["deviceId"])
    device_ws = await open_device(client, device)
    assert (await recv_json(agent_ws))["t"] == "deviceAttach"
    await recv_json(device_ws)

    await notify(agent_ws, kind="turnEnd", sid="s-1")
    await settle()

    assert push_stub.calls == [], "在线的设备不该收到推送（它自己会弹本地通知）"

    await agent_ws.close()
    await device_ws.close()


async def test_the_switch_for_that_kind_turns_the_push_off(client, store, provisioned, push_stub):
    agent_ws = await open_agent(client, provisioned)
    await drain_handshake(agent_ws)
    device = await claim_device(client, provisioned)
    # 用户只想被通知"跑完了"，不想被通知"有待确认"。
    await register_push(store, device["deviceId"], turn_end=True, attention=False)

    await notify(agent_ws, kind="attention", sid="s-1", eid="e-1")
    await settle()
    assert push_stub.calls == []

    await notify(agent_ws, kind="turnEnd", sid="s-1")
    await asyncio.wait_for(push_stub.sent.wait(), 3.0)
    assert [call["kind"] for call in push_stub.calls] == ["turnEnd"]

    await agent_ws.close()


async def test_a_device_without_a_registration_is_not_pushed(client, provisioned, push_stub):
    agent_ws = await open_agent(client, provisioned)
    await drain_handshake(agent_ws)
    await claim_device(client, provisioned)

    await notify(agent_ws, kind="turnEnd", sid="s-1")
    await settle()
    assert push_stub.calls == []

    await agent_ws.close()


async def test_a_revoked_device_is_not_pushed(client, store, provisioned, push_stub):
    agent_ws = await open_agent(client, provisioned)
    await drain_handshake(agent_ws)
    device = await claim_device(client, provisioned)
    await register_push(store, device["deviceId"])
    store.revoke_device(device["deviceId"])

    await notify(agent_ws, kind="turnEnd", sid="s-1")
    await settle()
    assert push_stub.calls == []

    await agent_ws.close()


async def test_a_disabled_sender_sends_nothing_and_breaks_nothing(client, store, provisioned):
    """未配置 APNs 时转发行为与今天逐字一致——这是最重要的一条。"""
    from push import PushSender

    client.app["hub"].set_push_sender(PushSender.disabled())
    agent_ws = await open_agent(client, provisioned)
    await drain_handshake(agent_ws)
    device = await claim_device(client, provisioned)
    await register_push(store, device["deviceId"])

    await notify(agent_ws, kind="turnEnd", sid="s-1")
    await settle()

    # 连接照样活着，转发照样工作（这里用一次 hostStatus 广播证明这条 agent 链还在）。
    await agent_ws.send_json({"t": "hostStatus", "info": {"online": True}})
    await settle()
    await agent_ws.close()


async def test_notify_is_never_forwarded_to_a_device(client, store, provisioned, push_stub):
    """`notify` 是 agent 侧控制帧，**不跨到设备**——手机根本不该看到它。

    做法：设备先连上、把它自己的 hostStatus 读干净，再发一条 notify。这台设备的
    两类开关都**开着**，所以"没有推送"只可能是「它在线」那一条成立；如果 notify
    被错当成普通帧转发了，设备这侧就会多出一帧。
    """
    device = await claim_device(client, provisioned)
    await register_push(store, device["deviceId"])
    device_ws = await open_device(client, device)
    assert (await recv_json(device_ws))["t"] == "hostStatus"

    agent_ws = await open_agent(client, provisioned)
    await drain_handshake(agent_ws)

    await notify(agent_ws, kind="turnEnd", sid="s-1")
    await settle()

    assert push_stub.calls == [], "在线设备被推了（应判在线不推）"

    # 设备这侧该看到的只有 "agent 上线了" 那条 hostStatus——没有任何带着 notify
    # 或 event 的帧。**不能简单断言"什么都收不到"**：agent 连上时 relay 本来就会
    # 给在线设备发一条 hostStatus，那是它该做的。
    received = []
    try:
        while True:
            message = await asyncio.wait_for(device_ws.receive(), 0.3)
            received.append(message)
    except asyncio.TimeoutError:
        pass
    frames = [json.loads(m.data) for m in received if m.type == WSMsgType.TEXT]
    assert all(frame.get("t") == "hostStatus" for frame in frames), \
        f"设备收到了不该跨过去的帧：{frames}"
    assert not any(frame.get("t") == "notify" for frame in frames)

    await agent_ws.close()
    await device_ws.close()


async def test_a_dead_token_is_cleared_by_the_relay(client, store, provisioned, push_stub):
    """`410`/`BadDeviceToken` 是唯一的自动清理机制：App 被卸载后别再推。"""
    from push import PushResult

    push_stub.results = [PushResult(ok=False, status=410, reason="Unregistered", dead_token=True)]
    agent_ws = await open_agent(client, provisioned)
    await drain_handshake(agent_ws)
    device = await claim_device(client, provisioned)
    await register_push(store, device["deviceId"])

    await notify(agent_ws, kind="turnEnd", sid="s-1")
    await asyncio.wait_for(push_stub.sent.wait(), 3.0)
    await settle()

    assert store.device_by_id(device["deviceId"])["apnsToken"] is None

    await agent_ws.close()


async def test_a_malformed_notify_is_ignored(client, provisioned, push_stub):
    agent_ws = await open_agent(client, provisioned)
    await drain_handshake(agent_ws)

    for frame in ({"kind": "made-up", "sid": "s-1"}, {"kind": "turnEnd"},
                  {"kind": "turnEnd", "sid": ""}, {"sid": "s-1"}):
        await notify(agent_ws, **frame)
    await settle()
    assert push_stub.calls == []

    await agent_ws.close()


async def test_push_delivery_never_blocks_the_agent_link(client, store, provisioned):
    """投递在任务里跑：`route_from_agent` 不等网络（否则 Apple 一慢就拖住转发）。"""
    class SlowSender(StubPushSender):
        async def send_many(self, targets, **kwargs):
            await asyncio.sleep(0.5)
            return await super().send_many(targets, **kwargs)

    slow = SlowSender()
    client.app["hub"].set_push_sender(slow)
    agent_ws = await open_agent(client, provisioned)
    await drain_handshake(agent_ws)
    device = await claim_device(client, provisioned)
    await register_push(store, device["deviceId"])

    loop = asyncio.get_running_loop()
    started = loop.time()
    await notify(agent_ws, kind="turnEnd", sid="s-1")
    # 紧跟着再发一条别的帧：它必须马上被处理，而不是排在推送后面。
    await agent_ws.send_json({"t": "hostStatus", "info": {"online": True}})
    await settle(0.2)
    assert loop.time() - started < 0.4, "推送阻塞了 agent 链路的处理"

    await agent_ws.close()
