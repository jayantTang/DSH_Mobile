"""Per-device pacing, the daily allowance, and the per-agent device budget.

These three exist because the relay runs on a **fixed-bandwidth** host that every
device shares:

* pacing stops one device's large frames (ten screenshots is 27 MB) from
  occupying the whole pipe and slowing everyone else down;
* the daily allowance stops one device from doing that all day;
* the device budget stops one leaked token from filling the relay with sockets.

The tests below fix the *semantics* — a device that is merely slow keeps its
frames, a device that is over quota is told why, and a reconnect does not count
against its own budget — because those are the parts a later refactor could
quietly break.
"""

from __future__ import annotations

import asyncio
import json
import time

import pytest

import dlp
from hub import (
    CLOSE_QUOTA_EXCEEDED,
    DailyQuota,
    DeviceLimitReached,
    Limits,
    RelayHub,
    TokenBucket,
)


class FakeStore:
    def touch_agent(self, *_args, **_kwargs):
        return None


class FakeWS:
    """Counts what was sent so a test can reason about order and volume."""

    def __init__(self):
        self.sent: list[str] = []
        self.bytes = 0

    async def send_str(self, text):
        self.sent.append(text)
        self.bytes += len(text.encode("utf-8"))

    async def close(self, code=1000, message=b""):
        self.closed_with = (code, message)
        return None


# ── TokenBucket ─────────────────────────────────────────────────────────────

def test_bucket_starts_full_so_a_normal_turn_never_waits():
    bucket = TokenBucket(rate=1000, burst=10_000)
    assert bucket.take(9_000) == 0.0


def test_bucket_paces_only_what_exceeds_the_burst():
    bucket = TokenBucket(rate=1000, burst=1_000)
    assert bucket.take(1_000) == 0.0          # exactly the burst: no wait
    # The next 1000 bytes are one second of allowance away.
    assert bucket.take(1_000) == pytest.approx(1.0, abs=0.05)


def test_a_disabled_bucket_never_waits():
    bucket = TokenBucket(rate=0)
    assert bucket.take(50 * 1024 * 1024) == 0.0
    assert bucket.enabled is False


def test_bucket_refills_over_time():
    bucket = TokenBucket(rate=1000, burst=1000)
    assert bucket.take(1000) == 0.0
    wait = bucket.take(500)
    assert wait == pytest.approx(0.5, abs=0.05)


# ── DailyQuota ──────────────────────────────────────────────────────────────

def test_quota_allows_up_to_the_limit_then_refuses():
    quota = DailyQuota(limit=1_000)
    assert quota.charge(600) is True
    assert quota.charge(400) is True           # exactly the limit is still fine
    assert quota.charge(1) is False
    assert quota.remaining() == 0


def test_quota_resets_on_the_next_utc_day():
    day = 20_000
    quota = DailyQuota(limit=1_000, now=day * 86_400)
    assert quota.charge(1_000) is True
    assert quota.charge(1) is False
    # One second past the boundary, the same device may send again.
    assert quota.charge(500, now=(day + 1) * 86_400 + 1) is True
    assert quota.used == 500


def test_a_disabled_quota_reports_unlimited():
    quota = DailyQuota(limit=0)
    assert quota.charge(10**9) is True
    assert quota.remaining() == -1


# ── RelayHub: pacing end to end ─────────────────────────────────────────────

async def make_hub(**limits):
    hub = RelayHub(FakeStore(), limits=Limits(**limits))
    agent_ws, device_ws = FakeWS(), FakeWS()
    agent = await hub.attach_agent({"agentId": "a1", "accountId": "ac", "name": "pc"}, agent_ws)
    device = await hub.attach_device(
        {"deviceId": "d1", "agentId": "a1", "name": "iPhone", "model": "iPhone17,1"}, device_ws)
    agent.start()
    device.start()
    await asyncio.sleep(0)                     # let the attach frames drain
    return hub, agent, device, device_ws


