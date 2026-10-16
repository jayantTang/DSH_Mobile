"""设备记录卫生：计数看得见、超阈值有 WARNING。

背景（已确认的事实）：中转在**连接器每次连上时**会把该 agent 名下所有"永远回不来"的设备
逐条重放给它（`hub.py:_tell_agent_about_the_gone`，一条一帧 `deviceDetach`）。2026-10-12
库里攒了 2012 条历次用例/调试留下的已撤销记录，一次重连灌 2012 帧，把连接器的处理链堵住
（maintainers/ANALYSIS-20261012-connector-flap.md）。真删由
`tests/test_purge_revoked_devices.py` 覆盖；这里钉的是"在它爆掉之前看得见"：`/stats` 与
`admin.py device-hygiene` 的数字必须就是库里的数字，超过阈值必须真的落一条 WARNING。

这里**没有**改 hub 的广播逻辑：告警只是把原本写死的 200 换成可配置的阈值，重放的条数与
行为逐字不变（下面用"3 条死记录 = 3 帧"钉住）。
"""

from __future__ import annotations

import asyncio
import json
import logging

from hub import DEFAULT_DEAD_DEVICE_WARN_THRESHOLD, Limits, RelayHub
from store import Store


# ── helpers ─────────────────────────────────────────────────────────────────

def provision(store: Store, name: str = "mac") -> dict:
    account = store.create_account("ops")
    agent = store.register_agent(account["accountId"], name)
    return {"account": account, "agent": agent}


def claim(store: Store, provisioned: dict, name: str = "iPhone") -> dict:
    code = store.mint_pair_code(provisioned["agent"]["agentId"], ttl_ms=60_000)
    return store.claim_pair_code(code["code"], device_name=name)


def expire(store: Store, device_id: str) -> None:
    """把配对 TTL 推到过去（`device_by_token` 从此拒它，与已撤销等价）。"""
    store._write("UPDATE devices SET expiresAt=? WHERE deviceId=?", (1, device_id))


class FakeWS:
    """只记录 hub 送来的东西；`attach_agent` 拿它当连接器的 WebSocket。"""

    def __init__(self):
        self.sent: list[dict] = []

    async def send_str(self, text: str) -> None:
        self.sent.append(json.loads(text))

    async def close(self, code=1000, message=b"") -> None:
        return None


async def drain(*links) -> None:
    for link in links:
        link.start()
    await asyncio.sleep(0)
    await asyncio.sleep(0)


def make_hub(store: Store, **limits) -> RelayHub:
    return RelayHub(store, logger=logging.getLogger("relay.hygiene.test"),
                    limits=Limits(**limits))


# ── 计数：口径与库一致 ───────────────────────────────────────────────────────

def test_device_hygiene_splits_live_revoked_and_expired(store):
    provisioned = provision(store)
    live = claim(store, provisioned, "live")
    revoked = claim(store, provisioned, "revoked")
    expired = claim(store, provisioned, "expired")
    store.revoke_device(revoked["deviceId"])
    expire(store, expired["deviceId"])

    counts = store.device_hygiene()
    assert counts == {"total": 3, "live": 1, "revoked": 1, "expired": 1, "dead": 2}, \
        "在用/已撤销/已过期必须各算各的，死记录是前两类的并集"
    assert store.device_by_id(live["deviceId"])["revokedAt"] is None

    scoped = store.device_hygiene(provisioned["agent"]["agentId"])
    assert scoped["agentId"] == provisioned["agent"]["agentId"]
    assert scoped["total"] == 3 and scoped["dead"] == 2


def test_device_hygiene_ignores_another_agents_rows_when_scoped(store):
    mine = provision(store, "mine")
    theirs = provision(store, "theirs")
    claim(store, mine, "mine-live")
    stranger = claim(store, theirs, "stranger")
    store.revoke_device(stranger["deviceId"])

    assert store.device_hygiene()["total"] == 2
    assert store.device_hygiene(mine["agent"]["agentId"])["dead"] == 0, \
        "按 agent 取数时别人的设备行一条都不该算进来"
    assert store.device_hygiene(theirs["agent"]["agentId"])["dead"] == 1


