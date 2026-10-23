"""反馈通道契约（014）：建线程、列表、详情、已读、设备绑定与 owner 回信。

四个接口（``submit`` / ``inbox`` / ``append`` / ``read``）都只走 HTTP；owner 侧的
回信与清单走 ``ADMIN_CMD``，因为那是「用户看得到的回信从哪来」的另一半。

**鉴权以现有实现为准：没有 401。** 有效设备令牌把线程绑定到设备与账号；无效、
撤销或干脆没带的令牌按匿名处理（``feedback.py`` 模块 docstring 的口径：一块过期
令牌不该让用户提交不了意见）。所以这里钉的是「匿名也能提交，但只有凭据或设备
能把它读回来」，而不是照抄一份想象出来的 401。

**附件不在当前契约里。** 请求体里多出来的 ``attachments`` 被忽略，线程留言只有
``messageId/author/body/format/createdAt`` 五个字段；这条也写成用例，免得 Go 版
凭空长出一套附件协议。
"""

from __future__ import annotations

import json

import pytest

from . import support

#: 一个格式合法但没人用过的取件凭据（``fk_`` + 43 字符）。
UNKNOWN_TICKET = "fk_" + "A" * 43


def thread_pair(thread: dict) -> dict:
    return {"threadId": thread["threadId"], "ticketKey": thread["ticketKey"]}


async def submit(client: support.Client, text: str, *, token: str | None = None,
                 **extra: object) -> dict:
    body = {"text": text, **extra}
    response = await client.post("/feedback/submit", json_body=body, token=token)
    assert response.status == 200, response.text
    return response.json()


async def inbox(client: support.Client, *, tickets: tuple[dict, ...] = (),
                token: str | None = None, **extra: object) -> dict:
    response = await client.post("/feedback/inbox",
                                 json_body={"tickets": list(tickets), **extra},
                                 token=token)
    assert response.status == 200, response.text
    return response.json()


# ── 建线程 ──────────────────────────────────────────────────────────────────


async def test_submit_returns_a_one_time_ticket(client: support.Client, relay) -> None:
    """取件凭据只在这里出现一次：owner 清单与线程详情里都没有它。"""
    created = await submit(client, "点了新建会话之后一直转圈", subject="新建会话卡住",
                           appVersion="9.9.9 (100)", deviceModel="iPhone17,1",
                           systemVersion="26.0")
    assert created["ok"] is True
    assert created["threadId"].startswith("th_")
    assert created["ticketKey"].startswith("fk_")
    assert len(created["ticketKey"]) == 46
    assert isinstance(created["createdAt"], int) and created["createdAt"] > 0

    rows = relay.admin("feedback-list", "--limit", "50")
    dumped = json.dumps(rows, ensure_ascii=False)
    assert "ticketKey" not in dumped, "owner 清单不该带取件凭据"
    assert created["ticketKey"] not in dumped, "凭据原文不得出现在管理面输出里"
    assert any(row["threadId"] == created["threadId"] for row in rows)


async def test_submit_without_a_token_is_anonymous_instead_of_401(
        client: support.Client, relay) -> None:
    """没有令牌不是错误：线程照建，凭据仍能把它读回来。"""
    anonymous = await submit(client, "匿名也能反馈")
    rows = {row["threadId"]: row for row in relay.admin("feedback-list", "--limit", "50")}
    assert rows[anonymous["threadId"]]["source"]["kind"] == "anonymous"

    listing = await inbox(client, tickets=(thread_pair(anonymous),))
    assert [thread["threadId"] for thread in listing["threads"]] == [anonymous["threadId"]]


@pytest.mark.parametrize("payload", [
    {},
    {"text": ""},
    {"text": "   "},
    {"text": 12},
    {"text": "ok", "subject": 5},
    {"text": "ok", "appVersion": 3},
    {"text": "ok", "format": "rtf"},
])
async def test_submit_rejects_malformed_bodies(client: support.Client,
                                               payload: dict) -> None:
    response = await client.post("/feedback/submit", json_body=payload)
    support.assert_error_envelope(response, status=400, code="feedback/bad-request")


