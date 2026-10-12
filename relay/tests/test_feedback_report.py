"""`admin.py ops-report`：日报的四个板块（014 T040）。

日报是在本机渲染的（服务器只出原始数据），所以这份 JSON 的字段名一旦改了口径，
`scripts/dev/*.mjs` 的图表会静默变空。用例因此把字段名钉在**已有的**命令输出上
（`usage` / `enrollments` / `device-list`），另外核一遍空库不报错、计数为 0。

库一律是 `tmp_path` 里新建的；`ops-report` 自己开连接读，写完就关。
"""

from __future__ import annotations

import json

import admin
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
                                  "medianFirstReplyHours": None, "threads": []}
    assert report["devices"]["paired"] == 0 and report["devices"]["active7d"] == 0
    assert report["devices"]["revoked"] == 0 and report["devices"]["list"] == []
    assert 0 < len(report["devices"]["newPerDay"]) <= 3
    assert all(entry["count"] == 0 for entry in report["devices"]["newPerDay"])
    assert 0 < len(report["usage"]["perDay"]) <= 3
    assert all(entry["egressBytes"] == 0 for entry in report["usage"]["perDay"])
    assert report["usage"]["perDay"][-1]["day"] == local_day()
    assert report["usage"]["topAccounts"] == []
    assert report["usage"]["totals"] == {"egressBytes": 0, "connections": 0}
    assert report["invites"] == {"minted": 0, "used": 0, "remaining": 0, "enrollments": []}


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
    assert report["usage"]["topAccounts"][0] == {
        "accountId": made["account"]["accountId"], "name": "ops", "egressBytes": 4096}
    assert report["usage"]["totals"] == {
        "egressBytes": sum(int(entry["egressBytes"]) for entry in usage),
        "connections": sum(int(entry["connections"]) for entry in usage)}

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
    assert today == {"day": local_day(), "egressBytes": 1250, "connections": 3, "devices": 2}
    assert report["usage"]["totals"] == {"egressBytes": 1250, "connections": 3}
    assert report["invites"]["minted"] == 1 and report["invites"]["remaining"] == 1
    assert report["invites"]["enrollments"] == []


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
                                         at=now - 2 * 86_400_000)
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


def test_the_digest_read_method_gives_the_excerpt_and_the_first_reply_time(tmp_path):
    """`ops-report` 与 `feedback-list` 共用它取"用户先说了什么"和"隔了多久回第一句"。"""
    store = Store(str(tmp_path / "state.db"))
    try:
        thread = store.create_feedback_thread(ticket_hash=sha256_hex("fk_1"), text="x" * 100,
                                              at=1_000)
        store.append_feedback_message(thread["threadId"], "回信", author="owner", at=2_000)
        store.append_feedback_message(thread["threadId"], "再回一句", author="owner", at=3_000)

        digest = store.feedback_digest([thread["threadId"], "th_nope", thread["threadId"]])
        assert set(digest) == {thread["threadId"]}, "重复的 id 只算一次，不存在的跳过"
        assert digest[thread["threadId"]] == {"excerpt": "x" * 80, "firstReplyAt": 2_000}
        assert store.feedback_digest([]) == {}
    finally:
        store.close()
