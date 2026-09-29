"""C-04：撤销对账（臂 1）与「连上时告知」（臂 2）。

`admin.py` 只写库、不碰 relay——撤销要真的落到在线世界（socket 关掉、连接器
放下 `$events` 值班流），只能由 relay 自己对账。这里用真 `Store`（临时库）+
真 `RelayHub`，但**不启进程**：F1/F2 的单元断言要的是 hub 的判据，真进程那部分
由 `test_revoke_reconcile_e2e.py` 覆盖。
"""

from __future__ import annotations

import asyncio
import logging

import pytest

import hub as hub_module
from hub import DeviceLink, Limits, RelayHub
from store import Store


class FakeWS:
    """A WebSocket that only records what the hub sent and when it closed.

    Frames are queued by ``Link.enqueue_frame`` and only reach here once the
    pump task is started, so the helpers below ``start()`` the link and yield
    the loop once before reading :attr:`sent`.
    """

    def __init__(self):
        self.sent: list[dict] = []
        self.closed_with: tuple[int, str] | None = None

    async def send_str(self, text: str) -> None:
        import json as _json
        self.sent.append(_json.loads(text))

    async def close(self, code=1000, message=b"") -> None:
        if isinstance(message, bytes):
            message = message.decode("utf-8", "replace")
        self.closed_with = (code, message)


async def drain(*links) -> None:
    """Start the given links' pumps and let everything already queued land."""
    for link in links:
        link.start()
    await asyncio.sleep(0)
    await asyncio.sleep(0)


def frames(ws: FakeWS, kind: str) -> list[dict]:
    return [frame for frame in ws.sent if frame.get("t") == kind]


@pytest.fixture
def store(tmp_path) -> Store:
    instance = Store(str(tmp_path / "state.db"))
    yield instance
    instance.close()


def provision(store: Store) -> dict:
    account = store.create_account("ops")
    agent = store.register_agent(account["accountId"], "mac")
    code = store.mint_pair_code(agent["agentId"], ttl_ms=60_000)
    return {"account": account, "agent": agent, "code": code}


def claim(store: Store, provisioned: dict, name: str = "iPhone") -> dict:
    code = store.mint_pair_code(provisioned["agent"]["agentId"], ttl_ms=60_000)
    return store.claim_pair_code(code["code"], device_name=name)


def make_hub(store: Store, *, interval: float | None = None) -> RelayHub:
    hub = RelayHub(store, logger=logging.getLogger("relay.test"), limits=Limits())
    if interval is not None:
        hub.revoked_reconcile_interval = interval
    return hub


async def attach_device(hub: RelayHub, row: dict) -> tuple[DeviceLink, FakeWS]:
    ws = FakeWS()
    link = await hub.attach_device(row, ws)
    return link, ws


# ── F1 单元：`revoked_ids_among` ────────────────────────────────────────────

def test_revoked_ids_among_returns_only_the_revoked_ones(store):
    provisioned = provision(store)
    live = claim(store, provisioned, "live")
    dead = claim(store, provisioned, "dead")
    store.revoke_device(dead["deviceId"])

    assert store.revoked_ids_among([live["deviceId"], dead["deviceId"]]) == {dead["deviceId"]}


def test_revoked_ids_among_ignores_unknown_and_empty_input(store):
    provisioned = provision(store)
    alive = claim(store, provisioned)
    assert store.revoked_ids_among([]) == set()
    assert store.revoked_ids_among(["dev_nope"]) == set()
    assert store.revoked_ids_among([alive["deviceId"], "dev_nope"]) == set()


def test_revoked_ids_among_deduplicates(store):
    provisioned = provision(store)
    dead = claim(store, provisioned)
    store.revoke_device(dead["deviceId"])
    assert store.revoked_ids_among([dead["deviceId"]] * 5) == {dead["deviceId"]}


def test_revoked_ids_among_survives_more_ids_than_sqlite_can_bind(store):
    """501 ids would blow SQLite's historical 999-variable ceiling if unchunked."""
    provisioned = provision(store)
    dead = claim(store, provisioned)
    store.revoke_device(dead["deviceId"])
    ids = [f"dev_pad_{i}" for i in range(600)] + [dead["deviceId"]]
    assert store.revoked_ids_among(ids) == {dead["deviceId"]}