async def test_submit_rejects_non_json(client: support.Client) -> None:
    response = await client.post("/feedback/submit", data=b"this is not json",
                                 headers={"content-type": "application/json"})
    support.assert_error_envelope(response, status=400, code="feedback/bad-request")


async def test_submit_enforces_the_text_and_subject_limits(client: support.Client) -> None:
    """字符数与字节数是两条线；主题超长单独报 too-long，而不是说正文太长。"""
    too_many_chars = await client.post("/feedback/submit", json_body={"text": "x" * 4001})
    support.assert_error_envelope(too_many_chars, status=400, code="feedback/too-long")

    # 3000 个汉字 = 9000 字节：字符数没超，字节数超了（上限 8000）。
    body = json.dumps({"text": "中" * 3000}, ensure_ascii=False).encode("utf-8")
    too_many_bytes = await client.post("/feedback/submit", data=body,
                                       headers={"content-type": "application/json"})
    support.assert_error_envelope(too_many_bytes, status=400, code="feedback/too-long")

    long_subject = await client.post("/feedback/submit",
                                     json_body={"text": "ok", "subject": "题" * 81})
    support.assert_error_envelope(long_subject, status=400, code="feedback/too-long")


async def test_a_request_body_over_sixteen_kilobytes_answers_413(
        client: support.Client) -> None:
    """公开写入接口的上限是 16 KB，不是 WebSocket 的 32 MB。"""
    response = await client.post("/feedback/submit", json_body={"text": "x" * 20000})
    support.assert_error_envelope(response, status=413, code="feedback/too-large")


async def test_submit_is_idempotent_per_client_ref(client: support.Client) -> None:
    """同一 ``clientRef`` 重试：同一条线程，新凭据可用，旧凭据随重试作废。"""
    first = await submit(client, "第一次", clientRef="blackbox-ref-1")
    second = await submit(client, "重试", clientRef="blackbox-ref-1")
    assert second["threadId"] == first["threadId"]
    assert second["ticketKey"] != first["ticketKey"]

    fresh = await inbox(client, tickets=(thread_pair(second),))
    assert len(fresh["threads"]) == 1
    assert len(fresh["threads"][0]["messages"]) == 1, "重试不该再写一条留言"

    stale = await inbox(client, tickets=(thread_pair(first),))
    assert stale["threads"] == [], "换过凭据之后旧的取件凭据必须失效"


# ── 列表与详情 ──────────────────────────────────────────────────────────────


async def test_inbox_lists_the_thread_and_its_messages_by_ticket(
        client: support.Client) -> None:
    created = await submit(client, "列表里应该看到这句", subject="一句主题")
    listing = await inbox(client, tickets=(thread_pair(created),))

    assert listing["ok"] is True
    assert listing["unreadCount"] == 0, "用户自己写的留言不算未读"
    assert listing["notices"] == []
    thread = listing["threads"][0]
    assert thread["threadId"] == created["threadId"]
    assert thread["subject"] == "一句主题"
    assert thread["status"] == "open"
    assert thread["unread"] == 0
    assert thread["createdAt"] == created["createdAt"]
    message = thread["messages"][0]
    assert message["author"] == "user"
    assert message["body"] == "列表里应该看到这句"
    assert message["format"] == "text"
    assert set(message) == {"messageId", "author", "body", "format", "createdAt"}


async def test_inbox_does_not_leak_threads_without_the_ticket(
        client: support.Client, relay) -> None:
    created = await submit(client, "只有凭据能打开这条")
    wrong = {"threadId": created["threadId"], "ticketKey": UNKNOWN_TICKET}

    assert (await inbox(client, tickets=(wrong,)))["threads"] == []
    assert (await inbox(client))["threads"] == [], "匿名且没有凭据时什么都看不到"

    other = await support.enroll(client, relay.admin, name="BLACKBOX-other")
    other_device = await support.pair_device(client, other, name="BLACKBOX-other-phone")
    theirs = await inbox(client, token=other_device.token)
    assert theirs["threads"] == [], "别的账号的设备不该看到这条线程"


