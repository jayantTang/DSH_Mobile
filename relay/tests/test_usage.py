"""Daily usage accounting: the day's bytes survive a restart and land per account.

What this covers, and why each piece is here:

* the accumulator adds up egress **and** connection counts, per day per device;
* a flush rewrites the same row many times (periodic flushing) without
  double-counting or losing the day's earlier bytes;
* a failure to write puts the batch back in memory instead of dropping it —
  the whole point of the accounting is that the number is trustworthy;
* the local-day boundary closes the previous day's row rather than folding it
  into the new one.
"""

from __future__ import annotations

import asyncio
import logging
import time

import pytest

import hub as hub_module
from hub import Limits, RelayHub
from store import Store, day_floor, local_day


class FakeStore:
    """Records what the hub asked it to write; nothing else."""

    def __init__(self, *, fail: bool = False):
        self.batches: list[list[dict]] = []
        self.fail = fail

    def add_usage(self, entries):
        if self.fail:
            raise RuntimeError("disk on fire")
        self.batches.append([dict(entry) for entry in entries])
        return len(entries)

    def usage_rows(self, day):
        return []


class FakeLink:
    """The bits of `DeviceLink` the accounting touches."""

    def __init__(self, device_id="dev_1", agent_id="agt_1", account_id="acc_1"):
        self.device_id = device_id
        self.agent_id = agent_id
        self.account_id = account_id
        self.closed = False
        self.egress_bytes = 0


def make_hub(store: FakeStore) -> RelayHub:
    return RelayHub(store, logger=logging.getLogger("relay.test"), limits=Limits())


def test_egress_accumulates_and_flush_writes_one_row_per_device():
    store = FakeStore()
    hub = make_hub(store)
    link = FakeLink()
    link.on_egress = hub._note_egress

    hub._note_usage(link, connection=True)
    for size in (100, 250, 650):
        link.egress_bytes += size
        hub._note_egress(link, size)

    asyncio.run(hub.flush_usage())
    assert len(store.batches) == 1
    (entry,) = store.batches[0]
    assert entry["deviceId"] == "dev_1"
    assert entry["accountId"] == "acc_1"
    assert entry["egressBytes"] == 1000
    assert entry["connections"] == 1
    assert entry["day"] == local_day()


def test_second_flush_adds_to_the_same_row_without_double_counting():
    store = FakeStore()
    hub = make_hub(store)
    link = FakeLink()

    hub._note_usage(link, connection=True, egress_bytes=500)
    asyncio.run(hub.flush_usage())
    hub._note_usage(link, egress_bytes=300)
    asyncio.run(hub.flush_usage())

    assert [entry["egressBytes"] for batch in store.batches for entry in batch] == [500, 300]
    # 两次写的是同一行；累加交给 store 的 UPSERT（test_store 里有那半边）。
    assert {entry["day"] for batch in store.batches for entry in batch} == {local_day()}
    assert hub._usage == {}


def test_flush_keeps_the_batch_when_the_write_fails():
    store = FakeStore(fail=True)
    hub = make_hub(store)
    link = FakeLink()
    hub._note_usage(link, connection=True, egress_bytes=42)

    asyncio.run(hub.flush_usage())          # 写失败
    assert store.batches == []
    assert sum(entry["egressBytes"] for entry in hub._usage.values()) == 42

    store.fail = False
    asyncio.run(hub.flush_usage())          # 下一次补上
    (entry,) = store.batches[0]
    assert entry["egressBytes"] == 42
    assert entry["connections"] == 1


def test_build_report_lands_on_the_day_row():
    store = FakeStore()
    hub = make_hub(store)
    link = FakeLink()
    hub._note_usage(link, connection=True, build="1.0 20260921.1036")

    asyncio.run(hub.flush_usage())
    (entry,) = store.batches[0]
    assert entry["lastBuild"] == "1.0 20260921.1036"


def test_same_build_again_still_lands_on_the_day_row():
    """重连时设备行里已经是这个构建号——当天那行的 lastBuild 不能因此空着。"""
    store = FakeStore()
    hub = make_hub(store)
    link = FakeLink()
    link.app_version = "1.0 20260921.1036"      # 设备行里已经有了

    async def run():
        await hub._note_client_build(link, {"clientVersion": "1.0",
                                            "clientBuild": "20260921.1036"})
    asyncio.run(run())
    asyncio.run(hub.flush_usage())
    (entry,) = store.batches[0]
    assert entry["lastBuild"] == "1.0 20260921.1036"


