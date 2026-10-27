"""团队收件箱（DESIGN-20261015-team-inbox）：用户来信直达团队账号 + 发件人标识。

钉住合并实施（一、二期）的服务端语义：

1. 归属是**派生谓词**（`store.is_user_letter`），不是提交时的配置快照：
   团队账号自己的提交与测试台机型不算来信。
2. 团队设备拉收件箱能看到来信线程，负载带 source（发件人标识）与 mySide；
   用户自己的可见性不受影响。
3. 团队在 App 里直接回信：append 免凭据、按团队授权，author=owner、
   状态翻 replied；用户换机重配后凭账号也能 append（author=user）。
4. 已读分侧：团队读来信推 ownerReadAt，未读只给"我这一侧"一个数。
5. 团队账号未配置（空）时一切回到拆分时的行为。
6. 开关为空期间收到的信，开关恢复后自动出现在团队收件箱（无回填脚本）。
"""

from __future__ import annotations

import mail as mail_module
from conftest import ACCOUNT_ID, device_headers, feedback_ticket, register_device
from store import Store

TEAM = "acc_team"


async def test_user_letters_reach_the_team_inbox_with_my_side_owner(client, store):
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
    # 发件人标识：机型 + 账号短 id；收件人=团队由 teamBound 表达（派生值，不落库）。
    assert thread["source"]["deviceModel"] == "iPhone15,4"
    assert thread["source"]["accountHint"] == "acc_user"
    assert thread["source"]["teamBound"] is True
    # v1 投影保持旧语义：unread = 我们写的留言里用户还没读的（这里没有回信 → 0），
    # teamUnread = 用户写的留言里我们还没读的（1）。
    assert thread["unread"] == 0 and thread["teamUnread"] == 1
    assert body["unreadCount"] == 1
    assert body["teamPerspective"] is True

    # 用户自己的可见性不变，且看到的是用户侧口径。
    user_inbox = await client.post("/feedback/inbox", json={"tickets": []},
                                   headers=device_headers(token))
    body = await user_inbox.json()
    assert [t["threadId"] for t in body["threads"]] == [thread_id]
    assert body["threads"][0]["unread"] == 0
    assert body["threads"][0]["teamUnread"] == 1, "旧语义：teamUnread = 自己那封的未读来信数"
    assert body["unreadCount"] == 0, "用户侧没有团队回信，未读为 0"
    assert body["teamPerspective"] is False, "视角按调用方账号给，不随线程走"


async def test_the_team_inbox_reports_my_side_owner_in_v2(client, store):
    ticket = await feedback_ticket(client, text="来信", deviceModel="iPhone15,4")
    team_token = register_device(client, account_id=TEAM)
    response = await client.post("/feedback/inbox", json={"inboxVersion": 2},
                                 headers=device_headers(team_token))
    assert response.status == 200, await response.text()
    body = await response.json()
    thread = body["threads"][0]
    assert thread["threadId"] == ticket["threadId"]
    assert thread["mySide"] == "owner" and thread["unread"] == 1
    assert "teamUnread" not in thread and "teamBound" not in thread["source"]
    assert body["unreadCount"] == 1


async def test_anonymous_letters_reach_the_team_inbox_too(client, store):
    ticket = await feedback_ticket(client, text="匿名来信", deviceModel="iPhone17,1")
    team_token = register_device(client, account_id=TEAM)
    inbox = await client.post("/feedback/inbox", json={"tickets": []},
                              headers=device_headers(team_token))
    body = await inbox.json()
    assert [t["threadId"] for t in body["threads"]] == [ticket["threadId"]]
    assert body["threads"][0]["source"]["kind"] == "anonymous"


async def test_the_teams_own_letters_live_only_on_the_user_side(client, store):
    """团队账号自己的提交：不进收件箱、不产生未读、回信落 user（P0-2 的服务端一半）。"""
    team_token = register_device(client, account_id=TEAM)
    mine = await client.post("/feedback/submit", json={"text": "团队自己测试",
                                                       "deviceModel": "iPhone15,4"},
                             headers=device_headers(team_token))
    assert mine.status == 200
    thread_id = (await mine.json())["threadId"]

    for version in ({}, {"inboxVersion": 2}):
        body = await (await client.post("/feedback/inbox", json=version,
                                        headers=device_headers(team_token))).json()
        assert [t["threadId"] for t in body["threads"]] == [thread_id], \
            "自己的信在列表里（客户端按 mySide 归到已发送）"
        thread = body["threads"][0]
        assert thread["unread"] == 0, "不产生未读"
        assert body["unreadCount"] == 0
        if version:
            assert thread["mySide"] == "user", "团队自己的信落在 user 侧"
        else:
            assert thread["teamUnread"] == 0, "老 App 的角标也不把自己的信算进来"

    reply = await client.post("/feedback/append", json={
        "threadId": thread_id, "text": "自己回自己"}, headers=device_headers(team_token))
    assert reply.status == 200, await reply.text()
    assert store.feedback_thread(thread_id, None)["messages"][-1]["author"] == "user"

    # 验收单（测试机型）连列表都不进团队视野。
    simulator = await client.post("/feedback/submit", json={"text": "验收单",
                                                            "deviceModel": "arm64"})
    assert simulator.status == 200
    body = await (await client.post("/feedback/inbox", json={},
                                    headers=device_headers(team_token))).json()
    assert {t["threadId"] for t in body["threads"]} == {thread_id}


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


