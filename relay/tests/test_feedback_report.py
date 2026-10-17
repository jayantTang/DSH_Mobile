"""`admin.py ops-report`：日报的四个板块（014 T040）。

日报是在本机渲染的（服务器只出原始数据），所以这份 JSON 的字段名一旦改了口径，
`scripts/dev/*.mjs` 的图表会静默变空。用例因此把字段名钉在**已有的**命令输出上
（`usage` / `enrollments` / `device-list`），另外核一遍空库不报错、计数为 0。

库一律是 `tmp_path` 里新建的；`ops-report` 自己开连接读，写完就关。
"""

from __future__ import annotations

import datetime
import json

import admin
import pytest
from store import Store, local_day, now_ms, sha256_hex


def run_cli(db: str, *args: str, capsys) -> tuple[int, object]:
    """跑一条命令，把 stdout 当 JSON 读回来（照 `tests/test_admin_push.py`）。"""
    code = admin.main(["--db", db, *args])
    captured = capsys.readouterr()
    out = captured.out.strip()
    return code, (json.loads(out) if out else {"stderr": captured.err.strip()})


def provisioned(tmp_path) -> tuple[str, dict]:
    """一个账号 + 一台设备 + 一条用量 + 一张用掉的邀请码。"""
    db = str(tmp_path / "state.db")
    store = Store(db)
    account = store.create_account("ops")
    agent = store.register_agent(account["accountId"], "mac")
    device = store.claim_pair_code(
        store.mint_pair_code(agent["agentId"], ttl_ms=60_000)["code"], device_name="iPhone")
    store.touch_device(device["deviceId"])
    store.add_usage([{"day": local_day(), "deviceId": device["deviceId"],
                      "agentId": agent["agentId"], "accountId": account["accountId"],
                      "egressBytes": 4096, "connections": 3, "at": now_ms(),
                      "lastBuild": "1.2.3"}])
    invite = store.mint_invite(note="for Sam")
    store.claim_invite(invite["code"], "Sam 的 MacBook")
    store.close()
    return db, {"account": account, "agent": agent, "device": device, "invite": invite}


def test_ops_report_has_all_four_sections_on_an_empty_database(tmp_path, capsys):
    """空库也要四个板块都在、计数为 0、不报错（日报每天都会跑）。"""
    db = str(tmp_path / "state.db")
    Store(db).close()

    code, report = run_cli(db, "ops-report", "--days", "3", capsys=capsys)
    assert code == 0 and report["ok"] is True
    assert report["days"] == 3 and report["generatedAt"] > 0
    assert report["feedback"] == {"new": 0, "open": 0, "replied": 0,
                                  "medianFirstReplyHours": None, "test": 0, "threads": []}
    assert report["devices"]["paired"] == 0 and report["devices"]["active7d"] == 0
    assert report["devices"]["revoked"] == 0 and report["devices"]["list"] == []
    assert 0 < len(report["devices"]["newPerDay"]) <= 3
    assert all(entry["count"] == 0 for entry in report["devices"]["newPerDay"])
    assert 0 < len(report["usage"]["perDay"]) <= 3
    assert all(entry["egressBytes"] == 0 for entry in report["usage"]["perDay"])
    assert report["usage"]["perDay"][-1]["day"] == local_day()
    assert report["usage"]["topAccounts"] == []
    assert report["usage"]["totals"] == {"egressBytes": 0, "connections": 0}
    assert report["invites"] == {"minted": 0, "used": 0, "remaining": 0, "test": 0,
                                 "usable": 0, "expiringSoon": 0, "expiredUnused": 0,
                                 "unused": [], "enrollments": []}
    # 留存板块：空库也要有形状（渲染层靠它画空态），没有账号时所有比例是 None。
    assert report["retention"]["scope"] == "external"
    assert report["retention"]["users"] == {"dau": 0, "wau": 0, "mau": 0,
                                            "stickiness": None, "external": 0}
    assert report["retention"]["d1"] is None and report["retention"]["d7"] is None
    assert report["retention"]["activation"] == {"rate": None, "cohort": 0, "active": 0}
    assert report["retention"]["weeks"] == []


def test_ops_report_keeps_the_field_names_the_other_commands_own(tmp_path, capsys):
    """`devices`/`usage`/`invites` 的字段名必须与 `device-list`/`usage`/`enrollments` 一致。"""
    db, made = provisioned(tmp_path)

    code, report = run_cli(db, "ops-report", "--days", "3", capsys=capsys)
    assert code == 0

    code, listed = run_cli(db, "device-list", "--all", capsys=capsys)
    assert code == 0 and len(listed) == 1
    row = report["devices"]["list"][0]
    assert set(listed[0]) <= set(row), "只允许加字段，不许改已有字段名"
    for field in ("deviceId", "name", "model", "appVersion", "createdAt", "lastSeenAt",
                  "revoked"):
        assert field in row, field
    assert row["revoked"] is False and row["deviceTokenHash"].endswith("…")
    assert row["push"] == listed[0]["push"]

    code, usage = run_cli(db, "usage", "--days", "3", capsys=capsys)
    assert code == 0 and usage
    assert set(usage[0]) >= set(report["usage"]["topAccounts"][0]), "topAccounts 照 usage 的行"
    # 合并之后除了出口字节，还要带上连接数与最近一次的构建（日报的账号排名要显示它们）。
    assert {key: report["usage"]["topAccounts"][0][key]
            for key in ("accountId", "name", "egressBytes", "connections")} == {
        "accountId": made["account"]["accountId"], "name": "ops", "egressBytes": 4096,
        "connections": 3}
    assert report["usage"]["totals"] == {
        "egressBytes": sum(int(entry["egressBytes"]) for entry in usage),
        "connections": sum(int(entry["connections"]) for entry in usage)}
    # 派生指标：日均、峰值日、有流量的天数（渲染层只显示，不自己算）。
    assert report["usage"]["averagePerDay"] == round(4096 / 3)
    assert report["usage"]["peakDay"] == {"day": local_day(), "egressBytes": 4096}
    assert report["usage"]["activeDays"] == 1

    code, enrolls = run_cli(db, "enrollments", capsys=capsys)
    assert code == 0
    assert report["invites"]["minted"] == enrolls["totals"]["minted"] == 1
    assert report["invites"]["used"] == enrolls["totals"]["used"] == 1
    assert report["invites"]["remaining"] == 0
    assert report["invites"]["enrollments"] == enrolls["enrollments"]