async def test_messages_carry_no_attachment_fields(client: support.Client) -> None:
    """附件尚未进入契约：多出来的 ``attachments`` 被忽略，留言形状不变。"""
    created = await submit(client, "带一个附件试试",
                           attachments=[{"name": "shot.png", "bytes": 3}])
    listing = await inbox(client, tickets=(thread_pair(created),))
    message = listing["threads"][0]["messages"][0]
    assert set(message) == {"messageId", "author", "body", "format", "createdAt"}
    assert "attachments" not in json.dumps(listing, ensure_ascii=False)


# ── 回信与已读 ──────────────────────────────────────────────────────────────


async def test_owner_reply_via_admin_lands_in_the_users_inbox(
        client: support.Client, relay) -> None:
    created = await submit(client, "我在设置页找不到退出登录")
    reply = relay.admin("feedback-reply", "--thread", created["threadId"],
                        "--body", "退出登录在设置最下面，下一版会加搜索。",
                        "--subject", "退出登录的位置")
    assert reply["ok"] is True
    assert reply["threadId"] == created["threadId"]

    listing = await inbox(client, tickets=(thread_pair(created),))
    thread = listing["threads"][0]
    assert thread["subject"] == "退出登录的位置", "回信可以替换主题"
    assert thread["status"] == "replied"
    assert [message["author"] for message in thread["messages"]] == ["user", "owner"]
    assert thread["messages"][-1]["body"] == "退出登录在设置最下面，下一版会加搜索。"
    assert thread["messages"][-1]["format"] == "text"
    assert thread["unread"] == 1, "owner 的留言是用户侧的未读"
    assert listing["unreadCount"] == 1


async def test_append_then_read_marks_the_thread_and_clears_unread(
        client: support.Client, relay) -> None:
    created = await submit(client, "第一个问题")
    appended = await client.post("/feedback/append", json_body={
        "threadId": created["threadId"], "ticketKey": created["ticketKey"],
        "text": "补充一句：重启之后还是一样"})
    assert appended.status == 200, appended.text
    assert appended.json()["ok"] is True
    assert appended.json()["threadId"] == created["threadId"]

    before = await inbox(client, tickets=(thread_pair(created),))
    assert [message["author"] for message in before["threads"][0]["messages"]] \
        == ["user", "user"]
    assert before["threads"][0]["status"] == "open"

    relay.admin("feedback-reply", "--thread", created["threadId"], "--body", "收到，我看一下。")
    unread = await inbox(client, tickets=(thread_pair(created),))
    assert unread["unreadCount"] == 1

    marked = await client.post("/feedback/read", json_body={
        "threadIds": [created["threadId"]],
        "tickets": [thread_pair(created)]})
    assert marked.status == 200, marked.text
    assert marked.json() == {"ok": True, "unreadCount": 0}

    after = await inbox(client, tickets=(thread_pair(created),))
    assert after["unreadCount"] == 0
    assert after["threads"][0]["unread"] == 0
    assert len(after["threads"][0]["messages"]) == 3, "已读不该删留言"

    wrong = await client.post("/feedback/append", json_body={
        "threadId": created["threadId"], "ticketKey": UNKNOWN_TICKET, "text": "我是谁"})
    support.assert_error_envelope(wrong, status=404, code="feedback/not-found")


async def test_read_rejects_malformed_id_lists(client: support.Client) -> None:
    for payload in (
            {"threadIds": "th_one"},
            {"noticeIds": [1, 2]},
            {"tickets": [{"threadId": "th_one"}]},
            {"tickets": [{"threadId": f"th_{index}", "ticketKey": UNKNOWN_TICKET}
                         for index in range(51)]},
    ):
        response = await client.post("/feedback/read", json_body=payload)
        support.assert_error_envelope(response, status=400, code="feedback/bad-request")