# ── 开关关闭 + 库里的团队绑定还在（2026-10-17 生产事故的回归用例）─────────────
#
# 事故形状：一次部署没导出 `DSH_MAIL_TEAM_ACCOUNT`，单元的开关变成空的；而线程的
# 团队绑定是**库里的列**，不归开关管。修复前，团队设备仍然拿到那些来信，但
# `teamPerspective` 是 false——App 按用户视角渲染，用户的信就出现在 owner 的
# 「已发送」里（"怎么用户的发送邮件到我这来了"）。修复的判据是：开关关闭 = 团队
# 命中路径整条不参与，团队两侧（收件箱/已发送）都看不到那些信；写信人自己的
# 可见性、以及 owner 自己的线程不受影响。


async def test_letters_bound_while_the_switch_was_on_are_invisible_when_it_is_off(
        client, client_without_team, store):
    letter = await feedback_ticket(client, text="开关开着时收到的来信", deviceModel="iPhone15,4")
    assert store.feedback_thread(letter["threadId"], None, team=TEAM)["userLetter"] is True

    team_token = register_device(client_without_team, account_id=TEAM)
    inbox = await client_without_team.post("/feedback/inbox", json={"tickets": []},
                                           headers=device_headers(team_token))
    body = await inbox.json()
    assert body["teamPerspective"] is False, "开关关闭，视角恒为用户侧"
    assert body["threads"] == [], "团队线程不许按用户视角发出去（事故回归）"
    assert body["unreadCount"] == 0

    # 那封信还在，凭据持有人照旧取得回来——开关只关掉团队那条命中路径。
    kept = await client_without_team.post("/feedback/inbox", json={
        "tickets": [{"threadId": letter["threadId"], "ticketKey": letter["ticketKey"]}]})
    assert [t["threadId"] for t in (await kept.json())["threads"]] == [letter["threadId"]]


async def test_turning_the_switch_off_keeps_the_owners_own_threads_and_the_authors_letter(
        client, client_without_team, store):
    """两侧的既有可见性都不受开关影响：写信人凭账号看得见自己那封（只是团队那条
    命中路径没了），owner 自己的提交（本来就没绑团队）照旧看得见。"""
    author = register_device(client, account_id="acc_user")
    submitted = await client.post("/feedback/submit", json={
        "text": "用户来信", "deviceModel": "iPhone15,4"}, headers=device_headers(author))
    assert submitted.status == 200, await submitted.text()
    letter_id = (await submitted.json())["threadId"]
    assert store.feedback_thread(letter_id, None, team=TEAM)["userLetter"] is True

    same_user = register_device(client_without_team, account_id="acc_user")
    team_token = register_device(client_without_team, account_id=TEAM)
    mine = await client_without_team.post("/feedback/submit", json={
        "text": "owner 自己的提交", "deviceModel": "iPhone17,1"},
        headers=device_headers(team_token))
    assert mine.status == 200, await mine.text()
    mine_id = (await mine.json())["threadId"]
    assert store.feedback_thread(mine_id, None, team=TEAM)["userLetter"] is False

    seen = {}
    for label, token in (("author", same_user), ("team", team_token)):
        body = await (await client_without_team.post(
            "/feedback/inbox", json={"tickets": []}, headers=device_headers(token))).json()
        seen[label] = [t["threadId"] for t in body["threads"]]
    assert seen["author"] == [letter_id], "写信人按账号看得到自己那封"
    assert seen["team"] == [mine_id], "owner 自己的线程照旧，用户的来信不在里面"


async def test_the_team_cannot_reply_or_mark_read_while_the_switch_is_off(
        client, client_without_team, store):
    letter = await feedback_ticket(client, text="来信", deviceModel="iPhone15,4")
    team_token = register_device(client_without_team, account_id=TEAM)

    reply = await client_without_team.post("/feedback/append", json={
        "threadId": letter["threadId"], "text": "开关关闭时不该写得进去"},
        headers=device_headers(team_token))
    assert reply.status == 404, "团队侧判定同样归开关管"

    before = store.feedback_thread(letter["threadId"], None)
    read = await client_without_team.post("/feedback/read", json={
        "threadIds": [letter["threadId"]]}, headers=device_headers(team_token))
    assert read.status == 200
    after = store.feedback_thread(letter["threadId"], None)
    assert after["ownerReadAt"] is None, "推不动团队侧已读"
    assert after["userReadAt"] == before["userReadAt"], "也不许顺手推用户侧已读"
    assert len(after["messages"]) == len(before["messages"]), "回信没有落库"


# ── 开关窗口自愈（P2-7）：不落库的派生谓词让开关恢复即自愈 ──────────────────


async def test_a_letter_received_while_the_switch_was_off_shows_up_when_it_comes_back(
        client, client_without_team, store):
    """开关为空期间提交 → 开关恢复 → 同一条线程出现在团队收件箱（同一库、无回填）。"""
    letter = await feedback_ticket(client_without_team, text="开关窗口里的来信",
                                   deviceModel="iPhone15,4")

    off_team = register_device(client_without_team, account_id=TEAM)
    off = await (await client_without_team.post(
        "/feedback/inbox", json={}, headers=device_headers(off_team))).json()
    assert off["threads"] == [], "开关关闭时团队看不到"

    on_team = register_device(client, account_id=TEAM)
    on = await (await client.post("/feedback/inbox", json={},
                                  headers=device_headers(on_team))).json()
    assert [t["threadId"] for t in on["threads"]] == [letter["threadId"]]
    assert on["unreadCount"] == 1
