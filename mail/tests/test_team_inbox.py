"""团队收件箱（DESIGN-20261015-team-inbox）：用户来信直达团队账号 + 发件人标识。

钉住合并实施（一、二期）的服务端语义：

1. 非团队账号的提交（含匿名）自动绑到团队账号；团队账号自己的提交与
   测试台机型不绑。
2. 团队设备拉收件箱能看到来信线程，负载带 source（发件人标识）；
   用户自己的可见性不受影响。
3. 团队在 App 里直接回信：append 免凭据、按团队授权，author=owner、
   状态翻 replied；用户换机重配后凭账号也能 append（author=user）。
4. 已读分侧：团队读来信推 ownerReadAt，unreadCount 按侧取 teamUnread。
5. 团队账号未配置（空）时一切回到拆分时的行为。
"""

from __future__ import annotations

import mail as mail_module
from conftest import ACCOUNT_ID, device_headers, feedback_ticket, register_device
from store import Store

TEAM = "acc_team"


async def test_user_letters_bind_to_the_team_account(client, store):
    token = register_device(client, account_id="acc_user")
    submitted = await client.post("/feedback/submit", json={
        "text": "来信正文", "subject": "来信", "deviceModel": "iPhone15,4",
        "appVersion": "1.0"}, headers=device_headers(token))
    assert submitted.status == 200, await submitted.text()
    thread_id = (await submitted.json())["threadId"]

    # 团队收件箱：团队设备按账号看到来信。
    team_token = register_device(client, account_id=TEAM)
    inbox = await client.post("/feedback/inbox", json={"tickets": []},
                              headers=device_headers(team_token))
    assert inbox.status == 200, await inbox.text()
    body = await inbox.json()
    assert [t["threadId"] for t in body["threads"]] == [thread_id]
    thread = body["threads"][0]
    # 发件人标识：机型 + 账号短 id；收件人=团队由 teamBound 表达。
    assert thread["source"]["deviceModel"] == "iPhone15,4"
    assert thread["source"]["accountHint"] == "acc_user"
    assert thread["source"]["teamBound"] is True
    # 团队侧未读 = 用户来信条数。
    assert thread["teamUnread"] == 1 and thread["unread"] == 0
    assert body["unreadCount"] == 1
    assert body["teamPerspective"] is True

    # 用户自己的可见性不变，且看到的是用户侧口径。
    user_inbox = await client.post("/feedback/inbox", json={"tickets": []},
                                   headers=device_headers(token))
    body = await user_inbox.json()
    assert [t["threadId"] for t in body["threads"]] == [thread_id]
    assert body["unreadCount"] == 0, "用户侧没有团队回信，未读为 0"
    assert body["teamPerspective"] is False, "视角按调用方账号给，不随线程走"


async def test_anonymous_letters_bind_to_the_team_account_too(client, store):
    ticket = await feedback_ticket(client, text="匿名来信", deviceModel="iPhone17,1")
    team_token = register_device(client, account_id=TEAM)
    inbox = await client.post("/feedback/inbox", json={"tickets": []},
                              headers=device_headers(team_token))
    body = await inbox.json()
    assert [t["threadId"] for t in body["threads"]] == [ticket["threadId"]]
    assert body["threads"][0]["source"]["kind"] == "anonymous"


async def test_team_own_submissions_and_simulator_models_stay_unbound(client, store):
    team_token = register_device(client, account_id=TEAM)
    mine = await client.post("/feedback/submit", json={"text": "团队自己测试"},
                             headers=device_headers(team_token))
    assert mine.status == 200
    thread_id = (await mine.json())["threadId"]
    assert store.feedback_thread(thread_id, None)["teamAccountId"] is None

    simulator = await client.post("/feedback/submit", json={
        "text": "验收单", "deviceModel": "arm64"})
    assert simulator.status == 200
    assert store.feedback_thread((await simulator.json())["threadId"],
                                 None)["teamAccountId"] is None


