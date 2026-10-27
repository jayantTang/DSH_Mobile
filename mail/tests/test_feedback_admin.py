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
    """一条已配对设备提的反馈。

    mail 侧没有账号/设备表：accountId/deviceId 是中转铸造的不透明值，
    这里用固定字符串直接落线程（DESIGN-20261015 I-4：只存值，不解释）。
    """
    path = str(tmp_path / "mail.db")
    store = Store(path)
    thread = store.create_feedback_thread(
        ticket_hash=sha256_hex("fk_one"), text="点了新建会话之后一直转圈",
        subject="新建会话一直转圈",
        account_id="acc_ops", device_id="dev_ops",
        device_model="iPhone17,1", app_version="1.2.3 (20261013)", system_version="iOS 18.2")
    store.close()
    return {"db": path, "accountId": "acc_ops", "deviceId": "dev_ops",
            "threadId": thread["threadId"]}


# ── T033：清单 / 详情 / 回信 ─────────────────────────────────────────────────


def test_feedback_list_reports_the_fields_the_owner_reads(relay, capsys):
    code, rows = run_cli(relay["db"], "feedback-list", capsys=capsys)
    assert code == 0
    (row,) = rows
    assert row["threadId"] == relay["threadId"]
    assert row["subject"] == "新建会话一直转圈", "清单里的那一行标题"
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
        assert set(message) >= {"messageId", "author", "body", "format", "createdAt"}
    assert [message["format"] for message in thread["messages"]] == ["text", "text", "text"], \
        "没指定 --format 的回信按 text"
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


# ── T064/T066：主题 subject ─────────────────────────────────────────────────


def test_feedback_show_carries_the_subject(relay, capsys):
    code, thread = run_cli(relay["db"], "feedback-show", "--thread", relay["threadId"],
                           capsys=capsys)
    assert code == 0
    assert thread["subject"] == "新建会话一直转圈"


def test_feedback_list_subject_is_null_when_the_user_did_not_write_one(relay, capsys):
    """没填主题的线程 `subject` 是 null（不是空串），展示层据此用摘要兜底。"""
    store = Store(relay["db"])
    try:
        store.create_feedback_thread(ticket_hash=sha256_hex("fk_two"), text="没写标题")
        store.create_feedback_thread(ticket_hash=sha256_hex("fk_three"), text="只敲了空格",
                                     subject="   ")
    finally:
        store.close()

    code, rows = run_cli(relay["db"], "feedback-list", capsys=capsys)
    assert code == 0
    without = [row for row in rows if row["threadId"] != relay["threadId"]]
    assert len(without) == 2
    assert all(row["subject"] is None for row in without)


def test_feedback_reply_subject_replaces_the_thread_subject(relay, capsys):
    """`--subject` 给出时改线程主题；这一串往返在清单里就有一个像邮件标题的行。"""
    code, report = run_cli(relay["db"], "feedback-reply", "--thread", relay["threadId"],
                           "--body", "称呼：你好\n\n已经修好了。\n", "--subject",
                           "  新建会话一直转圈（已定位）  ", capsys=capsys)
    assert code == 0 and report["ok"] is True
    assert query(relay["db"], "SELECT subject FROM feedbackThreads WHERE threadId=?",
                 (relay["threadId"],))[0]["subject"] == "新建会话一直转圈（已定位）", \
        "存的是去过首尾空白的那一句"

    code, rows = run_cli(relay["db"], "feedback-list", capsys=capsys)
    assert code == 0 and rows[0]["subject"] == "新建会话一直转圈（已定位）"
    code, thread = run_cli(relay["db"], "feedback-show", "--thread", relay["threadId"],
                           capsys=capsys)
    assert code == 0 and thread["subject"] == "新建会话一直转圈（已定位）"


