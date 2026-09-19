"""Relay routing tests (spec §5): registry, hostStatus, forwarding, cleanup."""

from __future__ import annotations

import asyncio
import json
import logging

import pytest
from aiohttp import WSMsgType

import hub as hub_module
from conftest import agent_headers


async def claim_device(client, provisioned, name="iPhone") -> dict:
    response = await client.post("/pair/claim", json={
        "pairCode": provisioned["code"]["code"], "deviceName": name,
        "deviceModel": "iPhone17,1", "appVersion": "1.0",
    })
    assert response.status == 200, await response.text()
    return await response.json()


async def open_device(client, provisioned, device=None):
    device = device or await claim_device(client, provisioned)
    ws = await client.ws_connect(f"/link/device?agentId={device['agentId']}",
                                 headers={"Authorization": f"Bearer {device['deviceToken']}"})
    return ws, device


async def open_agent(client, provisioned):
    return await client.ws_connect(f"/link/agent?agentId={provisioned['agent']['agentId']}",
                                   headers=agent_headers(provisioned["agent"]))


async def recv_json(ws, timeout=3.0) -> dict:
    message = await asyncio.wait_for(ws.receive(), timeout)
    assert message.type == WSMsgType.TEXT, f"unexpected frame {message.type}: {message}"
    return json.loads(message.data)


async def expect_no_frame(ws, timeout=0.3) -> None:
    with pytest.raises(asyncio.TimeoutError):
        await asyncio.wait_for(ws.receive(), timeout)


async def test_device_without_agent_is_told_the_host_is_offline(client, provisioned):
    ws, device = await open_device(client, provisioned)
    status = await recv_json(ws)
    assert status == {"t": "hostStatus", "info": {"online": False, "agentId": device["agentId"]}}
    await ws.close()


async def test_agent_online_is_announced_and_devices_are_attached(client, provisioned):
    device_ws, device = await open_device(client, provisioned)
    assert (await recv_json(device_ws))["info"]["online"] is False

    agent_ws = await open_agent(client, provisioned)

    attach = await recv_json(agent_ws)
    assert attach == {"t": "deviceAttach", "deviceId": device["deviceId"],
                      "device": {"name": "iPhone", "model": "iPhone17,1",
                                 "agentId": provisioned["agent"]["agentId"]}}
    status = await recv_json(device_ws)
    assert status["t"] == "hostStatus"
    assert status["info"]["online"] is True
    assert status["info"]["agentId"] == provisioned["agent"]["agentId"]
    assert status["info"]["name"] == "test mac"

    await agent_ws.close()
    await device_ws.close()


async def test_request_and_response_round_trip_preserves_id(client, provisioned):
    agent_ws = await open_agent(client, provisioned)
    device_ws, device = await open_device(client, provisioned)
    assert (await recv_json(agent_ws))["t"] == "deviceAttach"
    assert (await recv_json(device_ws))["info"]["online"] is True

    await device_ws.send_str(json.dumps({"t": "req", "id": "1", "method": "session/list",
                                         "args": {"_request": {}}}))
    forwarded = await recv_json(agent_ws)
    assert forwarded["t"] == "req"
    assert forwarded["id"] == "1"
    assert forwarded["deviceId"] == device["deviceId"]
    assert forwarded["args"] == {"_request": {}}

    await agent_ws.send_str(json.dumps({"t": "res", "id": "1", "ok": True,
                                        "deviceId": device["deviceId"], "value": {"items": []}}))
    answer = await recv_json(device_ws)
    assert answer == {"t": "res", "id": "1", "ok": True, "value": {"items": []}}
    assert "deviceId" not in answer

    await agent_ws.close()
    await device_ws.close()


