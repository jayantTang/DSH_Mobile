"""HTTP 契约：`/feedback` 的四个接口（014）。

错误码、字段名与上限逐字照
`specs/014-feedback-channel/contracts/feedback-http.md`；写法照 `tests/test_pair_api.py`
（接口 + 错误码 + 限流）与 `tests/test_base_path.py`（双路径）。所有用例只用 `tmp_path`
里的库，不碰生产 `state.db`。
"""

from __future__ import annotations

import json

import pytest

import relay as relay_module
from conftest import device_headers, feedback_ticket
from hub import Limits

#: 一个格式合法但没人用过的取件凭据（`fk_` + 43 字符）。
TICKET = "fk_" + "A" * 43


async def paired_device(client, agent_id: str, name: str = "DSH-Test") -> str:
    """给这台 agent 配一台临时设备，返回它的设备令牌。"""
    code = client.app["store"].mint_pair_code(agent_id, ttl_ms=60_000)
    claim = await client.post("/pair/claim", json={
        "pairCode": code["code"], "deviceName": name, "model": "iPhone17,1"})
    assert claim.status == 200, await claim.text()
    return (await claim.json())["deviceToken"]


def ticket_pair(ticket: dict) -> dict:
    return {"threadId": ticket["threadId"], "ticketKey": ticket["ticketKey"]}


async def inbox(client, tickets=(), headers=None, **extra) -> dict:
    response = await client.post("/feedback/inbox", json={"tickets": list(tickets), **extra},
                                 headers=headers or {})
    assert response.status == 200, await response.text()
    return await response.json()


# ── POST /feedback/submit（T009）─────────────────────────────────────────────


async def test_submit_returns_a_one_time_ticket(client):
    response = await client.post("/feedback/submit", json={
        "text": "  点了新建会话之后一直转圈  ", "appVersion": "1.2 (345)",
        "deviceModel": "iPhone15,4", "systemVersion": "18.2", "clientRef": "6F2B0B3E-1"})
    assert response.status == 200, await response.text()
    body = await response.json()
    assert body["ok"] is True
    assert body["threadId"].startswith("th_")
    assert body["ticketKey"].startswith("fk_") and len(body["ticketKey"]) == 46
    assert body["createdAt"] > 0


@pytest.mark.parametrize("payload", [
    {},
    {"text": ""},
    {"text": "   "},
    {"text": 12},
    {"text": "ok", "appVersion": 3},
    {"text": "ok", "deviceModel": ["iPhone"]},
    {"text": "ok", "clientRef": "bad ref!"},
    {"text": "ok", "clientRef": "x" * 65},
])
async def test_submit_rejects_bad_input(client, payload):
    response = await client.post("/feedback/submit", json=payload)
    assert response.status == 400, await response.text()
    assert (await response.json())["error"]["code"] == "feedback/bad-request"


async def test_submit_accepts_exactly_four_thousand_characters(client):
    response = await client.post("/feedback/submit", json={"text": "x" * 4000})
    assert response.status == 200, await response.text()


async def test_submit_rejects_text_over_the_limits(client):
    too_many_chars = await client.post("/feedback/submit", json={"text": "x" * 4001})
    assert too_many_chars.status == 400
    assert (await too_many_chars.json())["error"]["code"] == "feedback/too-long"

    # 3000 个汉字 = 9000 字节：字符数没超，字节数超了（上限 8000）。按 App 的做法发
    # 未转义的 UTF-8（`json=` 会把汉字转成 `\uXXXX`，那样先撞上 16 KB 的体上限）。
    body = json.dumps({"text": "中" * 3000}, ensure_ascii=False).encode("utf-8")
    assert 8000 < len(body) < 16 * 1024
    too_many_bytes = await client.post("/feedback/submit", data=body,
                                       headers={"content-type": "application/json"})
    assert too_many_bytes.status == 400
    assert (await too_many_bytes.json())["error"]["code"] == "feedback/too-long"

    # 技术信息字段各 64 字符。
    long_version = await client.post("/feedback/submit", json={"text": "ok", "appVersion": "v" * 65})
    assert long_version.status == 400
    assert (await long_version.json())["error"]["code"] == "feedback/too-long"