def test_feedback_reply_without_subject_keeps_the_users_own_subject(relay, capsys):
    code, report = run_cli(relay["db"], "feedback-reply", "--thread", relay["threadId"],
                           "--body", "称呼：你好\n\n已经修好了。\n", capsys=capsys)
    assert code == 0 and report["ok"] is True
    assert query(relay["db"], "SELECT subject FROM feedbackThreads WHERE threadId=?",
                 (relay["threadId"],))[0]["subject"] == "新建会话一直转圈", "不给就沿用原主题"


def test_feedback_reply_with_a_blank_subject_clears_it(relay, capsys):
    """空白主题与提交时同一个口径：按"没填"存 NULL，不留一个空串在列表里。"""
    code, report = run_cli(relay["db"], "feedback-reply", "--thread", relay["threadId"],
                           "--body", "称呼：你好\n\n已经修好了。\n", "--subject", "   \n",
                           capsys=capsys)
    assert code == 0 and report["ok"] is True
    assert query(relay["db"], "SELECT subject FROM feedbackThreads WHERE threadId=?",
                 (relay["threadId"],))[0]["subject"] is None


def test_feedback_reply_subject_over_the_limit_writes_nothing(relay, capsys):
    """主题被拒时**连那封信也不许进库**：校验在写回信之前，不能留半封信。"""
    before = count(relay["db"], "feedbackMessages")
    code, report = run_cli(relay["db"], "feedback-reply", "--thread", relay["threadId"],
                           "--body", "称呼：你好\n\n正文。\n", "--subject", "长" * 81,
                           capsys=capsys)
    assert code == 1 and "stderr" in report
    assert "at most" in report["stderr"], report["stderr"]
    assert count(relay["db"], "feedbackMessages") == before
    assert query(relay["db"], "SELECT subject FROM feedbackThreads WHERE threadId=?",
                 (relay["threadId"],))[0]["subject"] == "新建会话一直转圈", "越界不改库"


def test_feedback_reply_subject_on_a_missing_thread_still_reports_not_found(relay, capsys):
    code, report = run_cli(relay["db"], "feedback-reply", "--thread", "th_nope",
                           "--body", "写给不存在的线程", "--subject", "主题", capsys=capsys)
    assert code == 1 and report == {"ok": False, "error": "thread not found"}


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


# ── 正文格式 --format（T079：富文本 2026-10-12）───────────────────────────────


def test_feedback_reply_defaults_to_text_and_takes_format_html(relay, capsys):
    """FR-034：回信默认 `text`（手机按 Markdown 渲染），`--format html` 走锁死的容器。"""
    code, first = run_cli(relay["db"], "feedback-reply", "--thread", relay["threadId"],
                          "--body", "称呼：你好\n\n已经修好了。\n", capsys=capsys)
    assert code == 0 and first["ok"] is True
    assert query(relay["db"], "SELECT format FROM feedbackMessages WHERE messageId=?",
                 (first["messageId"],))[0]["format"] == "text"

    code, second = run_cli(relay["db"], "feedback-reply", "--thread", relay["threadId"],
                           "--body", "<h1>日报</h1>", "--format", "html", capsys=capsys)
    assert code == 0 and second["ok"] is True
    assert query(relay["db"], "SELECT format FROM feedbackMessages WHERE messageId=?",
                 (second["messageId"],))[0]["format"] == "html"

    code, thread = run_cli(relay["db"], "feedback-show", "--thread", relay["threadId"],
                           capsys=capsys)
    assert code == 0
    assert [message["format"] for message in thread["messages"]] == ["text", "text", "html"]


def test_feedback_reply_refuses_an_unknown_format_and_writes_nothing(relay, capsys):
    """取值只认 text/html：别的值在解析命令行时就拒掉，一条留言都不留。"""
    before = count(relay["db"], "feedbackMessages")
    with pytest.raises(SystemExit) as caught:
        run_cli(relay["db"], "feedback-reply", "--thread", relay["threadId"],
                "--body", "正文", "--format", "rtf", capsys=capsys)
    assert caught.value.code == 2, "argparse 的用法错误"
    assert count(relay["db"], "feedbackMessages") == before


