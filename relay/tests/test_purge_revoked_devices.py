"""`purge-revoked-devices.py`：只删该死的那两类，an in-use device row is never deleted。

背景（已确认的事实）：中转在**连接器每次连上时**会把该 agent 名下所有"永远回不来"的设备
逐条重放给它（`hub.py:_tell_agent_about_the_gone`，一条一帧 `deviceDetach`）。2026-10-12
库里攒了 2012 条历次用例/调试留下的已撤销记录，一次重连灌 2012 帧，把连接器的处理链堵住
（maintainers/ANALYSIS-20261012-connector-flap.md）。

所以这个脚本的价值**全在安全约定上**，而读代码看不出它有没有照做，下面跑的是**真 CLI**
（子进程 + 临时库），断言的是库里的实际行数：默认预演、只删已撤销/已过期、连带的
`usageDaily` 与在用设备的令牌都不动、没有待删行时不写备份。
"""

from __future__ import annotations

import json
import pathlib
import subprocess
import sys

import store as store_module
from store import Store

RELAY_DIR = pathlib.Path(__file__).resolve().parents[1]
PURGE = RELAY_DIR / "purge-revoked-devices.py"


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


def run_purge(db: str, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(PURGE), "--db", db, *args],
                          capture_output=True, text=True, timeout=60)


def test_purge_dry_run_changes_nothing_at_all(store):
    provisioned = provision(store)
    live = claim(store, provisioned, "live")
    revoked = claim(store, provisioned, "revoked")
    expired = claim(store, provisioned, "expired")
    store.revoke_device(revoked["deviceId"])
    expire(store, expired["deviceId"])

    result = run_purge(store.path, "--all-agents")
    assert result.returncode == 0, result.stderr
    assert "将删除 2 行" in result.stdout
    assert f"KEEP {live['deviceId']}" in result.stdout, "in-use devices are listed so they can be checked by eye"
    assert "预演结束" in result.stdout
    for row in (live, revoked, expired):
        assert store.device_by_id(row["deviceId"]) is not None, "a dry run must not touch the database"
    assert not (pathlib.Path(store.path).parent / "backups").exists(), "a dry run must not write a backup"


def test_purge_apply_deletes_only_revoked_and_expired(store):
    provisioned = provision(store)
    live = claim(store, provisioned, "live")
    revoked = claim(store, provisioned, "revoked")
    expired = claim(store, provisioned, "expired")
    store.revoke_device(revoked["deviceId"])
    expire(store, expired["deviceId"])
    # 死设备的用量账必须留住（设备行没了只是留下孤立引用，账目是历史）。
    day = store_module.local_day()
    store.add_usage([{
        "day": day, "deviceId": revoked["deviceId"], "agentId": provisioned["agent"]["agentId"],
        "accountId": provisioned["account"]["accountId"], "egressBytes": 1234,
        "connections": 1, "at": store_module.now_ms(), "lastBuild": "test",
    }])

    result = run_purge(store.path, "--all-agents", "--apply")
    assert result.returncode == 0, result.stderr
    assert store.device_by_id(revoked["deviceId"]) is None
    assert store.device_by_id(expired["deviceId"]) is None
    assert store.device_by_id(live["deviceId"]) is not None, "an in-use device row is never deleted"
    assert store.device_by_token(live["deviceToken"]) is not None, \
        "the purge only deletes rows; it never touches a live device token"
    assert store.list_devices(provisioned["agent"]["agentId"]) != [], \
        "the in-use device is still listed (it is all that is left)"
    assert store.usage_rows(day), "usageDaily rows must survive the purge"

    backups = pathlib.Path(store.path).parent / "backups"
    dumps = sorted(backups.glob("purged-devices-all-*.json"))
    assert len(list(backups.glob("state-*.db"))) == 1, "a full database backup is taken before the delete"
    assert len(dumps) == 1
    exported = json.loads(dumps[0].read_text(encoding="utf-8"))
    assert sorted(row["deviceId"] for row in exported) == sorted(
        [revoked["deviceId"], expired["deviceId"]]), "the JSON dump holds exactly the rows that are about to be deleted"


