"""End-to-end: the day's usage is still there after the relay restarts.

``03-change-items.md`` CI-03 asks for exactly this, and it is the one part of the
item that a unit test can only approximate: a *real* SQLite file, a real hub over
it, a real flush, then a process-level restart (a fresh ``Store`` over the same
path) and a fresh ``/stats``.

It is the operator-visible half of "the daily allowance survives a reconnect":
if the day's number came back as zero, the allowance would too.
"""

from __future__ import annotations

import asyncio
import json

import pytest

import hub as hub_module
from hub import Limits, RelayHub
from store import Store, local_day


class FakeWS:
    def __init__(self):
        self.sent: list[str] = []

    async def send_str(self, text):
        self.sent.append(text)

    async def close(self, code=1000, message=b""):
        return None


async def drive_one_day(store: Store, *, payload: str = "x" * 4_000):
    """Attach a device, push one frame through, and flush — as a real day would."""
    hub = RelayHub(store, limits=Limits(queue_depth=8))
    await hub.attach_agent({"agentId": "agt_1", "accountId": "acc_1", "name": "pc"}, FakeWS())
    link = await hub.attach_device({"deviceId": "dev_1", "agentId": "agt_1",
                                    "name": "iPhone"}, FakeWS())
    link.start()
    await asyncio.sleep(0.05)
    await hub.route_from_agent(hub.agents["agt_1"], {
        "t": "item", "id": "s1", "deviceId": "dev_1",
        "value": {"type": "text-delta", "text": payload}})
    await asyncio.sleep(0.1)
    await hub.shutdown()          # flushes
    return hub


async def test_the_day_survives_a_relay_restart(tmp_path):
    path = str(tmp_path / "state.db")

    first = Store(path)
    hub = await drive_one_day(first)
    today = local_day()
    (row,) = first.usage_rows(today)
    bytes_before = row["egressBytes"]
    assert bytes_before > 0
    report_before = hub.usage_today()["totalEgressBytes"]
    first.close()

    # A restart: same file, brand-new process-level objects.
    second = Store(path)
    try:
        (row,) = second.usage_rows(today)
        assert row["egressBytes"] == bytes_before, "重启后当日记账不能归零"
        assert row["connections"] >= 1

        restarted = RelayHub(second, limits=Limits(queue_depth=8))
        try:
            assert restarted.usage_today()["totalEgressBytes"] == report_before
        finally:
            await restarted.shutdown()
    finally:
        second.close()


async def test_the_allowance_also_survives_the_restart(tmp_path):
    """The number the report shows and the number the quota enforces agree."""
    path = str(tmp_path / "state.db")
    limit = 10_000

    first = Store(path)
    await drive_one_day(first, payload="y" * 6_000)
    spent = first.usage_rows(local_day())[0]["egressBytes"]
    first.close()

    second = Store(path)
    try:
        hub = RelayHub(second, limits=Limits(device_daily_bytes=limit))
        await hub.attach_agent({"agentId": "agt_1", "accountId": "acc_1", "name": "pc"}, FakeWS())
        ws = FakeWS()
        link = await hub.attach_device({"deviceId": "dev_1", "agentId": "agt_1",
                                        "name": "iPhone"}, ws)
        assert link.quota.used >= spent, (
            f"重启后额度基线应包含今天已用的 {spent}，实际 {link.quota.used}")
        assert link.quota.remaining() <= limit - spent
        await hub.shutdown()
    finally:
        second.close()


async def test_stats_reports_the_surviving_day_over_http(client, store, provisioned):
    """The `/stats` route the operator actually reads, after a flush."""
    hub = client.app["hub"]
    claim = await client.post("/pair/claim", json={
        "pairCode": provisioned["code"]["code"], "deviceName": "iPhone"})
    device = await claim.json()
    device_ws = await client.ws_connect(
        f"/link/device?agentId={device['agentId']}",
        headers={"Authorization": f"Bearer {device['deviceToken']}"})
    agent_ws = await client.ws_connect(
        f"/link/agent?agentId={provisioned['agent']['agentId']}",
        headers={"Authorization": f"Bearer {provisioned['agent']['agentSecret']}"})
    await asyncio.sleep(0.1)

    await agent_ws.send_json({"t": "chunk", "deviceId": device["deviceId"], "data": "z" * 3_000})
    await asyncio.sleep(0.2)
    await hub.flush_usage()

    stats = await (await client.get("/stats")).json()
    assert stats["today"]["day"] == local_day()
    assert stats["today"]["totalEgressBytes"] >= 3_000
    # The stored row is what a restart would reload — it must already carry it.
    stored = store.usage_rows(local_day())
    assert stored and stored[0]["egressBytes"] > 0

    await device_ws.close()
    await agent_ws.close()