def test_ops_report_counts_devices_usage_and_invites(tmp_path, capsys):
    db = str(tmp_path / "state.db")
    store = Store(db)
    account = store.create_account("ops")
    agent = store.register_agent(account["accountId"], "mac")
    first = store.claim_pair_code(
        store.mint_pair_code(agent["agentId"], ttl_ms=60_000)["code"], device_name="iPhone")
    second = store.claim_pair_code(
        store.mint_pair_code(agent["agentId"], ttl_ms=60_000)["code"], device_name="iPad")
    # 一台调试设备：日报的设备板块要把它剔出去，只把它记进 `debug` 计数。
    store.claim_pair_code(
        store.mint_pair_code(agent["agentId"], ttl_ms=60_000)["code"], device_name="DSH-Test")
    store.touch_device(first["deviceId"])
    store.revoke_device(second["deviceId"])
    store.add_usage([
        {"day": local_day(), "deviceId": first["deviceId"], "agentId": agent["agentId"],
         "accountId": account["accountId"], "egressBytes": 1000, "connections": 2,
         "at": now_ms(), "lastBuild": "1.2.3"},
        {"day": local_day(), "deviceId": second["deviceId"], "agentId": agent["agentId"],
         "accountId": account["accountId"], "egressBytes": 250, "connections": 1,
         "at": now_ms(), "lastBuild": None},
    ])
    store.mint_invite(note="没人领")
    store.close()

    code, report = run_cli(db, "ops-report", "--days", "1", capsys=capsys)
    assert code == 0
    assert report["devices"]["paired"] == 1 and report["devices"]["revoked"] == 1
    assert report["devices"]["active7d"] == 1, "撤销的那台不算活跃"
    assert report["devices"]["newPerDay"][-1] == {"day": local_day(), "count": 2}, \
        "调试设备（DSH- 前缀）不算新增"
    # 清单只列未撤销的设备：生产库上历史（历次调试配对）有 1900+ 行，全量会把日报撑爆
    # （2026-10-12 第一版 327 KB，正文九成是 DSH-Test/DSH-Sweep）。计数仍是全量的。
    listed = report["devices"]["list"]
    assert len(listed) == 1 and listed[0]["name"] == "iPhone", "已撤销的设备不进清单"
    assert report["devices"]["debug"] == 1, "被剔除的调试设备数要单独报出来"

    today = report["usage"]["perDay"][-1]
    assert today == {"day": local_day(), "egressBytes": 1250, "connections": 3, "devices": 2,
                     "accounts": 1}, "两台手机同属一个账号：活跃用户（账号口径）只算一个"
    assert report["usage"]["totals"] == {"egressBytes": 1250, "connections": 3}
    assert report["invites"]["minted"] == 1 and report["invites"]["remaining"] == 1
    assert report["invites"]["enrollments"] == []


def test_ops_report_counts_a_reinstalled_phone_once(tmp_path, capsys):
    """重装/换版本会新插一行设备行，但它不是新手机（2026-10-14 生产库上的实际形态）。

    同一账号同机型两行 + 一台别的机型：新增手机是 2 台，设备行是 3 行；
    两个数字都留在 JSON 里（`newPerDay` / `newRawPerDay`），免得口径改了看不出来。
    """
    db = str(tmp_path / "state.db")
    store = Store(db)
    account = store.create_account("ops")
    agent = store.register_agent(account["accountId"], "mac")
    for _ in range(2):
        store.claim_pair_code(
            store.mint_pair_code(agent["agentId"], ttl_ms=60_000)["code"],
            device_name="iPhone", model="iPhone12,1")
    store.claim_pair_code(
        store.mint_pair_code(agent["agentId"], ttl_ms=60_000)["code"],
        device_name="iPad", model="iPad17,1")
    store.close()

    code, report = run_cli(db, "ops-report", "--days", "1", capsys=capsys)
    assert code == 0
    assert report["devices"]["newPerDay"][-1] == {"day": local_day(), "count": 2}, \
        "同账号同机型的两行只算一台手机"
    assert report["devices"]["newRawPerDay"][-1] == {"day": local_day(), "count": 3}, \
        "设备行口径留在 newRawPerDay 里对账"
    assert report["devices"]["newInWindow"] == 2
    assert report["devices"]["newRawInWindow"] == 3
    assert report["today"]["devices"]["new"] == 2
    assert report["today"]["devices"]["newRaw"] == 3


def test_ops_report_counts_feedback_and_the_median_first_reply(tmp_path, capsys):
    """`--days` 是窗口（本地日，含今天）：窗口外的老线程不进日报。"""
    db = str(tmp_path / "state.db")
    store = Store(db)
    now = now_ms()
    answered = store.create_feedback_thread(ticket_hash=sha256_hex("fk_1"), text="点了没反应",
                                            at=now - 10 * 86_400_000)
    store.append_feedback_message(answered["threadId"], "回信", author="owner",
                                  at=now - 10 * 86_400_000 + 6 * 3_600_000 + 1_800_000)
    fresh = store.create_feedback_thread(ticket_hash=sha256_hex("fk_2"), text="第二个问题",
                                         subject="新建会话一直转圈", at=now - 2 * 86_400_000)
    store.create_feedback_thread(ticket_hash=sha256_hex("fk_3"), text="40 天前的老问题",
                                 at=now - 40 * 86_400_000)
    store.close()

    code, report = run_cli(db, "ops-report", "--days", "30", capsys=capsys)
    assert code == 0
    assert report["feedback"]["new"] == 2, "只数窗口内新建的线程"
    assert report["feedback"]["open"] == 1 and report["feedback"]["replied"] == 1
    assert report["feedback"]["medianFirstReplyHours"] == 6.5
    assert [row["threadId"] for row in report["feedback"]["threads"]] == [
        fresh["threadId"], answered["threadId"]], "最近的在前"
    assert report["feedback"]["threads"][0]["excerpt"] == "第二个问题"
    assert report["feedback"]["threads"][0]["subject"] == "新建会话一直转圈", \
        "日报的线程行与 feedback-list 同形（含 subject）"
    assert report["feedback"]["threads"][1]["subject"] is None, "没填主题就是 null"
    # FR-034：线程行带首条留言的格式（线程行不带留言，格式只能顺着摘要一起出来）。
    assert [row["format"] for row in report["feedback"]["threads"]] == ["text", "text"]
    assert report["feedback"]["threads"][0]["source"]["kind"] == "anonymous"
    # 回信过但没人 `feedback-show` 过：用户原文在 owner 侧仍是"没看过"的一条。
    assert report["feedback"]["threads"][1]["ownerUnread"] == 1