def test_feedback_notify_stores_the_format_it_was_given(relay, capsys):
    """通知的格式落在 `notices.format` 上：日报这类正文走 html。"""
    code, preview = run_cli(relay["db"], "feedback-notify", "--body", "<h1>日报</h1>",
                            "--format", "html", "--account", relay["accountId"], capsys=capsys)
    assert code == 0 and preview["dryRun"] is True
    assert count(relay["db"], "notices") == 0, "预演不写库"

    code, report = run_cli(relay["db"], "feedback-notify", "--body", "<h1>日报</h1>",
                           "--subject", "日报", "--format", "html",
                           "--account", relay["accountId"], "--yes", capsys=capsys)
    assert code == 0 and report["ok"] is True
    assert query(relay["db"], "SELECT format FROM notices WHERE noticeId=?",
                 (report["noticeId"],))[0]["format"] == "html"

    # 不给 --format 的那条按默认 text。
    code, plain = run_cli(relay["db"], "feedback-notify", "--body", "维护",
                          "--account", relay["accountId"], "--yes", capsys=capsys)
    assert code == 0
    assert query(relay["db"], "SELECT format FROM notices WHERE noticeId=?",
                 (plain["noticeId"],))[0]["format"] == "text"


def test_feedback_list_reports_the_format_of_the_first_message(relay, capsys):
    """清单行不带留言，格式顺着摘要（首条留言）出来；`html` 的回信改不了用户首条那封。"""
    store = Store(relay["db"])
    try:
        store.append_feedback_message(relay["threadId"], "<h1>日报</h1>", author="owner",
                                      format="html")
    finally:
        store.close()

    code, rows = run_cli(relay["db"], "feedback-list", capsys=capsys)
    assert code == 0
    (row,) = rows
    assert row["format"] == "text", "用户首条是 text"
    code, thread = run_cli(relay["db"], "feedback-show", "--thread", relay["threadId"],
                           capsys=capsys)
    assert code == 0 and thread["messages"][-1]["format"] == "html"


# ── T034：防误发 ─────────────────────────────────────────────────────────────


def test_feedback_notify_without_yes_only_previews(relay, capsys):
    """发送前先看账号数（FR-016/019）：不带 `--yes` 一律预演，库里不留任何痕迹。"""
    code, report = run_cli(relay["db"], "feedback-notify", "--body", "今晚 22:00 维护",
                           "--subject", "服务通知", "--account", relay["accountId"],
                           capsys=capsys)
    assert code == 0
    assert report["ok"] is True and report["dryRun"] is True and report["recipients"] == 1
    assert report["accounts"] == [relay["accountId"]], "收件人是账号，不是设备"
    assert count(relay["db"], "notices") == 0 and count(relay["db"], "noticeDeliveries") == 0


def test_feedback_notify_writes_one_delivery_row_per_account(relay, capsys):
    """019 的核心：投递行是"一个账号一行"。同一个账号点名两次也不多出收件人。"""
    code, report = run_cli(relay["db"], "feedback-notify", "--body", "今晚 22:00 维护",
                           "--subject", "服务通知",
                           "--account", relay["accountId"], "--account", "acc_others",
                           "--account", relay["accountId"], "--yes", capsys=capsys)
    assert code == 0 and report["ok"] is True and report["recipients"] == 2
    assert report["noticeId"].startswith("nt_") and report["createdAt"] > 0

    (notice,) = query(relay["db"], "SELECT subject, body, createdBy FROM notices WHERE noticeId=?",
                      (report["noticeId"],))
    assert notice["subject"] == "服务通知" and notice["body"] == "今晚 22:00 维护"
    assert notice["createdBy"], "发送记录要有来源标注"

    deliveries = query(relay["db"],
                       "SELECT accountId, readAt FROM noticeDeliveries WHERE noticeId=?",
                       (report["noticeId"],))
    assert {row["accountId"] for row in deliveries} == {relay["accountId"], "acc_others"}
    assert all(row["readAt"] is None for row in deliveries), "投递即未读，等手机自己来读"
    assert count(relay["db"], "notices") == 1


