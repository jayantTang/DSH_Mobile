"""HTTP 契约：`/feedback` 的四个接口（014）—— mail 侧移植版。

从中转的 test_feedback_api.py 逐字移植（DESIGN-20261015 M2）：错误码、字段名与
上限不变，App 侧零改动是拆分的验收标准。差异只在"设备从哪来"：mail 没有配对，
`paired_device` 变成往假解析器里注册一台设备（见 conftest）。
"""

from __future__ import annotations

import json

import pytest

import mail as mail_module
from store import sha256_hex
from conftest import (TEAM_ACCOUNT, device_headers, device_of, feedback_ticket,
                      register_device, unregister_device)

#: 一个格式合法但没人用过的取件凭据（`fk_` + 43 字符）。
TICKET = "fk_" + "A" * 43


async def paired_device(client, agent_id: str | None = None, name: str = "DSH-Test") -> str:
    """注册一台临时设备到假解析器，返回它的设备令牌（agent_id 兼容旧签名，忽略）。"""
    return register_device(client, name=name)


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


async def submit_raw(client, payload: dict):
    """按 App 的做法发未转义的 UTF-8。

    `json=` 会把非 ASCII 转成 `\\uXXXX`（每个 emoji 12 B），先撞体上限得到 413——
    那是体上限的断言，不是正文上限的断言。
    """
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    return await client.post("/feedback/submit", data=body,
                             headers={"content-type": "application/json"})


async def test_submit_takes_four_thousand_characters_and_twelve_thousand_bytes(client):
    """两个上限同一条判定：4000 字符 / 12000 字节（4000 汉字正好 12000 B）。"""
    exact = await submit_raw(client, {"text": "中" * 4000})
    assert len(("中" * 4000).encode("utf-8")) == 12_000
    assert exact.status == 200, await exact.text()

    too_many_chars = await submit_raw(client, {"text": "中" * 4001})
    assert too_many_chars.status == 400
    assert (await too_many_chars.json())["error"]["code"] == "feedback/too-long"

    # 字符数没超、字节数超了：3001 个 emoji = 12004 B（体仍在 40 KB 以内，所以不是 413）。
    too_many_bytes = await submit_raw(client, {"text": "😀" * 3001})
    assert len(("😀" * 3001).encode("utf-8")) == 12_004
    assert too_many_bytes.status == 400
    assert (await too_many_bytes.json())["error"]["code"] == "feedback/too-long"

    # 技术信息字段各 64 字符。
    long_version = await client.post("/feedback/submit", json={"text": "ok", "appVersion": "v" * 65})
    assert long_version.status == 400
    assert (await long_version.json())["error"]["code"] == "feedback/too-long"


async def test_submit_rejects_a_body_over_forty_kilobytes(client):
    """体上限 40 KB（与凭据条数、正文上限是同一个耦合三元组）。"""
    def padded(total: int) -> bytes:
        base = len(json.dumps({"text": "x", "pad": ""}).encode())
        return json.dumps({"text": "x", "pad": "x" * (total - base)}).encode()

    exact = padded(40 * 1024)
    assert len(exact) == 40 * 1024
    assert (await client.post("/feedback/submit", data=exact,
                              headers={"content-type": "application/json"})).status == 200

    over = padded(40 * 1024 + 1)
    assert len(over) == 40 * 1024 + 1
    response = await client.post("/feedback/submit", data=over,
                                 headers={"content-type": "application/json"})
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


# ── 可选主题 subject（T065：界面重做 2026-10-12）─────────────────────────────


async def test_submit_takes_an_optional_subject_and_inbox_returns_it(client, store):
    """主题是「写反馈」里的那一行标题：提交时给进去，列表/详情读回来。"""
    submitted = await client.post("/feedback/submit", json={
        "text": "点了新建会话之后一直转圈", "subject": "  新建会话一直转圈  "})
    assert submitted.status == 200, await submitted.text()
    body = await submitted.json()

    thread = (await inbox(client, [{"threadId": body["threadId"],
                                    "ticketKey": body["ticketKey"]}]))["threads"][0]
    assert thread["subject"] == "新建会话一直转圈", "存的是去过首尾空白的那一句"
    assert store.feedback_thread(body["threadId"], None)["subject"] == "新建会话一直转圈"


async def test_submit_without_a_subject_stores_null_and_the_field_is_still_there(client, store):
    """不填时服务端**不替用户补**正文首句：字段在，值是 null（展示层兜底）。"""
    ticket = await feedback_ticket(client)
    thread = (await inbox(client, [ticket_pair(ticket)]))["threads"][0]
    assert thread["subject"] is None
    assert store.feedback_thread(ticket["threadId"], None)["subject"] is None


async def test_submit_accepts_the_80_char_subject_limit_and_rejects_81(client):
    exact = await client.post("/feedback/submit", json={"text": "正文", "subject": "字" * 80})
    assert exact.status == 200, await exact.text()

    too_long = await client.post("/feedback/submit", json={"text": "正文", "subject": "字" * 81})
    assert too_long.status == 400
    assert (await too_long.json())["error"]["code"] == "feedback/too-long"