def test_ops_report_merges_top_accounts_across_days(tmp_path, capsys):
    """`usage_totals(by="account")` 是按天一行：日报要按账号合并再排名。

    2026-10-12 第一次跑生产日报时，图上"出口流量前几名"是一长串同名条目
    （同一个账号每一天一行），所以合并这一步要有用例钉住。
    """
    db = str(tmp_path / "state.db")
    store = Store(db)
    account = store.create_account("ops")
    agent = store.register_agent(account["accountId"], "mac")
    device = store.claim_pair_code(
        store.mint_pair_code(agent["agentId"], ttl_ms=60_000)["code"], device_name="iPhone")
    for day, egress in ((local_day(), 1000), (local_day(now_ms() / 1000 - 86_400), 3000)):
        store.add_usage([{"day": day, "deviceId": device["deviceId"],
                          "agentId": agent["agentId"], "accountId": account["accountId"],
                          "egressBytes": egress, "connections": 1, "at": now_ms(),
                          "lastBuild": "1.2.3"}])
    store.close()

    code, report = run_cli(db, "ops-report", "--days", "2", capsys=capsys)
    assert code == 0
    ranked = report["usage"]["topAccounts"]
    assert len(ranked) == 1, "同一个账号两天要合并成一行"
    assert ranked[0]["accountId"] == account["accountId"]
    assert ranked[0]["egressBytes"] == 4000


def test_ops_report_keeps_simulator_and_debug_feedback_out(tmp_path, capsys):
    """验收单不进"用户反馈"：模拟器来源（机型 arm64）与调试设备提的只计数、不进清单。

    2026-10-12 的生产日报里 16 条反馈有 15 条是这么来的——真问题会被它们盖住。
    """
    db = str(tmp_path / "state.db")
    store = Store(db)
    account = store.create_account("ops")
    agent = store.register_agent(account["accountId"], "mac")
    debug = store.claim_pair_code(
        store.mint_pair_code(agent["agentId"], ttl_ms=60_000)["code"], device_name="DSH-Test")
    real = store.claim_pair_code(
        store.mint_pair_code(agent["agentId"], ttl_ms=60_000)["code"], device_name="iPhone")
    store.create_feedback_thread(ticket_hash=sha256_hex("fk_sim"), text="验收：重做后的界面",
                                 subject="验收：重做后的界面", device_model="arm64",
                                 app_version="1.0 (1)")
    store.create_feedback_thread(ticket_hash=sha256_hex("fk_deploy"), text="部署演练",
                                 device_model="deploy-check")
    store.create_feedback_thread(ticket_hash=sha256_hex("fk_debug"), text="调试设备提的",
                                 device_id=debug["deviceId"])
    real_thread = store.create_feedback_thread(ticket_hash=sha256_hex("fk_real"), text="真机提的",
                                               device_id=real["deviceId"],
                                               device_model="iPhone15,4")
    store.close()

    code, report = run_cli(db, "ops-report", "--days", "3", capsys=capsys)
    assert code == 0
    assert [row["threadId"] for row in report["feedback"]["threads"]] == [real_thread["threadId"]]
    assert report["feedback"]["new"] == 1, "计数也只算真实来源"
    assert report["feedback"]["test"] == 3, "被剔除的测试提交要单独报出来"
    assert [row["threadId"] for row in report["today"]["feedback"]["threads"]] == [
        real_thread["threadId"]]


def test_ops_report_retention_only_counts_external_accounts(tmp_path, capsys):
    """留存只算用邀请码登记的外部账号：owner 自用账号天天在连，混进来会把留存抬平。"""
    db = str(tmp_path / "state.db")
    store = Store(db)
    owner = store.create_account("Jayant")
    owner_agent = store.register_agent(owner["accountId"], "mac")
    owner_device = store.claim_pair_code(
        store.mint_pair_code(owner_agent["agentId"], ttl_ms=60_000)["code"], device_name="iPhone")
    for offset in range(0, 12):
        store.add_usage([{"day": local_day(now_ms() / 1000 - offset * 86_400),
                          "deviceId": owner_device["deviceId"], "agentId": owner_agent["agentId"],
                          "accountId": owner["accountId"], "egressBytes": 1000, "connections": 1,
                          "at": now_ms() - offset * 86_400_000, "lastBuild": "1.2.3"}])
    # 一个外部账号：登记后连着两天活跃（第 5 天与第 4 天，即隔天又来了）。
    invite = store.mint_invite(note="公开试用")
    enrolled = store.claim_invite(invite["code"], "Sam 的 MacBook")
    device = store.claim_pair_code(
        store.mint_pair_code(enrolled["agentId"], ttl_ms=60_000)["code"], device_name="iPhone")
    for offset in (5, 4):
        store.add_usage([{"day": local_day(now_ms() / 1000 - offset * 86_400),
                          "deviceId": device["deviceId"], "agentId": enrolled["agentId"],
                          "accountId": enrolled["accountId"], "egressBytes": 2000,
                          "connections": 2, "at": now_ms() - offset * 86_400_000,
                          "lastBuild": "1.2.3"}])
    store.close()

    code, report = run_cli(db, "ops-report", "--days", "30", capsys=capsys)
    assert code == 0
    retention = report["retention"]
    assert retention["scope"] == "external"
    assert retention["users"]["external"] == 1, "外部账号只有一个"
    assert retention["users"]["mau"] == 1, "owner 的账号不算进来"
    assert retention["users"]["dau"] == 0, "外部账号上次活跃是 4 天前，今天没来"
    assert retention["users"]["wau"] == 1 and retention["users"]["stickiness"] == 1.0
    assert retention["d1"] == {"rate": 1.0, "cohort": 1, "active": 1}, "隔天又活跃"
    # 留存量的是"第一次活跃"那天起算，窗口外的历史也要看到（owner 那 12 天不参与）。
    assert retention["d7"] is None, "首次活跃才 5 天前，7 日留存还没有可观察的队列"


