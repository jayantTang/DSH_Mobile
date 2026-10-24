"""设备记录卫生：计数看得见、超阈值有 WARNING。

背景（已确认的事实）：中转在**连接器每次连上时**会把该 agent 名下所有"永远回不来"的设备
逐条重放给它（`hub.py:_tell_agent_about_the_gone`，一条一帧 `deviceDetach`）。2026-10-12
库里攒了 2012 条历次用例/调试留下的已撤销记录，一次重连灌 2012 帧，把连接器的处理链堵住
（maintainers/20261012-连接器断续分析.md）。真删由
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
        "in-use, revoked and expired are counted separately; dead is the union of the two"
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
        "an agent-scoped count must not include another agent's device rows"
    assert store.device_hygiene(theirs["agent"]["agentId"])["dead"] == 1


def test_a_device_that_is_both_revoked_and_expired_counts_once_as_dead(store):
    """`revoked + expired` 不等于 `dead`——同一条记录可以两者都占。"""
    provisioned = provision(store)
    both = claim(store, provisioned, "both")
    store.revoke_device(both["deviceId"])
    expire(store, both["deviceId"])

    counts = store.device_hygiene()
    assert (counts["revoked"], counts["expired"]) == (1, 1)
    assert counts["dead"] == 1, "the replay count is the deduplicated union, not revoked + expired"


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
        "/stats must report the numbers in the database (read live, never cached)"
    assert body["deviceRecords"]["dead"] == 2

    raw = await response.text()
    assert "deviceId" not in json.dumps(body["deviceRecords"]), "the counts endpoint must not carry device details"
    assert revoked["deviceId"] not in raw and expired["deviceId"] not in raw, \
        "/stats is loopback-only, but device details do not belong here (use admin.py device-list)"


async def test_stats_page_shows_the_dead_device_count(client, store):
    provisioned = provision(store)
    claim(store, provisioned, "live")
    dead = claim(store, provisioned, "dead")
    store.revoke_device(dead["deviceId"])

    response = await client.get("/stats", headers={"Accept": "text/html"})
    assert response.status == 200
    page = await response.text()
    assert "死设备记录" in page, "the operator reads this page, so the number has to be on it"
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
    assert len(detaches) == 3, "the warning is about this replay: 3 dead records = 3 deviceDetach frames"
    warnings = [record for record in caplog.records if record.levelno == logging.WARNING]
    assert len(warnings) == 1, "over the threshold it logs exactly one warning, not one per device"
    message = warnings[0].getMessage()
    assert "3 dead device records" in message
    assert "over the 2 threshold" in message
    assert provisioned["agent"]["agentId"] in message, "the log line names the agent"
    assert "purge-revoked-devices.py" in message, "the warning carries the command that fixes it"


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
        "equal to the threshold is not over it (same rule as the old hard-coded > 200)"


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
        "0 turns the warning off, like the other limits"


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
        "the threshold is per agent, so the global view reports null (not judged), not false"

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