async def test_submit_rejects_a_body_over_sixteen_kilobytes(client):
    response = await client.post("/feedback/submit", json={"text": "x" * 20000})
    assert response.status == 413
    assert (await response.json())["error"]["code"] == "feedback/too-large"


async def test_submit_is_idempotent_per_client_ref(client, store):
    first = await client.post("/feedback/submit", json={"text": "第一次", "clientRef": "ref-1"})
    second = await client.post("/feedback/submit", json={"text": "重试", "clientRef": "ref-1"})
    assert first.status == second.status == 200
    one, two = await first.json(), await second.json()
    assert two["threadId"] == one["threadId"]
    assert store._rows("SELECT COUNT(*) AS n FROM feedbackThreads")[0]["n"] == 1
    assert store._rows("SELECT COUNT(*) AS n FROM feedbackMessages")[0]["n"] == 1
    # 重试是在"上一条响应丢了"之后发起的，所以第二次给的凭据必须能用。
    body = await inbox(client, [{"threadId": two["threadId"], "ticketKey": two["ticketKey"]}])
    assert [t["threadId"] for t in body["threads"]] == [two["threadId"]]


async def test_submit_refuses_a_client_ref_that_belongs_to_another_source(client, provisioned, store):
    token = await paired_device(client, provisioned["agent"]["agentId"])
    first = await client.post("/feedback/submit", json={"text": "我的", "clientRef": "shared-1"},
                              headers=device_headers(token))
    assert first.status == 200, await first.text()
    # 同一个 clientRef 从别人那里来：不新建，也不把那条线程交出去（别人顶不掉凭据）。
    stolen = await client.post("/feedback/submit", json={"text": "偷的", "clientRef": "shared-1"})
    assert stolen.status == 400
    assert (await stolen.json())["error"]["code"] == "feedback/bad-request"
    assert store._rows("SELECT COUNT(*) AS n FROM feedbackThreads")[0]["n"] == 1


async def test_submit_with_an_invalid_device_token_is_anonymous(client, store):
    response = await client.post("/feedback/submit", json={"text": "过期令牌也要能提意见"},
                                 headers={"Authorization": "Bearer dt_nope"})
    assert response.status == 200, "无效令牌不报 401，按匿名处理"
    thread = store.feedback_thread((await response.json())["threadId"], None)
    assert thread["deviceId"] is None and thread["accountId"] is None


# ── POST /feedback/inbox（T010）─────────────────────────────────────────────


async def test_inbox_returns_the_thread_behind_a_valid_ticket(client):
    ticket = await feedback_ticket(client, text="第一条")
    body = await inbox(client, [ticket_pair(ticket)])
    assert body["ok"] is True
    assert len(body["threads"]) == 1
    thread = body["threads"][0]
    assert thread["threadId"] == ticket["threadId"]
    assert thread["status"] == "open" and thread["unread"] == 0
    assert thread["createdAt"] == ticket["createdAt"]
    assert thread["lastMessageAt"] >= thread["createdAt"]
    assert [m["author"] for m in thread["messages"]] == ["user"]
    assert thread["messages"][0]["body"] == "第一条"
    # 字段集合就是契约里那一组：内部的 ticketHash/来源信息一个都不出网。
    assert set(thread) == {"threadId", "status", "createdAt", "lastMessageAt", "unread", "messages"}
    assert set(thread["messages"][0]) == {"messageId", "author", "body", "createdAt"}
    assert body["notices"] == [] and body["unreadCount"] == 0


async def test_inbox_with_a_wrong_ticket_returns_nothing(client):
    mine = await feedback_ticket(client)
    wrong = await inbox(client, [{"threadId": mine["threadId"], "ticketKey": TICKET}])
    missing = await inbox(client, [{"threadId": "th_nope", "ticketKey": TICKET}])
    assert wrong == missing, "凭据不匹配与线程不存在必须给出完全一样的空结果"
    assert wrong["threads"] == [] and wrong["notices"] == [] and wrong["unreadCount"] == 0