@pytest.mark.parametrize("subject", ["   ", "", "\n\t "])
async def test_a_blank_subject_is_the_same_as_not_sending_one(client, subject):
    """空白按未填处理——不是 400，也不是空串入库。"""
    ticket = await feedback_ticket(client, subject=subject)
    thread = (await inbox(client, [ticket_pair(ticket)]))["threads"][0]
    assert thread["subject"] is None


@pytest.mark.parametrize("subject", [12, ["标题"], {"text": "标题"}, True])
async def test_submit_rejects_a_non_string_subject(client, subject):
    response = await client.post("/feedback/submit", json={"text": "正文", "subject": subject})
    assert response.status == 400
    assert (await response.json())["error"]["code"] == "feedback/bad-request"


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
    assert set(thread) == {"threadId", "subject", "status", "createdAt", "lastMessageAt",
                           "unread", "teamUnread", "source", "messages"}
    assert set(thread["messages"][0]) == {"messageId", "author", "body", "format", "createdAt"}
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


def real_ticket_pairs(count: int) -> list[dict]:
    """真实形状的凭据对：`th_` + 18 位、`fk_` + 43 位（每对 102 B，与生产同形）。"""
    return [{"threadId": f"th_{index:018x}", "ticketKey": "fk_" + "A" * 43}
            for index in range(count)]


async def test_two_hundred_ticket_pairs_fit_and_two_hundred_and_one_do_not(client):
    """条数与体上限必须一起改：只抬条数时 200 对会被 413 拦住。按字节断言。"""
    accepted = {"tickets": real_ticket_pairs(200)}
    assert len(json.dumps(accepted).encode()) == 20_413, "200 对的真实体长"
    ok = await client.post("/feedback/inbox", json=accepted)
    assert ok.status == 200, await ok.text()

    over = {"tickets": real_ticket_pairs(201)}
    assert len(json.dumps(over).encode()) == 20_515, "201 对只多 102 B"
    rejected = await client.post("/feedback/inbox", json=over)
    assert rejected.status == 400
    assert (await rejected.json())["error"]["code"] == "feedback/bad-request"


async def test_the_ticket_pair_limit_and_the_body_limit_are_one_coupling(client, monkeypatch):
    """把体上限改回 16 KB：同一份 200 对请求立刻变成 413——两个上限只有一起改才成立。"""
    import api

    monkeypatch.setattr(api, "_MAX_BODY_BYTES", 16 * 1024)
    response = await client.post("/feedback/inbox", json={"tickets": real_ticket_pairs(200)})
    assert response.status == 413
    assert (await response.json())["error"]["code"] == "feedback/too-large"


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


async def test_inbox_reports_notices_for_the_account(client, provisioned, store):
    token = await paired_device(client, provisioned["agent"]["agentId"])
    account_id = device_of(client, token)["accountId"]
    notice = store.create_notice("维护通知正文", "服务通知", [account_id], at=5_000)

    body = await inbox(client, headers=device_headers(token))
    assert [n["noticeId"] for n in body["notices"]] == [notice["noticeId"]]
    row = body["notices"][0]
    assert set(row) == {"noticeId", "subject", "body", "format", "createdAt", "read"}
    assert row["read"] is False and row["subject"] == "服务通知"
    assert row["format"] == "text", "没指定格式的通知按 text（手机侧 Markdown）"
    assert body["unreadCount"] == 1
    assert (await inbox(client))["notices"] == [], "匿名没有通知"


async def test_inbox_reports_an_html_notice_and_an_html_reply(client, provisioned, store):
    """FR-034：我们发出的正文自带格式标记，inbox 原样带出（html 走锁死的容器）。"""
    token = await paired_device(client, provisioned["agent"]["agentId"])
    account_id = device_of(client, token)["accountId"]
    store.create_notice("<h1>日报</h1>", "日报", [account_id], format="html", at=5_000)
    ticket = await feedback_ticket(client)
    store.append_feedback_message(ticket["threadId"], "<h1>报告</h1>", author="owner",
                                  format="html")

    body = await inbox(client, [ticket_pair(ticket)], headers=device_headers(token))
    assert [n["format"] for n in body["notices"]] == ["html"]
    thread = next(t for t in body["threads"] if t["threadId"] == ticket["threadId"])
    assert [m["format"] for m in thread["messages"]] == ["text", "html"], \
        "用户那封是 text，我们的回信是 html"


@pytest.mark.parametrize("path", ["/feedback/submit", "/feedback/append"])
async def test_the_user_paths_reject_an_unknown_format(client, path):
    """用户提交的正文永远是 text：给一个我们不认的格式就在 400 上拒掉，不入库。"""
    payload: dict = {"text": "正文", "format": "rtf"}
    if path.endswith("append"):
        payload.update(ticket_pair(await feedback_ticket(client)))
    response = await client.post(path, json=payload)
    assert response.status == 400, await response.text()
    assert (await response.json())["error"]["code"] == "feedback/bad-request"