async def test_the_team_replies_from_the_app_without_a_ticket(client, store):
    ticket = await feedback_ticket(client, text="来信")
    team_token = register_device(client, account_id=TEAM)

    reply = await client.post("/feedback/append", json={
        "threadId": ticket["threadId"], "text": "团队在手机上直接回信"},
        headers=device_headers(team_token))
    assert reply.status == 200, await reply.text()

    thread = store.feedback_thread(ticket["threadId"], None)
    assert thread["messages"][-1]["author"] == "owner", "团队侧补充按回信入账"
    assert thread["status"] == "replied"
    # 用户侧看到未读 +1。
    user_inbox = await client.post("/feedback/inbox", json={
        "tickets": [{"threadId": ticket["threadId"], "ticketKey": ticket["ticketKey"]}]})
    body = await user_inbox.json()
    assert body["unreadCount"] == 1


async def test_a_repaired_user_device_can_append_without_a_ticket(client, store):
    """用户换机重配（新设备同账号）后凭账号补充——既有缺口的顺带修复。"""
    first = register_device(client, account_id="acc_user", name="DSH-Old")
    submitted = await client.post("/feedback/submit", json={"text": "原信"},
                                  headers=device_headers(first))
    thread_id = (await submitted.json())["threadId"]
    from conftest import unregister_device
    unregister_device(client, first)
    second = register_device(client, account_id="acc_user", name="DSH-New")

    appended = await client.post("/feedback/append", json={
        "threadId": thread_id, "text": "换机后的补充"},
        headers=device_headers(second))
    assert appended.status == 200, await appended.text()
    thread = store.feedback_thread(thread_id, None)
    assert thread["messages"][-1]["author"] == "user"


async def test_team_read_marks_the_team_side(client, store):
    ticket = await feedback_ticket(client, text="来信")
    team_token = register_device(client, account_id=TEAM)

    inbox = await client.post("/feedback/inbox", json={"tickets": []},
                              headers=device_headers(team_token))
    assert (await inbox.json())["unreadCount"] == 1

    read = await client.post("/feedback/read", json={
        "threadIds": [ticket["threadId"]]}, headers=device_headers(team_token))
    assert read.status == 200
    assert (await read.json())["unreadCount"] == 0, "团队读来信，teamUnread 清零"
    thread = store.feedback_thread(ticket["threadId"], None)
    assert thread["ownerReadAt"] is not None


async def test_a_stale_ticket_does_not_block_an_authorized_team_device(client, store):
    """授权路径彼此独立：团队设备已按账号授权，客户端残留的失效凭据不当拦路石。

    「错凭据 → 404」的隐私性质属于**无设备授权**的调用方（匿名探测者），
    那条由移植用例 test_append_404_is_byte_identical… 钉住；这里钉的是
    授权团队的顺滑路径——App 里团队回信不会带用户的取件凭据。
    """
    ticket = await feedback_ticket(client, text="来信")
    team_token = register_device(client, account_id=TEAM)
    response = await client.post("/feedback/append", json={
        "threadId": ticket["threadId"], "ticketKey": "fk_" + "B" * 43,
        "text": "凭据失效也不影响团队回信"},
        headers=device_headers(team_token))
    assert response.status == 200, await response.text()
    thread = store.feedback_thread(ticket["threadId"], None)
    assert thread["messages"][-1]["author"] == "owner"


async def test_everything_falls_back_to_the_old_behaviour_without_a_team_account(
        aiohttp_client, store):
    """未配置团队账号：不绑、不投、不认团队侧——拆分时的行为原样。"""
    async def resolve(token):
        return {"deviceId": "dev_x", "accountId": "acc_user"}

    app = mail_module.create_app(store=store, resolve_device=resolve)
    client = await aiohttp_client(app)
    submitted = await client.post("/feedback/submit", json={
        "text": "无团队配置", "deviceModel": "iPhone15,4"},
        headers={"Authorization": "Bearer any"})
    assert submitted.status == 200
    thread = store.feedback_thread((await submitted.json())["threadId"], None)
    assert thread["teamAccountId"] is None