async def test_inbox_does_not_touch_the_read_state(client, store):
    ticket = await feedback_ticket(client)
    store.append_feedback_message(ticket["threadId"], "回信", author="owner")
    first = await inbox(client, [ticket_pair(ticket)])
    second = await inbox(client, [ticket_pair(ticket)])
    assert first["unreadCount"] == 1 and second["unreadCount"] == 1
    assert second["threads"][0]["unread"] == 1
    assert store.feedback_thread(ticket["threadId"], None)["userReadAt"] is None, "拉取不改已读"


async def test_inbox_messages_per_thread_defaults_to_fifty_and_caps_at_two_hundred(client, store):
    ticket = await feedback_ticket(client)
    for index in range(205):        # 时间戳排在原文之后，才数得清"最近的 N 条"
        store.append_feedback_message(ticket["threadId"], f"补充 {index}",
                                      at=9_000_000_000_000 + index)

    default = await inbox(client, [ticket_pair(ticket)])
    assert len(default["threads"][0]["messages"]) == 50

    capped = await inbox(client, [ticket_pair(ticket)], messagesPerThread=500)
    assert len(capped["threads"][0]["messages"]) == 200
    assert capped["threads"][0]["messages"][-1]["body"] == "补充 204", "取最近的 N 条"


async def test_inbox_rejects_more_than_fifty_tickets(client):
    response = await client.post("/feedback/inbox", json={
        "tickets": [{"threadId": "th_x", "ticketKey": TICKET}] * 51})
    assert response.status == 400
    assert (await response.json())["error"]["code"] == "feedback/bad-request"


@pytest.mark.parametrize("payload", [
    {"tickets": "nope"},
    {"tickets": [{"threadId": "th_x"}]},
    {"tickets": [{"threadId": "th_x", "ticketKey": 1}]},
    {"tickets": [1]},
    {"messagesPerThread": 0},
    {"messagesPerThread": "50"},
])
async def test_inbox_rejects_bad_input(client, payload):
    response = await client.post("/feedback/inbox", json=payload)
    assert response.status == 400
    assert (await response.json())["error"]["code"] == "feedback/bad-request"


async def test_inbox_includes_threads_bound_to_the_device(client, provisioned):
    token = await paired_device(client, provisioned["agent"]["agentId"])
    submitted = await client.post("/feedback/submit", json={"text": "配对后提交"},
                                  headers=device_headers(token))
    assert submitted.status == 200, await submitted.text()
    thread_id = (await submitted.json())["threadId"]

    with_token = await inbox(client, headers=device_headers(token))
    assert [t["threadId"] for t in with_token["threads"]] == [thread_id]

    # 没带令牌就取不到：设备绑定不是公开信息。
    assert (await inbox(client))["threads"] == []
    # 同一账号的其它设备看得到：重装后重新配对（换了 deviceId）靠这条找回（R2）。
    other = await paired_device(client, provisioned["agent"]["agentId"], "DSH-Other")
    assert [t["threadId"] for t in (await inbox(client, headers=device_headers(other)))["threads"]] \
        == [thread_id]


async def test_inbox_dedupes_a_thread_hit_by_both_ticket_and_device(client, provisioned):
    token = await paired_device(client, provisioned["agent"]["agentId"])
    submitted = await client.post("/feedback/submit", json={"text": "两条路都命中"},
                                  headers=device_headers(token))
    body = await submitted.json()
    merged = await inbox(client, [{"threadId": body["threadId"], "ticketKey": body["ticketKey"]}],
                         headers=device_headers(token))
    assert [t["threadId"] for t in merged["threads"]] == [body["threadId"]]


async def test_inbox_orders_threads_by_last_activity(client, store):
    early = await feedback_ticket(client, text="早的")
    late = await feedback_ticket(client, text="晚的")
    store.append_feedback_message(early["threadId"], "刚补充的", at=9_000_000_000_000)
    body = await inbox(client, [ticket_pair(early), ticket_pair(late)])
    assert [t["threadId"] for t in body["threads"]] == [early["threadId"], late["threadId"]]