def test_retention_report_computes_d1_d7_and_activation():
    """留存四个口径的算法本身：只喂一张活动表，断言 D1/D7、粘性、登记激活、分周队列。"""
    today = local_day()
    day = lambda offset: local_day(now_ms() / 1000 - offset * 86_400)  # noqa: E731
    window = {day(offset): set() for offset in range(30)}
    for offset, active in ((10, {"acc_a", "acc_b"}), (9, {"acc_a"}), (3, {"acc_a"}),
                           (2, {"acc_c"}), (1, {"acc_c"}), (0, {"acc_a"})):
        window[day(offset)] = active
    external = {"acc_a", "acc_b", "acc_c"}
    first_seen = {"acc_a": day(10), "acc_b": day(10), "acc_c": day(2)}
    enrollments = [
        {"accountId": "acc_a", "usedAt": now_ms() - 12 * 86_400_000, "accountName": "a",
         "agentName": "a"},
        {"accountId": "acc_c", "usedAt": now_ms() - 3 * 86_400_000, "accountName": "c",
         "agentName": "c"},
    ]

    class FakeStore:
        def list_enrollments(self):
            return enrollments

    report = admin._retention_report(FakeStore(), days=30, stamp=now_ms(), external=external,
                                     active_by_day=window, first_seen=first_seen)
    assert report["users"] == {"dau": 1, "wau": 2, "mau": 3, "stickiness": 0.667, "external": 3}
    assert report["d1"] == {"rate": 0.667, "cohort": 3, "active": 2}, "a 与 c 隔天回来，b 没有"
    assert report["d7"] == {"rate": 0.5, "cohort": 2, "active": 1}, "只有 a 在第 7 天回来"
    assert report["activation"] == {"rate": 1.0, "cohort": 1, "active": 1}, \
        "c 登记才 3 天，还进不了 7 天激活的分母；a 登记后两天就连上了"
    assert report["users"]["external"] == 3 and today == day(0)
    for entry in report["weeks"]:
        assert entry["week"].startswith("20") and entry["size"] >= 1
        assert entry["rate"] is None or 0 <= entry["rate"] <= 1


def test_ops_report_excludes_debug_devices_from_the_window_usage(tmp_path, capsys):
    """调试设备的流量不进日报的用量板块：否则同一天会在「今日」和 30 天表里给出两个数字。

    2026-10-12 实测到的正是这个：今日 4.0 GB，同一天在 30 天表里 4.4 GB，差的 400 MB
    是历次用例的 DSH-Test。`usage` 命令保持全量（它是账本），日报是给人看的视图。
    """
    db = str(tmp_path / "state.db")
    store = Store(db)
    account = store.create_account("ops")
    agent = store.register_agent(account["accountId"], "mac")
    real = store.claim_pair_code(
        store.mint_pair_code(agent["agentId"], ttl_ms=60_000)["code"], device_name="iPhone")
    tester = store.claim_pair_code(
        store.mint_pair_code(agent["agentId"], ttl_ms=60_000)["code"], device_name="DSH-Test")
    node = store.claim_pair_code(
        store.mint_pair_code(agent["agentId"], ttl_ms=60_000)["code"], device_name="headless",
        model="Node")
    store.add_usage([
        {"day": local_day(), "deviceId": real["deviceId"], "agentId": agent["agentId"],
         "accountId": account["accountId"], "egressBytes": 1000, "connections": 2,
         "at": now_ms(), "lastBuild": "1.2.3"},
        {"day": local_day(), "deviceId": tester["deviceId"], "agentId": agent["agentId"],
         "accountId": account["accountId"], "egressBytes": 9000, "connections": 9,
         "at": now_ms(), "lastBuild": "9.9.9"},
        {"day": local_day(), "deviceId": node["deviceId"], "agentId": agent["agentId"],
         "accountId": account["accountId"], "egressBytes": 5000, "connections": 5,
         "at": now_ms(), "lastBuild": "8.8.8"},
    ])
    store.close()

    code, report = run_cli(db, "ops-report", "--days", "3", capsys=capsys)
    assert code == 0
    assert report["usage"]["totals"]["egressBytes"] == 1000, "只算真实设备"
    assert report["usage"]["perDay"][-1]["egressBytes"] == 1000
    assert report["usage"]["perDay"][-1]["connections"] == 2
    assert report["usage"]["perDay"][-1]["devices"] == 1
    assert report["usage"]["averagePerDay"] == round(1000 / 3)
    assert report["usage"]["peakDay"] == {"day": local_day(), "egressBytes": 1000}
    assert [row["egressBytes"] for row in report["usage"]["topAccounts"]] == [1000]
    assert report["usage"]["topAccounts"][0]["devices"] == 1
    # 「今日」与 30 天窗口的同一天必须给出同一个数字（这就是这次改口径要解决的问题）。
    assert report["today"]["usage"]["egressBytes"] == report["usage"]["perDay"][-1]["egressBytes"]


def test_ops_report_counts_active_users_per_account(tmp_path, capsys):
    """活跃用户按**账号**算（owner 2026-10-17 定的口径）：同一账号的多台手机只算一个。

    一天的账号数不能相加求并集，所以窗口级（`activeAccounts`）与近 7 天级
    （`activeAccounts7d`）都在服务端按账号集合算，渲染层不自己拼。设备行数
    （`devices`）保持原样，两者不等是常态：重装会多出行。
    """
    db = str(tmp_path / "state.db")
    store = Store(db)
    first = store.create_account("房主")
    first_agent = store.register_agent(first["accountId"], "mac")
    one = store.claim_pair_code(
        store.mint_pair_code(first_agent["agentId"], ttl_ms=60_000)["code"], device_name="iPhone")
    two = store.claim_pair_code(
        store.mint_pair_code(first_agent["agentId"], ttl_ms=60_000)["code"], device_name="iPad")
    second = store.create_account("旧用户")
    second_agent = store.register_agent(second["accountId"], "pc")
    old = store.claim_pair_code(
        store.mint_pair_code(second_agent["agentId"], ttl_ms=60_000)["code"], device_name="iPhone")
    eight_days_ago = local_day(now_ms() / 1000 - 8 * 86_400)
    store.add_usage([
        {"day": local_day(), "deviceId": one["deviceId"], "agentId": first_agent["agentId"],
         "accountId": first["accountId"], "egressBytes": 100, "connections": 1,
         "at": now_ms(), "lastBuild": "1.2.3"},
        {"day": local_day(), "deviceId": two["deviceId"], "agentId": first_agent["agentId"],
         "accountId": first["accountId"], "egressBytes": 200, "connections": 2,
         "at": now_ms(), "lastBuild": "1.2.3"},
        {"day": eight_days_ago, "deviceId": old["deviceId"], "agentId": second_agent["agentId"],
         "accountId": second["accountId"], "egressBytes": 300, "connections": 3,
         "at": now_ms() - 8 * 86_400_000, "lastBuild": "1.2.0"},
    ])
    store.close()

    code, report = run_cli(db, "ops-report", "--days", "30", capsys=capsys)
    assert code == 0
    today = report["usage"]["perDay"][-1]
    assert today["devices"] == 2 and today["accounts"] == 1
    assert report["today"]["usage"]["accounts"] == 1
    assert report["usage"]["activeAccounts"] == 2, "30 天窗口里有两个账号来过"
    assert report["usage"]["activeAccounts7d"] == 1, "8 天前那位不算近 7 天活跃"


