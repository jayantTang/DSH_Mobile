"""信件在账号之间的隔离：谁看得到谁的信、谁写得进去。

背景（owner 2026-10-17 追问）：团队收件箱把**其他用户**的来信放进 owner 的收件箱，
于是必须钉死反过来的一半——别的用户看不到不是写给他们的信。可见性只有三条命中
路径（`store.feedback_threads_by_device` + `feedback_threads_by_tickets`）：

1. 取件凭据（`fk_` 明文只在写信人自己手机的 Keychain，服务端只存 SHA-256）；
2. 设备命中（`deviceId` 相同）；
3. 账号命中（`accountId` 相同）；
   外加团队那一侧：调用方**就是**团队账号，且线程命中派生谓词（只在开关打开时参与）。

本文件按身份矩阵逐格钉：匿名 / 无关账号 / 写信人 / 团队，四者对**同一个线程**
分别能读什么、能写什么。矩阵之外的边界（错凭据、坏令牌、缺字段）在
`test_feedback_api.py` 里已有，这里只补跨身份这一面。
"""

from __future__ import annotations

import pytest

from conftest import TEAM_ACCOUNT, device_headers, feedback_ticket, register_device

TEAM = TEAM_ACCOUNT
AUTHOR = "acc_author"
OTHER = "acc_other"


async def _inbox(client, token: str | None, **payload) -> dict:
    headers = device_headers(token) if token else {}
    response = await client.post("/feedback/inbox", json={"tickets": [], **payload},
                                 headers=headers)
    assert response.status == 200, await response.text()
    return await response.json()


async def test_an_unrelated_account_sees_nothing_of_a_letter_it_did_not_write(client, store):
    author = register_device(client, account_id=AUTHOR)
    submitted = await client.post("/feedback/submit", json={
        "text": "只有我和团队该看到这封信", "deviceModel": "iPhone15,4"},
        headers=device_headers(author))
    assert submitted.status == 200, await submitted.text()
    letter_id = (await submitted.json())["threadId"]

    other = register_device(client, account_id=OTHER)
    body = await _inbox(client, other)
    assert body["threads"] == []
    assert body["unreadCount"] == 0

    anonymous = await _inbox(client, None)
    assert anonymous["threads"] == [], "匿名调用只有凭据，没有凭据就什么都没有"

    # 对照：写信人与团队都看得到（团队那一侧由派生谓词决定，不落库）。
    assert [t["threadId"] for t in (await _inbox(client, author))["threads"]] == [letter_id]
    team = register_device(client, account_id=TEAM)
    assert [t["threadId"] for t in (await _inbox(client, team))["threads"]] == [letter_id]
    assert store.feedback_thread(letter_id, None, team=TEAM_ACCOUNT,
                                 caller_account=TEAM)["userLetter"] is True


async def test_the_team_hit_path_never_answers_a_non_team_caller(client, store):
    """团队那条命中路径的判据是「调用方**就是**团队账号」——扩出来的隔离用例。

    修 P0-2 时要改的正是这一处：旧实现靠"线程上的 teamAccountId 等于调用方账号"
    隐式达到，改成派生谓词后必须显式比较调用方账号，否则任何账号都会命中全部来信。
    """
    author = register_device(client, account_id=AUTHOR)
    submitted = await client.post("/feedback/submit", json={
        "text": "只有我和团队该看到这封信", "deviceModel": "iPhone15,4"},
        headers=device_headers(author))
    assert submitted.status == 200, await submitted.text()
    letter_id = (await submitted.json())["threadId"]

    # 两个不同的非团队账号，各自带着"团队开关已打开"的同一份配置，一条来信都拿不到。
    for account_id in (OTHER, "acc_someone_else"):
        stranger = register_device(client, account_id=account_id)
        body = await _inbox(client, stranger)
        assert letter_id not in {t["threadId"] for t in body["threads"]}
        assert body["unreadCount"] == 0

    # 存储层同一格：给了 team_account 也只回答"调用方自己是不是团队"。
    assert store.feedback_threads_by_device("dev_stranger", OTHER, team_account=TEAM) == []
    assert [t["threadId"] for t in store.feedback_threads_by_device(
        "dev_any", TEAM, team_account=TEAM)] == [letter_id]


async def test_an_unrelated_account_cannot_append_even_knowing_the_thread_id(client, store):
    author = register_device(client, account_id=AUTHOR)
    submitted = await client.post("/feedback/submit", json={"text": "原信"},
                                  headers=device_headers(author))
    letter_id = (await submitted.json())["threadId"]
    before = len(store.feedback_thread(letter_id, None)["messages"])

    for token in (None, register_device(client, account_id=OTHER)):
        headers = device_headers(token) if token else {}
        for ticket in (None, "fk_" + "Z" * 43):
            payload = {"threadId": letter_id, "text": "越权写一句"}
            if ticket:
                payload["ticketKey"] = ticket
            response = await client.post("/feedback/append", json=payload, headers=headers)
            assert response.status == 404, "与「线程不存在」同一个响应，不泄露存在与否"
            assert (await response.json())["error"]["code"] == "feedback/not-found"
    assert len(store.feedback_thread(letter_id, None)["messages"]) == before, "一个字都不许写进去"


