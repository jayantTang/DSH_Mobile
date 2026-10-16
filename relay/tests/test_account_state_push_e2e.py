"""032：账户级状态的端到端（真 WebSocket）。

单元用例断言的是"谁被通知了"；这一条断言**帧真的到了另一台设备手上**——
两台设备各开一条 `/link/device` WebSocket，A 写状态，B 必须收到
`{"t":"accountState","keys":[...]}`，而且 A 自己不该收到。

为什么值得单独一条：`hub.notify_account_state` 是"入队失败就当没发"的尽力而为通道，
单测里用假 link 看不到"真的从 socket 出去"这一层；这条用真 socket 把它钉住。
"""
import asyncio
import json

import pytest

import relay as relay_module
from conftest import device_headers
from hub import Limits
from store import Store


@pytest.fixture
async def client(aiohttp_client, store: Store):
    app = relay_module.create_app(store=store, limits=Limits(queue_depth=8), pair_ttl_ms=60_000)
    return await aiohttp_client(app)


async def _pair(client, store, agent, name, device_key=None):
    minted = store.mint_pair_code(agent["agentId"])
    payload = {"pairCode": minted["code"], "deviceName": name}
    if device_key:
        payload["deviceKey"] = device_key
    response = await client.post("/pair/claim", json=payload)
    assert response.status == 200, await response.text()
    return await response.json()


async def _connect(client, agent_id, token):
    return await client.ws_connect(f"/link/device?agentId={agent_id}",
                                   headers=device_headers(token))


async def _drain_until(ws, predicate, timeout=2.0):
    """读到第一条满足 `predicate` 的帧；超时返回 None（不抛，便于断言"没收到"）。"""
    async def read():
        async for msg in ws:
            if msg.type.name != "TEXT":
                continue
            frame = json.loads(msg.data)
            if predicate(frame):
                return frame
        return None

    try:
        return await asyncio.wait_for(read(), timeout=timeout)
    except asyncio.TimeoutError:
        return None


async def test_a_write_reaches_the_other_device_over_a_real_socket(client, store, provisioned):
    agent = provisioned["agent"]
    writer = await _pair(client, store, agent, "DSH-Writer", device_key="key-writer01")
    reader = await _pair(client, store, agent, "DSH-Reader", device_key="key-reader01")

    writer_ws = await _connect(client, agent["agentId"], writer["deviceToken"])
    reader_ws = await _connect(client, agent["agentId"], reader["deviceToken"])
    try:
        # 两台都先握上手（中转 attach 之后才会把它们算进"在线设备"）。
        await asyncio.sleep(0.05)

        response = await client.put("/account/state", json={
            "entries": [{"key": "sessionRead.agt_x", "value": {"sess_a": 42},
                         "updatedAt": 1_790_000_000_000}],
        }, headers=device_headers(writer["deviceToken"]))
        assert response.status == 200, await response.text()
        assert (await response.json())["applied"] == ["sessionRead.agt_x"]

        frame = await _drain_until(reader_ws, lambda f: f.get("t") == "accountState")
        assert frame is not None, "the other device must receive the accountState frame"
        assert frame["keys"] == ["sessionRead.agt_x"]

        # 写入者自己不该收到（它已经改了本地）。
        echoed = await _drain_until(writer_ws, lambda f: f.get("t") == "accountState", timeout=0.3)
        assert echoed is None, "the writer must not be notified about its own write"
    finally:
        await writer_ws.close()
        await reader_ws.close()


async def test_another_account_device_is_not_notified(client, store, provisioned):
    agent = provisioned["agent"]
    mine = await _pair(client, store, agent, "DSH-Mine", device_key="key-mine0001")
    other_account = store.create_account("someone else")
    other_agent = store.register_agent(other_account["accountId"], "other mac")
    theirs = await _pair(client, store, other_agent, "DSH-Theirs", device_key="key-theirs1")

    mine_ws = await _connect(client, agent["agentId"], mine["deviceToken"])
    theirs_ws = await _connect(client, other_agent["agentId"], theirs["deviceToken"])
    try:
        await asyncio.sleep(0.05)
        response = await client.put("/account/state", json={
            "entries": [{"key": "alertPrefs", "value": {"turnEnd": False},
                         "updatedAt": 1_790_000_000_000}],
        }, headers=device_headers(mine["deviceToken"]))
        assert response.status == 200

        # 另一个账户的设备一条都不该收到。
        leaked = await _drain_until(theirs_ws, lambda f: f.get("t") == "accountState", timeout=0.3)
        assert leaked is None
    finally:
        await mine_ws.close()
        await theirs_ws.close()