async def test_a_device_over_its_rate_still_receives_every_frame():
    hub, agent, _device, ws = await make_hub(device_bytes_per_second=50_000)
    payload = "x" * 200_000                    # 200 KB against a 50 KB/s allowance
    await hub.route_from_agent(agent, {"t": "item", "id": "s1", "deviceId": "d1",
                                       "value": {"type": "text-delta", "text": payload}})
    for _ in range(60):                        # pacing sleeps in the writer
        if ws.bytes:
            break
        await asyncio.sleep(0.1)
    assert ws.bytes > 0, "被限速的设备仍然应当收到帧，只是慢一些"
    await hub.shutdown()


async def test_a_long_frame_is_charged_against_the_rate_once():
    """A frame over the chunk size used to pay for itself twice.

    The paced writer charged the whole frame, then charged every chunk again, so
    the bucket went negative by twice the frame's size and a 20 Mbit allowance
    delivered about 10. The wait for a 700 KB frame against a 500 KB/s allowance
    with a 500 KB burst is (700-500)/500 = 0.4 s; charging twice made it 1.8 s.
    """
    hub, agent, device, ws = await make_hub(device_bytes_per_second=500_000)
    payload = "x" * 700_000                     # over _CHUNK_CHARS (512 KB)
    await hub.route_from_agent(agent, {"t": "item", "id": "s1", "deviceId": "d1",
                                       "value": {"type": "text-delta", "text": payload}})
    for _ in range(80):
        if ws.bytes >= 700_000:
            break
        await asyncio.sleep(0.1)
    assert ws.bytes >= 700_000, "限速路径必须把整帧发完"
    assert device.paced_seconds == pytest.approx(0.4, abs=0.2), (
        f"整帧只应记一次账，实际等了 {device.paced_seconds:.2f} 秒"
    )
    await hub.shutdown()


async def test_pacing_is_per_device_not_global():
    hub = RelayHub(FakeStore(), limits=Limits(device_bytes_per_second=50_000))
    agent = await hub.attach_agent({"agentId": "a1", "accountId": "ac", "name": "pc"}, FakeWS())
    fast_ws = FakeWS()
    await hub.attach_device({"deviceId": "d1", "agentId": "a1", "name": "one"}, fast_ws)
    await hub.attach_device({"deviceId": "d2", "agentId": "a1", "name": "two"}, FakeWS())
    agent.start()

    # Push one device over its allowance and leave the other idle.
    device = hub._devices["d1"]
    device.bucket.take(int(device.bucket.burst))
    wait = device.bucket.take(1)
    assert wait > 0
    assert hub._devices["d2"].bucket.take(1_000) == 0.0
    await hub.shutdown()


# ── RelayHub: daily allowance ───────────────────────────────────────────────

async def test_a_device_over_its_daily_allowance_is_closed_with_a_reason():
    hub, agent, device, ws = await make_hub(device_daily_bytes=50_000)
    big = {"t": "item", "id": "s1", "deviceId": "d1", "value": {"type": "text-delta", "text": "y" * 60_000}}
    await hub.route_from_agent(agent, big)
    for _ in range(40):
        if device.closed:
            break
        await asyncio.sleep(0.05)
    assert device.closed, "超过每日额度的设备应当被断开"
    assert device.reason == "daily quota"
    # …and it is told why, in a frame that still fits in the same allowance.
    assert any('"quota/device-daily"' in text for text in ws.sent), ws.sent[-1][:200]
    await hub.shutdown()


async def test_the_allowance_is_charged_on_what_goes_to_the_phone():
    hub, agent, device, _ws = await make_hub(device_daily_bytes=10**9)
    # The attach frames have already gone out; measure the delta, not the total.
    before, quota_before = device.egress_bytes, device.quota.used
    frame = {"t": "item", "id": "s1", "deviceId": "d1", "value": {"type": "text-delta", "text": "z" * 1_000}}
    expected = len(dlp.encode_frame(dlp.strip_device_id(frame)).encode("utf-8"))
    await hub.route_from_agent(agent, frame)
    # The allowance is charged on the enqueue path, the egress counter in the
    # writer: wait for both, since they are deliberately different moments.
    for _ in range(40):
        if device.quota.used > quota_before and device.egress_bytes > before:
            break
        await asyncio.sleep(0.05)
    assert device.quota.used - quota_before == expected
    assert device.egress_bytes - before == expected
    # The agent's total is the sum of its devices', for the operator's report.
    assert agent.egress_bytes >= expected
    await hub.shutdown()