def test_ops_report_drops_internal_orphan_usage_rows(tmp_path, capsys):
    """设备行已被清理工具删掉的**内部账号**用量行不进报表；外部账号的孤儿行保留。

    背景（2026-10-13 实测）：`maintainers/purge-revoked-devices.py` 会删已撤销/过期的
    设备行、按约定保留 `usageDaily`，于是历史用量里留下找不到设备主体的行——近 30 天
    636 台、29.5 GB，全是 owner 自用账号（历次用例的模拟器），把「活跃手机」抬到
    真实值的两倍以上（10-12 那天 88 台 vs 真实 19 台）。账本不动，视图要干净。
    外部账号自己解绑后留下的孤儿行是真人真事，历史该保留。
    """
    db = str(tmp_path / "state.db")
    store = Store(db)
    owner = store.create_account("Jayant")
    owner_agent = store.register_agent(owner["accountId"], "mac")
    invite = store.mint_invite(note="公开试用")
    enrolled = store.claim_invite(invite["code"], "Sam 的 MacBook")
    store.add_usage([
        # 内部账号的孤儿行：设备行不存在（模拟 purge 之后的状态）。
        {"day": local_day(), "deviceId": "dev_ghost_internal", "agentId": owner_agent["agentId"],
         "accountId": owner["accountId"], "egressBytes": 1_000_000, "connections": 50,
         "at": now_ms(), "lastBuild": "1.0 1"},
        # 外部账号的孤儿行：历史该留住。
        {"day": local_day(), "deviceId": "dev_ghost_external", "agentId": enrolled["agentId"],
         "accountId": enrolled["accountId"], "egressBytes": 2048, "connections": 4,
         "at": now_ms(), "lastBuild": "1.2.3"},
    ])
    store.close()

    code, report = run_cli(db, "ops-report", "--days", "3", capsys=capsys)
    assert code == 0
    assert report["usage"]["totals"]["egressBytes"] == 2048, "内部孤儿行剔除、外部保留"
    assert report["usage"]["perDay"][-1]["devices"] == 1
    assert report["usage"]["perDay"][-1]["connections"] == 4
    assert [row["accountId"] for row in report["usage"]["topAccounts"]] == [enrolled["accountId"]]
    # 「今日」板块同一口径，且与窗口里的同一天是同一个数字。
    assert report["today"]["usage"]["egressBytes"] == report["usage"]["perDay"][-1]["egressBytes"]
    assert report["today"]["usage"]["devices"] == 1
    assert [row["deviceId"] for row in report["today"]["devices"]["list"]] == ["dev_ghost_external"]


def test_ops_report_keeps_orphan_rows_of_a_revoked_device_that_still_exists(tmp_path, capsys):
    """设备行还在（只是已撤销）的用量行照旧算——孤儿过滤只针对"设备行已不存在"的行。"""
    db = str(tmp_path / "state.db")
    store = Store(db)
    account = store.create_account("ops")
    agent = store.register_agent(account["accountId"], "mac")
    device = store.claim_pair_code(
        store.mint_pair_code(agent["agentId"], ttl_ms=60_000)["code"], device_name="iPhone")
    store.revoke_device(device["deviceId"])
    store.add_usage([{"day": local_day(), "deviceId": device["deviceId"],
                      "agentId": agent["agentId"], "accountId": account["accountId"],
                      "egressBytes": 777, "connections": 3, "at": now_ms(),
                      "lastBuild": "1.2.3"}])
    store.close()

    code, report = run_cli(db, "ops-report", "--days", "3", capsys=capsys)
    assert code == 0
    assert report["usage"]["totals"]["egressBytes"] == 777


def test_ops_report_today_block_is_a_local_day_slice(tmp_path, capsys):
    """「今日」= 服务器本地自然日 00:00 起：昨天与调试设备的量都不进这一块。

    这一块是日报第一屏（"今天有没有事"），口径错了整页都在骗人，所以三件事都要钉住：
    跨日不算、调试设备不算、账号/设备/用量三处合计一致。
    """
    db = str(tmp_path / "state.db")
    store = Store(db)
    account = store.create_account("ops")
    agent = store.register_agent(account["accountId"], "mac")
    phone = store.claim_pair_code(
        store.mint_pair_code(agent["agentId"], ttl_ms=60_000)["code"], device_name="iPhone")
    debug = store.claim_pair_code(
        store.mint_pair_code(agent["agentId"], ttl_ms=60_000)["code"], device_name="DSH-Test")
    other = store.claim_pair_code(
        store.mint_pair_code(agent["agentId"], ttl_ms=60_000)["code"], device_name="iPad")
    store.touch_device(phone["deviceId"])
    yesterday = local_day(now_ms() / 1000 - 86_400)
    store.add_usage([
        {"day": local_day(), "deviceId": phone["deviceId"], "agentId": agent["agentId"],
         "accountId": account["accountId"], "egressBytes": 1000, "connections": 2,
         "at": now_ms(), "lastBuild": "1.2.3"},
        # 调试设备：今日的流量、设备、账号一并剔除。
        {"day": local_day(), "deviceId": debug["deviceId"], "agentId": agent["agentId"],
         "accountId": account["accountId"], "egressBytes": 999_000, "connections": 90,
         "at": now_ms(), "lastBuild": "9.9.9"},
        # 昨天：不进「今日」。
        {"day": yesterday, "deviceId": phone["deviceId"], "agentId": agent["agentId"],
         "accountId": account["accountId"], "egressBytes": 5000, "connections": 5,
         "at": now_ms() - 86_400_000, "lastBuild": "1.2.2"},
    ])
    fresh = store.create_feedback_thread(ticket_hash=sha256_hex("fk_today"), text="今天的问题")
    store.create_feedback_thread(ticket_hash=sha256_hex("fk_old"), text="三天前的问题",
                                 at=now_ms() - 3 * 86_400_000)
    invite = store.mint_invite(note="今天登记的")
    store.claim_invite(invite["code"], "Sam 的 MacBook")
    store.close()

    code, report = run_cli(db, "ops-report", "--days", "30", capsys=capsys)
    assert code == 0
    today = report["today"]
    assert today["day"] == local_day()
    assert today["usage"]["egressBytes"] == 1000, "调试设备与昨天的量都不进今日"
    assert today["usage"]["connections"] == 2
    assert today["usage"]["devices"] == 1
    assert [row["deviceId"] for row in today["devices"]["list"]] == [phone["deviceId"]]
    assert today["devices"]["list"][0]["name"] == "iPhone"
    # 今日版本分布：每个构建挂多少台设备、多少个账号（同账号多设备只算一次）。
    assert today["usage"]["builds"] == [{"build": "1.2.3", "devices": 1, "accounts": 1}]
    assert [row["accountId"] for row in today["topAccounts"]] == [account["accountId"]]
    assert today["topAccounts"][0]["egressBytes"] == 1000
    # 设备三态：今日新增只算真实设备（iPhone / iPad），今日活跃是连过中转的那些。
    assert today["devices"]["new"] == 2 and today["devices"]["active"] == 1
    assert today["devices"]["live"] == 2, "在线设备数也只数真实设备（iPhone / iPad）"
    assert [row["threadId"] for row in today["feedback"]["threads"]] == [fresh["threadId"]]
    assert today["feedback"]["new"] == 1 and today["feedback"]["open"] == 1
    assert today["invites"]["used"] == 1
    assert [row["inviteNote"] for row in today["invites"]["enrollments"]] == ["今天登记的"]
    assert other["deviceId"] not in [row["deviceId"] for row in today["devices"]["list"]]

    # 今日的数字必须与 `usage --days 1`（同一口径的那条命令）对得上。
    code, usage = run_cli(db, "usage", "--days", "1", capsys=capsys)
    assert code == 0
    assert sum(int(row["egressBytes"]) for row in usage) >= today["usage"]["egressBytes"]


