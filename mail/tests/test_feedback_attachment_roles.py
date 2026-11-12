"""信件附件的角色（原图 / 预览）：迁移、幂等、计数、投影、回滚开关。

对应设计 `maintainers/design/image-fixes-20261112/design.md` §4.1 / §5 A1（服务端部分），
用例编号 `IMG-SRV-01` … `IMG-SRV-10`（见 `test-plan.md` §5）。

要钉住的事实：

- `role` 是服务端附件行上的事实（`original` / `preview`），幂等键是
  `(draftRef, slot, role)`；每封的条数按**逻辑附件**（distinct slot）计。
- wire 上按 slot 投影成**一个**对象：原图为主、`preview` 为子对象；
  只有预览时主对象就是预览并带 `compressed: true`。
- 回滚开关关掉角色时，投影仍按 slot 分组（已存在的配对信件不重复显示）。
"""

from __future__ import annotations

import hashlib
import sqlite3

import api
from conftest import ACCOUNT_ID, build_client, device_headers, register_device

MiB = 1024 * 1024
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"

#: 迁移前（2026-11-02 那一版）的表形状：**没有** `role`，唯一键是 `(draftRef, slot)`。
#: 迁移用例拿它建"旧库"，不借道当前 Store（否则测的是新建库而不是迁移）。
OLD_SCHEMA = """
CREATE TABLE IF NOT EXISTS feedbackThreads (
  threadId    TEXT PRIMARY KEY,
  ticketHash  TEXT NOT NULL,
  accountId   TEXT,
  deviceId    TEXT,
  appVersion  TEXT,
  deviceModel TEXT,
  systemVersion TEXT,
  createdAt   INTEGER NOT NULL,
  lastMessageAt INTEGER NOT NULL,
  status      TEXT NOT NULL DEFAULT 'open',
  ownerReadAt INTEGER,
  userReadAt  INTEGER,
  clientRef   TEXT,
  subject     TEXT
);
CREATE TABLE IF NOT EXISTS feedbackMessages (
  messageId  TEXT PRIMARY KEY,
  threadId   TEXT NOT NULL,
  author     TEXT NOT NULL,
  body       TEXT NOT NULL,
  format     TEXT NOT NULL DEFAULT 'text',
  createdAt  INTEGER NOT NULL,
  clientRef  TEXT
);
CREATE TABLE IF NOT EXISTS feedbackAttachments (
  attachmentId    TEXT PRIMARY KEY,
  scope           TEXT NOT NULL DEFAULT 'thread',
  draftRef        TEXT,
  slot            INTEGER,
  threadId        TEXT,
  messageId       TEXT,
  noticeId        TEXT,
  originDeviceId  TEXT,
  originAccountId TEXT,
  clientRef       TEXT,
  fileName        TEXT NOT NULL,
  contentType     TEXT NOT NULL,
  byteSize        INTEGER NOT NULL,
  sha256          TEXT NOT NULL,
  width           INTEGER,
  height          INTEGER,
  state           TEXT NOT NULL DEFAULT 'pending',
  storedPath      TEXT,
  createdAt       INTEGER NOT NULL,
  storedAt        INTEGER,
  boundAt         INTEGER
);
CREATE UNIQUE INDEX IF NOT EXISTS feedbackAttachmentsDraftSlot
  ON feedbackAttachments(draftRef, slot)
  WHERE draftRef IS NOT NULL AND slot IS NOT NULL;
"""


def png(size: int) -> bytes:
    """指定字节数、开头仍是 PNG 魔数（上传时的魔数嗅探是硬判据）。"""
    assert size >= len(PNG_MAGIC)
    return PNG_MAGIC + b"x" * (size - len(PNG_MAGIC))