async def test_inbox_reports_notices_per_device(client, provisioned, store):
    token = await paired_device(client, provisioned["agent"]["agentId"])
    device_id = store.device_by_token(token)["deviceId"]
    notice = store.create_notice("维护通知正文", "服务通知", [device_id], at=5_000)

    body = await inbox(client, headers=device_headers(token))
    assert [n["noticeId"] for n in body["notices"]] == [notice["noticeId"]]
    row = body["notices"][0]
    assert set(row) == {"noticeId", "subject", "body", "createdAt", "read"}
    assert row["read"] is False and row["subject"] == "服务通知"
    assert body["unreadCount"] == 1
    assert (await inbox(client))["notices"] == [], "匿名没有通知"


# ── 限流（T011）─────────────────────────────────────────────────────────────


async def test_submit_is_rate_limited_and_a_refused_request_is_not_stored(client, store):
    accepted = 0
    blocked = None
    for _ in range(200):
        response = await client.post("/feedback/submit", json={"text": "spam"})
        if response.status == 200:
            accepted += 1
            continue
        blocked = response
        break
    assert blocked is not None, "公开的写入接口必须有限流"
    assert blocked.status == 429
    assert (await blocked.json())["error"]["code"] == "feedback/rate-limited"
    assert accepted >= 1
    assert store._rows("SELECT COUNT(*) AS n FROM feedbackThreads")[0]["n"] == accepted, \
        "命中限流的那次不落库"


async def test_the_submit_budget_is_kept_per_source(client):
    for _ in range(200):
        response = await client.post("/feedback/submit", json={"text": "spam"})
        if response.status == 429:
            break
    assert response.status == 429
    elsewhere = await client.post("/feedback/submit", json={"text": "另一个来源"},
                                  headers={"X-Forwarded-For": "203.0.113.9"})
    assert elsewhere.status == 200, "限流按来源分桶，一个人不能把所有人堵死"


async def test_append_is_rate_limited(client):
    ticket = await feedback_ticket(client)
    payload = {**ticket_pair(ticket), "text": "补充"}
    for _ in range(200):
        response = await client.post("/feedback/append", json=payload)
        if response.status == 429:
            break
    assert response.status == 429
    assert (await response.json())["error"]["code"] == "feedback/rate-limited"


# ── base_path（T012）───────────────────────────────────────────────────────


@pytest.fixture
async def prefixed_client(aiohttp_client, store):
    app = relay_module.create_app(store=store, limits=Limits(queue_depth=8),
                                  pair_ttl_ms=60_000, base_path="/dsh-link")
    return await aiohttp_client(app)


async def test_the_four_feedback_endpoints_work_under_the_prefix(prefixed_client):
    submit = await prefixed_client.post("/dsh-link/feedback/submit", json={"text": "前缀路径"})
    assert submit.status == 200, await submit.text()
    ticket = await submit.json()

    unprefixed = await prefixed_client.post("/feedback/submit", json={"text": "无前缀"})
    assert unprefixed.status == 200, "两种路径同时都活着"

    inboxed = await prefixed_client.post("/dsh-link/feedback/inbox", json={
        "tickets": [{"threadId": ticket["threadId"], "ticketKey": ticket["ticketKey"]}]})
    assert inboxed.status == 200, await inboxed.text()
    assert [t["threadId"] for t in (await inboxed.json())["threads"]] == [ticket["threadId"]]

    appended = await prefixed_client.post("/dsh-link/feedback/append", json={
        "threadId": ticket["threadId"], "ticketKey": ticket["ticketKey"], "text": "补充"})
    assert appended.status == 200, await appended.text()

    marked = await prefixed_client.post("/dsh-link/feedback/read", json={
        "threadIds": [ticket["threadId"]],
        "tickets": [{"threadId": ticket["threadId"], "ticketKey": ticket["ticketKey"]}]})
    assert marked.status == 200, await marked.text()
    assert (await marked.json())["unreadCount"] == 0


# ── POST /feedback/append（T025）───────────────────────────────────────────


async def test_append_hits_the_thread_with_a_matching_ticket(client):
    ticket = await feedback_ticket(client)
    response = await client.post("/feedback/append", json={
        "threadId": ticket["threadId"], "ticketKey": ticket["ticketKey"],
        "text": "补充：只有 iOS 18 会这样", "clientRef": "A1C3"})
    assert response.status == 200, await response.text()
    body = await response.json()
    assert body["ok"] is True and body["threadId"] == ticket["threadId"]
    assert body["messageId"].startswith("fm_") and body["createdAt"] > 0

    thread = (await inbox(client, [ticket_pair(ticket)]))["threads"][0]
    assert [m["author"] for m in thread["messages"]] == ["user", "user"]
    assert thread["messages"][-1]["body"] == "补充：只有 iOS 18 会这样"