def test_purge_with_one_agent_leaves_another_agents_rows_alone(store):
    mine = provision(store, "mine")
    theirs = provision(store, "theirs")
    mine_dead = claim(store, mine, "mine-dead")
    theirs_dead = claim(store, theirs, "theirs-dead")
    store.revoke_device(mine_dead["deviceId"])
    store.revoke_device(theirs_dead["deviceId"])

    result = run_purge(store.path, "--agent", mine["agent"]["agentId"], "--apply")
    assert result.returncode == 0, result.stderr
    assert store.device_by_id(mine_dead["deviceId"]) is None
    assert store.device_by_id(theirs_dead["deviceId"]) is not None, \
        "--agent purges only the named agent; --all-agents is the whole database"


def test_purge_writes_no_backup_when_there_is_nothing_to_purge(store):
    """每天跑一次的定时任务不许在没事的时候每天复制一份库。"""
    provisioned = provision(store)
    claim(store, provisioned, "live")

    result = run_purge(store.path, "--all-agents", "--apply")
    assert result.returncode == 0, result.stderr
    assert "没有待删行" in result.stdout
    assert store.list_devices() != [], "nothing else is deleted when there is nothing to purge"
    assert not (pathlib.Path(store.path).parent / "backups").exists()


def test_purge_keep_prunes_only_its_own_backups(store):
    """`--keep` 只认本脚本写的文件名，目录里放别的东西不许被删。"""
    provisioned = provision(store)
    dead = claim(store, provisioned, "dead")
    store.revoke_device(dead["deviceId"])
    backups = pathlib.Path(store.path).parent / "backups"
    backups.mkdir()
    keep_me = backups / "unrelated-notes.txt"
    keep_me.write_text("not ours", encoding="utf-8")
    for stamp in ("20200101-000000", "20200102-000000", "20200103-000000"):
        (backups / f"state-{stamp}.db").write_text("", encoding="utf-8")
        (backups / f"purged-devices-other-{stamp}.json").write_text("[]", encoding="utf-8")

    result = run_purge(store.path, "--all-agents", "--apply", "--keep", "2")
    assert result.returncode == 0, result.stderr
    assert "清理旧备份" in result.stdout
    assert not (backups / "state-20200101-000000.db").exists(), "the oldest backup group is pruned"
    assert (backups / "state-20200103-000000.db").exists(), "the newest backup group is kept"
    assert not (backups / "purged-devices-other-20200101-000000.json").exists()
    assert keep_me.exists(), "a file this script did not write is never touched"
    # 这一轮自己写的那组备份当然也留着。
    assert len(list(backups.glob("purged-devices-all-*.json"))) == 1


def test_the_purge_units_call_this_script_with_apply():
    """定时任务与脚本必须是同一套：路径、参数、沙箱可写目录都对得上。

    这条不是"文档检查"，而是接线检查——unit 里少一个 `--apply` 就是每天空跑一次，
    备份目录写成 `/root` 就是每晚以 `dsh-relay` 身份写不进去（沙箱有 ProtectHome）。
    """
    unit = (RELAY_DIR / "deploy" / "dsh-relay-purge.service").read_text(encoding="utf-8")
    timer = (RELAY_DIR / "deploy" / "dsh-relay-purge.timer").read_text(encoding="utf-8")

    assert "purge-revoked-devices.py" in unit
    assert "--all-agents" in unit and "--apply" in unit
    assert "--db /var/lib/dsh-relay/state.db" in unit
    assert "--backup-dir /var/lib/dsh-relay/backups" in unit
    assert "StateDirectory=dsh-relay" in unit and "ReadWritePaths=/var/lib/dsh-relay" in unit
    assert "User=dsh-relay" in unit
    assert "OnCalendar=" in timer and "Persistent=true" in timer
    assert "WantedBy=timers.target" in timer
