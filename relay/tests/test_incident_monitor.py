"""监控模块：按类别去重、限量、落盘，且永远不抛（2026-10-17 事故的"没人知道"部分）。

事故里 24 小时 143 次未处理异常、702 次连接器断开，一条告警都没有——用户不发反馈就
没人会去翻 systemd 日志。这里锁住四件事：

1. **新类别必报**，同类别的后续只累计次数（默认 24 小时静默），不会变成告警洪水。
2. **抖动算一类**：同一台电脑在窗口内断够次数才报，同一窗口只报一次。
3. **限量**：一小时/一天各有上限，被压掉的条数会带在下一条告警里。
4. **不抛、不拖转发**：目录写不了、状态文件坏了都只是少一条告警。
"""

from __future__ import annotations

import json

import pytest
from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer

import monitor as monitor_module
import relay as relay_module
from hub import Limits
from store import Store


def _clock() -> tuple[list[float], object]:
    now = [1_700_000_000.0]
    return now, (lambda: now[0])


def _records(alert_dir) -> list[dict]:
    path = alert_dir / "alerts.jsonl"
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def _boom(message: str = "boom") -> BaseException:
    """一个带真实 traceback 的异常（分类要看最内层位置）。"""
    try:
        raise ValueError(message)
    except ValueError as error:
        return error


def test_a_new_category_is_queued_and_repeats_are_only_counted(tmp_path):
    now, clock = _clock()
    monitor = monitor_module.IncidentMonitor(alert_dir=tmp_path / "alerts", clock=clock)
    error = _boom()

    monitor.note_exception(error, path="/link/agent")
    monitor.note_exception(_boom("again"), path="/link/agent")
    monitor.note_exception(_boom("third"), path="/link/agent")

    records = _records(tmp_path / "alerts")
    assert len(records) == 1, "同一类别的重复出现不该每来一条就发一封"
    assert records[0]["count"] == 1, "发出那一刻的次数"
    assert records[0]["newCategory"] is True
    assert "ValueError" in records[0]["title"]
    assert records[0]["details"]["path"] == "/link/agent"

    # 后面的两次只累计在状态里（下次同类放行时才会带上新的总数）。
    monitor.flush()
    state = json.loads((tmp_path / "alerts" / "state.json").read_text(encoding="utf-8"))
    assert state["categories"][records[0]["key"]]["count"] == 3

    # 24 小时后同类再来一次：重新上报，并且带上"又出现了几次"。
    now[0] += 24 * 3600 + 1
    monitor.note_exception(_boom("old"), path="/link/agent")
    records = _records(tmp_path / "alerts")
    assert len(records) == 2
    assert records[1]["newCategory"] is False
    assert records[1]["count"] == 4


def test_a_different_code_location_is_a_different_category(tmp_path):
    monitor = monitor_module.IncidentMonitor(alert_dir=tmp_path / "alerts",
                                            clock=lambda: 1_700_000_000.0)

    def alpha():
        raise KeyError("first place")

    def beta():
        raise KeyError("second place")

    for producer in (alpha, beta):
        try:
            producer()
        except KeyError as error:
            monitor.note_exception(error, path="/x")

    records = _records(tmp_path / "alerts")
    assert len(records) == 2, "换个位置就算新类别——'没见过的错误'才是要被告知的事"
    keys = {record["key"] for record in records}
    assert len(keys) == 2


def test_the_hourly_cap_suppresses_and_reports_what_it_dropped(tmp_path):
    now, clock = _clock()
    monitor = monitor_module.IncidentMonitor(alert_dir=tmp_path / "alerts", clock=clock,
                                            max_alerts_per_hour=2, max_alerts_per_day=10)

    def raise_at(number):
        if number == 0:
            raise KeyError("a")
        if number == 1:
            raise IndexError("b")
        if number == 2:
            raise TypeError("c")
        raise RuntimeError("d")

    for index in range(3):
        try:
            raise_at(index)
        except Exception as error:  # noqa: BLE001
            monitor.note_exception(error, path="/x")
    assert len(_records(tmp_path / "alerts")) == 2, "一小时上限必须生效"

    # 被打掉的那条会在下一条放行的告警里报出来（不是静默丢弃）。
    now[0] += 3600 + 1
    try:
        raise_at(3)
    except Exception as error:  # noqa: BLE001
        monitor.note_exception(error, path="/x")
    records = _records(tmp_path / "alerts")
    assert len(records) == 3
    assert records[-1]["suppressedSinceLastAlert"] == 1


def test_flapping_is_reported_once_per_window(tmp_path):
    now, clock = _clock()
    monitor = monitor_module.IncidentMonitor(alert_dir=tmp_path / "alerts", clock=clock,
                                            flap_window_s=300, flap_threshold=5)

    for _ in range(4):
        monitor.note_agent_disconnect("agt_1", name="Windows-PC")
        now[0] += 10
    assert _records(tmp_path / "alerts") == [], "只断 4 次不算抖"

    monitor.note_agent_disconnect("agt_1", name="Windows-PC")
    records = _records(tmp_path / "alerts")
    assert len(records) == 1
    assert records[0]["kind"] == "flap"
    assert records[0]["details"]["disconnectsInWindow"] == 5

    # 同一个窗口里再断几次：不重复打扰。
    for _ in range(3):
        now[0] += 10
        monitor.note_agent_disconnect("agt_1", name="Windows-PC")
    assert len(_records(tmp_path / "alerts")) == 1

    # 过了窗口又重新计数。
    now[0] += 400
    for _ in range(5):
        now[0] += 10
        monitor.note_agent_disconnect("agt_1", name="Windows-PC")
    assert len(_records(tmp_path / "alerts")) == 2