# ── F1 单元：`reconcile_revoked_devices` ────────────────────────────────────

async def test_reconcile_detaches_a_revoked_device_and_returns_its_id(store):
    provisioned = provision(store)
    device = claim(store, provisioned)
    hub = make_hub(store)
    link, ws = await attach_device(hub, store.device_by_id(device["deviceId"]))
    store.revoke_device(device["deviceId"])

    detached = await hub.reconcile_revoked_devices()
    await asyncio.gather(*list(hub._detach_tasks))

    assert detached == [device["deviceId"]]
    assert device["deviceId"] not in hub._devices
    assert ws.closed_with is not None, "the socket must actually be closed"


async def test_reconcile_leaves_a_healthy_device_alone(store):
    """防误踢：在线但未撤销的设备，一个字节都不许动。"""
    provisioned = provision(store)
    device = claim(store, provisioned)
    hub = make_hub(store)
    link, ws = await attach_device(hub, store.device_by_id(device["deviceId"]))

    assert await hub.reconcile_revoked_devices() == []
    await asyncio.gather(*list(hub._detach_tasks), return_exceptions=True)

    assert hub._devices.get(device["deviceId"]) is link
    assert ws.closed_with is None


async def test_reconcile_does_not_touch_the_store_when_nobody_is_online(store, monkeypatch):
    hub = make_hub(store)
    calls: list[list[str]] = []

    def spy(device_ids):
        calls.append(list(device_ids))
        return set()

    monkeypatch.setattr(store, "revoked_ids_among", spy)
    assert await hub.reconcile_revoked_devices() == []
    assert calls == [], "an empty live table must not cause a query"


async def test_reconcile_tells_the_agent_with_reason_revoked(store):
    provisioned = provision(store)
    device = claim(store, provisioned)
    hub = make_hub(store)
    agent_ws = FakeWS()
    agent_link = await hub.attach_agent(provisioned["agent"], agent_ws)
    await attach_device(hub, store.device_by_id(device["deviceId"]))
    store.revoke_device(device["deviceId"])

    await hub.reconcile_revoked_devices()
    await asyncio.gather(*list(hub._detach_tasks))
    await drain(agent_link)

    detaches = frames(agent_ws, "deviceDetach")
    assert detaches and detaches[-1]["reason"] == "revoked"
    assert detaches[-1]["deviceId"] == device["deviceId"]


# ── F1 单元：循环不能死 ─────────────────────────────────────────────────────

async def test_one_bad_tick_does_not_kill_the_reconcile_loop(store):
    provisioned = provision(store)
    device = claim(store, provisioned)
    hub = make_hub(store, interval=0.01)
    link, ws = await attach_device(hub, store.device_by_id(device["deviceId"]))
    store.revoke_device(device["deviceId"])

    boom = {"times": 0}
    real = store.revoked_ids_among

    def flaky(device_ids):
        boom["times"] += 1
        if boom["times"] == 1:
            raise RuntimeError("disk on fire")
        return real(device_ids)

    store.revoked_ids_among = flaky
    hub.start_revoke_reconcile()
    try:
        for _ in range(200):
            await asyncio.sleep(0.01)
            if device["deviceId"] not in hub._devices:
                break
        assert device["deviceId"] not in hub._devices, "the loop died after one failure"
        assert boom["times"] >= 2
    finally:
        await hub.shutdown()


async def test_shutdown_cancels_the_reconcile_task(store):
    hub = make_hub(store, interval=0.01)
    hub.start_revoke_reconcile()
    assert hub._reconcile_task is not None
    await hub.shutdown()
    assert hub._reconcile_task is None


async def test_start_revoke_reconcile_is_idempotent_and_respects_zero(store):
    hub = make_hub(store, interval=0.01)
    hub.start_revoke_reconcile()
    first = hub._reconcile_task
    hub.start_revoke_reconcile()
    assert hub._reconcile_task is first
    await hub.shutdown()

    off = make_hub(store, interval=0)
    off.start_revoke_reconcile()
    assert off._reconcile_task is None
    await off.shutdown()


