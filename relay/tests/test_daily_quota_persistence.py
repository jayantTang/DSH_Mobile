"""The daily allowance must survive a reconnect and a relay restart.

The allowance is 2 GB/day per device, and its whole purpose is to cap what one
device can pull through a **fixed-bandwidth, metered** host in a day. A budget
that is only counted in the live ``DeviceLink`` cannot do that job: a phone that
reconnects — on a network change, after a background suspension, on a relay
restart — silently gets a fresh allowance. The cap then bounds a *connection*
rather than a *day*, which is not what it says.

What is pinned here:

* the count is per ``(deviceId, local day)`` and comes from ``usageDaily``, so it
  is the same number the operator's ``admin.py usage`` report shows;
* reconnecting adds to it instead of resetting it;
* the day boundary is the **local** one, and the allowance and the accounting use
  the *same* function — the two used to disagree (``store.local_day`` vs a UTC
  day computed inside ``DailyQuota``), which meant "today's usage" and "today's
  allowance" described different days;
* going over is reported to the client as a DLP ``error`` frame before the socket
  closes, not as a silent drop.
"""

from __future__ import annotations

import asyncio
import time

import pytest

import dlp
import hub as hub_module
import store as store_module
from hub import CLOSE_QUOTA_EXCEEDED, DailyQuota, Limits, RelayHub
from store import Store, local_day


class FakeWS:
    def __init__(self):
        self.sent: list[str] = []
        self.closed_with = None

    async def send_str(self, text):
        self.sent.append(text)

    async def close(self, code=1000, message=b""):
        self.closed_with = (code, message)

    def frames(self):
        return [json.loads(text) for text in self.sent if text.startswith("{")]


import json  # noqa: E402  (kept next to its only user)


class RecordingStore:
    """A store that answers ``usage_rows`` from a dict a test controls."""

    def __init__(self, used: int = 0, day: int | None = None):
        self.used = used
        self.day = day if day is not None else local_day()
        self.queries: list[int] = []

    def usage_rows(self, day):
        self.queries.append(day)
        if day != self.day:
            return []
        return [{
            "day": day, "deviceId": "d1", "agentId": "a1", "accountId": "ac",
            "egressBytes": self.used, "connections": 1, "lastBuild": None,
            "firstSeenAt": 1, "lastSeenAt": 2,
        }]

    def add_usage(self, entries):
        for entry in entries:
            if entry["deviceId"] == "d1":
                self.used += entry["egressBytes"]
        return len(list(entries))

    def touch_agent(self, *_a, **_k):
        return None


async def attach(hub: RelayHub, device_id="d1"):
    if "a1" not in hub.agents:
        await hub.attach_agent({"agentId": "a1", "accountId": "ac", "name": "pc"}, FakeWS())
    ws = FakeWS()
    link = await hub.attach_device(
        {"deviceId": device_id, "agentId": "a1", "name": "iPhone"}, ws)
    link.start()
    await asyncio.sleep(0)
    return link, ws


# ── the core judgement: a reconnect does not reset the allowance ─────────────

async def test_a_reconnect_does_not_reset_the_daily_allowance():
    """The core case. Before CI-03 this was a fresh 50 KB per connection."""
    store = RecordingStore(used=45_000)
    hub = RelayHub(store, limits=Limits(device_daily_bytes=50_000))

    first, _ = await attach(hub)
    assert first.quota.limit == 50_000
    assert first.quota.used == 45_000, "额度基线必须来自 usageDaily，不是 0"

    await hub.detach_device(first, reason="network changed")

    again, ws = await attach(hub)
    # The attach itself sends one `hostStatus` frame, so a fresh connection's
    # count is the baseline plus that frame — never just the frame.
    assert again.quota.used >= 45_000, "重连后额度不能被重置"
    assert again.quota.used < 46_000, "也不该凭空多出一整份额度"
    assert again.quota.remaining() <= 5_000

    # And it really refuses: 6 KB is now over the 5 KB that is left.
    agent = hub.agents["a1"]
    await hub.route_from_agent(agent, {
        "t": "item", "id": "s1", "deviceId": "d1",
        "value": {"type": "text-delta", "text": "x" * 6_000}})
    assert again.closed is True
    assert again.reason == "daily quota"
    await hub.shutdown()


async def test_a_device_that_already_spent_today_is_refused_immediately():
    """Reconnecting into a spent allowance must not buy a single frame."""
    store = RecordingStore(used=50_000)
    hub = RelayHub(store, limits=Limits(device_daily_bytes=50_000))
    link, ws = await attach(hub)
    assert link.quota.remaining() == 0

    agent = hub.agents["a1"]
    await hub.route_from_agent(agent, {
        "t": "item", "id": "s1", "deviceId": "d1",
        "value": {"type": "text-delta", "text": "y" * 100}})
    assert link.closed is True
    assert any('"quota/device-daily"' in text for text in ws.sent)
    await hub.shutdown()


async def test_a_relay_restart_keeps_the_days_usage():
    """A restart is the other way a per-link counter is lost."""
    store = RecordingStore(used=40_000)
    first_hub = RelayHub(store, limits=Limits(device_daily_bytes=50_000))
    link, _ = await attach(first_hub)
    assert link.quota.used == 40_000
    await first_hub.shutdown()

    # A brand-new hub over the same store: this is what a relay restart looks like.
    second_hub = RelayHub(store, limits=Limits(device_daily_bytes=50_000))
    link, _ = await attach(second_hub)
    assert link.quota.used >= 40_000, "重启后当日额度不能归零"
    assert link.quota.used < 41_000, "也不该凭空多出一整份额度"
    await second_hub.shutdown()