def digest(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def columns(path: str, table: str) -> list[str]:
    conn = sqlite3.connect(path)
    try:
        return [row[1] for row in conn.execute(f"PRAGMA table_info({table})")]
    finally:
        conn.close()


def indexes(path: str, table: str) -> set[str]:
    conn = sqlite3.connect(path)
    try:
        return {row[1] for row in conn.execute(f"PRAGMA index_list({table})")}
    finally:
        conn.close()


def v2_attachments(body: dict) -> list[dict]:
    return [item for thread in body["threads"] for message in thread["messages"]
            for item in message.get("attachments", [])]


async def begin(client, *, client_ref: str, slot: int = 0, payload: bytes = png(64),
                role: str | None = None, name: str = "截屏.png",
                content_type: str = "image/png", headers=None):
    body = {"clientRef": client_ref, "slot": slot, "name": name,
            "contentType": content_type, "byteSize": len(payload),
            "sha256": digest(payload)}
    if role is not None:
        body["role"] = role
    return await client.post("/feedback/attachment/begin", json=body, headers=headers or {})


async def upload(client, attachment_id: str, payload: bytes, *, headers=None):
    return await client.post(f"/feedback/attachment/upload?attachmentId={attachment_id}",
                             data=payload,
                             headers={"Content-Type": "application/octet-stream",
                                      **(headers or {})})


async def stored(client, token: str, *, client_ref: str, slot: int = 0,
                 payload: bytes = png(64), role: str | None = None, **extra) -> dict:
    """begin + upload（都带设备令牌）；返回 begin 的回包。"""
    response = await begin(client, client_ref=client_ref, slot=slot, payload=payload,
                           role=role, headers=device_headers(token), **extra)
    assert response.status == 200, await response.text()
    begun = await response.json()
    upload_response = await upload(client, begun["attachmentId"], payload,
                                   headers=device_headers(token))
    assert upload_response.status == 200, await upload_response.text()
    return begun


async def inbox_v2(client, token: str) -> dict:
    response = await client.post("/feedback/inbox", json={"inboxVersion": 2},
                                 headers=device_headers(token))
    assert response.status == 200, await response.text()
    return await response.json()


# ── IMG-SRV-01 迁移 ────────────────────────────────────────────────────────


def test_migration_adds_role_and_replaces_the_unique_index(tmp_path):
    path = str(tmp_path / "mail.db")
    conn = sqlite3.connect(path)
    conn.executescript(OLD_SCHEMA)
    conn.execute(
        "INSERT INTO feedbackAttachments(attachmentId, scope, draftRef, slot, threadId,"
        " messageId, fileName, contentType, byteSize, sha256, state, storedPath, createdAt)"
        " VALUES('fa_old','thread','ref-old',0,'th_1','fm_1','旧图.png','image/png',"
        " 12,'" + "a" * 64 + "','stored','2026/01/fa_old',1000)")
    conn.commit()
    conn.close()
    assert "role" not in columns(path, "feedbackAttachments")
    assert "feedbackAttachmentsDraftSlot" in indexes(path, "feedbackAttachments")

    from store import Store
    Store(path).close()          # 迁移在 store 初始化时一次完成

    assert columns(path, "feedbackAttachments")[-1] == "role", "列追加在表末"
    assert "feedbackAttachmentsDraftSlot" not in indexes(path, "feedbackAttachments"), \
        "旧的 (draftRef, slot) 唯一键必须被删掉，否则同一个 slot 落不了两行"
    assert "feedbackAttachmentsDraftSlotRole" in indexes(path, "feedbackAttachments")
    conn = sqlite3.connect(path)
    try:
        assert conn.execute("SELECT role FROM feedbackAttachments WHERE attachmentId='fa_old'"
                            ).fetchone()[0] == "original"
    finally:
        conn.close()

    Store(path).close()          # 幂等：再开一次不报错、列不重复


# ── IMG-SRV-02 角色幂等与冲突 ───────────────────────────────────────────────


async def test_a_preview_and_an_original_are_idempotent_per_role(client):
    token = register_device(client)
    payload = png(64)
    first = await begin(client, client_ref="ref-pair", slot=0, payload=payload,
                        role="preview", headers=device_headers(token))
    assert first.status == 200, await first.text()
    preview_id = (await first.json())["attachmentId"]

    again = await begin(client, client_ref="ref-pair", slot=0, payload=payload,
                        role="preview", headers=device_headers(token))
    assert again.status == 200
    assert (await again.json())["attachmentId"] == preview_id, "同键同内容 = 幂等命中"

    original = await begin(client, client_ref="ref-pair", slot=0, payload=payload,
                           role="original", headers=device_headers(token))
    assert original.status == 200, "同一个 slot 的原图与预览是两行"
    original_id = (await original.json())["attachmentId"]
    assert original_id != preview_id

    conflict = await begin(client, client_ref="ref-pair", slot=0, payload=png(128),
                           role="preview", headers=device_headers(token))
    assert conflict.status == 409
    assert (await conflict.json())["error"]["code"] == "feedback/attachment-conflict"


# ── IMG-SRV-03 每封按逻辑附件计数 ──────────────────────────────────────────


async def test_the_cap_counts_logical_attachments_not_rows(client, monkeypatch):
    # 16 行要 32 次写调用：放宽**测试进程的**写入桶（生产仍是 30 次 / 10 min）。
    monkeypatch.setattr(api, "_WRITE_LIMIT", 200)
    monkeypatch.setattr(api, "_WRITE_DEVICE_LIMIT", 200)
    token = register_device(client)
    for slot in range(8):
        await stored(client, token, client_ref="ref-eight", slot=slot,
                     payload=png(64 + slot), role="preview")
        await stored(client, token, client_ref="ref-eight", slot=slot,
                     payload=png(64 + slot), role="original")

    ninth = await begin(client, client_ref="ref-eight", slot=8, payload=png(64),
                        role="preview", headers=device_headers(token))
    assert ninth.status == 413, "第 9 个**逻辑附件**越界，而不是第 5 个"

    response = await client.post("/feedback/submit", json={
        "text": "", "clientRef": "ref-eight"}, headers=device_headers(token))
    assert response.status == 200, await response.text()
    assert (await response.json())["attachmentsBound"] == 16, "绑定数仍是行数"
    body = await inbox_v2(client, token)
    assert len(v2_attachments(body)) == 8, "8 个逻辑附件 = 8 个对象"


# ── IMG-SRV-04 24 MiB 合计 ─────────────────────────────────────────────────


async def test_the_total_byte_cap_still_rejects_the_last_original(client):
    token = register_device(client)
    preview = png(512 * 1024)
    original = png(8 * MiB)
    for slot in (0, 1):
        await stored(client, token, client_ref="ref-bytes", slot=slot,
                     payload=preview, role="preview")
        await stored(client, token, client_ref="ref-bytes", slot=slot,
                     payload=original, role="original")
    # slot 2 的预览永远放得下（预览优先）。
    await stored(client, token, client_ref="ref-bytes", slot=2, payload=preview, role="preview")
    over = await begin(client, client_ref="ref-bytes", slot=2, payload=original,
                       role="original", headers=device_headers(token))
    assert over.status == 413
    assert (await over.json())["error"]["code"] == "feedback/too-large"

    # 释放一个原图之后，同一份字节就能存。
    store = client.app["store"]
    victim = [row for row in store.list_attachments(state="stored")
              if row["draftRef"] == "ref-bytes" and row["role"] == "original"][0]
    discarded = await client.post("/feedback/attachment/discard", json={
        "attachmentId": victim["attachmentId"], "clientRef": "ref-bytes"},
        headers=device_headers(token))
    assert discarded.status == 200, await discarded.text()
    retry = await begin(client, client_ref="ref-bytes", slot=2, payload=original,
                        role="original", headers=device_headers(token))
    assert retry.status == 200, await retry.text()


# ── IMG-SRV-05 / 06 / 07 投影 ──────────────────────────────────────────────


async def test_a_bound_letter_projects_the_original_with_a_preview(client):
    token = register_device(client)
    preview = await stored(client, token, client_ref="ref-proj", slot=0,
                           payload=png(64), role="preview")
    original = await stored(client, token, client_ref="ref-proj", slot=0,
                            payload=png(256), role="original")
    response = await client.post("/feedback/submit", json={
        "text": "配对", "clientRef": "ref-proj"}, headers=device_headers(token))
    assert response.status == 200, await response.text()

    body = await inbox_v2(client, token)
    items = v2_attachments(body)
    assert len(items) == 1, "两行投影成一个逻辑附件，旧客户端不会看到重复图"
    item = items[0]
    assert item["attachmentId"] == original["attachmentId"], "主对象是原图"
    assert item["compressed"] is False
    assert item["preview"] == {
        "attachmentId": preview["attachmentId"], "contentType": "image/png",
        "byteSize": 64, "sha256": digest(png(64)), "width": None, "height": None}


async def test_a_preview_only_letter_is_marked_compressed(client):
    token = register_device(client)
    preview = await stored(client, token, client_ref="ref-only-preview", slot=0,
                           payload=png(64), role="preview")
    await client.post("/feedback/submit", json={
        "text": "只有预览", "clientRef": "ref-only-preview"}, headers=device_headers(token))
    items = v2_attachments(await inbox_v2(client, token))
    assert len(items) == 1
    assert items[0]["attachmentId"] == preview["attachmentId"]
    assert items[0]["compressed"] is True
    assert "preview" not in items[0]


async def test_an_old_letter_has_no_preview_and_is_not_compressed(client):
    token = register_device(client)
    only = await stored(client, token, client_ref="ref-legacy")
    await client.post("/feedback/submit", json={
        "text": "旧信", "clientRef": "ref-legacy"}, headers=device_headers(token))
    items = v2_attachments(await inbox_v2(client, token))
    assert len(items) == 1
    assert items[0]["attachmentId"] == only["attachmentId"]
    assert items[0]["compressed"] is False
    assert "preview" not in items[0]
    assert set(items[0]) == {"attachmentId", "name", "contentType", "byteSize", "sha256",
                             "width", "height", "createdAt", "compressed"}


# ── IMG-SRV-08 旧客户端 ────────────────────────────────────────────────────


async def test_an_old_client_writes_one_row_per_slot_and_sees_the_roles_contract(client):
    token = register_device(client)
    for slot in (0, 1):
        await stored(client, token, client_ref="ref-old-client", slot=slot,
                     payload=png(64 + slot))
    response = await client.post("/feedback/submit", json={
        "text": "老客户端", "clientRef": "ref-old-client"}, headers=device_headers(token))
    assert response.status == 200, await response.text()
    store = client.app["store"]
    rows = [row for row in store.list_attachments(state="stored")
            if row["draftRef"] == "ref-old-client"]
    assert sorted(row["role"] for row in rows) == ["original", "original"]

    items = v2_attachments(await inbox_v2(client, token))
    assert len(items) == 2 and all("preview" not in item for item in items)
    limits = (await inbox_v2(client, token))["limits"]["attachments"]
    assert limits == {
        "maxPerMessage": 8, "maxFileBytes": 8 * MiB, "maxTotalBytes": 24 * MiB,
        "types": ["jpeg", "png", "heic", "pdf", "txt", "log", "csv", "json"],
        "roles": ["original", "preview"]}


# ── IMG-SRV-09 回滚开关 ────────────────────────────────────────────────────


async def test_the_roles_switch_turns_pairing_off(aiohttp_client, store):
    paired = await build_client(aiohttp_client, store)
    token = register_device(paired, name="DSH-Roles")
    preview = await stored(paired, token, client_ref="ref-switch", slot=0,
                           payload=png(64), role="preview")
    await stored(paired, token, client_ref="ref-switch", slot=0, payload=png(256),
                 role="original")
    await paired.post("/feedback/submit", json={
        "text": "配对信", "clientRef": "ref-switch"}, headers=device_headers(token))

    off = await build_client(aiohttp_client, store, attachment_limits={"roles": []})
    off_token = register_device(off, name="DSH-Roles")
    body = await inbox_v2(off, off_token)
    assert "roles" not in body["limits"]["attachments"], "关掉后不下发 roles"

    refused = await begin(off, client_ref="ref-switch-off", slot=0, payload=png(64),
                          role="preview", headers=device_headers(off_token))
    assert refused.status == 400, "关掉后不再接受 preview 行"
    assert (await refused.json())["error"]["code"] == "feedback/bad-request"

    legacy = await begin(off, client_ref="ref-switch-off", slot=0, payload=png(64),
                         headers=device_headers(off_token))
    assert legacy.status == 200, "不带 role 的老写入照旧"

    items = v2_attachments(body)
    assert len(items) == 1, "已存在的配对信件仍投影成一个对象，不重复显示"
    assert items[0]["attachmentId"] != preview["attachmentId"], "主对象仍是原图"
    assert items[0]["preview"]["attachmentId"] == preview["attachmentId"]


# ── IMG-SRV-10 通知附件不受影响 ────────────────────────────────────────────


async def test_notice_attachments_stay_single_file(client, store):
    notice = store.create_notice("通知正文", "标题", [ACCOUNT_ID])
    limits = {"maxPerMessage": 8, "maxFileBytes": 8 * MiB, "maxTotalBytes": 24 * MiB,
              "maxPerThreadBytes": 48 * MiB, "storageSoftBytes": 2 * 1024 * 1024 * 1024}
    row = store.begin_attachment(notice_id=notice["noticeId"], client_ref="notice-ref",
                                 file_name="附件.png", content_type="image/png",
                                 byte_size=12, sha256=digest(b"notice-bytes"), limits=limits)
    store.mark_attachment_stored(row["attachmentId"], "2026/11/notice", stored_at=1000)

    token = register_device(client, name="DSH-Notice")
    response = await client.post("/feedback/notice", json={"noticeId": notice["noticeId"]},
                                 headers=device_headers(token))
    assert response.status == 200, await response.text()
    items = (await response.json())["notice"]["attachments"]
    assert len(items) == 1 and items[0]["attachmentId"] == row["attachmentId"]
    assert items[0]["compressed"] is False
    assert "preview" not in items[0]