async def test_the_user_paths_store_text_whatever_format_they_are_handed(client, store):
    """`text`/`html` 都是合法取值，但用户提交的正文一律存 `text`（FR-034 只管我们发出的）。"""
    response = await client.post("/feedback/submit", json={"text": "正文", "format": "  text "})
    assert response.status == 200, await response.text()
    body = await response.json()
    assert store.feedback_thread(body["threadId"], None)["messages"][0]["format"] == "text"

    token = await feedback_ticket(client)
    appended = await client.post("/feedback/append", json={**ticket_pair(token), "text": "补充",
                                                           "format": "html"})
    assert appended.status == 200, await appended.text()
    thread = store.feedback_thread(token["threadId"], None)
    assert [m["format"] for m in thread["messages"]] == ["text", "text"], \
        "用户补充不是 html——我们不替调用方解释这个字段"


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
    registry: dict[str, dict] = {}

    async def resolve(token: str):
        return registry.get(token)

    app = mail_module.create_app(store=store, resolve_device=resolve, base_path="/dsh-link")
    app["test_devices"] = registry
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
    assert thread["ownerUnread"] == 0 and thread["userReadAt"] is not None
    assert (await inbox(client, [ticket_pair(ticket)]))["unreadCount"] == 0


async def test_read_tells_the_account_so_the_other_devices_refresh(client, store, provisioned):
    """032 FR-009：已读落库后通知同账户的其他在线设备（这里只验"通知了一声、带着账户"）。"""
    token = await paired_device(client, provisioned["agent"]["agentId"], "DSH-One")
    ticket = await feedback_ticket(client)
    store.append_feedback_message(ticket["threadId"], "回信", author="owner")
    client.app["test_notified"].clear()

    marked = await client.post("/feedback/read", json={
        "threadIds": [ticket["threadId"]], "tickets": [ticket_pair(ticket)],
    }, headers={"Authorization": f"Bearer {token}"})
    assert marked.status == 200, await marked.text()

    assert client.app["test_notified"] == [(provisioned["account"]["accountId"], None)]


async def test_a_new_ticket_tells_the_team_account(client, store):
    """032 FR-009 的另一半：不止"已读"，**新信**也要让对面那几台设备当场去拉。

    在此之前只有已读会通知，新信悄无声息——团队的手机要等回前台才看到角标（owner 2026-10-17 反馈）。
    """
    client.app["test_notified"].clear()
    await feedback_ticket(client, text="新来信", deviceModel="iPhone15,4")
    assert client.app["test_notified"] == [(TEAM_ACCOUNT, None)]


async def test_an_owner_reply_tells_the_submitter(client, store):
    """团队回信是一封新信：来信账户的设备要当场知道，角标立刻动。"""
    user = register_device(client, account_id="acc_user")
    submitted = await client.post("/feedback/submit", json={
        "text": "来信正文", "deviceModel": "iPhone15,4"}, headers=device_headers(user))
    assert submitted.status == 200, await submitted.text()
    ticket = await submitted.json()
    team = register_device(client, account_id=TEAM_ACCOUNT)

    client.app["test_notified"].clear()
    replied = await client.post("/feedback/append", json={
        "threadId": ticket["threadId"], "text": "我们看一下", "format": "text"},
        headers=device_headers(team))
    assert replied.status == 200, await replied.text()
    assert client.app["test_notified"] == [("acc_user", None)]


async def test_a_user_note_tells_the_team_again(client, store):
    """用户往线程里补一句也是新信：团队收件箱的角标要跟着动，不能只在自己设备上变。"""
    ticket = await feedback_ticket(client, text="来信", deviceModel="iPhone15,4")
    client.app["test_notified"].clear()
    appended = await client.post("/feedback/append", json={
        "threadId": ticket["threadId"], "ticketKey": ticket["ticketKey"], "text": "补充一句"})
    assert appended.status == 200, await appended.text()
    assert client.app["test_notified"] == [(TEAM_ACCOUNT, None)]


async def test_read_without_a_device_token_notifies_nobody(client, store):
    """匿名提交没有账户，"通知其他设备"这件事无从谈起——不能因此报错或发空通知。"""
    ticket = await feedback_ticket(client)
    client.app["test_notified"].clear()
    marked = await client.post("/feedback/read", json={
        "threadIds": [ticket["threadId"]], "tickets": [ticket_pair(ticket)],
    })
    assert marked.status == 200, await marked.text()
    assert client.app["test_notified"] == []


async def test_read_without_a_device_token_ignores_notice_ids(client, store):
    store.create_notice("通知正文", "服务通知", ["acc_x"], at=5_000)
    notice_id = store._rows("SELECT noticeId FROM notices")[0]["noticeId"]
    response = await client.post("/feedback/read", json={"threadIds": [], "noticeIds": [notice_id]})
    assert response.status == 200, await response.text()
    assert (await response.json())["unreadCount"] == 0
    assert store.notices_for_account("acc_x")[0]["read"] is False, "没有设备令牌就标不动 notice"