async def test_append_brings_the_thread_back_to_open(client, store):
    ticket = await feedback_ticket(client)
    store.append_feedback_message(ticket["threadId"], "回信", author="owner")
    assert store.feedback_thread(ticket["threadId"], None)["status"] == "replied"
    response = await client.post("/feedback/append",
                                 json={**ticket_pair(ticket), "text": "还有一句"})
    assert response.status == 200, await response.text()
    assert store.feedback_thread(ticket["threadId"], None)["status"] == "open"


async def test_append_is_idempotent_per_client_ref(client, store):
    ticket = await feedback_ticket(client)
    payload = {**ticket_pair(ticket), "text": "补充", "clientRef": "retry-1"}
    first = await client.post("/feedback/append", json=payload)
    second = await client.post("/feedback/append", json=payload)
    assert first.status == second.status == 200
    assert (await first.json())["messageId"] == (await second.json())["messageId"]
    rows = store._rows("SELECT COUNT(*) AS n FROM feedbackMessages WHERE threadId=?",
                       (ticket["threadId"],))
    assert rows[0]["n"] == 2, "重试不产生第二条补充"


async def test_append_404_is_byte_identical_for_a_missing_thread_and_a_wrong_ticket(client):
    ticket = await feedback_ticket(client)
    missing = await client.post("/feedback/append", json={
        "threadId": "th_nope", "ticketKey": TICKET, "text": "补充"})
    wrong = await client.post("/feedback/append", json={
        "threadId": ticket["threadId"], "ticketKey": TICKET, "text": "补充"})
    assert missing.status == wrong.status == 404
    assert await missing.read() == await wrong.read(), "状态码与响应体必须逐字节相同"
    assert (await missing.json())["error"]["code"] == "feedback/not-found"


async def test_append_binds_the_device_after_a_later_pairing(client, provisioned, store):
    ticket = await feedback_ticket(client)          # 先匿名提交
    token = await paired_device(client, provisioned["agent"]["agentId"])
    response = await client.post("/feedback/append",
                                 json={**ticket_pair(ticket), "text": "配对后补充"},
                                 headers=device_headers(token))
    assert response.status == 200, await response.text()
    thread = store.feedback_thread(ticket["threadId"], None)
    assert thread["deviceId"] is not None and thread["accountId"] is not None
    # 这条线程之后不带凭据也能靠设备找回来。
    body = await inbox(client, headers=device_headers(token))
    assert [t["threadId"] for t in body["threads"]] == [ticket["threadId"]]


@pytest.mark.parametrize("payload", [
    {},
    {"threadId": "th_x"},
    {"threadId": "th_x", "ticketKey": ""},
    {"threadId": "th_x", "ticketKey": TICKET, "text": "  "},
])
async def test_append_rejects_bad_input(client, payload):
    response = await client.post("/feedback/append", json=payload)
    assert response.status == 400
    assert (await response.json())["error"]["code"] == "feedback/bad-request"


# ── POST /feedback/read（T026）─────────────────────────────────────────────


async def test_read_clears_the_unread_count_and_is_idempotent(client, store):
    ticket = await feedback_ticket(client)
    store.append_feedback_message(ticket["threadId"], "回信", author="owner")
    payload = {"threadIds": [ticket["threadId"]], "tickets": [ticket_pair(ticket)]}

    marked = await client.post("/feedback/read", json=payload)
    assert marked.status == 200, await marked.text()
    assert await marked.json() == {"ok": True, "unreadCount": 0}

    again = await client.post("/feedback/read", json=payload)
    assert await again.json() == {"ok": True, "unreadCount": 0}, "重复调用幂等"
    thread = store.feedback_thread(ticket["threadId"], None)
    assert thread["unread"] == 0 and thread["userReadAt"] is not None
    assert (await inbox(client, [ticket_pair(ticket)]))["unreadCount"] == 0