async def test_the_baseline_comes_from_the_local_day_row():
    """The allowance and the accounting must agree on what "today" is."""
    store = RecordingStore(used=1_000, day=local_day())
    hub = RelayHub(store, limits=Limits(device_daily_bytes=50_000))
    link, _ = await attach(hub)
    assert store.queries and store.queries[-1] == local_day()
    assert link.quota.day == local_day()
    await hub.shutdown()


async def test_yesterdays_usage_does_not_count_against_today():
    """The day boundary still resets — a stale row is not carried forward."""
    yesterday = int(time.strftime("%Y%m%d", time.localtime(time.time() - 86_400)))
    store = RecordingStore(used=50_000, day=yesterday)
    hub = RelayHub(store, limits=Limits(device_daily_bytes=50_000))
    link, _ = await attach(hub)
    assert link.quota.used == 0, "昨天用满不该影响今天"
    assert link.quota.remaining() == 50_000
    await hub.shutdown()


async def test_an_unlimited_allowance_does_not_query_the_store():
    """No limit configured means nothing to read; do not pay for it per connect."""
    store = RecordingStore()
    hub = RelayHub(store, limits=Limits(device_daily_bytes=0))
    link, _ = await attach(hub)
    assert store.queries == []
    assert link.quota.enabled is False
    await hub.shutdown()


async def test_bytes_this_connection_are_added_on_top_of_the_stored_baseline():
    """The stored row plus this connection's own traffic is the real total."""
    store = RecordingStore(used=10_000)
    hub = RelayHub(store, limits=Limits(device_daily_bytes=1_000_000))
    link, _ = await attach(hub)
    assert link.quota.used == 10_000

    agent = hub.agents["a1"]
    await hub.route_from_agent(agent, {
        "t": "item", "id": "s1", "deviceId": "d1",
        "value": {"type": "text-delta", "text": "z" * 2_000}})
    assert link.quota.used > 10_000, "本连接的增量要加上去"
    await hub.shutdown()


async def test_the_flushed_baseline_is_not_double_counted():
    """After a flush the bytes are in the row *and* still in `quota.used`.

    Re-reading at flush time would count them twice and cut a day short, so the
    baseline is taken once, at attach, and only ever grows in memory.
    """
    store = RecordingStore(used=0)
    hub = RelayHub(store, limits=Limits(device_daily_bytes=1_000_000))
    link, _ = await attach(hub)
    agent = hub.agents["a1"]
    await hub.route_from_agent(agent, {
        "t": "item", "id": "s1", "deviceId": "d1",
        "value": {"type": "text-delta", "text": "z" * 1_000}})
    used_before = link.quota.used
    await hub.flush_usage()
    # 冲盘会把"已经发出去的"写进库；额度里那份是"发出去 + 还没发出去的"，
    # 所以库里的数只会 ≤ 额度里的数，绝不会翻倍。
    assert 0 < store.used <= used_before, f"库里 {store.used} vs 额度 {used_before}"
    assert link.quota.used == used_before, "内存里不能因为冲盘再加一遍"
    await hub.shutdown()


# ── the client is told why ──────────────────────────────────────────────────

async def test_the_refusal_is_a_dlp_error_frame_before_the_close():
    """Not a silent drop: the phone needs to be able to say what happened."""
    store = RecordingStore(used=0)
    hub = RelayHub(store, limits=Limits(device_daily_bytes=1_000))
    link, ws = await attach(hub)
    agent = hub.agents["a1"]
    await hub.route_from_agent(agent, {
        "t": "item", "id": "s1", "deviceId": "d1",
        "value": {"type": "text-delta", "text": "w" * 5_000}})

    errors = [frame for frame in ws.frames() if frame.get("t") == "error"]
    assert errors, f"应当先收到 error 帧，实际收到 {ws.sent}"
    frame = errors[-1]
    assert frame["code"] == "quota/device-daily"
    assert frame["details"]["limitBytes"] == 1_000
    assert ws.closed_with[0] == CLOSE_QUOTA_EXCEEDED
    await hub.shutdown()


# ── pure DailyQuota semantics that must not regress ─────────────────────────

def test_daily_quota_can_be_seeded_with_a_baseline():
    quota = DailyQuota(limit=1_000, used=600, day=local_day())
    assert quota.remaining() == 400
    assert quota.charge(400) is True
    assert quota.charge(1) is False


def test_daily_quota_ignores_a_baseline_from_another_day():
    quota = DailyQuota(limit=1_000, used=600, day=20200101)
    assert quota.used == 0
    assert quota.remaining() == 1_000


def test_daily_quota_uses_the_same_day_function_as_the_accounting():
    """One definition of "today", not two."""
    quota = DailyQuota(limit=10)
    assert quota.day == local_day()
    assert hub_module.store_module.local_day is store_module.local_day


def test_a_negative_or_zero_limit_is_unlimited():
    assert DailyQuota(limit=0, used=10**9).remaining() == -1
    assert DailyQuota(limit=-5).enabled is False