def test_ops_report_today_is_empty_on_a_quiet_day(tmp_path, capsys):
    """今天没有任何活动时，今日板块照样齐全、计数为 0（渲染层靠它画空态）。"""
    db = str(tmp_path / "state.db")
    store = Store(db)
    account = store.create_account("ops")
    agent = store.register_agent(account["accountId"], "mac")
    device = store.claim_pair_code(
        store.mint_pair_code(agent["agentId"], ttl_ms=60_000)["code"], device_name="iPhone")
    store.add_usage([{"day": local_day(now_ms() / 1000 - 86_400), "deviceId": device["deviceId"],
                      "agentId": agent["agentId"], "accountId": account["accountId"],
                      "egressBytes": 4096, "connections": 1, "at": now_ms() - 86_400_000,
                      "lastBuild": "1.2.3"}])
    store.close()

    code, report = run_cli(db, "ops-report", "--days", "30", capsys=capsys)
    assert code == 0
    today = report["today"]
    assert today["usage"] == {"egressBytes": 0, "connections": 0, "devices": 0, "accounts": 0,
                              "firstSeenAt": None, "lastSeenAt": None, "builds": []}
    assert today["topAccounts"] == [] and today["devices"]["list"] == []
    # 设备是今天刚配的，所以「今日新增」是 1；流量、活跃、反馈、登记仍是 0。
    assert today["devices"]["new"] == 1 and today["devices"]["active"] == 0
    assert today["feedback"] == {"new": 0, "open": 0, "replied": 0, "threads": []}
    assert today["invites"] == {"used": 0, "enrollments": []}


def test_the_digest_read_method_gives_the_excerpt_and_the_first_reply_time(tmp_path):
    """`ops-report` 与 `feedback-list` 共用它取"用户先说了什么"和"隔了多久回第一句"。

    主题（`subject`）也在这一份摘要里——它落在 `feedbackThreads` 上，而摘要在
    `feedbackMessages` 上，所以这一次要一起取回来；`format` 同理，而且是**首条**
    留言的那一个（摘要取的就是首条）。
    """
    store = Store(str(tmp_path / "state.db"))
    try:
        thread = store.create_feedback_thread(ticket_hash=sha256_hex("fk_1"), text="x" * 100,
                                              subject="点了没反应", at=1_000)
        store.append_feedback_message(thread["threadId"], "回信", author="owner", at=2_000)
        store.append_feedback_message(thread["threadId"], "<h1>报告</h1>", author="owner",
                                      format="html", at=3_000)

        digest = store.feedback_digest([thread["threadId"], "th_nope", thread["threadId"]])
        assert set(digest) == {thread["threadId"]}, "重复的 id 只算一次，不存在的跳过"
        assert digest[thread["threadId"]] == {"subject": "点了没反应", "excerpt": "x" * 80,
                                              "format": "text", "firstReplyAt": 2_000}
        assert store.feedback_digest([]) == {}
    finally:
        store.close()


def test_resolve_as_of_maps_now_yesterday_and_a_date_to_an_anchor():
    """`--as-of` 的三种取值 → 锚点：`now` 是不给锚点，其余两种锚到那一整天最后一毫秒。

    日报改到每天 00:00 跑（owner 2026-10-12 要求："发刚过去的一整天"）：那一刻若按
    "今天"算，新的一天刚开头，「今日」板块全是 0。锚点必须落在刚结束的那一天。
    """
    assert admin._resolve_as_of("now") is None and admin._resolve_as_of(None) is None

    today = local_day()
    anchor = admin._resolve_as_of("yesterday")
    assert datetime.datetime.fromtimestamp(anchor / 1000).strftime("%Y%m%d") == \
        str(admin._day_shift(today, -1))
    assert admin._resolve_as_of("2026-10-12") == admin._day_start_ms(20261012) + 86_400_000 - 1
    # 跨月跨年由 `_day_shift` 负责，不能用整数加减（20261030 + 7 ≠ 20261037）。
    assert admin._resolve_as_of("2026-10-31") == admin._day_start_ms(20261101) - 1

    with pytest.raises(admin.StoreError) as caught:
        admin._resolve_as_of("2026-13-01")
    assert "--as-of" in str(caught.value)


def yesterday_and_today_usage(tmp_path) -> tuple[str, dict]:
    """昨天与今天各一条用量（数字可区分）+ 各一条反馈，用来验锚点选对了哪一天。"""
    db = str(tmp_path / "state.db")
    store = Store(db)
    account = store.create_account("ops")
    agent = store.register_agent(account["accountId"], "mac")
    device = store.claim_pair_code(
        store.mint_pair_code(agent["agentId"], ttl_ms=60_000)["code"], device_name="iPhone")
    today = local_day()
    yesterday = admin._day_shift(today, -1)
    for day, egress, connections in ((yesterday, 3000, 2), (today, 7000, 5)):
        store.add_usage([{"day": day, "deviceId": device["deviceId"], "agentId": agent["agentId"],
                          "accountId": account["accountId"], "egressBytes": egress,
                          "connections": connections, "at": now_ms(), "lastBuild": "1.2.3"}])
    old = store.create_feedback_thread(ticket_hash=sha256_hex("fk_old"), text="昨天提的",
                                       at=now_ms() - 86_400_000)
    fresh = store.create_feedback_thread(ticket_hash=sha256_hex("fk_new"), text="今天提的")
    store.close()
    return db, {"device": device, "today": today, "yesterday": yesterday,
                "old": old, "fresh": fresh}