def test_surrogate_samples_are_capped_per_day(tmp_path):
    monitor = monitor_module.IncidentMonitor(alert_dir=tmp_path / "alerts",
                                            clock=lambda: 1_700_000_000.0,
                                            surrogate_samples_per_day=2,
                                            max_alerts_per_hour=100, max_alerts_per_day=100)

    class Damage:
        def as_details(self):
            return {"count": 1, "totalChars": 10, "firstIndex": 9,
                    "trailingChars": 0, "kinds": "high", "context": "尾巴 "}

    for _ in range(3):
        monitor.note_unpaired_surrogates(agent_id="agt_1", device_id="dev_1",
                                         frame_type="item", damage=Damage())

    records = [r for r in _records(tmp_path / "alerts") if r["key"] == "surrogate:unpaired"]
    assert len(records) == 1, "同一类别只报一条"
    assert records[0]["details"]["sample"] == "1/2"
    # 单条告警里就带着定位根因的字段。
    assert records[0]["details"]["trailingChars"] == 0


def test_state_survives_a_restart(tmp_path):
    alert_dir = tmp_path / "alerts"
    first = monitor_module.IncidentMonitor(alert_dir=alert_dir, clock=lambda: 1_700_000_000.0)
    first.note_exception(_boom(), path="/x")
    assert len(_records(alert_dir)) == 1

    # 重启（新进程、新实例）之后同类不该再报一次。
    second = monitor_module.IncidentMonitor(alert_dir=alert_dir, clock=lambda: 1_700_000_001.0)
    second.note_exception(_boom("after restart"), path="/x")
    assert len(_records(alert_dir)) == 1


def test_disabled_monitor_is_a_no_op(tmp_path):
    monitor = monitor_module.IncidentMonitor(alert_dir=None)
    assert monitor.enabled is False
    monitor.note_exception(_boom(), path="/x")
    monitor.note_agent_disconnect("agt_1")
    monitor.flush()
    monitor.save_state()
    assert list(tmp_path.iterdir()) == []


def test_a_broken_alert_directory_never_raises(tmp_path):
    """告警目录被占成一个普通文件时：少一条告警，转发照旧。"""
    blocker = tmp_path / "alerts"
    blocker.write_text("not a directory", encoding="utf-8")
    monitor = monitor_module.IncidentMonitor(alert_dir=blocker)
    monitor.note_exception(_boom(), path="/x")   # 不抛就是通过
    monitor.note_agent_disconnect("agt_1")
    monitor.flush()


# ── 中间件：真实 app 里的未处理异常 ─────────────────────────────────────────

async def _monitored_app(tmp_path):
    store = Store(str(tmp_path / "state.db"))
    monitor = monitor_module.IncidentMonitor(alert_dir=tmp_path / "alerts")
    app = relay_module.create_app(store=store, limits=Limits(queue_depth=8),
                                  pair_ttl_ms=60_000, monitor=monitor)

    async def explode(_request):
        raise ValueError("handler 里没接住的异常")

    app.router.add_get("/test/explode", explode)
    return store, app


async def test_the_middleware_records_an_unhandled_exception(tmp_path):
    store, app = await _monitored_app(tmp_path)
    try:
        async with TestClient(TestServer(app)) as client:
            response = await client.get("/test/explode")
            assert response.status == 500
    finally:
        store.close()

    records = _records(tmp_path / "alerts")
    assert len(records) == 1
    assert records[0]["kind"] == "exception"
    assert records[0]["details"]["path"] == "/test/explode"
    assert records[0]["details"]["source"] == "http"


async def test_the_middleware_ignores_normal_http_errors(tmp_path):
    """404/401 这类是协议的一部分，不是事故。"""
    store, app = await _monitored_app(tmp_path)
    try:
        async with TestClient(TestServer(app)) as client:
            assert (await client.get("/no/such/route")).status == 404
            assert (await client.get("/link/agent")).status in (401, 403)
    finally:
        store.close()
    assert _records(tmp_path / "alerts") == []


async def test_agent_disconnects_are_counted_by_the_hub(tmp_path):
    """hub 的 detach 会把断开报给监控——抖动检测的数据源。"""
    store = Store(str(tmp_path / "state.db"))
    alerts = tmp_path / "alerts"
    monitor = monitor_module.IncidentMonitor(alert_dir=alerts, flap_threshold=2,
                                            flap_window_s=300)
    app = relay_module.create_app(store=store, limits=Limits(queue_depth=8),
                                  pair_ttl_ms=60_000, monitor=monitor)
    try:
        account = store.create_account("flapper")
        agent = store.register_agent(account["accountId"], "mac")
        async with TestClient(TestServer(app)) as client:
            for _ in range(2):
                ws = await client.ws_connect(f"/link/agent?agentId={agent['agentId']}",
                                             headers={"Authorization": f"Bearer {agent['agentSecret']}"})
                await ws.close()
    finally:
        store.close()

    records = [r for r in _records(alerts) if r["kind"] == "flap"]
    assert len(records) == 1
    assert records[0]["details"]["agentId"] == agent["agentId"]


def test_describe_is_operator_facing_only(tmp_path):
    monitor = monitor_module.IncidentMonitor(alert_dir=tmp_path / "alerts")
    described = monitor.describe()
    assert described["enabled"] is True
    assert described["alertDir"] == str(tmp_path / "alerts")
    assert set(described) >= {"renotifyHours", "maxPerHour", "flapThreshold"}