def test_feedback_notify_requires_an_explicit_recipient(relay, capsys):
    """019 收紧：不给 `--account` 也不给 `--all` 是错误，不许默认就广播给所有人。

    起因是一次真实手滑：漏了收件人参数，测试正文被写给了库里全部 58 个账号。
    """
    code, report = run_cli(relay["db"], "feedback-notify", "--body", "手滑", "--yes", capsys=capsys)
    assert code == 1, "没点名收件人：业务失败，不是写成功"
    assert "必须点名收件人" in report["stderr"]
    assert count(relay["db"], "notices") == 0, "没有点名就一条都不许写"


def test_feedback_notify_refuses_all_with_a_pointer_to_the_owner_tool(relay, capsys):
    """mail 没有账号清单：`--all` 直接拒绝，并指向 owner 工具的取名单路径（I-4）。"""
    code, report = run_cli(relay["db"], "feedback-notify", "--body", "空发",
                           "--all", "--yes", capsys=capsys)
    assert code == 1
    assert "mail 没有账号清单" in report["stderr"]
    assert count(relay["db"], "notices") == 0, "没有收件人就不许留下发送记录"


def test_feedback_notify_accepts_any_account_id_without_validation(relay, capsys):
    """点名即投递：mail 不校验账号存在（没有可查的表），名单校验在中转与 owner 工具。

    投给一个不存在的账号只是一行永远没人取的投递，不是数据问题（DESIGN-20261015 I-4）。
    """
    code, report = run_cli(relay["db"], "feedback-notify", "--body", "x",
                           "--account", "acc_nope", "--yes", capsys=capsys)
    assert code == 0 and report["recipients"] == 1
    assert count(relay["db"], "noticeDeliveries") == 1


def test_feedback_notify_has_no_device_flag_any_more(relay, capsys):
    """设备维度已经删掉：`--device` 是用法错误，不会静默被当成账号或别名。"""
    with pytest.raises(SystemExit) as caught:
        run_cli(relay["db"], "feedback-notify", "--body", "x",
                "--device", relay["deviceId"], capsys=capsys)
    assert caught.value.code == 2, "argparse 的用法错误"
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


# ── 032 FR-009：owner 侧写下的新信也要通知收件账户 ────────────────────────────

class _RecordingNotifier:
    """替掉 `admin.AccountStateNotifier`：只记"通知了谁"，不发环回请求。"""

    def __init__(self, calls: list) -> None:
        self._calls = calls

    async def __call__(self, account_id, keys=None) -> None:  # noqa: ANN001 - 与生产同签名
        if account_id:
            self._calls.append(account_id)

    async def aclose(self) -> None:
        return None


@pytest.fixture
def notified(monkeypatch):
    calls: list = []
    monkeypatch.setattr(admin, "AccountStateNotifier", lambda *a, **k: _RecordingNotifier(calls))
    return calls


def _thread_with_account(db: str, account_id: str) -> str:
    store = Store(db)
    try:
        thread = store.create_feedback_thread(ticket_hash=sha256_hex("fk_badge"), text="来信正文",
                                              account_id=account_id, device_id="dev_one")
        return thread["threadId"]
    finally:
        store.close()


def test_feedback_reply_tells_the_sender(tmp_path, capsys, notified):
    """回信落库后通知来信账户：那台手机当场去拉，角标不必等下次前台刷新。"""
    db = str(tmp_path / "mail.db")
    thread_id = _thread_with_account(db, "acc_user")

    code, out = run_cli(db, "feedback-reply", "--thread", thread_id,
                        "--body", "看到了，正在修", capsys=capsys)
    assert code == 0, out
    assert out["ok"] is True
    assert notified == ["acc_user"]


