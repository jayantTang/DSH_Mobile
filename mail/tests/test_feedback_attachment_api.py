"""四个附件路由 + 提交时绑定（v4：先传后发，按 `clientRef` 绑定）。

判据集中在五件事：草稿的两段授权（新信按设备归属、回信按线程）、字节边界、
配额（按 `draftRef` 归集、绑定时复核）、限流（拒绝路径也计数）、以及
"空信在服务端不可能出现"（空正文 + 0 草稿 → 400 且库里没有任何新行）。

草稿永远不进 v1/v2/owner CLI；只有 `submit`/`append` 绑过的行才会出现在投影里。
"""

from __future__ import annotations

import asyncio
import hashlib
import os
from urllib.parse import quote

import pytest

import attachments as files
from conftest import (TEAM_ACCOUNT, build_client, device_headers, feedback_ticket,
                      register_device)
from store import Store

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
PNG = PNG_MAGIC + b"pixels" * 100
#: 直接调 store 层造数据时用的默认配额（与 api.LIMITS 一致；HTTP 用例走服务端下发的值）。
STORE_LIMITS = {"maxPerMessage": 8, "maxFileBytes": 8 * 1024 * 1024,
                "maxTotalBytes": 24 * 1024 * 1024, "maxPerThreadBytes": 48 * 1024 * 1024,
                "storageSoftBytes": 2 * 1024 * 1024 * 1024}


