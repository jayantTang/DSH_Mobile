"""owner 侧附件命令（设计 M7）：show 打元数据、list 带数量、attachment-get 落盘。

CLI 的行形状是 owner 的产品面，所以断言打印出来的 JSON；写盘的命令还要回文件系统
再确认一遍（只断言输出等于没验）。
"""

from __future__ import annotations

import hashlib
import json
import os
import stat

import pytest

import admin
import attachments as files
from store import Store, sha256_hex

LIMITS = {"maxPerMessage": 8, "maxFileBytes": 8 * 1024 * 1024,
          "maxTotalBytes": 24 * 1024 * 1024, "maxPerThreadBytes": 48 * 1024 * 1024,
          "storageSoftBytes": 2 * 1024 * 1024 * 1024}
PAYLOAD = b"\x89PNG\r\n\x1a\n" + b"pixels" * 50


def run_cli(db: str, *args: str, capsys) -> tuple[int, object, str]:
    """跑一条命令：`(退出码, stdout 的 JSON, stderr 文本)`。

    stderr 单独返回：`feedback-attachment-get` 把落盘路径打到那里（stdout 保持一条 JSON）。
    """
    code = admin.main(["--db", db, *args])
    captured = capsys.readouterr()
    out = captured.out.strip()
    payload = json.loads(out) if out else {"stderr": captured.err.strip()}
    return code, payload, captured.err.strip()


def make_draft(store: Store, root: str, *, client_ref: str = "ref-admin", slot: int = 0,
               name: str = "截屏 2026-11-02.png", at: int = 2_000) -> dict:
    """v4 的"先传附件"那一步：登记草稿 → 字节落盘 → 标 stored。"""
    row = store.begin_attachment(
        draft_ref=client_ref, slot=slot, file_name=name, content_type="image/png",
        byte_size=len(PAYLOAD), sha256=hashlib.sha256(PAYLOAD).hexdigest(),
        width=1179, height=2556, limits=LIMITS, origin_device_id="dev_1", at=at)
    stored_at = at + 1_000
    relative = files.stored_path(stored_at, row["attachmentId"])
    final = files.final_path(root, stored_at, row["attachmentId"])
    os.makedirs(os.path.dirname(final), exist_ok=True)
    with open(final, "wb") as handle:
        handle.write(PAYLOAD)
    store.mark_attachment_stored(row["attachmentId"], relative, stored_at)
    return row


@pytest.fixture
def seeded(tmp_path):
    """一条用户来信 + 一张**已绑定**的附件（字节真的落盘，供 attachment-get/delete 用）。"""
    db = str(tmp_path / "mail.db")
    store = Store(db)
    root = files.ensure_dirs(files.root_for(db))
    try:
        row = make_draft(store, root)
        thread = store.create_feedback_thread(
            ticket_hash=sha256_hex("fk_one"), text="截屏之后一直转圈",
            client_ref="ref-admin", device_id="dev_1", account_id="acc_user",
            device_model="iPhone15,4", limits=LIMITS, at=5_000)
        assert thread["attachmentsBound"] == 1, "夹具必须真的绑上"
    finally:
        store.close()
    return {"db": db, "root": root, "thread": thread, "attachment": row}


def test_show_prints_the_attachment_metadata_of_each_letter(seeded, capsys):
    code, body, err = run_cli(seeded["db"], "feedback-show", "--thread",
                         seeded["thread"]["threadId"], capsys=capsys)
    assert code == 0
    attachments = body["messages"][0]["attachments"]
    assert [item["attachmentId"] for item in attachments] == \
        [seeded["attachment"]["attachmentId"]]
    assert attachments[0]["fileName"] == "截屏 2026-11-02.png"
    assert attachments[0]["contentType"] == "image/png"
    assert attachments[0]["byteSize"] == len(PAYLOAD)
    assert attachments[0]["state"] == "stored"
    assert attachments[0]["storedPath"] == files.stored_path(
        3_000, seeded["attachment"]["attachmentId"])


def test_list_reports_the_attachment_count_per_thread(seeded, capsys):
    code, rows, err = run_cli(seeded["db"], "feedback-list", capsys=capsys)
    assert code == 0
    assert [row["attachmentCount"] for row in rows] == [1]