async def test_an_unrelated_account_cannot_mark_someone_elses_letter_read(client, store):
    author = register_device(client, account_id=AUTHOR)
    submitted = await client.post("/feedback/submit", json={"text": "原信"},
                                  headers=device_headers(author))
    letter_id = (await submitted.json())["threadId"]
    other = register_device(client, account_id=OTHER)

    response = await client.post("/feedback/read", json={"threadIds": [letter_id]},
                                 headers=device_headers(other))
    assert response.status == 200
    assert (await response.json())["unreadCount"] == 0
    thread = store.feedback_thread(letter_id, None)
    assert thread["ownerReadAt"] is None and thread["userReadAt"] is None, "两边都不许被推"


async def test_a_letter_is_not_reachable_through_someone_elses_ticket(client, store):
    """拿自己那条线程的合法凭据，去点别人的线程 id——命中不了（凭据是按线程配对的）。"""
    author = register_device(client, account_id=AUTHOR)
    mine = await client.post("/feedback/submit", json={"text": "我的信"},
                             headers=device_headers(author))
    theirs = await feedback_ticket(client, text="别人的信", deviceModel="iPhone15,4")
    my_ticket = await mine.json()

    response = await client.post("/feedback/inbox", json={"tickets": [
        {"threadId": theirs["threadId"], "ticketKey": my_ticket["ticketKey"]},
        {"threadId": my_ticket["threadId"], "ticketKey": my_ticket["ticketKey"]}]})
    body = await response.json()
    assert [t["threadId"] for t in body["threads"]] == [my_ticket["threadId"]]


async def test_notices_are_only_delivered_to_the_named_accounts(client, store):
    team = register_device(client, account_id=TEAM)
    other = register_device(client, account_id=OTHER)
    store.create_notice(body="只投给写信人的通知", subject="通知", account_ids=[AUTHOR])

    assert [n["subject"] for n in (await _inbox(client, other))["notices"]] == []
    assert (await _inbox(client, team))["notices"] == []
    assert (await _inbox(client, None))["notices"] == []

    delivered = await _inbox(client, None, notices=True)
    assert delivered["notices"] == [], "匿名没有账号，通知也投不到"

    author = register_device(client, account_id=AUTHOR)
    body = await _inbox(client, author)
    assert [n["subject"] for n in body["notices"]] == ["通知"]
    assert body["unreadCount"] == 1, "未读通知只算在收件账号头上"


async def test_the_write_budget_is_kept_per_device_not_only_per_source(client, store):
    """每台设备另有一桶写预算：同一来源上多设备连发也不该被误伤，
    单台设备刷爆时只挡它自己（匿名没有设备，按来源那桶算）。"""
    from api import ClaimLimiter

    client.app["feedback_write_device_limiter"] = ClaimLimiter(limit=2, window_s=600)
    first = register_device(client, account_id=AUTHOR)
    second = register_device(client, account_id=AUTHOR)

    for index in range(2):
        ok = await client.post("/feedback/submit", json={"text": f"第 {index} 封"},
                               headers=device_headers(first))
        assert ok.status == 200, await ok.text()
    blocked = await client.post("/feedback/submit", json={"text": "第三封"},
                                headers=device_headers(first))
    assert blocked.status == 429
    assert (await blocked.json())["error"]["code"] == "feedback/rate-limited"

    unaffected = await client.post("/feedback/submit", json={"text": "另一台设备"},
                                   headers=device_headers(second))
    assert unaffected.status == 200, "别的设备有自己的桶，不该被牵连"


@pytest.mark.parametrize("model", ["arm64", "x86_64", "deploy-check", "Node", "simulator",
                                   "test-harness"])
async def test_every_test_harness_model_stays_out_of_the_team_inbox(client, store, model):
    """测试台机型名单是"别把自己的验收单当用户来信"的**唯一**防线，逐项钉住。"""
    submitted = await client.post("/feedback/submit", json={"text": "验收单", "deviceModel": model})
    assert submitted.status == 200, await submitted.text()
    assert store.feedback_thread((await submitted.json())["threadId"], None,
                                 team=TEAM_ACCOUNT)["userLetter"] is False

    team = register_device(client, account_id=TEAM)
    assert (await _inbox(client, team))["threads"] == []


async def test_a_real_model_counts_as_a_letter_even_when_the_hint_field_is_missing(client, store):
    """名单之外（含完全不填机型）的提交一律算真实来信——宁可信其真。"""
    for payload in ({"text": "无机型字段"}, {"text": "空机型字段", "deviceModel": ""}):
        submitted = await client.post("/feedback/submit", json=payload)
        assert submitted.status == 200, await submitted.text()
        assert store.feedback_thread((await submitted.json())["threadId"], None,
                                     team=TEAM_ACCOUNT)["userLetter"] is True
