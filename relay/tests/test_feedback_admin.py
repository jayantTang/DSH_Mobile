"""owner 侧反馈命令（014 T033/T034）：`feedback-list/show/reply/notify/delete`。

这些命令就是 owner 的产品面——我在服务器上读反馈、回信、群发、响应隐私删除请求，
所以用例一律走 `argv`（照 `tests/test_admin_push.py` 的 `run_cli`），断言**打印出来的
JSON**。两个写命令的预演用例都会回库里再数一遍：契约里"不加 `--yes` 不写库"是硬要求，
只断言输出等于没验。

库一律是 `tmp_path` 里新建的（fixture 自己关连接，要核对事实就另开一个连接重新读），
绝不碰生产 `state.db`。
"""

from __future__ import annotations

import json
import re

import pytest

import admin
from store import Store, now_ms, sha256_hex


def run_cli(db: str, *args: str, capsys) -> tuple[int, object]:
    """跑一条命令，把 stdout 当 JSON 读回来（没有输出时退回 stderr 文本）。"""
    code = admin.main(["--db", db, *args])
    captured = capsys.readouterr()
    out = captured.out.strip()
    return code, (json.loads(out) if out else {"stderr": captured.err.strip()})


def run_text(db: str, *args: str, capsys) -> tuple[int, str]:
    """给 `--template` 用：它的输出是给人编辑的骨架，不是 JSON。"""
    code = admin.main(["--db", db, *args])
    return code, capsys.readouterr().out


def query(db: str, sql: str, params: tuple = ()) -> list[dict]:
    """另开一个连接直接看库里的事实——写完之后的真相在库里，不在输出里。"""
    store = Store(db)
    try:
        return [dict(row) for row in store._rows(sql, params)]
    finally:
        store.close()


def count(db: str, table: str) -> int:
    return int(query(db, f"SELECT COUNT(*) AS n FROM {table}")[0]["n"])


@pytest.fixture
def relay(tmp_path) -> dict:
    """一条已配对设备提的反馈，外加一台已撤销的设备（通知范围要用到）。"""
    path = str(tmp_path / "state.db")
    store = Store(path)
    account = store.create_account("ops")
    agent = store.register_agent(account["accountId"], "mac")
    device = store.claim_pair_code(
        store.mint_pair_code(agent["agentId"], ttl_ms=60_000)["code"], device_name="iPhone")
    gone = store.claim_pair_code(
        store.mint_pair_code(agent["agentId"], ttl_ms=60_000)["code"], device_name="iPad")
    store.revoke_device(gone["deviceId"])
    thread = store.create_feedback_thread(
        ticket_hash=sha256_hex("fk_one"), text="点了新建会话之后一直转圈",
        account_id=account["accountId"], device_id=device["deviceId"],
        device_model="iPhone17,1", app_version="1.2.3 (20261013)", system_version="iOS 18.2")
    store.close()
    return {"db": path, "agentId": agent["agentId"], "accountId": account["accountId"],
            "deviceId": device["deviceId"], "revokedId": gone["deviceId"],
            "threadId": thread["threadId"]}


# ── T033：清单 / 详情 / 回信 ─────────────────────────────────────────────────


def test_feedback_list_reports_the_fields_the_owner_reads(relay, capsys):
    code, rows = run_cli(relay["db"], "feedback-list", capsys=capsys)
    assert code == 0
    (row,) = rows
    assert row["threadId"] == relay["threadId"]
    assert row["status"] == "open" and row["ownerUnread"] == 1 and row["messages"] == 1
    assert row["createdAt"] == row["lastMessageAt"] > 0
    assert row["source"] == {"kind": "device", "deviceId": relay["deviceId"],
                             "accountId": relay["accountId"], "deviceModel": "iPhone17,1",
                             "appVersion": "1.2.3 (20261013)", "systemVersion": "iOS 18.2"}
    assert row["excerpt"] == "点了新建会话之后一直转圈"