async def test_read_marks_a_notice_for_the_whole_account(client, provisioned, store):
    """019：已读是账号级一份——同一账号的另一台设备再拉，看到的是已读。"""
    one = await paired_device(client, provisioned["agent"]["agentId"], "DSH-One")
    two = await paired_device(client, provisioned["agent"]["agentId"], "DSH-Two")
    account_id = device_of(client, one)["accountId"]
    assert device_of(client, two)["accountId"] == account_id, "前提：两台设备同账号"
    notice = store.create_notice("维护通知", "服务通知", [account_id], at=5_000)

    response = await client.post("/feedback/read",
                                 json={"threadIds": [], "noticeIds": [notice["noticeId"]]},
                                 headers=device_headers(one))
    assert response.status == 200, await response.text()
    assert (await response.json())["unreadCount"] == 0
    assert store.notices_for_account(account_id)[0]["read"] is True

    # 另一台设备（同账号）不需要再标一次，拉到的就是已读、未读数为 0。
    body = await inbox(client, headers=device_headers(two))
    assert [n["read"] for n in body["notices"]] == [True]
    assert body["unreadCount"] == 0


async def test_a_repaired_device_still_sees_the_accounts_notices(client, provisioned, store):
    """019 的起因场景：手机重配换了 deviceId，收件箱里的通知不该跟着丢。

    断言的是"重新配对之后还能取到"——旧实现里这条会失败，因为投递行挂在旧设备上。
    """
    first = await paired_device(client, provisioned["agent"]["agentId"], "DSH-Old")
    account_id = device_of(client, first)["accountId"]
    notice = store.create_notice("日报", "运营日报", [account_id], at=5_000)
    unregister_device(client, first)   # 旧设备的令牌从此解析不到
    second = await paired_device(client, provisioned["agent"]["agentId"], "DSH-New")

    body = await inbox(client, headers=device_headers(second))
    assert [n["noticeId"] for n in body["notices"]] == [notice["noticeId"]]
    assert [n["read"] for n in body["notices"]] == [False]
    assert body["unreadCount"] == 1


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
    unregister_device(client, token)   # 令牌从此解析不到 = 撤销/过期/中转不可达

    submitted = await client.post("/feedback/submit", json={"text": "撤销之后也要能提意见"},
                                  headers=device_headers(token))
    assert submitted.status == 200, "撤销的令牌不报 401（提交按匿名处理）"
    thread = store.feedback_thread((await submitted.json())["threadId"], None)
    assert thread["deviceId"] is None

    # 读取同样按匿名：拿不到东西，但也不是 401。
    assert (await inbox(client, headers=device_headers(token)))["threads"] == []


# ── 并发（2026-10-17：单进程多请求同时落到同一个 SQLite 库）───────────────────
#
# 生产是单进程 aiohttp + 线程池里的同步 SQLite，App 侧又会并发（别的设备、崩溃上报、
# 用户连点）。这里只钉"并发不丢写、不串号"这条底线：丢一条留言或把两封信并成一条
# 都是生产上很难回查的那种坏法。


async def test_parallel_appends_to_one_thread_keep_every_message(client, store):
    import asyncio

    ticket = await feedback_ticket(client, text="原文")
    sentences = [f"第 {index} 句" for index in range(12)]
    responses = await asyncio.gather(*[
        client.post("/feedback/append", json={**ticket_pair(ticket), "text": text})
        for text in sentences])
    assert [response.status for response in responses] == [200] * len(sentences), \
        [await response.text() for response in responses]

    bodies = [message["body"] for message in
              store.feedback_thread(ticket["threadId"], None)["messages"]]
    assert sorted(bodies) == sorted(["原文", *sentences]), "并发追加一条都不许丢、不许重复"
    thread = store.feedback_thread(ticket["threadId"], None)
    assert thread["status"] == "open", "用户补的话把线程拨回 open"
    assert thread["lastMessageAt"] is not None


async def test_parallel_submits_each_get_their_own_thread(client, store):
    import asyncio

    payloads = [{"text": f"第 {index} 封"} for index in range(10)]
    responses = await asyncio.gather(*[client.post("/feedback/submit", json=payload)
                                       for payload in payloads])
    assert [response.status for response in responses] == [200] * len(payloads)
    thread_ids = [(await response.json())["threadId"] for response in responses]
    assert len(set(thread_ids)) == len(payloads), "每封信一条线程，不许并号"
    subjects = {store.feedback_thread(thread_id, None)["messages"][0]["body"]
                for thread_id in thread_ids}
    assert subjects == {payload["text"] for payload in payloads}


# ── v2 数据面（M2）：同一批行的第二种投影，老形状一个字段都不变 ──────────────


async def inbox_v2(client, tickets=(), headers=None, **extra) -> dict:
    response = await client.post("/feedback/inbox",
                                 json={"inboxVersion": 2, "tickets": list(tickets), **extra},
                                 headers=headers or {})
    assert response.status == 200, await response.text()
    return await response.json()


def without_message_ids(body: dict) -> dict:
    """把随机的 `fm_…` 换成占位，换来可以逐字段对比的快照。"""
    for thread in body["threads"]:
        for message in thread["messages"]:
            message["messageId"] = "<messageId>"
    return body