def test_reconcile_interval_falls_back_to_five_on_garbage(monkeypatch):
    monkeypatch.setenv("DLP_REVOKE_RECONCILE_S", "not-a-number")
    assert hub_module._reconcile_interval_from_env() == 5.0
    monkeypatch.setenv("DLP_REVOKE_RECONCILE_S", "0.25")
    assert hub_module._reconcile_interval_from_env() == 0.25
    monkeypatch.delenv("DLP_REVOKE_RECONCILE_S")
    assert hub_module._reconcile_interval_from_env() == 5.0


# ── F2 单元：臂 2 ───────────────────────────────────────────────────────────

async def test_attach_agent_tells_it_about_revoked_devices_only(store):
    provisioned = provision(store)
    dead = claim(store, provisioned, "dead")
    alive = claim(store, provisioned, "alive")
    store.revoke_device(dead["deviceId"])

    hub = make_hub(store)
    ws = FakeWS()
    link = await hub.attach_agent(provisioned["agent"], ws)
    await drain(link)

    detaches = frames(ws, "deviceDetach")
    assert [frame["deviceId"] for frame in detaches] == [dead["deviceId"]]
    assert all(frame["reason"] == "revoked" for frame in detaches)
    assert alive["deviceId"] not in {frame["deviceId"] for frame in detaches}


async def test_attach_agent_says_nothing_when_nothing_is_gone(store):
    provisioned = provision(store)
    claim(store, provisioned)

    hub = make_hub(store)
    ws = FakeWS()
    link = await hub.attach_agent(provisioned["agent"], ws)
    await drain(link)

    assert frames(ws, "deviceDetach") == []


async def test_attach_agent_does_not_mention_another_agents_devices(store):
    mine = provision(store)
    theirs = provision(store)
    stranger = claim(store, theirs, "stranger")
    store.revoke_device(stranger["deviceId"])

    hub = make_hub(store)
    ws = FakeWS()
    link = await hub.attach_agent(mine["agent"], ws)
    await drain(link)

    assert frames(ws, "deviceDetach") == []


async def test_attach_agent_tells_it_about_expired_devices(store):
    """365 天过期的设备也是"回不来了"（`device_by_token` 同样拒掉）。"""
    provisioned = provision(store)
    old = claim(store, provisioned, "old")
    store._write("UPDATE devices SET expiresAt=? WHERE deviceId=?",
                 (1, old["deviceId"]))

    hub = make_hub(store)
    ws = FakeWS()
    link = await hub.attach_agent(provisioned["agent"], ws)
    await drain(link)

    detaches = frames(ws, "deviceDetach")
    assert [frame["deviceId"] for frame in detaches] == [old["deviceId"]]


async def test_attach_agent_never_detaches_an_expired_device_that_is_online(store):
    """未撤销、但令牌已过期的**在线**设备不许被打断——那是产品行为变更。

    它此刻的 socket 不做重新鉴权，仍然能用；踢它等于把"去年配的手机"当场掐掉。
    过期的残留只在它不在线时由臂 2 收。
    """
    provisioned = provision(store)
    old = claim(store, provisioned, "old")
    hub = make_hub(store)
    link, ws = await attach_device(hub, store.device_by_id(old["deviceId"]))
    store._write("UPDATE devices SET expiresAt=? WHERE deviceId=?", (1, old["deviceId"]))

    agent_ws = FakeWS()
    agent_link = await hub.attach_agent(provisioned["agent"], agent_ws)
    await drain(agent_link)

    assert frames(agent_ws, "deviceDetach") == [], \
        "an online device must not be dropped for expiry alone"
    assert hub._devices.get(old["deviceId"]) is link
    assert ws.closed_with is None


async def test_attach_agent_still_re_adopts_live_devices(store):
    """臂 2 是**追加**，不许影响既有的 re-adopt。"""
    provisioned = provision(store)
    device = claim(store, provisioned, "live")
    hub = make_hub(store)
    await attach_device(hub, store.device_by_id(device["deviceId"]))

    agent_ws = FakeWS()
    link = await hub.attach_agent(provisioned["agent"], agent_ws)
    await drain(link)

    assert link.devices.get(device["deviceId"]) is not None
    assert frames(agent_ws, "deviceAttach")