def test_ops_report_as_of_yesterday_is_the_whole_previous_day(tmp_path, capsys):
    """`--as-of yesterday`：日报覆盖刚过去的一整天，窗口也以那一天为界。"""
    db, made = yesterday_and_today_usage(tmp_path)

    code, report = run_cli(db, "ops-report", "--days", "3", "--as-of", "yesterday",
                           capsys=capsys)
    assert code == 0
    assert report["today"]["day"] == made["yesterday"]
    assert report["today"]["usage"]["egressBytes"] == 3000, "今日板块要的是昨天那一整天"
    assert report["today"]["usage"]["connections"] == 2
    # 今天的流量不在窗口里，也不在昨日板块里。
    assert [entry["day"] for entry in report["usage"]["perDay"]][-1] == made["yesterday"]
    assert made["today"] not in [entry["day"] for entry in report["usage"]["perDay"]]
    assert report["usage"]["perDay"][-1]["egressBytes"] == 3000
    assert report["devices"]["newPerDay"][-1]["day"] == made["yesterday"]
    # 反馈同口径：锚点之后（今天）新建的线程不算进来。
    assert [row["threadId"] for row in report["feedback"]["threads"]] == [made["old"]["threadId"]]
    assert report["today"]["feedback"]["new"] == 1

    # 锚点在过去，`generatedAt` 仍是真实的生成时刻（渲染层靠它写"生成时间"）。
    assert report["asOf"] == admin._resolve_as_of("yesterday")
    assert report["generatedAt"] >= report["asOf"]


def test_ops_report_as_of_a_date_covers_that_day(tmp_path, capsys):
    """`--as-of YYYY-MM-DD`：补跑历史日报用，窗口最后一天就是那一天。"""
    db = str(tmp_path / "state.db")
    store = Store(db)
    account = store.create_account("ops")
    agent = store.register_agent(account["accountId"], "mac")
    device = store.claim_pair_code(
        store.mint_pair_code(agent["agentId"], ttl_ms=60_000)["code"], device_name="iPhone")
    store.add_usage([{"day": 20261012, "deviceId": device["deviceId"], "agentId": agent["agentId"],
                      "accountId": account["accountId"], "egressBytes": 1234, "connections": 7,
                      "at": now_ms(), "lastBuild": "1.2.3"}])
    store.close()

    code, report = run_cli(db, "ops-report", "--days", "5", "--as-of", "2026-10-12", capsys=capsys)
    assert code == 0
    assert report["today"]["day"] == 20261012
    assert report["today"]["usage"]["egressBytes"] == 1234
    assert [entry["day"] for entry in report["usage"]["perDay"]] == \
        [20261008, 20261009, 20261010, 20261011, 20261012]
    assert report["usage"]["perDay"][-1]["egressBytes"] == 1234
    assert report["usage"]["peakDay"] == {"day": 20261012, "egressBytes": 1234}


def test_invite_report_separates_usable_from_expired(tmp_path):
    """余量要分三本账：能用、7 天内到期、已过期没用。`remaining` 是老口径（不区分过期）。"""
    store = Store(str(tmp_path / "state.db"))
    store.mint_invite(ttl_ms=60 * 86_400_000, note="long")
    store.mint_invite(ttl_ms=2 * 86_400_000, note="soon")
    store.mint_invite(ttl_ms=-1000, note="dead")
    try:
        report = admin._invite_report(store, now_ms(), [])
    finally:
        store.close()
    assert (report["minted"], report["remaining"]) == (3, 3)
    assert (report["usable"], report["expiringSoon"], report["expiredUnused"]) == (2, 1, 1)
    # 最早到期的排前面：下一批什么时候失效，看第一行。
    assert [row["note"] for row in report["unused"]] == ["soon", "long"]


def test_ops_report_rejects_an_unparsable_as_of(tmp_path, capsys):
    """写错的日期是业务失败（退出码 1）并把取值原样带出来，不静默当成今天。"""
    db = str(tmp_path / "state.db")
    Store(db).close()

    code, out = run_cli(db, "ops-report", "--as-of", "2026-13-01", capsys=capsys)
    assert code == 1, "业务失败（不是用法错误 2，也不是静默成功）"
    assert "ok" not in out and "--as-of" in out["stderr"] and "2026-13-01" in out["stderr"]


def test_ops_report_without_as_of_still_covers_today_to_now(tmp_path, capsys):
    """不给 `--as-of` 时口径不变：锚点就是此刻（白天手工看日报的那条路）。"""
    db, made = yesterday_and_today_usage(tmp_path)

    code, report = run_cli(db, "ops-report", "--days", "3", capsys=capsys)
    assert code == 0
    assert report["today"]["day"] == made["today"]
    assert report["today"]["usage"]["egressBytes"] == 7000
    assert report["asOf"] == report["generatedAt"]
    assert report["usage"]["perDay"][-1]["day"] == made["today"]


# ── 2026-10-17：版本分布与「过去 72 小时」活跃分布 ─────────────────────────────

def _version_fixture(tmp_path, rows):
    """建一个库，写入给定的用量行，返回 (store, devices 映射, now)。"""
    store = Store(str(tmp_path / "state.db"))
    at = now_ms()
    device_map = {}
    entries = []
    for device_id, version, account_id, seen_at in rows:
        device_map[device_id] = {"deviceId": device_id, "appVersion": version,
                                 "accountId": account_id, "agentId": "agt_a"}
        entries.append({"day": local_day(seen_at / 1000), "deviceId": device_id,
                        "agentId": "agt_a", "accountId": account_id,
                        "egressBytes": 1024, "connections": 1, "at": seen_at,
                        "lastBuild": version})
    store.add_usage(entries)
    return store, device_map, at


def test_version_report_counts_accounts_once_per_version(tmp_path):
    """同一账号的两台设备，在版本分布里只算一个账号、两台设备。

    这条口径和「活跃账号」一致：owner 看的是"多少人在哪个版本"，不是设备行数。
    """
    at = now_ms()
    store, devices, _ = _version_fixture(tmp_path, [
        ("dev_a", "1.0 20261013.2233", "acc_a", at - 1000),
        ("dev_b", "1.0 20261013.2233", "acc_a", at - 2000),
        ("dev_c", "1.0 (20260924.1925)", "acc_b", at - 3000),
    ])
    try:
        reported = admin._version_report(store, since_ms=at - 48 * 3_600_000, until_ms=at,
                                         devices=devices, debug_ids=set(),
                                         known_ids=set(devices), external=set())
    finally:
        store.close()
    by_version = {row["appVersion"]: row for row in reported}
    newest = by_version["1.0 20261013.2233"]
    assert newest["devices"] == 2 and newest["accounts"] == 1
    assert by_version["1.0 (20260924.1925)"]["devices"] == 1
    # 设备多的版本排前面。
    assert reported[0]["appVersion"] == "1.0 20261013.2233"