async def test_the_v1_inbox_shape_is_pinned_verbatim(client, store):
    """不带 `inboxVersion` 的响应形状逐字钉住：老 App 的 wire 契约不是第二份数据。"""
    token = await paired_device(client, name="DSH-V1")
    account_id = device_of(client, token)["accountId"]
    submitted = await client.post("/feedback/submit", json={
        "text": "原文", "subject": "主题", "deviceModel": "iPhone15,4",
        "appVersion": "1.2 (345)", "systemVersion": "18.2"}, headers=device_headers(token))
    assert submitted.status == 200, await submitted.text()
    ticket = await submitted.json()
    replied_at = ticket["createdAt"] + 1_000
    store.append_feedback_message(ticket["threadId"], "回信", author="owner", at=replied_at)
    notice = store.create_notice("通知正文", "服务通知", [account_id], at=5_000)

    body = without_message_ids(await inbox(client, headers=device_headers(token)))
    assert body == {
        "ok": True,
        "threads": [{
            "threadId": ticket["threadId"], "subject": "主题", "status": "replied",
            "createdAt": ticket["createdAt"], "lastMessageAt": replied_at,
            "unread": 1, "teamUnread": 1,   # 旧语义：unread=回信未读，teamUnread=来信未读
            "source": {"kind": "device", "deviceModel": "iPhone15,4",
                       "appVersion": "1.2 (345)", "systemVersion": "18.2",
                       "accountHint": account_id[:12], "teamBound": True},
            "messages": [
                {"messageId": "<messageId>", "author": "user", "body": "原文",
                 "format": "text", "createdAt": ticket["createdAt"]},
                {"messageId": "<messageId>", "author": "owner", "body": "回信",
                 "format": "text", "createdAt": replied_at},
            ]}],
        "notices": [{"noticeId": notice["noticeId"], "subject": "服务通知", "body": "通知正文",
                     "format": "text", "createdAt": 5_000, "read": False}],
        "unreadCount": 2,
        "teamPerspective": False,
    }


async def test_the_v2_inbox_reports_pages_limits_and_my_side(client, store):
    """v2：摘要 + 游标 + 一页容量 + 视角；正文、teamUnread、teamBound 不再出现。"""
    token = await paired_device(client, name="DSH-V2")
    account_id = device_of(client, token)["accountId"]
    submitted = await client.post("/feedback/submit", json={
        "text": "原文", "deviceModel": "iPhone15,4"}, headers=device_headers(token))
    ticket = await submitted.json()
    notice = store.create_notice("通知正文", "服务通知", [account_id], at=5_000)

    body = await inbox_v2(client, headers=device_headers(token))
    assert set(body) == {"ok", "inboxVersion", "teamPerspective", "threads", "threadsPage",
                         "notices", "noticesPage", "unreadCount", "limits"}
    assert body["ok"] is True and body["inboxVersion"] == 2 and body["teamPerspective"] is False

    thread = body["threads"][0]
    assert set(thread) == {"threadId", "subject", "status", "createdAt", "lastMessageAt",
                           "mySide", "unread", "source", "messages"}
    assert thread["mySide"] == "user" and thread["unread"] == 0
    assert set(thread["source"]) == {"kind", "deviceModel", "appVersion", "systemVersion",
                                     "accountHint"}, "v2 不再下发 source.teamBound"
    assert "teamUnread" not in thread

    assert body["threadsPage"] == {"more": False, "nextBefore": {
        "lastMessageAt": thread["lastMessageAt"], "threadId": ticket["threadId"]}}
    assert body["notices"] == [{"noticeId": notice["noticeId"], "subject": "服务通知",
                                "format": "text", "createdAt": 5_000, "read": False}], \
        "v2 列表只持有摘要，正文去 /feedback/notice 取"
    assert body["noticesPage"] == {"more": False, "nextBefore": {
        "createdAt": 5_000, "noticeId": notice["noticeId"]}}
    assert body["limits"] == {"textChars": 4000, "textBytes": 12000, "subjectChars": 80,
                              "maxTicketPairs": 200, "messagesPerThread": 6,
                              "threadPageSize": 30, "noticePageSize": 40}
    assert body["unreadCount"] == 1


async def test_the_v2_thread_window_defaults_to_six_messages_per_thread(client, store):
    ticket = await feedback_ticket(client)
    for index in range(10):
        store.append_feedback_message(ticket["threadId"], f"补充 {index}",
                                      at=9_000_000_000_000 + index)
    default = await inbox_v2(client, [ticket_pair(ticket)])
    assert [m["body"] for m in default["threads"][0]["messages"]] == [
        f"补充 {index}" for index in range(4, 10)]
    narrowed = await inbox_v2(client, [ticket_pair(ticket)], messagesPerThread=2)
    assert [m["body"] for m in narrowed["threads"][0]["messages"]] == ["补充 8", "补充 9"]


@pytest.mark.parametrize("payload", [
    {"threadsPage": {"limit": 0}},
    {"threadsPage": {"limit": 101}},
    {"threadsPage": {"limit": "30"}},
    {"threadsPage": {"before": {"lastMessageAt": 1}}},
    {"noticePage": {"limit": 101}},
    {"noticePage": {"before": {"createdAt": "x", "noticeId": "nt_x"}}},
])
async def test_the_v2_pages_reject_bad_input(client, payload):
    response = await client.post("/feedback/inbox", json={"inboxVersion": 2, **payload})
    assert response.status == 400, await response.text()
    assert (await response.json())["error"]["code"] == "feedback/bad-request"