async def test_a_rejected_older_write_notifies_nobody(client, store, provisioned):
    """被拒的写（更旧的时间戳）不该发通知——否则另一台设备会白拉一次。"""
    agent = provisioned["agent"]
    first = await _pair(client, store, agent, "DSH-One", device_key="key-one00001")
    second = await _pair(client, store, agent, "DSH-Two", device_key="key-two00001")

    first_ws = await _connect(client, agent["agentId"], first["deviceToken"])
    second_ws = await _connect(client, agent["agentId"], second["deviceToken"])
    try:
        await asyncio.sleep(0.05)
        await client.put("/account/state", json={
            "entries": [{"key": "badgeWatermark", "value": {"at": 10},
                         "updatedAt": 1_790_000_000_000}],
        }, headers=device_headers(first["deviceToken"]))
        # 排掉刚才那条正常通知，再看"更旧的写"会不会再发一条。
        await _drain_until(second_ws, lambda f: f.get("t") == "accountState")

        stale = await client.put("/account/state", json={
            "entries": [{"key": "badgeWatermark", "value": {"at": 1},
                         "updatedAt": 1_700_000_000_000}],
        }, headers=device_headers(first["deviceToken"]))
        assert (await stale.json())["applied"] == []

        extra = await _drain_until(second_ws, lambda f: f.get("t") == "accountState", timeout=0.3)
        assert extra is None, "a rejected write must not wake the other device"
    finally:
        await first_ws.close()
        await second_ws.close()


async def test_regenerating_the_code_leaves_connected_devices_alone(client, store, provisioned):
    """032 FR-002 的真 socket 版：换码之后两台已连设备的 socket 一条都不掉。"""
    from conftest import agent_headers

    agent = provisioned["agent"]
    # 同一枚持久码配两台设备。
    code = store.mint_pair_code(agent["agentId"])["code"]
    tokens = []
    for name, key in (("DSH-A", "key-aaaa0001"), ("DSH-B", "key-bbbb0001")):
        response = await client.post("/pair/claim", json={
            "pairCode": code, "deviceName": name, "deviceKey": key})
        assert response.status == 200, await response.text()
        tokens.append((await response.json())["deviceToken"])

    sockets = [await _connect(client, agent["agentId"], token) for token in tokens]
    try:
        await asyncio.sleep(0.05)
        hub = client.server.app["hub"]
        attached_before = len([d for d in hub._devices.values()  # noqa: SLF001
                               if d.account_id == provisioned["account"]["accountId"]])
        assert attached_before == 2

        regenerated = await client.post("/pair/code/regenerate", json={},
                                        headers=agent_headers(agent))
        assert regenerated.status == 200
        assert (await regenerated.json())["revoked"] >= 1
        await asyncio.sleep(0.05)

        # 两条 socket 都还在（`closed` 是 Link 上的公开状态），中转的登记也还在。
        assert all(not socket.closed for socket in sockets), "换码不许踢掉已连设备"
        attached_after = len([d for d in hub._devices.values()  # noqa: SLF001
                              if d.account_id == provisioned["account"]["accountId"]])
        assert attached_after == 2

        # 而且两条都还能干活：各自发一个 ping，能收到 pong。
        for socket in sockets:
            await socket.send_str(json.dumps({"t": "ping", "ts": 1}))
            pong = await _drain_until(socket, lambda f: f.get("t") == "pong")
            assert pong is not None, "换码之后这条连接必须仍然可用"
    finally:
        for socket in sockets:
            await socket.close()