def test_feedback_list_sorts_by_last_activity_and_filters(relay, capsys):
    """最近活动的排最前；`--status` 只认 open/replied/all，`--since` 卡创建时间。"""
    store = Store(relay["db"])
    try:
        old = store.create_feedback_thread(ticket_hash=sha256_hex("fk_old"), text="老问题",
                                           at=now_ms() - 40 * 86_400_000)
        answered = store.create_feedback_thread(ticket_hash=sha256_hex("fk_two"),
                                                text="第二个问题", at=now_ms() - 3_600_000)
        store.append_feedback_message(answered["threadId"], "回信", author="owner",
                                      at=now_ms() + 5_000)
    finally:
        store.close()

    code, rows = run_cli(relay["db"], "feedback-list", capsys=capsys)
    assert code == 0
    assert [row["threadId"] for row in rows] == [answered["threadId"], relay["threadId"],
                                                 old["threadId"]]

    code, open_rows = run_cli(relay["db"], "feedback-list", "--status", "open", capsys=capsys)
    assert code == 0
    assert {row["threadId"] for row in open_rows} == {relay["threadId"], old["threadId"]}
    code, replied = run_cli(relay["db"], "feedback-list", "--status", "replied", capsys=capsys)
    assert [row["threadId"] for row in replied] == [answered["threadId"]]

    code, recent = run_cli(relay["db"], "feedback-list", "--since", "7", capsys=capsys)
    assert code == 0 and old["threadId"] not in {row["threadId"] for row in recent}
    code, limited = run_cli(relay["db"], "feedback-list", "--limit", "1", capsys=capsys)
    assert code == 0 and len(limited) == 1


def test_feedback_list_excerpt_is_the_first_message_cut_to_80_chars(relay, capsys):
    """摘要要的是用户第一句话，不是最后一句——清单默认不带留言，所以要单独取。"""
    long_text = "第" + "很长的问题描述" * 20
    store = Store(relay["db"])
    try:
        thread = store.create_feedback_thread(ticket_hash=sha256_hex("fk_long"), text=long_text)
        store.append_feedback_message(thread["threadId"], "补充：还是不行", author="user",
                                      at=now_ms() + 1_000)
    finally:
        store.close()

    code, rows = run_cli(relay["db"], "feedback-list", capsys=capsys)
    assert code == 0
    row = next(entry for entry in rows if entry["threadId"] == thread["threadId"])
    assert row["excerpt"] == long_text[:80] and len(row["excerpt"]) == 80
    assert row["messages"] == 2


def test_feedback_show_returns_the_trail_in_time_order_and_marks_it_read(relay, capsys):
    """`feedback-show` 就是"owner 已看过"的落点：`ownerReadAt` 推到最新一条用户消息。"""
    base = now_ms() + 1_000
    store = Store(relay["db"])
    try:
        store.append_feedback_message(relay["threadId"], "我们这边看一下", author="owner",
                                      at=base + 1_000)
        store.append_feedback_message(relay["threadId"], "还是不行，附上日志", author="user",
                                      at=base + 2_000)
    finally:
        store.close()

    code, thread = run_cli(relay["db"], "feedback-show", "--thread", relay["threadId"],
                           capsys=capsys)
    assert code == 0
    assert thread["threadId"] == relay["threadId"] and thread["status"] == "open"
    assert [message["author"] for message in thread["messages"]] == ["user", "owner", "user"]
    assert [message["body"] for message in thread["messages"]] == [
        "点了新建会话之后一直转圈", "我们这边看一下", "还是不行，附上日志"]
    stamps = [message["createdAt"] for message in thread["messages"]]
    assert stamps == sorted(stamps), "留言按时间正序"
    for message in thread["messages"]:
        assert set(message) >= {"messageId", "author", "body", "createdAt"}
    assert thread["ownerReadAt"] == base + 2_000, "推到最新一条用户消息"

    code, rows = run_cli(relay["db"], "feedback-list", capsys=capsys)
    assert code == 0 and rows[0]["ownerUnread"] == 0, "看过之后清单里的'新'归零"
    # 取件凭据的哈希按仓库口径只留截断（`invite-list`/`agent-list` 同款）。
    assert thread["ticketHash"].endswith("…")