async def test_all_notice_history_is_reachable_and_the_badge_ignores_the_window(client, store):
    """205 条未读、40/页走到尾：并集 205、无重复、每页都没有正文，角标恒为 205。"""
    token = await paired_device(client, name="DSH-Pages")
    account_id = device_of(client, token)["accountId"]
    for index in range(205):
        store.create_notice(f"日报正文 {index}", f"日报 {index}", [account_id], at=1_000 + index)

    seen: list[str] = []
    before = None
    pages = 0
    while True:
        body = await inbox_v2(client, headers=device_headers(token),
                              noticePage={"limit": 40, **({"before": before} if before else {})})
        assert body["unreadCount"] == 205, "角标与窗口无关"
        assert len(body["notices"]) == (40 if body["noticesPage"]["more"] else 5)
        assert all("body" not in notice for notice in body["notices"]), "v2 列表不带正文"
        seen.extend(notice["noticeId"] for notice in body["notices"])
        pages += 1
        if not body["noticesPage"]["more"]:
            break
        before = body["noticesPage"]["nextBefore"]
    assert pages == 6 and len(seen) == 205 == len(set(seen))


async def test_all_thread_history_is_reachable_through_the_thread_cursor(client, store):
    token = await paired_device(client, name="DSH-Walk")
    device = device_of(client, token)
    for index in range(205):
        thread = store.create_feedback_thread(
            ticket_hash=sha256_hex(f"fk_{index}"), text=f"第 {index} 封",
            device_id=device["deviceId"], account_id=device["accountId"], at=1_000 + index)
        for extra in range(5):
            store.append_feedback_message(thread["threadId"], f"补充 {extra}", author="owner",
                                          at=1_000 + index)

    seen: list[str] = []
    before = None
    pages = 0
    while True:
        body = await inbox_v2(client, headers=device_headers(token),
                              messagesPerThread=6,
                              threadsPage={"limit": 30, **({"before": before} if before else {})})
        assert len(body["threads"]) == (30 if body["threadsPage"]["more"] else 25)
        assert all(len(thread["messages"]) == 6 for thread in body["threads"])
        seen.extend(thread["threadId"] for thread in body["threads"])
        pages += 1
        if not body["threadsPage"]["more"]:
            break
        before = body["threadsPage"]["nextBefore"]
    assert pages == 7 and len(seen) == 205 == len(set(seen))


async def test_the_v2_first_screen_stays_under_the_budget(client, store):
    """首屏 = 30 线程 × 6 留言 + 40 条通知摘要；生产副本对照组的 v1 是 6.95 MB。"""
    token = await paired_device(client, name="DSH-Budget")
    device = device_of(client, token)
    account_id = device["accountId"]
    body_text = "会话一直转圈，日志已附上，麻烦看一下。" * 2      # 约 100 B，贴近生产正文中位
    for index in range(30):
        thread = store.create_feedback_thread(
            ticket_hash=sha256_hex(f"fk_{index}"), text=body_text,
            subject=f"问题 {index}", device_id=device["deviceId"], account_id=account_id,
            at=1_000 + index)
        for extra in range(5):
            store.append_feedback_message(thread["threadId"], body_text, author="owner",
                                          at=1_000 + index)
    for index in range(40):
        store.create_notice("日报正文" * 20, f"日报 {index}", [account_id], format="html",
                            at=9_000 + index)

    response = await client.post("/feedback/inbox",
                                 json={"inboxVersion": 2}, headers=device_headers(token))
    assert response.status == 200
    raw = await response.read()
    assert len(raw) < 128 * 1024, f"首屏 {len(raw)} B 超预算"
    body = json.loads(raw)
    assert len(body["threads"]) == 30 and len(body["notices"]) == 40


async def test_the_v1_window_is_still_two_hundred_notices_and_counts_beyond_it(client, store):
    """v1 的窗口与形状不变；未读聚合与 v2 同一次计算（设计 M2.5：不保留第二套算法）。"""
    token = await paired_device(client, name="DSH-Legacy")
    account_id = device_of(client, token)["accountId"]
    for index in range(205):
        store.create_notice(f"正文 {index}", f"通知 {index}", [account_id], at=1_000 + index)

    body = await inbox(client, headers=device_headers(token))
    assert len(body["notices"]) == 200, "v1 仍是 200 条窗口"
    assert set(body["notices"][0]) == {"noticeId", "subject", "body", "format", "createdAt",
                                       "read"}, "v1 仍内联正文"
    assert body["unreadCount"] == 205, "角标不再被封顶在 200"


# ── POST /feedback/notice（M2）：正文按需取，三次未命中同一条 404 ─────────────