def test_version_report_only_counts_usage_inside_the_window(tmp_path):
    """近 48 小时口径：窗口外没有用量行的设备不进版本分布（看用量行，不看 lastSeen）。"""
    at = now_ms()
    store, devices, _ = _version_fixture(tmp_path, [
        ("dev_new", "1.0 20261017.1430", "acc_new", at - 3_600_000),
        ("dev_old", "1.0 20260924.1925", "acc_old", at - 72 * 3_600_000),
    ])
    try:
        reported = admin._version_report(store, since_ms=at - 48 * 3_600_000, until_ms=at,
                                         devices=devices, debug_ids=set(),
                                         known_ids=set(devices), external=set())
    finally:
        store.close()
    assert [row["appVersion"] for row in reported] == ["1.0 20261017.1430"]
    assert reported[0]["accounts"] == 1 and reported[0]["devices"] == 1


def test_hourly_activity_counts_accounts_with_a_device_connected():
    """只有**设备**连着才算活跃：电脑的连接器一直挂着，不设备连接不该占一格。

    `closed a socket that had already been replaced` 是旧 socket 的收尾，忽略。
    """
    tz = datetime.timezone(datetime.timedelta(hours=8))
    end = int(datetime.datetime(2026, 10, 17, 16, 0, 0, tzinfo=tz).timestamp() * 1000)
    at_14 = int(datetime.datetime(2026, 10, 17, 14, 0, 0, tzinfo=tz).timestamp() * 1000)
    at_15 = at_14 + 3_600_000
    lines = [
        "2026-10-17T14:10:00+0800 host python[1]: 2026-10-17 14:10:00,000 INFO relay relay: "
        "device dev_a (iPhone) attached to agent agt_a",
        "2026-10-17T15:20:00+0800 host python[1]: 2026-10-17 15:20:00,000 INFO relay relay: "
        "device dev_b (Chrome) attached to agent agt_a",
        "2026-10-17T15:30:00+0800 host python[1]: 2026-10-17 15:30:00,000 INFO relay relay: "
        "device dev_b closed a socket that had already been replaced; no detach "
        "notification sent for it (agent agt_a)",
        "2026-10-17T15:40:00+0800 host python[1]: 2026-10-17 15:40:00,000 INFO relay relay: "
        "device dev_b detached (socket closed) (agent agt_a)",
        "2026-10-17T15:50:00+0800 host python[1]: 2026-10-17 15:50:00,000 INFO relay relay: "
        "device dev_a detached (socket closed) (agent agt_a)",
    ]
    devices = {"dev_a": {"accountId": "acc_1", "agentId": "agt_a"},
               "dev_b": {"accountId": "acc_1", "agentId": "agt_a"}}
    agents = {"agt_a": {"accountId": "acc_1"}}
    buckets = admin._hourly_activity(6, end, devices, agents, lines=lines)
    assert len(buckets) == 7, "6 小时窗口落成 7 个整点格（含两端）"
    by_hour = {bucket["hourStartAt"]: bucket for bucket in buckets}
    # 14 点只有 dev_a；15 点先 dev_a 后 dev_b，但同属 acc_1，账号数仍是 1。
    assert by_hour[at_14] == {"hourStartAt": at_14, "accounts": 1, "devices": 1}
    assert by_hour[at_15] == {"hourStartAt": at_15, "accounts": 1, "devices": 2}


def test_hourly_activity_falls_back_to_the_agent_account_for_purged_devices():
    """设备行被清理工具删掉时，用日志里带的 agent 归属到账号，不丢这一格。"""
    tz = datetime.timezone(datetime.timedelta(hours=8))
    end = int(datetime.datetime(2026, 10, 17, 16, 0, 0, tzinfo=tz).timestamp() * 1000)
    lines = [
        "2026-10-17T15:10:00+0800 host python[1]: 2026-10-17 15:10:00,000 INFO relay relay: "
        "device dev_gone (iPhone) attached to agent agt_a",
    ]
    buckets = admin._hourly_activity(2, end, {}, {"agt_a": {"accountId": "acc_9"}}, lines=lines)
    assert buckets[-1]["accounts"] == 1 and buckets[-1]["devices"] == 1


def test_hourly_activity_skips_debug_devices():
    """调试设备（DSH- 前缀）不进日报；也不能因为兜底到 agent 就算成 owner 的活跃。"""
    tz = datetime.timezone(datetime.timedelta(hours=8))
    end = int(datetime.datetime(2026, 10, 17, 16, 0, 0, tzinfo=tz).timestamp() * 1000)
    lines = [
        "2026-10-17T15:10:00+0800 host python[1]: 2026-10-17 15:10:00,000 INFO relay relay: "
        "device dev_dbg (iPhone) attached to agent agt_owner",
    ]
    devices = {"dev_dbg": {"accountId": "acc_owner", "agentId": "agt_owner",
                           "name": "DSH-Test", "model": "iPhone 15"}}
    buckets = admin._hourly_activity(2, end, devices,
                                     {"agt_owner": {"accountId": "acc_owner"}}, lines=lines)
    assert all(bucket["accounts"] == 0 and bucket["devices"] == 0 for bucket in buckets)


def test_hourly_activity_returns_none_when_the_journal_is_unreadable(monkeypatch):
    """读不到日志就是 `None`：渲染层据此写「跳过」，不拿空表冒充 0。"""
    monkeypatch.setattr(admin, "_read_journal", lambda *a, **k: None)
    assert admin._hourly_activity(72, now_ms(), {}, {}) is None


def test_ops_report_carries_the_version_table_and_the_hourly_window(tmp_path, capsys, monkeypatch):
    """两个新板块必须出现在 `ops-report` 的 JSON 里，且读不到日志时 buckets 是 None。"""
    monkeypatch.setattr(admin, "_read_journal", lambda *a, **k: None)
    db, made = yesterday_and_today_usage(tmp_path)

    code, report = run_cli(db, "ops-report", "--days", "3", capsys=capsys)
    assert code == 0
    assert "versions" in report and isinstance(report["versions"], list)
    hourly = report["hourlyActivity"]
    assert hourly["windowHours"] == 72
    assert hourly["buckets"] is None