def test_a_device_that_is_both_revoked_and_expired_counts_once_as_dead(store):
    """`revoked + expired` 不等于 `dead`——同一条记录可以两者都占。"""
    provisioned = provision(store)
    both = claim(store, provisioned, "both")
    store.revoke_device(both["deviceId"])
    expire(store, both["deviceId"])

    counts = store.device_hygiene()
    assert (counts["revoked"], counts["expired"]) == (1, 1)
    assert counts["dead"] == 1, "重放帧数是并集去重后的条数，不是两类相加"


# ── /stats 出口：计数与库一致，且不含设备明细 ────────────────────────────────

async def test_stats_device_records_match_the_database(client, store):
    provisioned = provision(store)
    claim(store, provisioned, "live")
    revoked = claim(store, provisioned, "revoked")
    expired = claim(store, provisioned, "expired")
    store.revoke_device(revoked["deviceId"])
    expire(store, expired["deviceId"])

    response = await client.get("/stats")
    assert response.status == 200
    body = await response.json()
    assert body["deviceRecords"] == store.device_hygiene(), \
        "面板上的数字必须就是库里的数字（每次现查，不许缓存出偏差）"
    assert body["deviceRecords"]["dead"] == 2

    raw = await response.text()
    assert "deviceId" not in json.dumps(body["deviceRecords"]), "计数出口不许带设备明细"
    assert revoked["deviceId"] not in raw and expired["deviceId"] not in raw, \
        "/stats 是回环页面，但设备明细没必要出现在这里（明细看 admin.py device-list）"


async def test_stats_page_shows_the_dead_device_count(client, store):
    provisioned = provision(store)
    claim(store, provisioned, "live")
    dead = claim(store, provisioned, "dead")
    store.revoke_device(dead["deviceId"])

    response = await client.get("/stats", headers={"Accept": "text/html"})
    assert response.status == 200
    page = await response.text()
    assert "死设备记录" in page, "运维看的就是这一页，数字不上页面等于没做"
    assert "<span class=big>1</span> 条" in page


# ── 阈值告警 ─────────────────────────────────────────────────────────────────

async def test_a_dead_record_burst_over_the_threshold_logs_a_warning(store, caplog):
    provisioned = provision(store)
    for index in range(3):
        dead = claim(store, provisioned, f"dead-{index}")
        store.revoke_device(dead["deviceId"])
    claim(store, provisioned, "live")
    hub = make_hub(store, dead_device_warn_threshold=2)
    ws = FakeWS()

    with caplog.at_level(logging.WARNING):
        link = await hub.attach_agent(provisioned["agent"], ws)
        await drain(link)

    detaches = [frame for frame in ws.sent if frame.get("t") == "deviceDetach"]
    assert len(detaches) == 3, "告警说的就是这条重放：3 条死记录 = 3 帧"
    warnings = [record for record in caplog.records if record.levelno == logging.WARNING]
    assert len(warnings) == 1, "超阈值只该落一条 WARNING，不要每条设备各喊一遍"
    message = warnings[0].getMessage()
    assert "3 dead device records" in message
    assert "over the 2 threshold" in message
    assert provisioned["agent"]["agentId"] in message, "日志要指出是哪个 agent"
    assert "purge-revoked-devices.py" in message, "告警要能直接照着做"


async def test_the_warning_stays_quiet_at_or_below_the_threshold(store, caplog):
    provisioned = provision(store)
    for index in range(2):
        dead = claim(store, provisioned, f"dead-{index}")
        store.revoke_device(dead["deviceId"])
    hub = make_hub(store, dead_device_warn_threshold=2)

    with caplog.at_level(logging.WARNING):
        link = await hub.attach_agent(provisioned["agent"], FakeWS())
        await drain(link)

    assert [r for r in caplog.records if r.levelno == logging.WARNING] == [], \
        "恰好等于阈值不算超（与旧实现的 > 200 逐字一致）"