async def test_read_without_a_device_token_ignores_notice_ids(client, store):
    store.create_notice("通知正文", "服务通知", ["dev_x"], at=5_000)
    notice_id = store._rows("SELECT noticeId FROM notices")[0]["noticeId"]
    response = await client.post("/feedback/read", json={"threadIds": [], "noticeIds": [notice_id]})
    assert response.status == 200, await response.text()
    assert (await response.json())["unreadCount"] == 0
    assert store.notices_for_device("dev_x")[0]["read"] is False, "没有设备令牌就标不动 notice"


async def test_read_marks_a_notice_only_for_this_device(client, provisioned, store):
    one = await paired_device(client, provisioned["agent"]["agentId"], "DSH-One")
    two = await paired_device(client, provisioned["agent"]["agentId"], "DSH-Two")
    ids = [store.device_by_token(one)["deviceId"], store.device_by_token(two)["deviceId"]]
    notice = store.create_notice("维护通知", "服务通知", ids, at=5_000)

    response = await client.post("/feedback/read",
                                 json={"threadIds": [], "noticeIds": [notice["noticeId"]]},
                                 headers=device_headers(one))
    assert response.status == 200, await response.text()
    assert (await response.json())["unreadCount"] == 0
    assert store.notices_for_device(ids[0])[0]["read"] is True
    assert store.notices_for_device(ids[1])[0]["read"] is False, "两台设备各记各的未读（FR-017）"


async def test_read_leaves_threads_the_caller_cannot_prove(client, provisioned, store):
    ticket = await feedback_ticket(client)
    store.append_feedback_message(ticket["threadId"], "回信", author="owner")
    token = await paired_device(client, provisioned["agent"]["agentId"])
    response = await client.post("/feedback/read", json={"threadIds": [ticket["threadId"]]},
                                 headers=device_headers(token))
    assert response.status == 200, await response.text()
    assert (await response.json())["unreadCount"] == 0
    assert store.feedback_thread(ticket["threadId"], None)["userReadAt"] is None, "别人的线程标不动"


async def test_read_with_a_wrong_ticket_does_not_mark(client, store):
    ticket = await feedback_ticket(client)
    store.append_feedback_message(ticket["threadId"], "回信", author="owner")
    response = await client.post("/feedback/read", json={
        "threadIds": [ticket["threadId"]],
        "tickets": [{"threadId": ticket["threadId"], "ticketKey": TICKET}]})
    assert response.status == 200, await response.text()
    assert store.feedback_thread(ticket["threadId"], None)["userReadAt"] is None


@pytest.mark.parametrize("payload", [
    {"threadIds": "th_x"},
    {"threadIds": [1]},
    {"noticeIds": ["nt_x", 2]},
    {"tickets": [{"threadId": "th_x"}]},
])
async def test_read_rejects_bad_input(client, payload):
    response = await client.post("/feedback/read", json=payload)
    assert response.status == 400
    assert (await response.json())["error"]["code"] == "feedback/bad-request"


# ── 四个接口共有的行为 ─────────────────────────────────────────────────────


@pytest.mark.parametrize("path", ["/feedback/submit", "/feedback/inbox",
                                  "/feedback/append", "/feedback/read"])
async def test_the_four_endpoints_reject_a_non_json_body(client, path):
    response = await client.post(path, data=b"not json",
                                 headers={"content-type": "application/json"})
    assert response.status == 400
    assert (await response.json())["error"]["code"] == "feedback/bad-request"


async def test_a_revoked_device_token_is_treated_as_anonymous(client, provisioned, store):
    token = await paired_device(client, provisioned["agent"]["agentId"])
    store.revoke_device(store.device_by_token(token)["deviceId"])

    submitted = await client.post("/feedback/submit", json={"text": "撤销之后也要能提意见"},
                                  headers=device_headers(token))
    assert submitted.status == 200, "撤销的令牌不报 401（提交按匿名处理）"
    thread = store.feedback_thread((await submitted.json())["threadId"], None)
    assert thread["deviceId"] is None

    # 读取同样按匿名：拿不到东西，但也不是 401。
    assert (await inbox(client, headers=device_headers(token)))["threads"] == []