def test_feedback_notify_tells_every_recipient(tmp_path, capsys, notified):
    """群发通知落库后逐个点名通知；重复点名的账户只通知一次。"""
    db = str(tmp_path / "mail.db")

    code, out = run_cli(db, "feedback-notify", "--body", "服务通知", "--subject", "服务通知",
                        "--account", "acc_b", "--account", "acc_a", "--account", "acc_a",
                        "--yes", capsys=capsys)
    assert code == 0, out
    assert out["ok"] is True
    assert notified == ["acc_a", "acc_b"]


def test_feedback_notify_dry_run_tells_nobody(tmp_path, capsys, notified):
    """预演不写库，也不该发通知：状态压根没变。"""
    db = str(tmp_path / "mail.db")

    code, out = run_cli(db, "feedback-notify", "--body", "服务通知",
                        "--account", "acc_a", capsys=capsys)
    assert code == 0, out
    assert out["dryRun"] is True
    assert notified == []


# ── M8：清单口径（--scope）、投递可查、回滚前的 rebind ──────────────────────
#
# 「哪条线程算用户来信」只有一份判据（store.is_user_letter）；管理清单的 scope
# 只是它的两个投影：user = 命中谓词的，test = 命不中的（测试机型/调试设备）。

TEAM = "acc_team"


def seed_scope_db(db: str) -> dict:
    """一库三行：真实来信、团队自己的提交、验收单（arm64）。"""
    store = Store(db)
    try:
        letter = store.create_feedback_thread(ticket_hash=sha256_hex("fk_letter"), text="用户来信",
                                              account_id="acc_user", device_id="dev_user",
                                              device_model="iPhone15,4", at=1_000)
        mine = store.create_feedback_thread(ticket_hash=sha256_hex("fk_mine"), text="自己测试",
                                            account_id=TEAM, device_id="dev_team",
                                            device_model="iPhone15,4", at=2_000)
        simulator = store.create_feedback_thread(ticket_hash=sha256_hex("fk_sim"), text="验收单",
                                                 device_model="arm64", at=3_000)
    finally:
        store.close()
    return {"letter": letter["threadId"], "mine": mine["threadId"],
            "simulator": simulator["threadId"]}


def test_feedback_list_scope_separates_user_letters_from_test_rows(relay, tmp_path, capsys):
    seeded = seed_scope_db(str(tmp_path / "scope.db"))
    db = str(tmp_path / "scope.db")

    code, everything = run_cli(db, "--team-account", TEAM, "feedback-list", capsys=capsys)
    assert code == 0 and len(everything) == 3, "默认 scope=all，向后兼容"

    code, users = run_cli(db, "--team-account", TEAM, "feedback-list", "--scope", "user",
                          capsys=capsys)
    assert code == 0
    assert {row["threadId"] for row in users} == {seeded["letter"]}
    assert users[0]["ownerUnread"] == 1, "未读只对 user 口径计数"

    code, tests = run_cli(db, "--team-account", TEAM, "feedback-list", "--scope", "test",
                          capsys=capsys)
    assert code == 0
    assert {row["threadId"] for row in tests} == {seeded["simulator"], seeded["mine"]}
    assert all(row["ownerUnread"] == 0 for row in tests), "测试口径不产生未读"


def test_feedback_notice_stats_reports_the_delivery_coverage(relay, capsys):
    store = Store(relay["db"])
    try:
        notice = store.create_notice("日报正文", "运营日报",
                                     ["acc_a", "acc_b", "acc_c"], at=5_000)
        store.mark_notices_read("acc_a", [notice["noticeId"]])
    finally:
        store.close()

    code, stats = run_cli(relay["db"], "feedback-notice-stats", "--notice",
                          notice["noticeId"], capsys=capsys)
    assert code == 0
    assert stats == {"noticeId": notice["noticeId"], "subject": "运营日报",
                     "delivered": 3, "read": 1, "unread": 2}

    code, missing = run_cli(relay["db"], "feedback-notice-stats", "--notice", "nt_nope",
                            capsys=capsys)
    assert code == 1 and missing == {"ok": False, "error": "notice not found"}