async def test_logical_stream_frames_pass_through(client, provisioned):
    agent_ws = await open_agent(client, provisioned)
    device_ws, device = await open_device(client, provisioned)
    await recv_json(agent_ws)
    await recv_json(device_ws)

    await device_ws.send_str(json.dumps({"t": "open", "id": "2", "endpoint": "session/follow",
                                         "args": {"request": {"address": {"kind": "session",
                                                                          "sessionId": "s-1"}}}}))
    opened = await recv_json(agent_ws)
    assert opened["t"] == "open" and opened["endpoint"] == "session/follow"

    for frame in ({"t": "item", "id": "2", "value": {"type": "snapshot"}},
                  {"t": "end", "id": "2"}):
        await agent_ws.send_str(json.dumps({**frame, "deviceId": device["deviceId"]}))
    assert (await recv_json(device_ws))["value"] == {"type": "snapshot"}
    assert (await recv_json(device_ws)) == {"t": "end", "id": "2"}

    await device_ws.send_str(json.dumps({"t": "cancel", "id": "2"}))
    cancelled = await recv_json(agent_ws)
    assert cancelled["t"] == "cancel" and cancelled["id"] == "2"

    await agent_ws.close()
    await device_ws.close()


async def test_ping_is_answered_by_the_relay_on_both_sides(client, provisioned):
    agent_ws = await open_agent(client, provisioned)
    device_ws, _device = await open_device(client, provisioned)
    await recv_json(agent_ws)
    await recv_json(device_ws)

    await device_ws.send_str('{"t":"ping","ts":11}')
    assert await recv_json(device_ws) == {"t": "pong", "ts": 11}
    await expect_no_frame(agent_ws)

    await agent_ws.send_str('{"t":"ping","ts":22}')
    assert await recv_json(agent_ws) == {"t": "pong", "ts": 22}

    await agent_ws.close()
    await device_ws.close()


async def test_host_status_without_device_id_broadcasts(client, provisioned):
    agent_ws = await open_agent(client, provisioned)
    device_ws, _device = await open_device(client, provisioned)
    await recv_json(agent_ws)
    await recv_json(device_ws)

    await agent_ws.send_str('{"t":"hostStatus","info":{"online":true,"version":"0.1.5"}}')
    assert await recv_json(device_ws) == {"t": "hostStatus", "info": {"online": True, "version": "0.1.5"}}

    await agent_ws.close()
    await device_ws.close()


async def test_device_disconnect_tells_the_agent_to_clean_up(client, provisioned):
    agent_ws = await open_agent(client, provisioned)
    device_ws, device = await open_device(client, provisioned)
    await recv_json(agent_ws)
    await recv_json(device_ws)

    await device_ws.close()
    detach = await recv_json(agent_ws)
    assert detach == {"t": "deviceDetach", "deviceId": device["deviceId"], "reason": "socket closed"}

    await agent_ws.close()


async def test_agent_outage_and_reconnect_keeps_the_device(client, provisioned):
    agent_ws = await open_agent(client, provisioned)
    device_ws, device = await open_device(client, provisioned)
    await recv_json(agent_ws)
    await recv_json(device_ws)

    await agent_ws.close()
    offline = await recv_json(device_ws)
    assert offline["info"]["online"] is False

    second = await open_agent(client, provisioned)
    attach = await recv_json(second)
    assert attach["t"] == "deviceAttach" and attach["deviceId"] == device["deviceId"]
    online = await recv_json(device_ws)
    assert online["info"]["online"] is True

    await device_ws.send_str('{"t":"req","id":"9","method":"session/list","args":{"_request":{}}}')
    forwarded = await recv_json(second)
    assert forwarded["id"] == "9" and forwarded["deviceId"] == device["deviceId"]

    await second.close()
    await device_ws.close()


async def test_new_agent_connection_supersedes_the_old_one(client, provisioned):
    first = await open_agent(client, provisioned)
    second = await open_agent(client, provisioned)
    closed = await asyncio.wait_for(first.receive(), 3.0)
    assert closed.type == WSMsgType.CLOSE
    assert closed.data == hub_module.CLOSE_SUPERSEDED
    await second.close()