def test_attachment_get_copies_the_bytes_into_the_directory(seeded, capsys, tmp_path):
    target = tmp_path / "out"
    code, body, err = run_cli(seeded["db"], "feedback-attachment-get",
                         "--attachment", seeded["attachment"]["attachmentId"],
                         "--dir", str(target), capsys=capsys)
    assert code == 0
    expected = target / f"{seeded['attachment']['attachmentId']}-截屏 2026-11-02.png"
    assert body["path"] == str(expected)
    assert expected.read_bytes() == PAYLOAD
    assert stat.S_IMODE(os.stat(expected).st_mode) == 0o600
    assert body["sha256"] == seeded["attachment"]["sha256"]
    assert err == str(expected), "本地路径打到 stderr"


def test_attachment_get_refuses_a_row_whose_bytes_are_gone(seeded, capsys):
    root = seeded["root"]
    os.remove(files.path_for(root, files.stored_path(
        3_000, seeded["attachment"]["attachmentId"])))
    code, body, err = run_cli(seeded["db"], "feedback-attachment-get",
                         "--attachment", seeded["attachment"]["attachmentId"],
                         "--dir", str(root), capsys=capsys)
    assert code == 1
    assert body["ok"] is False and "missing" in body["error"]


def test_attachment_get_reports_a_pending_row_instead_of_writing_nothing(seeded, capsys,
                                                                        tmp_path):
    store = Store(seeded["db"])
    try:
        pending = store.begin_attachment(
            draft_ref="ref-pending", slot=0, file_name="没传完.png",
            content_type="image/png", byte_size=10, sha256=sha256_hex("p"),
            limits=LIMITS, origin_device_id="dev_1", at=4_000)
    finally:
        store.close()
    code, body, err = run_cli(seeded["db"], "feedback-attachment-get",
                              "--attachment", pending["attachmentId"],
                              "--dir", str(tmp_path / "out"), capsys=capsys)
    assert code == 1
    assert body["ok"] is False and "draft" in body["error"]


def test_a_draft_never_appears_in_show_list_or_attachment_get(seeded, capsys, tmp_path):
    """草稿不进任何 CLI 面（§7.1-11）：show 没有、list 不计数、get 直接拒。"""
    store = Store(seeded["db"])
    try:
        draft = make_draft(store, seeded["root"], client_ref="ref-draft",
                           name="还没发出去的.png", at=6_000)
    finally:
        store.close()

    code, body, _err = run_cli(seeded["db"], "feedback-show",
                               "--thread", seeded["thread"]["threadId"], capsys=capsys)
    assert code == 0
    shown = [item["attachmentId"] for message in body["messages"]
             for item in message["attachments"]]
    assert shown == [seeded["attachment"]["attachmentId"]], "只有已绑定的那一条"

    code, rows, _err = run_cli(seeded["db"], "feedback-list", capsys=capsys)
    assert code == 0 and [row["attachmentCount"] for row in rows] == [1]

    code, body, _err = run_cli(seeded["db"], "feedback-attachment-get",
                               "--attachment", draft["attachmentId"],
                               "--dir", str(tmp_path / "out"), capsys=capsys)
    assert code == 1 and "draft" in body["error"]


def test_delete_takes_the_bytes_with_it(seeded, capsys):
    relative = files.stored_path(3_000, seeded["attachment"]["attachmentId"])
    on_disk = files.path_for(seeded["root"], relative)
    assert os.path.exists(on_disk)

    code, dry, err = run_cli(seeded["db"], "feedback-delete",
                        "--thread", seeded["thread"]["threadId"], capsys=capsys)
    assert code == 0 and dry["dryRun"] is True and dry["attachments"] == 1
    assert os.path.exists(on_disk), "预演一个字节都不许删"

    code, body, err = run_cli(seeded["db"], "feedback-delete",
                         "--thread", seeded["thread"]["threadId"], "--yes", capsys=capsys)
    assert code == 0
    assert body["deleted"] is True and body["attachments"] == 1
    assert not os.path.exists(on_disk), "删信必须同时删掉附件字节"
    assert os.path.exists(seeded["root"]), "只删这一封的字节，不动附件目录本身"