async def test_a_zero_threshold_turns_the_warning_off(store, caplog):
    provisioned = provision(store)
    for index in range(3):
        dead = claim(store, provisioned, f"dead-{index}")
        store.revoke_device(dead["deviceId"])
    hub = make_hub(store, dead_device_warn_threshold=0)

    with caplog.at_level(logging.WARNING):
        link = await hub.attach_agent(provisioned["agent"], FakeWS())
        await drain(link)

    assert [r for r in caplog.records if r.levelno == logging.WARNING] == [], \
        "0 = 关掉告警（与其它 limit 的约定一致）"


def test_the_threshold_defaults_to_the_old_hard_coded_value():
    assert Limits().dead_device_warn_threshold == DEFAULT_DEAD_DEVICE_WARN_THRESHOLD == 200
    assert Limits().describe()["deadDeviceWarnThreshold"] == 200


def test_the_threshold_is_configurable_by_env_and_by_flag(monkeypatch):
    import relay as relay_module
    from hub import dead_device_warn_threshold_from_env

    monkeypatch.setenv("DLP_DEAD_DEVICE_WARN_THRESHOLD", "37")
    assert dead_device_warn_threshold_from_env() == 37
    assert relay_module.build_parser().parse_args(["--db", "x"]).dead_device_warn_threshold == 37
    assert Limits(dead_device_warn_threshold=dead_device_warn_threshold_from_env()) \
        .dead_device_warn_threshold == 37
    # 环境里写坏了要回默认值，不是崩在启动路上；负数夹到 0（= 关）。
    for garbage, expected in (("", DEFAULT_DEAD_DEVICE_WARN_THRESHOLD),
                              ("garbage", DEFAULT_DEAD_DEVICE_WARN_THRESHOLD),
                              ("-5", 0)):
        monkeypatch.setenv("DLP_DEAD_DEVICE_WARN_THRESHOLD", garbage)
        assert dead_device_warn_threshold_from_env() == expected


# ── admin 出口：没有 relay 进程时也能数 ──────────────────────────────────────

def test_admin_device_hygiene_prints_the_counts(tmp_path, capsys):
    import admin

    db = str(tmp_path / "state.db")
    instance = Store(db)
    provisioned = provision(instance)
    claim(instance, provisioned, "live")
    revoked = claim(instance, provisioned, "revoked")
    instance.revoke_device(revoked["deviceId"])
    agent_id = provisioned["agent"]["agentId"]
    instance.close()

    code = admin.main(["--db", db, "device-hygiene"])
    payload = json.loads(capsys.readouterr().out)
    assert code == 0
    assert (payload["total"], payload["live"], payload["dead"]) == (2, 1, 1)
    assert payload["warnThreshold"] == DEFAULT_DEAD_DEVICE_WARN_THRESHOLD
    assert payload["overThreshold"] is None, \
        "阈值是按 agent 判的，全局视图只能说'没判'，不能说'没超'"

    code = admin.main(["--db", db, "device-hygiene", "--agent", agent_id])
    scoped = json.loads(capsys.readouterr().out)
    assert code == 0
    assert scoped["agentId"] == agent_id and scoped["dead"] == 1
    assert scoped["overThreshold"] is False


def test_admin_device_hygiene_reports_an_agent_over_the_threshold(tmp_path, capsys, monkeypatch):
    import admin

    monkeypatch.setenv("DLP_DEAD_DEVICE_WARN_THRESHOLD", "1")
    db = str(tmp_path / "state.db")
    instance = Store(db)
    provisioned = provision(instance)
    for index in range(2):
        dead = claim(instance, provisioned, f"dead-{index}")
        instance.revoke_device(dead["deviceId"])
    agent_id = provisioned["agent"]["agentId"]
    instance.close()

    code = admin.main(["--db", db, "device-hygiene", "--agent", agent_id])
    payload = json.loads(capsys.readouterr().out)
    assert code == 0
    assert payload["warnThreshold"] == 1 and payload["dead"] == 2
    assert payload["overThreshold"] is True
    assert "purge-revoked-devices.py" in payload["hint"]