async def test_unknown_and_malformed_frames_do_not_reach_the_agent(client, provisioned):
    agent_ws = await open_agent(client, provisioned)
    device_ws, _device = await open_device(client, provisioned)
    await recv_json(agent_ws)
    await recv_json(device_ws)

    await device_ws.send_str("not json")
    assert (await recv_json(device_ws))["t"] == "error"
    await device_ws.send_str('{"t":"req","method":"session/list"}')
    assert (await recv_json(device_ws))["t"] == "error"
    await expect_no_frame(agent_ws)

    # Unknown frame types are forwarded verbatim so the tunnel stays forward-compatible.
    await device_ws.send_str('{"t":"futureThing","id":"7"}')
    forwarded = await recv_json(agent_ws)
    assert forwarded["t"] == "futureThing" and forwarded["id"] == "7"

    await agent_ws.close()
    await device_ws.close()


async def test_binary_frames_are_rejected(client, provisioned):
    device_ws, _device = await open_device(client, provisioned)
    await recv_json(device_ws)
    await device_ws.send_bytes(b"\x00\x01")
    error = await recv_json(device_ws)
    assert error["t"] == "error" and error["code"] == "protocol/binary-unsupported"
    await device_ws.close()


async def test_dlp_hello_with_a_mismatched_agent_is_fatal(client, provisioned):
    ws, _device = await open_device(client, provisioned)
    await recv_json(ws)
    await ws.send_str('{"t":"hello","agentId":"agt_someone_else"}')
    error = await recv_json(ws)
    assert error["code"] == "auth/agent-mismatch" and error["fatal"] is True
    closed = await asyncio.wait_for(ws.receive(), 3.0)
    assert closed.type == WSMsgType.CLOSE


# ── backpressure (spec §5: 512 unacked frames drops the slow device) ─────────


class _StuckSocket:
    """A socket whose writes never complete, to pin the queue bound."""

    def __init__(self) -> None:
        self.sent: list[str] = []
        self.gate = asyncio.Event()

    async def send_str(self, text: str) -> None:
        self.sent.append(text)
        await self.gate.wait()

    async def close(self, code: int = 1000, message: bytes = b"") -> None:
        self.gate.set()


def test_link_queue_is_bounded():
    link = hub_module.Link(_StuckSocket(), label="test", queue_depth=2,
                           logger=logging.getLogger("test"))
    assert link.enqueue_text("{}") is True
    assert link.enqueue_text("{}") is True
    assert link.enqueue_text("{}") is False
    assert link.pending() == 2
    assert link.dropped == 1


def test_device_agent_queue_is_bounded():
    device = {"deviceId": "dev_1", "agentId": "agt_1", "name": "iPhone", "model": None,
              "appVersion": None}
    limits = hub_module.Limits(queue_depth=2)
    link = hub_module.DeviceLink(_StuckSocket(), device=device, logger=logging.getLogger("test"),
                                 limits=limits)
    assert link.enqueue_to_agent({"t": "req", "id": "1"}) is True
    assert link.enqueue_to_agent({"t": "req", "id": "2"}) is True
    assert link.enqueue_to_agent({"t": "req", "id": "3"}) is False


def test_agent_frame_for_an_unknown_device_is_dropped():
    async def scenario():
        hub = hub_module.RelayHub(store=None, logger=logging.getLogger("test"))
        link = hub_module.AgentLink(_StuckSocket(), agent={"agentId": "agt_1", "accountId": "acc_1",
                                                           "name": "mac"},
                                    logger=logging.getLogger("test"), limits=hub.limits)
        link.start()
        await hub.route_from_agent(link, {"t": "res", "id": "1", "deviceId": "dev_nope", "ok": True})
        await link.close()
    asyncio.run(scenario())