def digest(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def png_bytes(size: int) -> bytes:
    """指定长度、开头仍是 PNG 魔数的字节（魔数嗅探在 upload 里是硬判据）。"""
    assert size >= len(PNG_MAGIC)
    return PNG_MAGIC + b"x" * (size - len(PNG_MAGIC))


def attachments_root(client) -> str:
    return client.app["attachments_root"]


def files_on_disk(client) -> list[str]:
    root = attachments_root(client)
    found: list[str] = []
    for directory, _dirs, names in os.walk(root):
        if os.path.basename(directory) == "tmp":
            continue
        found.extend(os.path.join(directory, name) for name in names)
    return sorted(found)


def temp_files(client) -> list[str]:
    tmp = os.path.join(attachments_root(client), "tmp")
    return sorted(os.listdir(tmp)) if os.path.isdir(tmp) else []


# ── 请求助手 ────────────────────────────────────────────────────────────────


async def submit(client, text: str = "原文", *, client_ref: str | None = None,
                 headers=None, **extra):
    body = {"text": text, **extra}
    if client_ref is not None:
        body["clientRef"] = client_ref
    return await client.post("/feedback/submit", json=body, headers=headers or {})


async def submit_ok(client, text: str = "原文", **kwargs) -> dict:
    response = await submit(client, text, **kwargs)
    assert response.status == 200, await response.text()
    return await response.json()


async def append(client, thread: dict, text: str = "补充", *,
                 client_ref: str | None = None, headers=None):
    body = {"threadId": thread["threadId"], "text": text,
            "ticketKey": thread["ticketKey"]}
    if client_ref is not None:
        body["clientRef"] = client_ref
    return await client.post("/feedback/append", json=body, headers=headers or {})


async def begin(client, *, client_ref: str, slot: int = 0, payload: bytes = PNG,
                name: str = "截屏.png", content_type: str = "image/png",
                thread: dict | None = None, headers=None, **extra):
    body = {"clientRef": client_ref, "slot": slot, "name": name,
            "contentType": content_type, "byteSize": len(payload),
            "sha256": digest(payload), **extra}
    if thread is not None:
        body["threadId"] = thread["threadId"]
        body.setdefault("ticketKey", thread["ticketKey"])
    return await client.post("/feedback/attachment/begin", json=body,
                             headers=headers or {})


async def begin_ok(client, **kwargs) -> dict:
    response = await begin(client, **kwargs)
    assert response.status == 200, await response.text()
    return await response.json()


async def upload(client, attachment_id: str, payload: bytes = PNG, *, ticket: str | None = None,
                 headers=None):
    request_headers = {"Content-Type": "application/octet-stream", **(headers or {})}
    if ticket:
        request_headers["X-Feedback-Ticket"] = ticket
    return await client.post(f"/feedback/attachment/upload?attachmentId={attachment_id}",
                             data=payload, headers=request_headers)


async def upload_ok(client, attachment_id: str, payload: bytes = PNG, **kwargs) -> dict:
    response = await upload(client, attachment_id, payload, **kwargs)
    assert response.status == 200, await response.text()
    return await response.json()


async def fetch(client, attachment_id: str, *, ticket: str | None = None, headers=None):
    body = {"attachmentId": attachment_id}
    if ticket:
        body["ticketKey"] = ticket
    return await client.post("/feedback/attachment/fetch", json=body, headers=headers or {})


async def discard(client, attachment_id: str, client_ref: str, *, ticket: str | None = None,
                  headers=None):
    body = {"attachmentId": attachment_id, "clientRef": client_ref}
    if ticket:
        body["ticketKey"] = ticket
    return await client.post("/feedback/attachment/discard", json=body, headers=headers or {})


async def stored_draft(client, token: str, *, client_ref: str, slot: int = 0,
                       payload: bytes = PNG, **extra) -> dict:
    """新信草稿的标准两步：begin → upload（都带设备令牌）。"""
    begun = await begin_ok(client, client_ref=client_ref, slot=slot, payload=payload,
                           headers=device_headers(token), **extra)
    await upload_ok(client, begun["attachmentId"], payload, headers=device_headers(token))
    return begun


async def reply_draft(client, thread: dict, *, client_ref: str, slot: int = 0,
                      payload: bytes = PNG, **extra) -> dict:
    """回信草稿：`begin` 即带 `threadId` + 取件凭据。"""
    begun = await begin_ok(client, client_ref=client_ref, slot=slot, thread=thread,
                           payload=payload, **extra)
    await upload_ok(client, begun["attachmentId"], payload, ticket=thread["ticketKey"])
    return begun


def v2_attachments(body: dict) -> list[dict]:
    return [item for thread in body["threads"] for message in thread["messages"]
            for item in message.get("attachments", [])]


# ── 通路与绑定：先传后发（§7.1-3）─────────────────────────────────────────


async def test_an_attachment_only_letter_is_submitted_without_text(client):
    """空正文 + 1 个已存草稿 = 合法的一封信（owner 2026-11-02 的裁定）。"""
    token = register_device(client)
    draft = await stored_draft(client, token, client_ref="ref-only")

    response = await submit(client, "", client_ref="ref-only",
                            headers=device_headers(token), deviceModel="iPhone15,4")
    assert response.status == 200, await response.text()
    body = await response.json()
    assert body["attachmentsBound"] == 1
    assert body["messageId"].startswith("fm_")

    inbox = await client.post("/feedback/inbox", json={"inboxVersion": 2},
                              headers=device_headers(token))
    payload = await inbox.json()
    message = payload["threads"][0]["messages"][0]
    assert message["body"] == "" and message["messageId"] == body["messageId"]
    assert [item["attachmentId"] for item in message["attachments"]] == \
        [draft["attachmentId"]]


async def test_an_empty_letter_is_refused_and_leaves_nothing_behind(client):
    """空正文 + 0 草稿 → 400，且库里没有新线程、没有新留言（"空信不可能"）。"""
    store: Store = client.app["store"]
    response = await submit(client, "", client_ref="ref-empty")
    assert response.status == 400, await response.text()
    payload = await response.json()
    assert payload["error"]["code"] == "feedback/bad-request"
    assert "text or at least one stored attachment" in payload["error"]["message"]
    assert store.list_feedback_threads(limit=10) == []

    thread = await feedback_ticket(client)
    before = store.feedback_thread(thread["threadId"], None)["messageCount"]
    refused = await append(client, thread, "", client_ref="ref-empty-reply")
    assert refused.status == 400, await refused.text()
    assert store.feedback_thread(thread["threadId"], None)["messageCount"] == before


async def test_a_reply_can_carry_attachments(client):
    """回信带附件与新信同一条路：append 的 clientRef 绑定回信草稿。"""
    token = register_device(client)
    thread = await submit_ok(client, "原文", headers=device_headers(token),
                             deviceModel="iPhone15,4")
    draft = await reply_draft(client, thread, client_ref="ref-reply")

    response = await append(client, thread, "", client_ref="ref-reply")
    assert response.status == 200, await response.text()
    body = await response.json()
    assert body["attachmentsBound"] == 1

    inbox = await client.post("/feedback/inbox", json={"inboxVersion": 2},
                              headers=device_headers(token))
    payload = await inbox.json()
    last = payload["threads"][0]["messages"][-1]
    assert last["messageId"] == body["messageId"]
    assert [item["attachmentId"] for item in last["attachments"]] == \
        [draft["attachmentId"]]


async def test_retrying_submit_does_not_bind_twice(client):
    token = register_device(client)
    draft = await stored_draft(client, token, client_ref="ref-retry")
    first = await submit_ok(client, "", client_ref="ref-retry",
                            headers=device_headers(token), deviceModel="iPhone15,4")
    assert first["attachmentsBound"] == 1

    second = await submit_ok(client, "", client_ref="ref-retry",
                             headers=device_headers(token), deviceModel="iPhone15,4")
    assert second["threadId"] == first["threadId"]
    assert second["attachmentsBound"] == 0, "重试不重复绑"
    store: Store = client.app["store"]
    assert store.attachment(draft["attachmentId"])["messageId"] == first["messageId"]


async def test_a_sent_letter_seals_its_client_ref(client):
    """提交即封口（owner 裁定 R5）：发出去之后同一 `clientRef` 不再收新草稿。

    重试 `submit` 恒 0 绑定、附件不变；`begin` 直接 409（免得留下只能等 7 天 TTL 的
    孤儿草稿）；v2 投影里也不会多出东西。
    """
    token = register_device(client)
    first = await stored_draft(client, token, client_ref="ref-sealed", slot=0)
    letter = await submit_ok(client, "", client_ref="ref-sealed",
                             headers=device_headers(token), deviceModel="iPhone15,4")
    assert letter["attachmentsBound"] == 1

    refused = await begin(client, client_ref="ref-sealed", slot=1,
                          payload=PNG_MAGIC + b"late", headers=device_headers(token))
    assert refused.status == 409, await refused.text()
    assert (await refused.json())["error"]["message"] == "this letter has already been sent"

    again = await submit_ok(client, "", client_ref="ref-sealed",
                            headers=device_headers(token), deviceModel="iPhone15,4")
    assert again["threadId"] == letter["threadId"]
    assert again["attachmentsBound"] == 0, "重试不绑"

    inbox = await client.post("/feedback/inbox", json={"inboxVersion": 2},
                              headers=device_headers(token))
    payload = await inbox.json()
    ids = [item["attachmentId"] for item in
           payload["threads"][0]["messages"][0]["attachments"]]
    assert ids == [first["attachmentId"]], "已经发出的信不会多出附件"
    store: Store = client.app["store"]
    assert store.list_attachments(limit=10)[0]["messageId"] == letter["messageId"]


async def test_a_sent_reply_seals_its_client_ref_too(client):
    token = register_device(client)
    thread = await submit_ok(client, "原文", headers=device_headers(token),
                             deviceModel="iPhone15,4")
    draft = await reply_draft(client, thread, client_ref="ref-reply-sealed")
    sent = await append(client, thread, "", client_ref="ref-reply-sealed")
    assert sent.status == 200 and (await sent.json())["attachmentsBound"] == 1

    refused = await begin(client, client_ref="ref-reply-sealed", slot=1, thread=thread,
                          payload=PNG_MAGIC + b"late")
    assert refused.status == 409, await refused.text()

    retried = await append(client, thread, "", client_ref="ref-reply-sealed")
    assert retried.status == 200 and (await retried.json())["attachmentsBound"] == 0
    store: Store = client.app["store"]
    assert store.attachment(draft["attachmentId"])["messageId"] is not None


async def test_two_devices_sharing_a_client_ref_do_not_bind_each_others_drafts(client):
    """`clientRef` 不是凭据：别人的草稿绑不进来（§7.1-3 最后一条）。"""
    mine = register_device(client, account_id="acc_a")
    other = register_device(client, account_id="acc_b")
    draft = await stored_draft(client, mine, client_ref="ref-shared")

    stolen = await submit(client, "", client_ref="ref-shared",
                          headers=device_headers(other), deviceModel="iPhone15,4")
    assert stolen.status == 400, "绑不到任何草稿 → 仍是一封空信"
    store: Store = client.app["store"]
    assert store.attachment(draft["attachmentId"])["messageId"] is None

    mine_letter = await submit_ok(client, "", client_ref="ref-shared",
                                  headers=device_headers(mine), deviceModel="iPhone15,4")
    assert mine_letter["attachmentsBound"] == 1


async def test_binding_rechecks_the_per_message_cap(tmp_path, aiohttp_client):
    """绑定时按 `messageId` 复核配额（M6-A）：超了 413 且整笔不落库。"""
    store = Store(str(tmp_path / "mail.db"))
    client = await build_client(aiohttp_client, store, attachment_limits={
        "maxPerMessage": 8, "maxTotalBytes": 1024})
    try:
        token = register_device(client)
        for slot in range(3):
            await stored_draft(client, token, client_ref="ref-cap", slot=slot,
                               payload=png_bytes(8))
        client.app["attachment_limits"]["maxPerMessage"] = 2   # 收窄后再提交
        refused = await submit(client, "", client_ref="ref-cap",
                               headers=device_headers(token), deviceModel="iPhone15,4")
        assert refused.status == 413, await refused.text()
        assert store.list_feedback_threads(limit=10) == []
        assert all(row["messageId"] is None for row in store.list_attachments(limit=10))
    finally:
        store.close()


async def test_two_threads_sharing_a_client_ref_do_not_cross_bind(client):
    """跨线程同 `clientRef` 只回 409，不复用别的线程的 messageId（F-V4-1）。

    复现验证方的场景：甲在线程 A、乙在线程 B 用同一个 `clientRef` 回信。乙的那次必须
    被拒、B 里不多出留言、A 原样不动，乙的草稿也仍是未绑定（无残留）。
    """
    owner_a = register_device(client, account_id="acc_a")
    owner_b = register_device(client, account_id="acc_b")
    thread_a = await submit_ok(client, "甲的信", client_ref="ref-letter-a",
                               headers=device_headers(owner_a), deviceModel="iPhone15,4")
    thread_b = await submit_ok(client, "乙的信", client_ref="ref-letter-b",
                               headers=device_headers(owner_b), deviceModel="iPhone15,4")

    # 乙先按自己的线程准备一张回信草稿（同一个 clientRef），但先不提交。
    draft = await reply_draft(client, thread_b, client_ref="ref-shared",
                              name="乙的图.png")

    reply_a = await append(client, thread_a, "甲的回信", client_ref="ref-shared")
    assert reply_a.status == 200, await reply_a.text()

    clash = await append(client, thread_b, "乙的回信", client_ref="ref-shared")
    assert clash.status == 409, await clash.text()
    assert (await clash.json())["error"]["code"] == "feedback/attachment-conflict"

    store: Store = client.app["store"]
    payload_b = store.feedback_thread(thread_b["threadId"], None, messages_per_thread=10)
    assert [message["body"] for message in payload_b["messages"]] == ["乙的信"], \
        "乙的回信没有被写进任何线程"
    payload_a = store.feedback_thread(thread_a["threadId"], None, messages_per_thread=10)
    assert [message["body"] for message in payload_a["messages"]] == ["甲的信", "甲的回信"]
    assert store.attachment(draft["attachmentId"])["messageId"] is None, "乙的草稿仍是草稿"
    assert store.attachment(draft["attachmentId"])["threadId"] == thread_b["threadId"]
    assert len(store.list_attachments(limit=10)) == 1


async def test_begin_does_not_leak_another_letters_slot(client):
    """别人的 `(clientRef, slot)` 不能被回显成我的附件（F-V4-3）。"""
    mine = register_device(client, account_id="acc_a")
    other = register_device(client, account_id="acc_b")
    first = await begin_ok(client, client_ref="ref-slot-owner", headers=device_headers(mine))

    stolen = await begin(client, client_ref="ref-slot-owner", slot=0,
                         payload=PNG + b"x", headers=device_headers(other))
    assert stolen.status == 409, await stolen.text()
    body = await stolen.json()
    assert "attachmentId" not in body and "sha256" not in body, "不回显对方的元数据"
    same_again = await begin(client, client_ref="ref-slot-owner", slot=0,
                             headers=device_headers(mine))
    assert same_again.status == 200
    assert (await same_again.json())["attachmentId"] == first["attachmentId"]


async def test_discard_hides_whether_a_letter_was_sent_from_strangers(client):
    """未授权的 `discard` 一律 404：不能靠 409 分出"已发出 vs 仍是草稿"（F-V4-2）。"""
    token = register_device(client, account_id="acc_a")
    stranger = register_device(client, account_id="acc_b")
    draft = await stored_draft(client, token, client_ref="ref-discard-auth")

    assert (await discard(client, draft["attachmentId"], "ref-discard-auth")).status == 404
    assert (await discard(client, draft["attachmentId"], "ref-discard-auth",
                          headers=device_headers(stranger))).status == 404

    await submit_ok(client, "", client_ref="ref-discard-auth",
                    headers=device_headers(token), deviceModel="iPhone15,4")
    assert (await discard(client, draft["attachmentId"], "ref-discard-auth")).status == 404
    assert (await discard(client, draft["attachmentId"], "ref-discard-auth",
                          headers=device_headers(stranger))).status == 404
    assert (await discard(client, draft["attachmentId"], "ref-discard-auth",
                          headers=device_headers(token))).status == 409


# ── 草稿的两段授权（§7.1-1、-13）─────────────────────────────────────────


async def test_a_new_letter_draft_needs_a_device_token(client):
    refused = await begin(client, client_ref="ref-anon")
    assert refused.status == 400, await refused.text()
    assert (await refused.json())["error"]["code"] == "feedback/bad-request"
    assert client.app["store"].list_attachments(limit=10) == []


async def test_a_new_letter_draft_is_readable_only_by_its_origin(client):
    mine = register_device(client, account_id="acc_a")
    same_account = register_device(client, account_id="acc_a")
    stranger = register_device(client, account_id="acc_b")
    draft = await stored_draft(client, mine, client_ref="ref-private")
    attachment_id = draft["attachmentId"]

    assert (await fetch(client, attachment_id)).status == 404, "匿名取不到草稿"
    assert (await fetch(client, attachment_id,
                        headers=device_headers(stranger))).status == 404
    assert (await upload(client, attachment_id,
                         headers=device_headers(stranger))).status == 404
    assert (await discard(client, attachment_id, "ref-private",
                          headers=device_headers(stranger))).status == 404

    assert (await fetch(client, attachment_id,
                        headers=device_headers(same_account))).status == 200, \
        "同账号的另一台设备可以继续这封信"
    assert (await fetch(client, attachment_id,
                        headers=device_headers(mine))).status == 200


async def test_a_reply_draft_uses_the_thread_credentials(client):
    token = register_device(client)
    thread = await submit_ok(client, "原文", headers=device_headers(token),
                             deviceModel="iPhone15,4")
    draft = await reply_draft(client, thread, client_ref="ref-reply-auth")

    wrong = await client.post("/feedback/attachment/fetch", json={
        "attachmentId": draft["attachmentId"], "ticketKey": "fk_" + "A" * 43})
    assert wrong.status == 404
    good = await fetch(client, draft["attachmentId"], ticket=thread["ticketKey"])
    assert good.status == 200
    by_device = await fetch(client, draft["attachmentId"], headers=device_headers(token))
    assert by_device.status == 200, "设备绑定也能证明这条线程"


async def test_a_reply_draft_cannot_be_bound_to_another_thread(client):
    token = register_device(client)
    first = await submit_ok(client, "一", headers=device_headers(token),
                            deviceModel="iPhone15,4")
    second = await submit_ok(client, "二", headers=device_headers(token),
                             deviceModel="iPhone15,4")
    draft = await reply_draft(client, first, client_ref="ref-cross")

    refused = await append(client, second, "", client_ref="ref-cross")
    assert refused.status == 400, "草稿属于另一条线程 → 绑不到 → 空信"
    store: Store = client.app["store"]
    assert store.attachment(draft["attachmentId"])["messageId"] is None


async def test_begin_refuses_the_old_message_id_order(client):
    token = register_device(client)
    thread = await submit_ok(client, "原文", headers=device_headers(token))
    response = await begin(client, client_ref="ref-old", messageId=thread["messageId"],
                           headers=device_headers(token))
    assert response.status == 400, await response.text()
    assert "messageId" in (await response.json())["error"]["message"]


async def test_begin_needs_a_client_ref_and_a_sane_slot(client):
    token = register_device(client)
    headers = device_headers(token)
    missing_ref = await client.post("/feedback/attachment/begin", json={
        "slot": 0, "name": "图.png", "contentType": "image/png",
        "byteSize": len(PNG), "sha256": digest(PNG)}, headers=headers)
    assert missing_ref.status == 400
    bad_slot = await begin(client, client_ref="ref-x", slot="0", headers=headers)
    assert bad_slot.status == 400
    too_far = await begin(client, client_ref="ref-x", slot=8, headers=headers)
    assert too_far.status == 413
    assert (await too_far.json())["error"]["code"] == "feedback/too-large"


async def test_begin_is_idempotent_per_slot_and_conflicts_on_a_different_file(client):
    token = register_device(client)
    headers = device_headers(token)
    first = await begin_ok(client, client_ref="ref-slot", slot=0, headers=headers)
    again = await begin_ok(client, client_ref="ref-slot", slot=0, headers=headers)
    assert again["attachmentId"] == first["attachmentId"]

    conflict = await begin(client, client_ref="ref-slot", slot=0, payload=PNG + b"x",
                           headers=headers)
    assert conflict.status == 409, await conflict.text()
    assert (await conflict.json())["error"]["code"] == "feedback/attachment-conflict"


# ── 字节与取回 ──────────────────────────────────────────────────────────────


async def test_a_letter_can_carry_a_picture_round_trip(client):
    token = register_device(client)
    draft = await stored_draft(client, token, client_ref="ref-round",
                               name="截屏 2026-11-02.png")
    letter = await submit_ok(client, "", client_ref="ref-round",
                             headers=device_headers(token), deviceModel="iPhone15,4")

    response = await fetch(client, draft["attachmentId"], ticket=letter["ticketKey"])
    assert response.status == 200, await response.text()
    assert await response.read() == PNG
    assert response.headers["Content-Type"] == "image/png"
    assert response.headers["Content-Length"] == str(len(PNG))
    assert response.headers["X-Content-Type-Options"] == "nosniff"
    assert response.headers["Cache-Control"] == "private, max-age=0, no-transform"
    assert response.headers["Content-Disposition"] == \
        f"attachment; filename*=UTF-8''{quote('截屏 2026-11-02.png')}"


async def test_v2_reports_only_bound_attachments_and_v1_reports_none(client):
    token = register_device(client)
    draft = await stored_draft(client, token, client_ref="ref-v2", name="一.png")
    await stored_draft(client, token, client_ref="ref-other", payload=PNG_MAGIC + b"other")
    await submit_ok(client, "", client_ref="ref-v2", headers=device_headers(token),
                    deviceModel="iPhone15,4")

    v2 = await (await client.post("/feedback/inbox", json={"inboxVersion": 2},
                                  headers=device_headers(token))).json()
    assert [(item["attachmentId"], item["name"]) for item in v2_attachments(v2)] == \
        [(draft["attachmentId"], "一.png")]
    assert set(v2["threads"][0]["messages"][0]["attachments"][0]) == {
        "attachmentId", "name", "contentType", "byteSize", "sha256", "width",
        "height", "createdAt", "compressed"}
    assert v2["limits"]["attachments"] == {
        "maxPerMessage": 8, "maxFileBytes": 8 * 1024 * 1024,
        "maxTotalBytes": 24 * 1024 * 1024,
        "types": ["jpeg", "png", "heic", "pdf", "txt", "log", "csv", "json"],
        "roles": ["original", "preview"]}

    v1 = await (await client.post("/feedback/inbox", json={},
                                  headers=device_headers(token))).json()
    assert all("attachments" not in message for thread in v1["threads"]
               for message in thread["messages"]), "v1 投影一个字段都不加"


async def test_drafts_are_invisible_until_they_are_submitted(client):
    token = register_device(client)
    draft = await stored_draft(client, token, client_ref="ref-hidden")
    body = await (await client.post("/feedback/inbox", json={"inboxVersion": 2},
                                    headers=device_headers(token))).json()
    assert body["threads"] == [] and v2_attachments(body) == []
    store: Store = client.app["store"]
    assert store.attachment(draft["attachmentId"])["messageId"] is None


# ── 字节边界 ────────────────────────────────────────────────────────────────


async def test_upload_without_a_content_length_is_refused_and_writes_nothing(client):
    token = register_device(client)
    begun = await begin_ok(client, client_ref="ref-cl", headers=device_headers(token))

    async def chunks():
        yield PNG

    response = await client.post(
        f"/feedback/attachment/upload?attachmentId={begun['attachmentId']}",
        data=chunks(), headers={"Content-Type": "application/octet-stream",
                                **device_headers(token)})
    assert response.status == 413, await response.text()
    assert (await response.json())["error"]["code"] == "feedback/too-large"
    assert files_on_disk(client) == [] and temp_files(client) == []
    assert client.app["store"].attachment(begun["attachmentId"])["state"] == "pending"


@pytest.mark.parametrize("underrun", [True, False])
async def test_a_content_length_that_does_not_match_the_declaration_is_refused(
        client, underrun):
    token = register_device(client)
    begun = await begin_ok(client, client_ref="ref-cl2", headers=device_headers(token))
    body = PNG[:-1] if underrun else PNG + b"x"
    response = await upload(client, begun["attachmentId"], body,
                            headers=device_headers(token))
    assert response.status == 413, await response.text()
    assert files_on_disk(client) == [] and temp_files(client) == []


async def test_bytes_that_do_not_match_the_digest_leave_no_file_behind(client):
    token = register_device(client)
    begun = await begin_ok(client, client_ref="ref-digest", headers=device_headers(token))
    response = await upload(client, begun["attachmentId"], PNG[:-1] + b"!",
                            headers=device_headers(token))
    assert response.status == 400, await response.text()
    assert files_on_disk(client) == [] and temp_files(client) == []
    assert client.app["store"].attachment(begun["attachmentId"])["state"] == "pending"


async def test_a_file_over_the_per_file_cap_is_refused_before_any_row_exists(
        tmp_path, aiohttp_client):
    store = Store(str(tmp_path / "mail.db"))
    client = await build_client(aiohttp_client, store, attachment_limits={"maxFileBytes": 8})
    try:
        token = register_device(client)
        response = await begin(client, client_ref="ref-big", headers=device_headers(token))
        assert response.status == 413, await response.text()
        assert store.list_attachments(limit=10) == []
    finally:
        store.close()


@pytest.mark.parametrize("content_type,body", [
    ("image/png", b"\xff\xd8\xff\xe0 not really a png"),
    ("image/jpeg", PNG),
    ("application/pdf", PNG),
    ("image/heic", b"\x00\x00\x00\x18ftypmif2 nope"),
    ("text/plain", b"log line\x00with a nul byte"),
])
async def test_upload_refuses_bytes_that_do_not_match_the_declared_type(
        client, content_type, body):
    token = register_device(client)
    begun = await begin_ok(client, client_ref="ref-type", payload=body,
                           content_type=content_type, headers=device_headers(token))
    response = await upload(client, begun["attachmentId"], body,
                            headers=device_headers(token))
    assert response.status == 415, await response.text()
    assert (await response.json())["error"]["code"] == "feedback/attachment-type"
    assert files_on_disk(client) == [] and temp_files(client) == []


@pytest.mark.parametrize("content_type,body", [
    ("text/plain", "会话一直转圈\n日志在下面\n".encode()),
    ("text/csv", "a,b\n1,2\n".encode()),
    ("application/json", b'{"ok": true}'),
    ("application/pdf", b"%PDF-1.7\n\xe2\xe3\xcf\xd3\n"),
    ("image/heic", b"\x00\x00\x00\x18ftypheic\x00\x00\x00\x00"),
])
async def test_upload_accepts_the_whitelisted_types(client, content_type, body):
    token = register_device(client)
    begun = await begin_ok(client, client_ref="ref-ok-type", payload=body,
                           content_type=content_type, headers=device_headers(token))
    await upload_ok(client, begun["attachmentId"], body, headers=device_headers(token))
    fetched = await fetch(client, begun["attachmentId"], headers=device_headers(token))
    assert fetched.status == 200 and await fetched.read() == body


@pytest.mark.parametrize("content_type", ["video/mp4", "image/svg+xml", "text/html",
                                          "application/zip"])
async def test_begin_refuses_a_type_outside_the_whitelist(client, content_type):
    token = register_device(client)
    response = await begin(client, client_ref="ref-bad-type", content_type=content_type,
                           headers=device_headers(token))
    assert response.status == 415, await response.text()
    assert (await response.json())["error"]["code"] == "feedback/attachment-type"
    assert client.app["store"].list_attachments(limit=10) == []


async def test_a_retried_upload_is_idempotent_and_a_different_length_is_a_conflict(client):
    token = register_device(client)
    begun = await begin_ok(client, client_ref="ref-retry-up", headers=device_headers(token))
    first = await upload_ok(client, begun["attachmentId"], headers=device_headers(token))
    assert first["state"] == "stored"

    again = await upload(client, begun["attachmentId"], headers=device_headers(token))
    assert again.status == 200 and (await again.json())["state"] == "stored"

    conflict = await upload(client, begun["attachmentId"], PNG + b"x",
                            headers=device_headers(token))
    assert conflict.status == 409, await conflict.text()
    assert (await conflict.json())["error"]["code"] == "feedback/attachment-conflict"
    assert len(files_on_disk(client)) == 1, "冲突不许再落一份字节"


async def test_a_same_length_retry_with_different_bytes_is_a_conflict(client):
    token = register_device(client)
    begun = await begin_ok(client, client_ref="ref-sha", headers=device_headers(token))
    await upload_ok(client, begun["attachmentId"], headers=device_headers(token))
    store: Store = client.app["store"]
    before = store.attachment(begun["attachmentId"])

    response = await upload(client, begun["attachmentId"], PNG[:-1] + b"!",
                            headers=device_headers(token))
    assert response.status == 409, await response.text()
    after = store.attachment(begun["attachmentId"])
    assert after["sha256"] == before["sha256"] and after["storedPath"] == before["storedPath"]
    fetched = await fetch(client, begun["attachmentId"], headers=device_headers(token))
    assert await fetched.read() == PNG
    assert len(files_on_disk(client)) == 1 and temp_files(client) == []


async def test_a_truncated_stored_file_is_rebuilt_by_a_retry(client):
    token = register_device(client)
    begun = await begin_ok(client, client_ref="ref-heal", headers=device_headers(token))
    await upload_ok(client, begun["attachmentId"], headers=device_headers(token))
    for path in files_on_disk(client):
        open(path, "wb").close()
    assert [os.path.getsize(path) for path in files_on_disk(client)] == [0]

    response = await upload(client, begun["attachmentId"], headers=device_headers(token))
    assert response.status == 200, await response.text()
    assert [os.path.getsize(path) for path in files_on_disk(client)] == [len(PNG)]
    fetched = await fetch(client, begun["attachmentId"], headers=device_headers(token))
    assert await fetched.read() == PNG


async def test_fetch_answers_404_when_the_stored_bytes_are_truncated(client):
    token = register_device(client)
    begun = await begin_ok(client, client_ref="ref-trunc", headers=device_headers(token))
    await upload_ok(client, begun["attachmentId"], headers=device_headers(token))
    for path in files_on_disk(client):
        open(path, "wb").close()
    response = await asyncio.wait_for(
        fetch(client, begun["attachmentId"], headers=device_headers(token)), timeout=5.0)
    assert response.status == 404, await response.text()


async def test_fetch_answers_404_when_the_stored_path_is_corrupt(client):
    token = register_device(client)
    begun = await begin_ok(client, client_ref="ref-corrupt", headers=device_headers(token))
    await upload_ok(client, begun["attachmentId"], headers=device_headers(token))
    store: Store = client.app["store"]
    store._conn.execute("UPDATE feedbackAttachments SET storedPath='../../../etc/passwd'"
                        " WHERE attachmentId=?", (begun["attachmentId"],))
    store._conn.commit()

    response = await fetch(client, begun["attachmentId"], headers=device_headers(token))
    assert response.status == 404, await response.text()
    assert (await response.json())["error"]["code"] == "feedback/not-found"


async def test_an_upload_whose_row_was_swept_away_answers_404_and_leaves_no_bytes(
        client, monkeypatch):
    token = register_device(client)
    begun = await begin_ok(client, client_ref="ref-swept", headers=device_headers(token))
    monkeypatch.setattr(client.app["store"], "mark_attachment_stored",
                        lambda *_args, **_kwargs: False)
    response = await upload(client, begun["attachmentId"], headers=device_headers(token))
    assert response.status == 404, await response.text()
    assert files_on_disk(client) == []


async def test_upload_and_fetch_answer_404_for_an_attachment_that_does_not_exist(client):
    token = register_device(client)
    assert (await upload(client, "fa_" + "0" * 18,
                         headers=device_headers(token))).status == 404
    assert (await fetch(client, "fa_" + "0" * 18,
                        headers=device_headers(token))).status == 404
    missing = await fetch(client, "fa_" + "0" * 18)
    wrong = await fetch(client, "fa_" + "0" * 18, ticket="fk_" + "A" * 43)
    assert await missing.read() == await wrong.read(), "不泄露附件是否存在"
    thread_404 = await client.post("/feedback/append", json={
        "threadId": "th_nope", "ticketKey": "fk_" + "A" * 43, "text": "补充"})
    assert await thread_404.read() == await missing.read(), "与线程那条 404 逐字节相同"


# ── 配额与限流 ──────────────────────────────────────────────────────────────


async def test_the_per_letter_slot_and_byte_caps_are_enforced(tmp_path, aiohttp_client):
    """`slot < maxPerMessage` 与单封合计（24 MiB 的口径）各判一次（§7.1-5）。"""
    store = Store(str(tmp_path / "mail.db"))
    client = await build_client(aiohttp_client, store, attachment_limits={
        "maxPerMessage": 3, "maxTotalBytes": 25, "maxFileBytes": 40})
    try:
        token = register_device(client)
        for slot in range(3):                 # 3 × 8 = 24 ≤ 25：先把 slot 与合计各推到边上
            await begin_ok(client, client_ref="ref-cap", slot=slot, payload=png_bytes(8),
                           headers=device_headers(token))
        too_far = await begin(client, client_ref="ref-cap", slot=3, payload=png_bytes(10),
                              headers=device_headers(token))
        assert too_far.status == 413, await too_far.text()

        over_bytes = await begin(client, client_ref="ref-cap2", slot=0, payload=png_bytes(30),
                                 headers=device_headers(token))
        assert over_bytes.status == 413, await over_bytes.text()
        assert (await over_bytes.json())["error"]["code"] == "feedback/too-large"
    finally:
        store.close()


async def test_the_library_soft_cap_is_a_507(tmp_path, aiohttp_client):
    store = Store(str(tmp_path / "mail.db"))
    client = await build_client(aiohttp_client, store,
                                attachment_limits={"storageSoftBytes": 8})
    try:
        token = register_device(client)
        response = await begin(client, client_ref="ref-full", headers=device_headers(token))
        assert response.status == 507, await response.text()
        assert (await response.json())["error"]["code"] == "feedback/storage-full"
    finally:
        store.close()


async def test_the_upload_byte_budget_stops_a_caller_before_the_count_bucket(
        tmp_path, aiohttp_client):
    store = Store(str(tmp_path / "mail.db"))
    client = await build_client(aiohttp_client, store, attachment_limits={
        "uploadBytesPerIp": 12, "uploadBytesPerDevice": 10 ** 6})
    try:
        token = register_device(client)
        first = await begin_ok(client, client_ref="ref-byte", payload=png_bytes(8),
                               headers=device_headers(token))
        await upload_ok(client, first["attachmentId"], png_bytes(8),
                        headers=device_headers(token))
        second = await begin_ok(client, client_ref="ref-byte", slot=1, payload=png_bytes(8),
                                headers=device_headers(token))
        response = await upload(client, second["attachmentId"], png_bytes(8),
                                headers=device_headers(token))
        assert response.status == 429, await response.text()
        assert (await response.json())["error"]["code"] == "feedback/rate-limited"
    finally:
        store.close()


async def test_a_fake_attachment_id_is_charged_like_append(client):
    """伪造的 attachmentId 也计入写入桶（R1）：先 404 后 429，与 append 同一个桶。"""
    fake = "fa_" + "0" * 18
    for _index in range(30):                 # 写入桶 30 次 / 10 min（api._WRITE_LIMIT）
        response = await upload(client, fake)
        assert response.status == 404, await response.text()
    over = await upload(client, fake)
    assert over.status == 429, "预算用尽后先回 429，不能一直 404 下去"
    append_429 = await client.post("/feedback/append", json={
        "threadId": "th_nope", "text": "补充"})
    assert append_429.status == 429, "上传与 append 共用同一个写入桶"


async def test_begin_still_counts_against_the_write_budget(tmp_path, aiohttp_client):
    store = Store(str(tmp_path / "mail.db"))
    client = await build_client(aiohttp_client, store, attachment_limits={"maxPerMessage": 64})
    try:
        token = register_device(client)
        headers = device_headers(token)
        for slot in range(30):              # begin 就是写请求：一次一条信用掉一档
            await begin_ok(client, client_ref="ref-budget", slot=slot,
                           payload=png_bytes(slot + 8), headers=headers)
        refused = await begin(client, client_ref="ref-budget", slot=31,
                              payload=png_bytes(64), headers=headers)
        assert refused.status == 429, await refused.text()
    finally:
        store.close()


# ── discard 与草稿回收（§7.1-8、-11）──────────────────────────────────────


async def test_discard_removes_the_draft_row_and_bytes(client):
    token = register_device(client)
    draft = await stored_draft(client, token, client_ref="ref-drop")
    assert len(files_on_disk(client)) == 1

    response = await discard(client, draft["attachmentId"], "ref-drop",
                             headers=device_headers(token))
    assert response.status == 200, await response.text()
    assert (await response.json())["deleted"] is True
    store: Store = client.app["store"]
    assert store.attachment(draft["attachmentId"]) is None
    assert files_on_disk(client) == []


async def test_discard_refuses_a_bound_attachment(client):
    token = register_device(client)
    draft = await stored_draft(client, token, client_ref="ref-bound")
    await submit_ok(client, "", client_ref="ref-bound", headers=device_headers(token),
                    deviceModel="iPhone15,4")

    response = await discard(client, draft["attachmentId"], "ref-bound",
                             headers=device_headers(token))
    assert response.status == 409, await response.text()
    assert (await response.json())["error"]["code"] == "feedback/attachment-conflict"
    assert len(files_on_disk(client)) == 1, "已发出的信不许客户端删附件"


async def test_discard_answers_404_for_a_wrong_client_ref(client):
    token = register_device(client)
    draft = await stored_draft(client, token, client_ref="ref-wrong")
    response = await discard(client, draft["attachmentId"], "ref-other",
                             headers=device_headers(token))
    assert response.status == 404
    assert client.app["store"].attachment(draft["attachmentId"]) is not None


async def test_discard_frees_the_draft_quota(tmp_path, aiohttp_client):
    """草稿的字节额度是真额度：discard 之后同一个 slot 才能重新登记（§7.1-11）。"""
    store = Store(str(tmp_path / "mail.db"))
    client = await build_client(aiohttp_client, store,
                                attachment_limits={"maxTotalBytes": 25})
    try:
        token = register_device(client)
        headers = device_headers(token)
        first = await begin_ok(client, client_ref="ref-quota", slot=0, payload=png_bytes(10),
                               headers=headers)
        await begin_ok(client, client_ref="ref-quota", slot=1, payload=png_bytes(10),
                       headers=headers)
        blocked = await begin(client, client_ref="ref-quota", slot=2, payload=png_bytes(10),
                              headers=headers)
        assert blocked.status == 413, "20 + 10 > 25"
        await discard(client, first["attachmentId"], "ref-quota", headers=headers)
        again = await begin_ok(client, client_ref="ref-quota", slot=2, payload=png_bytes(10),
                               headers=headers)
        assert again["state"] == "pending"
    finally:
        store.close()


async def test_drafts_expire_after_seven_days_and_free_the_quota(tmp_path, aiohttp_client):
    import mail as mail_module
    store = Store(str(tmp_path / "mail.db"))
    client = await build_client(aiohttp_client, store, attachment_limits={
        "maxPerMessage": 1})
    try:
        token = register_device(client)
        headers = device_headers(token)
        stale = await begin_ok(client, client_ref="ref-stale", slot=0, headers=headers)
        await upload_ok(client, stale["attachmentId"], headers=headers)
        store._conn.execute("UPDATE feedbackAttachments SET createdAt=? WHERE attachmentId=?",
                            (1_000, stale["attachmentId"]))
        store._conn.commit()

        swept = await mail_module.sweep_attachments_once(
            store, client.app["attachments_root"], now=8 * 24 * 3600 * 1000)
        assert swept["drafts"] == 1
        assert store.attachment(stale["attachmentId"]) is None
        assert files_on_disk(client) == []
        assert (await begin_ok(client, client_ref="ref-stale", slot=0,
                               headers=headers))["state"] == "pending"
    finally:
        store.close()


# ── 回滚开关（MAIL_ATTACHMENT_MAX_PER_MESSAGE=0）──────────────────────────


async def test_the_rollback_switch_closes_the_routes_but_keeps_sent_bytes(
        tmp_path, aiohttp_client):
    """`maxPerMessage = 0`：入口消失、三条路由 404，但历史附件仍可取（不删行不删字节）。"""
    store = Store(str(tmp_path / "mail.db"))
    on = await build_client(aiohttp_client, store)
    token = register_device(on)
    draft = await stored_draft(on, token, client_ref="ref-switch")
    letter = await submit_ok(on, "", client_ref="ref-switch",
                             headers=device_headers(token), deviceModel="iPhone15,4")
    assert letter["attachmentsBound"] == 1
    assert len(files_on_disk(on)) == 1

    off = await build_client(aiohttp_client, store,
                             attachment_limits={"maxPerMessage": 0})

    # ① v2 不再下发 limits.attachments（客户端因此关闭入口）。
    reader = register_device(off)
    payload = await (await off.post("/feedback/inbox", json={"inboxVersion": 2},
                                    headers=device_headers(reader))).json()
    assert "attachments" not in payload["limits"]
    assert payload["limits"]["textChars"] == 4000, "其余上限照常下发"

    # ② begin / upload / discard 一律 404，与"附件不存在"逐字节相同。
    missing = await fetch(off, "fa_" + "0" * 18)
    begin_off = await begin(off, client_ref="ref-new", headers=device_headers(reader))
    assert begin_off.status == 404
    assert await begin_off.read() == await missing.read()
    upload_off = await upload(off, draft["attachmentId"], ticket=letter["ticketKey"])
    assert upload_off.status == 404
    discard_off = await discard(off, draft["attachmentId"], "ref-switch",
                               ticket=letter["ticketKey"])
    assert discard_off.status == 404

    # ③ 已绑定的历史附件仍可取回同样的字节。
    fetched = await fetch(off, draft["attachmentId"], ticket=letter["ticketKey"])
    assert fetched.status == 200, await fetched.text()
    assert await fetched.read() == PNG

    # 不删行、不删字节。
    assert store.attachment(draft["attachmentId"])["state"] == "stored"
    assert len(files_on_disk(off)) == 1

    # ④ 恢复非 0：行为回到今天。
    back_on = await build_client(aiohttp_client, store)
    reader_on = register_device(back_on)
    revived = await begin_ok(back_on, client_ref="ref-revived",
                             headers=device_headers(reader_on))
    assert revived["state"] == "pending"
    payload = await (await back_on.post("/feedback/inbox", json={"inboxVersion": 2},
                                        headers=device_headers(reader_on))).json()
    assert payload["limits"]["attachments"]["maxPerMessage"] == 8


# ── 装配与并发 ──────────────────────────────────────────────────────────────


def mail_module_app(store, *, base_path: str = "", **options):
    import mail as mail_module

    async def resolve(_token):
        return None

    async def notify(_account_id, _keys=None):
        return None

    return mail_module.create_app(store=store, resolve_device=resolve,
                                  notify_account_state=notify,
                                  base_path=base_path, **options)


async def test_the_attachment_routes_are_registered_under_the_prefix(tmp_path, aiohttp_client):
    store = Store(str(tmp_path / "mail.db"))
    app = mail_module_app(store, base_path="/dsh-link")
    client = await aiohttp_client(app)
    try:
        response = await client.post(
            "/dsh-link/feedback/attachment/begin",
            json={"clientRef": "ref-prefix", "slot": 0, "name": "图.png",
                  "contentType": "image/png", "byteSize": len(PNG),
                  "sha256": digest(PNG)})
        assert response.status == 400, "无设备令牌 → 400（路由通了，不是 404）"
        assert (await response.json())["error"]["message"].startswith(
            "a draft attachment needs a device token")
    finally:
        store.close()


async def test_two_uploads_do_not_stall_the_inbox(client):
    """磁盘写走 to_thread：并发上传时收件箱仍然在 2 秒内回答（宽松阈值）。"""
    token = register_device(client)
    await submit_ok(client, "原文", headers=device_headers(token))
    big = PNG_MAGIC + b"z" * (256 * 1024)
    first = await begin_ok(client, client_ref="ref-loop", slot=0, payload=big,
                           headers=device_headers(token))
    second = await begin_ok(client, client_ref="ref-loop", slot=1, payload=big,
                            headers=device_headers(token))
    uploads = asyncio.gather(upload(client, first["attachmentId"], big,
                                    headers=device_headers(token)),
                             upload(client, second["attachmentId"], big,
                                    headers=device_headers(token)))
    inbox = await asyncio.wait_for(
        client.post("/feedback/inbox", json={"inboxVersion": 2},
                    headers=device_headers(token)), timeout=2.0)
    assert inbox.status == 200
    assert [response.status for response in await uploads] == [200, 200]


# ── 通知附件（§7.1-14）─────────────────────────────────────────────────────


async def test_a_notice_attachment_is_readable_only_by_its_recipient(client, store):
    token = register_device(client, name="DSH-Notice-Attach")
    account_id = client.app["test_devices"][token]["accountId"]
    notice = store.create_notice("通知正文", "服务通知", [account_id], at=1_000)
    row = store.begin_attachment(notice_id=notice["noticeId"], client_ref="notice-ref",
                                 file_name="公告.png", content_type="image/png",
                                 byte_size=len(PNG), sha256=digest(PNG), limits=STORE_LIMITS)
    stored_at = 5_000
    relative = files.stored_path(stored_at, row["attachmentId"])
    final = files.final_path(attachments_root(client), stored_at, row["attachmentId"])
    os.makedirs(os.path.dirname(final), exist_ok=True)
    with open(final, "wb") as handle:
        handle.write(PNG)
    store.mark_attachment_stored(row["attachmentId"], relative, stored_at)

    mine = await fetch(client, row["attachmentId"], headers=device_headers(token))
    assert mine.status == 200 and await mine.read() == PNG
    assert (await fetch(client, row["attachmentId"])).status == 404
    stranger = await fetch(client, row["attachmentId"],
                           headers=device_headers(register_device(client, account_id="acc_x")))
    assert stranger.status == 404