def test_day_rollover_closes_the_old_day(monkeypatch):
    store = FakeStore()
    hub = make_hub(store)
    link = FakeLink()
    yesterday = int(time.strftime("%Y%m%d", time.localtime(time.time() - 86400)))
    hub._usage_day = yesterday              # 这一笔发生在前一天
    hub._note_usage(link, connection=True, egress_bytes=10)

    monkeypatch.setattr(hub_module.store_module, "local_day", lambda *a: yesterday + 1)
    asyncio.run(hub.flush_usage())          # 冲的是旧日那行
    (entry,) = store.batches[0]
    assert entry["day"] == yesterday
    # 换账本后新的字节不再落进旧日
    hub._usage_day = yesterday + 1
    hub._note_usage(link, egress_bytes=5)
    asyncio.run(hub.flush_usage())
    assert store.batches[1][0]["day"] == yesterday + 1


def test_usage_today_merges_stored_rows_with_pending_bytes(monkeypatch):
    store = FakeStore()
    hub = make_hub(store)
    link = FakeLink()
    today = local_day()

    monkeypatch.setattr(store, "usage_rows", lambda day: [{
        "day": day, "deviceId": "dev_1", "agentId": "agt_1", "accountId": "acc_1",
        "egressBytes": 700, "connections": 2, "lastBuild": "1.0 old",
        "firstSeenAt": 1, "lastSeenAt": 2,
    }])
    hub._note_usage(link, egress_bytes=300, build="1.0 new")

    view = hub.usage_today()
    assert view["day"] == today
    assert view["totalEgressBytes"] == 1000
    assert view["devices"][0]["egressBytes"] == 1000
    assert view["devices"][0]["lastBuild"] == "1.0 new"
    assert view["accounts"][0] == {"accountId": "acc_1", "egressBytes": 1000, "devices": 1}


def test_store_upsert_adds_instead_of_replacing(tmp_path):
    """store 那半边：同一行写两次是相加，连接数也是。"""
    store = Store(str(tmp_path / "state.db"))
    today = local_day()
    base = {"day": today, "deviceId": "dev_1", "agentId": "agt_1", "accountId": "acc_1",
            "at": 1_700_000_000_000, "lastBuild": None}
    store.add_usage([{**base, "egressBytes": 100, "connections": 1}])
    store.add_usage([{**base, "egressBytes": 250, "connections": 1, "lastBuild": "1.0 x"}])

    (row,) = store.usage_rows(today)
    assert row["egressBytes"] == 350
    assert row["connections"] == 2
    assert row["lastBuild"] == "1.0 x"
    assert row["firstSeenAt"] == 1_700_000_000_000

    totals = store.usage_totals(days=1, by="account")
    assert totals[0]["accountId"] == "acc_1"
    assert totals[0]["egressBytes"] == 350
    assert day_floor(1) == today
    store.close()


async def test_stats_reports_today_after_a_frame_goes_out(client, provisioned):
    """整条链路：一帧发给手机 → /stats 的 today 立刻有数（含还没冲盘的那部分）。"""
    claim = await client.post("/pair/claim", json={
        "pairCode": provisioned["code"]["code"], "deviceName": "iPhone",
        "deviceModel": "iPhone17,1", "appVersion": "1.0 20260921.1036",
    })
    device = await claim.json()
    device_ws = await client.ws_connect(
        f"/link/device?agentId={device['agentId']}",
        headers={"Authorization": f"Bearer {device['deviceToken']}"})
    agent_ws = await client.ws_connect(
        f"/link/agent?agentId={provisioned['agent']['agentId']}",
        headers={"Authorization": f"Bearer {provisioned['agent']['agentSecret']}"})
    await asyncio.sleep(0.1)

    payload = "x" * 4096
    await agent_ws.send_json({"t": "chunk", "deviceId": device["deviceId"], "data": payload})
    await asyncio.sleep(0.2)

    stats = await (await client.get("/stats")).json()
    today = stats["today"]
    assert today["day"] == local_day()
    assert today["totalEgressBytes"] >= len(payload)
    (row,) = [item for item in today["devices"] if item["deviceId"] == device["deviceId"]]
    assert row["accountId"] == provisioned["account"]["accountId"]
    assert row["connections"] >= 1
    assert today["accounts"][0]["egressBytes"] >= len(payload)

    await device_ws.close()
    await agent_ws.close()