async def test_backpressure_drops_only_the_slow_device(client, store, provisioned):
    """With a queue depth of 8, a device that never reads is disconnected."""
    agent_ws = await open_agent(client, provisioned)
    device_ws, device = await open_device(client, provisioned)
    await recv_json(agent_ws)
    await recv_json(device_ws)

    hub = client.app["hub"]
    link = hub._devices[device["deviceId"]]
    # Simulate a device whose socket stopped draining by making the writer wait
    # forever and pushing frames directly through the queue.
    for index in range(8):
        assert link.enqueue_frame({"t": "item", "id": str(index), "value": index}) is True
    assert link.enqueue_frame({"t": "item", "id": "overflow", "value": 0}) is False
    # The relay drops the device, and the agent is told to clean up its streams.
    await hub._drop_device(device["deviceId"], "backpressure")
    detach = await recv_json(agent_ws)
    assert detach["t"] == "deviceDetach"
    assert detach["deviceId"] == device["deviceId"]
    assert detach["reason"] == "backpressure"
    # The device still has its queued frames to drain before the close lands.
    deadline = asyncio.get_running_loop().time() + 3.0
    while True:
        remaining = deadline - asyncio.get_running_loop().time()
        assert remaining > 0, "the relay never closed the slow device"
        message = await asyncio.wait_for(device_ws.receive(), remaining)
        if message.type == WSMsgType.CLOSE:
            break
    assert message.data == hub_module.CLOSE_BACKPRESSURE

    await agent_ws.close()
    await device_ws.close()


async def test_a_phone_reporting_its_build_refreshes_the_device_row(client, provisioned, store):
    """The one frame in which the client's own build travels.

    The device row is written when the phone pairs and, before this, never
    again — so "did that phone update?" was answered with whatever it ran the
    day it paired. The handshake carries it once per connection; the relay
    records it, and the agent's view of the device gets the fresh value.
    """
    agent_ws = await open_agent(client, provisioned)
    device_ws, device = await open_device(client, provisioned)
    assert (await recv_json(agent_ws))["t"] == "deviceAttach"
    assert (await recv_json(device_ws))["info"]["online"] is True

    await device_ws.send_json({
        "t": "req", "id": "hello-1", "method": "_link/hello",
        "args": {"clientName": "DSHMobile", "clientVersion": "1.0",
                 "clientBuild": "20260919.0005"},
    })
    forwarded = await recv_json(agent_ws)
    assert forwarded["method"] == "_link/hello", "the frame must still reach the connector"

    await asyncio.sleep(0.1)  # the row write happens off the routing path
    row = store.device_by_id(device["deviceId"])
    assert row["appVersion"] == "1.0 20260919.0005"

    # And the second hello does not rewrite the row for the same build.
    before = row["appVersion"]
    await device_ws.send_json({
        "t": "req", "id": "hello-2", "method": "_link/hello",
        "args": {"clientName": "DSHMobile", "clientVersion": "1.0",
                 "clientBuild": "20260919.0005"},
    })
    assert (await recv_json(agent_ws))["method"] == "_link/hello"
    await asyncio.sleep(0.1)
    assert store.device_by_id(device["deviceId"])["appVersion"] == before

    await agent_ws.close()
    await device_ws.close()


async def test_a_client_that_reports_nothing_leaves_the_row_alone(client, provisioned, store):
    """An older app sends an empty handshake; unknown must not overwrite known."""
    agent_ws = await open_agent(client, provisioned)
    device_ws, device = await open_device(client, provisioned)
    assert (await recv_json(agent_ws))["t"] == "deviceAttach"
    assert (await recv_json(device_ws))["info"]["online"] is True

    await device_ws.send_json({"t": "req", "id": "hello-1", "method": "_link/hello", "args": {}})
    assert (await recv_json(agent_ws))["method"] == "_link/hello"
    await asyncio.sleep(0.1)
    assert store.device_by_id(device["deviceId"])["appVersion"] == "1.0"

    await agent_ws.close()
    await device_ws.close()