def test_feedback_show_of_a_missing_thread_exits_one(relay, capsys):
    code, report = run_cli(relay["db"], "feedback-show", "--thread", "th_nope", capsys=capsys)
    assert code == 1 and report == {"ok": False, "error": "thread not found"}


def test_feedback_reply_stores_the_body_verbatim_and_flips_the_status(relay, capsys):
    draft = ("称呼：你好\n\n正文：已经修好了，下个开发版就能看到。\n\n"
             "署名：DSH Mobile 团队\n日期：2026-10-13\n")
    code, report = run_cli(relay["db"], "feedback-reply", "--thread", relay["threadId"],
                           "--body", draft, capsys=capsys)
    assert code == 0 and report["ok"] is True
    assert report["threadId"] == relay["threadId"] and report["messageId"].startswith("fm_")
    assert report["createdAt"] > 0

    (stored,) = query(relay["db"], "SELECT body, author FROM feedbackMessages WHERE messageId=?",
                      (report["messageId"],))
    assert stored == {"body": draft, "author": "owner"}, "正文原样入库，服务端不加工"
    assert query(relay["db"], "SELECT status FROM feedbackThreads WHERE threadId=?",
                 (relay["threadId"],))[0]["status"] == "replied"


def test_feedback_reply_takes_a_body_file_and_refuses_a_missing_thread(relay, tmp_path, capsys):
    draft = tmp_path / "reply.txt"
    draft.write_text("称呼：你好\n\n正文：查到了，是缓存的问题。\n", encoding="utf-8")
    code, report = run_cli(relay["db"], "feedback-reply", "--thread", relay["threadId"],
                           "--body-file", str(draft), capsys=capsys)
    assert code == 0 and report["ok"] is True

    code, report = run_cli(relay["db"], "feedback-reply", "--thread", "th_nope",
                           "--body", "写给不存在的线程", capsys=capsys)
    assert code == 1 and report == {"ok": False, "error": "thread not found"}

    # 正文两种给法都缺、或者都给了，都是用法错误——不许默默发一条空的。
    code, report = run_cli(relay["db"], "feedback-reply", "--thread", relay["threadId"],
                           capsys=capsys)
    assert code == 1 and "stderr" in report
    code, report = run_cli(relay["db"], "feedback-reply", "--thread", relay["threadId"],
                           "--body", "x", "--body-file", str(draft), capsys=capsys)
    assert code == 1 and "stderr" in report
    code, report = run_cli(relay["db"], "feedback-reply", "--thread", relay["threadId"],
                           "--body", "   \n", capsys=capsys)
    assert code == 1 and "stderr" in report
    assert int(query(relay["db"],
                     "SELECT COUNT(*) AS n FROM feedbackMessages WHERE TRIM(body)=''")[0]["n"]) == 0


def test_feedback_reply_template_has_the_four_parts_and_writes_nothing(relay, capsys):
    """骨架的形态是**真信件**：称呼行、正文、署名、日期。

    四部分仍在，但不写成「称呼：」「正文：」这类字段名——那些字会原样渲染到手机上的
    信件卡片与列表摘要里（2026-10-12 仿真器上看到「称呼：你好」成了列表标题之后改的）。
    """
    before = count(relay["db"], "feedbackMessages")
    code, text = run_text(relay["db"], "feedback-reply", "--template", capsys=capsys)
    assert code == 0
    lines = [line for line in text.splitlines() if line.strip()]
    assert lines[0].endswith("："), "第一行是称呼（以冒号收尾）"
    assert "<对用户的称呼>" in lines[0]
    assert any("<回信正文" in line for line in lines), "正文段落要在"
    assert "DSH Mobile 团队" in lines, "署名默认是团队名"
    assert re.search(r"^\d{4}-\d{2}-\d{2}$", lines[-1]), "最后一行是日期"
    assert count(relay["db"], "feedbackMessages") == before, "--template 不写库"


# ── T034：防误发 ─────────────────────────────────────────────────────────────