async def test_the_notice_endpoint_returns_the_body_to_its_recipient(client, store):
    token = await paired_device(client, name="DSH-Notice")
    account_id = device_of(client, token)["accountId"]
    notice = store.create_notice("通知正文", "服务通知", [account_id], format="html", at=5_000)

    response = await client.post("/feedback/notice", json={"noticeId": notice["noticeId"]},
                                 headers=device_headers(token))
    assert response.status == 200, await response.text()
    assert await response.json() == {
        "ok": True,
        "notice": {"noticeId": notice["noticeId"], "subject": "服务通知", "body": "通知正文",
                   "format": "html", "createdAt": 5_000, "read": False}}


async def test_the_notice_endpoint_answers_one_404_for_anonymous_missing_and_foreign(
        client, store):
    token = await paired_device(client, name="DSH-Notice")
    foreign = store.create_notice("给别人的正文", "别人的通知", ["acc_someone"], at=5_000)

    other = await client.post("/feedback/notice", json={"noticeId": foreign["noticeId"]},
                              headers=device_headers(token))
    missing = await client.post("/feedback/notice", json={"noticeId": "nt_nope"},
                                headers=device_headers(token))
    anonymous = await client.post("/feedback/notice", json={"noticeId": foreign["noticeId"]})
    assert [response.status for response in (other, missing, anonymous)] == [404, 404, 404]

    bodies = [await response.read() for response in (other, missing, anonymous)]
    assert bodies[0] == bodies[1] == bodies[2], "不泄露通知是否存在/是否投给这个账号"
    append_404 = await client.post("/feedback/append", json={
        "threadId": "th_nope", "ticketKey": TICKET, "text": "补充"})
    assert await append_404.read() == bodies[0], "与线程那条 404 逐字节相同"


async def test_the_notice_endpoint_charges_the_read_budget(client, store):
    from api import ClaimLimiter

    notice = store.create_notice("正文", "通知", ["acc_someone"], at=5_000)
    client.app["feedback_read_limiter"] = ClaimLimiter(limit=1, window_s=600)
    first = await client.post("/feedback/notice", json={"noticeId": notice["noticeId"]})
    assert first.status == 404, "未命中同样计入预算"
    second = await client.post("/feedback/notice", json={"noticeId": notice["noticeId"]})
    assert second.status == 429
    assert (await second.json())["error"]["code"] == "feedback/rate-limited"


async def test_the_notice_route_is_registered_under_the_prefix(prefixed_client):
    response = await prefixed_client.post("/dsh-link/feedback/notice",
                                          json={"noticeId": "nt_nope"})
    assert response.status == 404
    assert (await response.json())["error"]["code"] == "feedback/not-found"


async def test_notices_false_still_counts_the_unread_badge(client, store):
    """`notices: false` 只是不返回通知列表：未读数照算（与窗口也无关系）。"""
    token = await paired_device(client, name="DSH-NoList")
    account_id = device_of(client, token)["accountId"]
    store.create_notice("正文", "通知", [account_id], at=5_000)
    body = await inbox_v2(client, headers=device_headers(token), notices=False)
    assert body["notices"] == []
    assert body["noticesPage"] == {"more": False, "nextBefore": None}
    assert body["unreadCount"] == 1


# ── 角标不受线程窗口影响（复核意见）：unreadCount 对所有可见线程成立 ──────────
#
# v2 的线程列表有窗口（30/页），但未读合计不是"当页之和"：它与 `feedback_read`
# 的回包必须永远是同一个数，否则同一账号会看到两个角标。


async def seed_unread_threads(client, store, count: int, *, side: str) -> dict:
    """造 `count` 条线程，每条留一句没读的留言（`side` = 谁没读）。"""
    token = await paired_device(client, name=f"DSH-Badge-{side}")
    device = device_of(client, token)
    for index in range(count):
        thread = store.create_feedback_thread(
            ticket_hash=sha256_hex(f"fk_badge_{index}"), text=f"第 {index} 封",
            device_id=device["deviceId"], account_id=device["accountId"], at=1_000 + index)
        store.append_feedback_message(
            thread["threadId"], f"未读 {index}",
            author="owner" if side == "user" else "user", at=2_000 + index)
    return {"token": token, "device": device}


async def test_the_badge_counts_every_visible_thread_not_just_the_first_page(client, store):
    """205 条线程 × 1 条未读、30/页：首页 unreadCount == 205（不是 30）。"""
    seeded = await seed_unread_threads(client, store, 205, side="user")
    body = await inbox_v2(client, headers=device_headers(seeded["token"]))
    assert len(body["threads"]) == 30 and body["threadsPage"]["more"] is True
    assert body["unreadCount"] == 205


async def test_the_badge_equals_the_sum_of_the_pages(client, store):
    """逐页累加当页线程的 unread == 每页都相同的 unreadCount。"""
    seeded = await seed_unread_threads(client, store, 205, side="user")
    seen: list[str] = []
    total = 0
    before = None
    while True:
        body = await inbox_v2(client, headers=device_headers(seeded["token"]),
                              threadsPage={"limit": 30, **({"before": before} if before else {})})
        assert body["unreadCount"] == 205
        total += sum(thread["unread"] for thread in body["threads"])
        seen.extend(thread["threadId"] for thread in body["threads"])
        if not body["threadsPage"]["more"]:
            break
        before = body["threadsPage"]["nextBefore"]
    assert len(seen) == 205 == len(set(seen))
    assert total == 205