async def test_admin_notice_is_account_scoped_and_read_is_shared(
        client: support.Client, relay, tenant: support.Tenant,
        device: support.Device) -> None:
    """owner 的通知按**账号**投递：同账号两台设备共享一份，读到即全账号已读。"""
    second = await support.pair_device(client, tenant, name="BLACKBOX-second-phone")
    other = await support.enroll(client, relay.admin, name="BLACKBOX-other")
    other_device = await support.pair_device(client, other, name="BLACKBOX-other-phone")

    sent = relay.admin("feedback-notify", "--account", tenant.account_id,
                       "--subject", "维护通知", "--body", "今晚 23:00 维护，约十分钟。",
                       "--yes")
    assert sent["ok"] is True and sent["recipients"] == 1

    first = await inbox(client, token=device.token)
    assert first["unreadCount"] == 1
    notice = first["notices"][0]
    assert notice["noticeId"] == sent["noticeId"]
    assert notice["subject"] == "维护通知"
    assert notice["body"] == "今晚 23:00 维护，约十分钟。"
    assert notice["format"] == "text"
    assert notice["read"] is False

    # 同账号的另一台设备看到的是同一条（账号级投递，不是设备级）。
    both = await inbox(client, token=second.token)
    assert [item["noticeId"] for item in both["notices"]] == [sent["noticeId"]]
    # 别的账号看不到。
    assert (await inbox(client, token=other_device.token))["notices"] == []

    marked = await client.post("/feedback/read", token=device.token,
                               json_body={"noticeIds": [sent["noticeId"]]})
    assert marked.status == 200, marked.text
    assert marked.json() == {"ok": True, "unreadCount": 0}

    after = await inbox(client, token=second.token)
    assert after["notices"][0]["read"] is True, "一台设备读过，另一台也是已读"
    assert after["unreadCount"] == 0


# ── 管理面（owner 侧）────────────────────────────────────────────────────────


async def test_admin_feedback_list_reports_the_device_source_and_counts(
        client: support.Client, relay, device: support.Device) -> None:
    created = await submit(client, "手机上的反馈正文", subject="设备来源",
                           token=device.token, appVersion="9.9.9 (100)",
                           deviceModel="iPhone17,1", systemVersion="26.0")

    rows = {row["threadId"]: row for row in relay.admin("feedback-list", "--status", "open")}
    row = rows[created["threadId"]]
    assert row["status"] == "open"
    assert row["messages"] == 1
    assert row["ownerUnread"] == 1, "owner 还没看过的用户留言"
    assert row["excerpt"] == "手机上的反馈正文"
    assert row["format"] == "text"
    assert row["source"]["kind"] == "device"
    assert row["source"]["deviceId"] == device.device_id
    assert row["source"]["accountId"] == device.account_id
    assert row["source"]["deviceModel"] == "iPhone17,1"
    assert row["source"]["appVersion"] == "9.9.9 (100)"
    assert row["source"]["systemVersion"] == "26.0"

    # 设备令牌自己也能把线程读回来（不靠取件凭据）。
    listing = await inbox(client, token=device.token)
    assert [thread["threadId"] for thread in listing["threads"]] == [created["threadId"]]

    shown = relay.admin("feedback-show", "--thread", created["threadId"])
    assert shown["threadId"] == created["threadId"]
    assert [message["author"] for message in shown["messages"]] == ["user"]
    after = {item["threadId"]: item for item in relay.admin("feedback-list", "--status", "open")}
    assert after[created["threadId"]]["ownerUnread"] == 0, "feedback-show 看过即已读"


async def test_device_append_binds_a_thread_started_anonymously(
        client: support.Client, relay, device: support.Device) -> None:
    """匿名提交后来配对了：用设备令牌补一句，线程就归到这台设备名下。"""
    created = await submit(client, "先匿名问一句")
    appended = await client.post("/feedback/append", token=device.token, json_body={
        "threadId": created["threadId"], "ticketKey": created["ticketKey"],
        "text": "现在我用设备令牌补一句"})
    assert appended.status == 200, appended.text

    rows = {row["threadId"]: row for row in relay.admin("feedback-list", "--limit", "50")}
    assert rows[created["threadId"]]["source"]["kind"] == "device"
    assert rows[created["threadId"]]["source"]["deviceId"] == device.device_id

    listing = await inbox(client, token=device.token)
    assert [thread["threadId"] for thread in listing["threads"]] == [created["threadId"]]