def test_feedback_rebind_is_a_dry_run_until_yes(tmp_path, capsys):
    """回滚到旧包之前把 `teamAccountId` 按谓词补齐；不带 --yes 一个字都不写。"""
    db = str(tmp_path / "rebind.db")
    seeded = seed_scope_db(db)

    code, preview = run_cli(db, "--team-account", TEAM, "feedback-rebind", capsys=capsys)
    assert code == 0 and preview["dryRun"] is True and preview["bound"] == 1
    assert all(row["teamAccountId"] is None for row in query(
        db, "SELECT teamAccountId FROM feedbackThreads"))

    code, done = run_cli(db, "--team-account", TEAM, "feedback-rebind", "--yes", capsys=capsys)
    assert code == 0 and done == {"team": TEAM, "bound": 1, "cleared": 0, "dryRun": False}
    column = {row["threadId"]: row["teamAccountId"]
              for row in query(db, "SELECT threadId, teamAccountId FROM feedbackThreads")}
    assert column[seeded["letter"]] == TEAM
    assert column[seeded["mine"]] is None and column[seeded["simulator"]] is None


def test_feedback_show_reports_the_derived_user_letter_flag(tmp_path, capsys):
    """CLI 与 App 用同一份谓词："这封会不会进团队收件箱"在两边是同一个事实。"""
    db = str(tmp_path / "show.db")
    seeded = seed_scope_db(db)
    code, letter = run_cli(db, "--team-account", TEAM, "feedback-show", "--thread",
                           seeded["letter"], capsys=capsys)
    assert code == 0 and letter["userLetter"] is True
    code, simulator = run_cli(db, "--team-account", TEAM, "feedback-show", "--thread",
                              seeded["simulator"], capsys=capsys)
    assert code == 0 and simulator["userLetter"] is False


# ── F2（评审）：没有团队账号时拒绝静默降级 ─────────────────────────────────
#
# `is_user_letter(account, model, "")` 会把所有非空账号都判成用户来信（团队自己的提交
# 也在内）。这三条命令要靠团队账号判口径，team 为空时必须报错，而不是猜。


def test_feedback_list_scope_refuses_to_guess_without_a_team_account(relay, capsys):
    before = count(relay["db"], "feedbackThreads")
    code, report = run_cli(relay["db"], "feedback-list", "--scope", "user", capsys=capsys)
    assert code == 1, "业务失败（与其它 StoreError 同一约定），不是 0 也不是 2"
    assert "--team-account" in report["stderr"] and "MAIL_TEAM_ACCOUNT" in report["stderr"]
    assert count(relay["db"], "feedbackThreads") == before, "只读命令不许写库"

    # 不给 --scope 时保持既有行为：行集与以前一样（默认 all），不因为缺团队账号失败。
    code, rows = run_cli(relay["db"], "feedback-list", capsys=capsys)
    assert code == 0 and len(rows) == 1


def test_feedback_stats_refuses_to_guess_without_a_team_account(relay, capsys):
    code, report = run_cli(relay["db"], "feedback-stats", capsys=capsys)
    assert code == 1
    assert "--team-account" in report["stderr"]
    # 给了团队账号就照常出报告（形状不变）。
    code, stats = run_cli(relay["db"], "--team-account", TEAM, "feedback-stats", capsys=capsys)
    assert code == 0 and stats["ok"] is True and stats["feedback"]["new"] == 1


def test_feedback_rebind_refuses_without_a_team_account(relay, capsys):
    code, report = run_cli(relay["db"], "feedback-rebind", "--yes", capsys=capsys)
    assert code == 1
    assert "--team-account" in report["stderr"]
    assert all(row["teamAccountId"] is None for row in query(
        relay["db"], "SELECT teamAccountId FROM feedbackThreads")), "报错时一列都不许写"