def test_feedback_notify_without_yes_only_previews(relay, capsys):
    """群发前先看人数（FR-016）：不带 `--yes` 一律预演，库里不留任何痕迹。"""
    code, report = run_cli(relay["db"], "feedback-notify", "--body", "今晚 22:00 维护",
                           "--subject", "服务通知", capsys=capsys)
    assert code == 0
    assert report["ok"] is True and report["dryRun"] is True and report["recipients"] == 1
    assert report["devices"] == [relay["deviceId"]], "已撤销的设备不在收件人里"
    assert count(relay["db"], "notices") == 0 and count(relay["db"], "noticeDeliveries") == 0


def test_feedback_notify_with_yes_writes_one_notice_and_unread_deliveries(relay, capsys):
    store = Store(relay["db"])
    try:
        extra = store.claim_pair_code(
            store.mint_pair_code(relay["agentId"], ttl_ms=60_000)["code"], device_name="iPhone 2")
    finally:
        store.close()

    code, report = run_cli(relay["db"], "feedback-notify", "--body", "今晚 22:00 维护",
                           "--subject", "服务通知", "--yes", capsys=capsys)
    assert code == 0 and report["ok"] is True and report["recipients"] == 2
    assert report["noticeId"].startswith("nt_") and report["createdAt"] > 0

    (notice,) = query(relay["db"], "SELECT subject, body, createdBy FROM notices WHERE noticeId=?",
                      (report["noticeId"],))
    assert notice["subject"] == "服务通知" and notice["body"] == "今晚 22:00 维护"
    assert notice["createdBy"], "发送记录要有来源标注"

    deliveries = query(relay["db"], "SELECT deviceId, readAt FROM noticeDeliveries WHERE noticeId=?",
                       (report["noticeId"],))
    assert {row["deviceId"] for row in deliveries} == {relay["deviceId"], extra["deviceId"]}
    assert all(row["readAt"] is None for row in deliveries), "投递即未读，等手机自己来读"
    assert count(relay["db"], "notices") == 1


def test_feedback_notify_refuses_to_write_when_nothing_matches(relay, capsys):
    store = Store(relay["db"])
    try:
        store.revoke_device(relay["deviceId"])  # 至此一台未撤销设备都没有
    finally:
        store.close()

    code, report = run_cli(relay["db"], "feedback-notify", "--body", "空发", "--yes", capsys=capsys)
    assert code == 1 and report["ok"] is False and report["recipients"] == 0
    assert report["error"] == "no recipients"
    assert count(relay["db"], "notices") == 0, "没有收件人就不许留下发送记录"


def test_feedback_notify_refuses_a_device_that_is_unknown_or_revoked(relay, capsys):
    """点名一台不存在/已撤销的设备是错误：打错一个 id 却看到"发出去了"最糟。"""
    for wrong in ("dev_nope", relay["revokedId"]):
        code, report = run_cli(relay["db"], "feedback-notify", "--body", "x",
                               "--device", wrong, capsys=capsys)
        assert code == 1 and wrong in report["stderr"]
    assert count(relay["db"], "notices") == 0


def test_feedback_delete_without_yes_only_reports_the_message_count(relay, capsys):
    store = Store(relay["db"])
    try:
        store.append_feedback_message(relay["threadId"], "再来一条", author="user")
    finally:
        store.close()

    code, report = run_cli(relay["db"], "feedback-delete", "--thread", relay["threadId"],
                           capsys=capsys)
    assert code == 0
    assert report["dryRun"] is True and report["exists"] is True and report["messages"] == 2
    assert count(relay["db"], "feedbackThreads") == 1, "不带 --yes 不删"


def test_feedback_delete_with_yes_removes_the_thread_and_its_messages(relay, capsys):
    code, report = run_cli(relay["db"], "feedback-delete", "--thread", relay["threadId"],
                           "--yes", capsys=capsys)
    assert code == 0 and report["ok"] is True and report["messages"] == 1
    assert count(relay["db"], "feedbackThreads") == 0
    assert count(relay["db"], "feedbackMessages") == 0

    code, report = run_cli(relay["db"], "feedback-delete", "--thread", relay["threadId"],
                           "--yes", capsys=capsys)
    assert code == 1 and report == {"ok": False, "error": "thread not found"}