async def test_the_read_response_and_the_next_v2_pull_agree_on_the_badge(client, store):
    """用户侧：read 回包与紧接的 v2 收件箱 unreadCount 相等（读完 10 条后都是 195）。"""
    seeded = await seed_unread_threads(client, store, 205, side="user")
    first = await inbox_v2(client, headers=device_headers(seeded["token"]))
    to_read = [thread["threadId"] for thread in first["threads"][:10]]

    marked = await client.post("/feedback/read", json={"threadIds": to_read},
                               headers=device_headers(seeded["token"]))
    assert marked.status == 200, await marked.text()
    after = await inbox_v2(client, headers=device_headers(seeded["token"]))
    assert (await marked.json())["unreadCount"] == 195
    assert after["unreadCount"] == 195, "read 与紧接的拉取必须是同一个数"


async def test_the_team_badge_also_counts_threads_beyond_the_first_page(client, store):
    """团队侧：40 封来信各 1 条未读，读 5 封后 read 回包 == v2 收件箱 == 35。"""
    letters: list[str] = []
    for index in range(40):
        letter = store.create_feedback_thread(
            ticket_hash=sha256_hex(f"fk_letter_{index}"), text=f"第 {index} 封来信",
            account_id="acc_letter_writer", device_id=f"dev_writer_{index}",
            device_model="iPhone15,4", at=1_000 + index)
        letters.append(letter["threadId"])

    team_token = register_device(client, account_id=TEAM_ACCOUNT)
    first = await inbox_v2(client, headers=device_headers(team_token))
    assert len(first["threads"]) == 30 and first["threadsPage"]["more"] is True
    assert first["unreadCount"] == 40
    assert all(thread["mySide"] == "owner" for thread in first["threads"])

    marked = await client.post("/feedback/read", json={"threadIds": letters[:5]},
                               headers=device_headers(team_token))
    assert marked.status == 200, await marked.text()
    after = await inbox_v2(client, headers=device_headers(team_token))
    assert (await marked.json())["unreadCount"] == 35
    assert after["unreadCount"] == 35


async def test_v1_and_v2_report_the_same_badge(client, store):
    """同一账号、同一时刻：v1（可见集合即全部）与 v2（有窗口）给出的角标相等。"""
    seeded = await seed_unread_threads(client, store, 205, side="user")
    legacy = await inbox(client, headers=device_headers(seeded["token"]))
    modern = await inbox_v2(client, headers=device_headers(seeded["token"]))
    assert len(legacy["threads"]) == 205 and len(modern["threads"]) == 30, "窗口仍然不同"
    assert legacy["unreadCount"] == modern["unreadCount"] == 205


async def test_v1_keeps_the_original_unread_semantics_and_v2_takes_my_side(client, store):
    """同一份非零未读（2 条未读回信 + 1 条未读来信）：

    v1 的 `unread` 仍是"我们写的、用户还没读"（2），`teamUnread` 仍是"用户写的、
    我们还没读"（1）——与旧实现逐字段一致；v2 的 `unread` 才取我这一侧（团队 = 1）。
    """
    letter = store.create_feedback_thread(
        ticket_hash=sha256_hex("fk_semantics"), text="原信", subject="主题",
        account_id="acc_user", device_id="dev_user", device_model="iPhone15,4",
        app_version="1.0", system_version="18.0", at=1_000)
    store.append_feedback_message(letter["threadId"], "补充", author="user", at=1_400)
    store.append_feedback_message(letter["threadId"], "回信一", author="owner", at=2_000)
    store.append_feedback_message(letter["threadId"], "回信二", author="owner", at=3_000)
    store._conn.execute(
        "UPDATE feedbackThreads SET userReadAt=1500, ownerReadAt=1200, lastMessageAt=3000"
        " WHERE threadId=?", (letter["threadId"],))
    store._conn.commit()

    team_token = register_device(client, account_id=TEAM_ACCOUNT)
    user_token = register_device(client, account_id="acc_user")

    for label, token, expected in (("团队", team_token, {"unread": 2, "teamUnread": 1,
                                                        "unreadCount": 1}),
                                   ("用户", user_token, {"unread": 2, "teamUnread": 1,
                                                        "unreadCount": 2})):
        body = await inbox(client, headers=device_headers(token))
        thread = next(t for t in body["threads"] if t["threadId"] == letter["threadId"])
        assert thread["unread"] == expected["unread"], label
        assert thread["teamUnread"] == expected["teamUnread"], label
        assert body["unreadCount"] == expected["unreadCount"], label

    modern = await inbox_v2(client, headers=device_headers(team_token))
    thread = next(t for t in modern["threads"] if t["threadId"] == letter["threadId"])
    assert thread["mySide"] == "owner"
    assert thread["unread"] == 1, "团队这一侧真正没读的来信只有 1 条"
    assert "teamUnread" not in thread
    assert modern["unreadCount"] == 1