# ── RelayHub: per-agent device budget ───────────────────────────────────────

async def test_device_budget_refuses_the_next_device():
    hub = RelayHub(FakeStore(), limits=Limits(max_devices_per_agent=1))
    await hub.attach_agent({"agentId": "a1", "accountId": "ac", "name": "pc"}, FakeWS())
    await hub.attach_device({"deviceId": "d1", "agentId": "a1", "name": "one"}, FakeWS())
    with pytest.raises(DeviceLimitReached):
        await hub.attach_device({"deviceId": "d2", "agentId": "a1", "name": "two"}, FakeWS())
    await hub.shutdown()


async def test_a_reconnect_does_not_count_against_its_own_budget():
    """The phone reconnecting must not be told the host is full.

    A reconnect can arrive while the relay is still tearing the previous socket
    down, so counting by device id — not by socket — is what keeps a phone from
    locking itself out.
    """
    hub = RelayHub(FakeStore(), limits=Limits(max_devices_per_agent=1))
    await hub.attach_agent({"agentId": "a1", "accountId": "ac", "name": "pc"}, FakeWS())
    await hub.attach_device({"deviceId": "d1", "agentId": "a1", "name": "one"}, FakeWS())
    again = await hub.attach_device({"deviceId": "d1", "agentId": "a1", "name": "one"}, FakeWS())
    assert again.device_id == "d1"
    await hub.shutdown()


async def test_an_unlimited_budget_accepts_many_devices():
    hub = RelayHub(FakeStore(), limits=Limits(max_devices_per_agent=0))
    await hub.attach_agent({"agentId": "a1", "accountId": "ac", "name": "pc"}, FakeWS())
    for index in range(25):
        await hub.attach_device({"deviceId": f"d{index}", "agentId": "a1", "name": "x"}, FakeWS())
    assert hub.device_count("a1") == 25
    await hub.shutdown()


# ── Observability ───────────────────────────────────────────────────────────

async def test_traffic_report_ranks_devices_by_egress():
    hub, agent, _device, _ws = await make_hub()
    device_two = await hub.attach_device({"deviceId": "d2", "agentId": "a1", "name": "second"}, FakeWS())
    device_two.start()
    await hub.route_from_agent(agent, {"t": "item", "id": "s1", "deviceId": "d2",
                                       "value": {"type": "text-delta", "text": "q" * 5_000}})
    await hub.route_from_agent(agent, {"t": "item", "id": "s2", "deviceId": "d1",
                                       "value": {"type": "text-delta", "text": "q" * 500}})
    for _ in range(20):
        if len(hub.traffic()["devices"]) == 2 and hub.traffic()["devices"][1]["egressBytes"]:
            break
        await asyncio.sleep(0.05)
    report = hub.traffic()
    assert report["devices"][0]["deviceId"] == "d2"
    assert report["totalEgressBytes"] == sum(item["egressBytes"] for item in report["devices"])
    # The snapshot carries the same numbers, so /stats can show both views.
    assert {item["deviceId"] for item in hub.snapshot()["devices"]} == {"d1", "d2"}
    await hub.shutdown()


def test_limits_describe_hides_disabled_ones():
    described = Limits().describe()
    assert described["maxDevicesPerAgent"] is None
    assert described["deviceBytesPerSecond"] is None
    assert described["deviceDailyBytes"] is None
    configured = Limits(max_devices_per_agent=4, device_bytes_per_second=25_000,
                        device_daily_bytes=1024).describe()
    assert configured["maxDevicesPerAgent"] == 4
    assert configured["deviceBytesPerSecond"] == 25_000
    assert configured["deviceDailyBytes"] == 1024
