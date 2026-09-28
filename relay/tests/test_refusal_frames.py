"""A refused device socket must say *why*, in the protocol's own vocabulary.

The relay refuses a device connect for two reasons a person can act on: the host
already has as many devices attached as it allows, and the device has spent its
daily traffic allowance. Both used to reach the phone as something that is not
an answer — an HTTP ``403`` before the upgrade, or a socket that simply goes
away — which reads as "the relay is broken" rather than "your host is full".
Clients then reported a network fault, and the person had nothing to act on.

These tests pin the contract: the refusal arrives as a DLP ``error`` frame with a
stable ``code``, followed by a clean application close carrying the matching
close code. Nothing here may turn into a 500 or a naked drop.
"""

from __future__ import annotations

import asyncio
import json

import pytest

import dlp
from hub import CLOSE_DEVICE_LIMIT, Limits
from conftest import agent_headers


async def connect_device(client, device):
    return await client.ws_connect(
        f"/link/device?agentId={device['agentId']}",
        headers={"Authorization": f"Bearer {device['deviceToken']}"})


async def test_the_device_budget_refusal_is_a_dlp_error_frame(client, store, provisioned):
    """Not a bare 403: the phone gets a code it can turn into a sentence."""
    client.app["limits"].max_devices_per_agent = 1

    first_code = store.mint_pair_code(provisioned["agent"]["agentId"], ttl_ms=60_000)
    first = await (await client.post("/pair/claim", json={
        "pairCode": first_code["code"], "deviceName": "first"})).json()
    second_code = store.mint_pair_code(provisioned["agent"]["agentId"], ttl_ms=60_000)
    second = await (await client.post("/pair/claim", json={
        "pairCode": second_code["code"], "deviceName": "second"})).json()

    agent_ws = await client.ws_connect(
        f"/link/agent?agentId={provisioned['agent']['agentId']}",
        headers=agent_headers(provisioned["agent"]))
    one = await connect_device(client, first)
    assert (await one.receive_json())["t"] == "hostStatus"      # first one is fine

    refused = await connect_device(client, second)
    frame = await refused.receive_json()
    assert frame["t"] == "error", frame
    assert frame["code"] == "limit/devices"
    assert frame["fatal"] is True
    assert frame["details"]["maxDevicesPerAgent"] == 1

    # …and then a clean close, with a code the app recognises. A 1006 (abnormal)
    # here would be indistinguishable from the socket having died. The close
    # frame arrives as the next message; reading it is what flushes the code.
    closing = await asyncio.wait_for(refused.receive(), timeout=5)
    assert closing.type.name in ("CLOSE", "CLOSING"), closing
    assert refused.close_code == CLOSE_DEVICE_LIMIT, refused.close_code

    await one.close()
    await agent_ws.close()


async def test_a_full_host_still_answers_a_reconnecting_device(client, store, provisioned):
    """The refusal must not lock a phone out of its *own* slot."""
    client.app["limits"].max_devices_per_agent = 1
    code = store.mint_pair_code(provisioned["agent"]["agentId"], ttl_ms=60_000)
    device = await (await client.post("/pair/claim", json={
        "pairCode": code["code"], "deviceName": "iPhone"})).json()

    agent_ws = await client.ws_connect(
        f"/link/agent?agentId={provisioned['agent']['agentId']}",
        headers=agent_headers(provisioned["agent"]))
    one = await connect_device(client, device)
    assert (await one.receive_json())["t"] == "hostStatus"

    # Same deviceId again while the first socket is still open: permitted.
    again = await connect_device(client, device)
    frame = await again.receive_json()
    assert frame["t"] == "hostStatus", f"重连不该被当成第二台设备: {frame}"

    await again.close()
    await one.close()
    await agent_ws.close()


async def test_the_daily_allowance_refusal_is_a_dlp_error_frame_and_a_clean_close(
        client, store, provisioned):
    """The quota path already framed its refusal; this pins that it still does."""
    client.app["limits"].device_daily_bytes = 1_000
    code = store.mint_pair_code(provisioned["agent"]["agentId"], ttl_ms=60_000)
    device = await (await client.post("/pair/claim", json={
        "pairCode": code["code"], "deviceName": "iPhone"})).json()

    agent_ws = await client.ws_connect(
        f"/link/agent?agentId={provisioned['agent']['agentId']}",
        headers=agent_headers(provisioned["agent"]))
    device_ws = await connect_device(client, device)

    # Drain the attach chatter, then push one frame that cannot fit the allowance.
    while True:
        frame = await asyncio.wait_for(device_ws.receive_json(), timeout=5)
        if frame["t"] == "hostStatus" and frame["info"]["online"]:
            break
    await agent_ws.send_json({"t": "chunk", "deviceId": device["deviceId"], "data": "x" * 5_000})

    errors = []
    for _ in range(10):
        frame = await asyncio.wait_for(device_ws.receive_json(), timeout=5)
        if frame["t"] == "error":
            errors.append(frame)
            break
    assert errors, "超配额时必须收到 error 帧，而不是被裸断"
    assert errors[0]["code"] == "quota/device-daily"
    assert errors[0]["details"]["limitBytes"] == 1_000

    await device_ws.close()
    await agent_ws.close()
