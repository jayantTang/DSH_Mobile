"""附件字节的磁盘侧（设计 M1）：目录布局、权限、分块读写、清扫。

这一层只认路径与字节：不认 HTTP、不认数据库。所以用例也只用 `tmp_path`，
所有断言看的是**文件系统里的事实**（内容、权限、还剩哪些文件）。
"""

from __future__ import annotations

import hashlib
import os
import stat

import pytest

import attachments as files


def mode_of(path: str) -> int:
    return stat.S_IMODE(os.stat(path).st_mode)


def chunks_of(payload: bytes, size: int = 7) -> list[bytes]:
    return [payload[at:at + size] for at in range(0, len(payload), size)]


async def stream(chunks: list[bytes]):
    for chunk in chunks:
        yield chunk


def test_the_root_sits_next_to_the_database(tmp_path):
    assert files.root_for(str(tmp_path / "mail.db")) == str(tmp_path / "attachments")


def test_ensure_dirs_makes_a_0700_root_and_a_tmp_dir(tmp_path):
    root = files.root_for(str(tmp_path / "mail.db"))
    files.ensure_dirs(root)
    assert mode_of(root) == 0o700
    assert mode_of(files.temp_dir(root)) == 0o700
    assert os.path.isdir(files.temp_dir(root))


def test_the_final_path_is_partitioned_by_the_utc_day_of_the_attachment(tmp_path):
    root = str(tmp_path)
    # 2026-11-02T06:31:25Z 的毫秒值：日期三层目录取 UTC，不看本地时区。
    stamp = 1_793_605_885_000
    relative = files.stored_path(stamp, "fa_0123456789abcdef01")
    assert relative == os.path.join("2026", "11", "02", "fa_0123456789abcdef01")
    assert files.final_path(root, stamp, "fa_0123456789abcdef01") == os.path.join(root, relative)
    assert files.path_for(root, relative) == os.path.join(root, relative)


def test_path_for_refuses_to_leave_the_root(tmp_path):
    root = str(tmp_path / "attachments")
    with pytest.raises(files.AttachmentPathError):
        files.path_for(root, "../../etc/passwd")


async def test_write_stream_counts_hashes_and_finish_locks_the_file_down_to_0600(tmp_path):
    root = files.ensure_dirs(files.root_for(str(tmp_path / "mail.db")))
    payload = b"\x89PNG\r\n\x1a\n" + b"pixels" * 1_000
    temp = files.temp_path(root)
    written = await files.write_stream(temp, stream(chunks_of(payload)),
                                       declared_bytes=len(payload))
    assert written["tempPath"] == temp
    assert written["byteSize"] == len(payload)
    assert written["sha256"] == hashlib.sha256(payload).hexdigest()

    final = files.final_path(root, 1_793_605_885_000, "fa_0123456789abcdef01")
    files.finish(temp, final)
    assert not os.path.exists(temp), "临时件只作为中间状态存在"
    assert mode_of(final) == 0o600
    assert b"".join([chunk async for chunk in files.open_stream(final)]) == payload


async def test_writing_one_byte_over_the_declaration_stops_and_deletes_the_temp(tmp_path):
    root = files.ensure_dirs(files.root_for(str(tmp_path / "mail.db")))
    temp = files.temp_path(root)
    with pytest.raises(files.AttachmentTooLarge):
        await files.write_stream(temp, stream([b"a" * 10, b"b" * 10]), declared_bytes=19)
    assert not os.path.exists(temp), "超限的临时件不许留在磁盘上"
    assert os.listdir(files.temp_dir(root)) == []


async def test_a_raising_reader_also_removes_the_partial_temp_file(tmp_path):
    root = files.ensure_dirs(files.root_for(str(tmp_path / "mail.db")))
    temp = files.temp_path(root)

    async def broken():
        yield b"half"
        raise ConnectionResetError("client went away")

    with pytest.raises(ConnectionResetError):
        await files.write_stream(temp, broken(), declared_bytes=10)
    assert not os.path.exists(temp)


async def test_open_stream_reads_in_64k_chunks(tmp_path):
    target = tmp_path / "blob"
    target.write_bytes(b"x" * (files.CHUNK_BYTES * 2 + 5))
    sizes = [len(chunk) async for chunk in files.open_stream(str(target))]
    assert sizes == [files.CHUNK_BYTES, files.CHUNK_BYTES, 5]


def test_sweep_temp_removes_only_stale_parts(tmp_path):
    root = files.ensure_dirs(files.root_for(str(tmp_path / "mail.db")))
    stale = files.temp_path(root)
    fresh = files.temp_path(root)
    for path in (stale, fresh):
        with open(path, "wb") as handle:
            handle.write(b"partial")
    now = 10_000.0
    os.utime(stale, (now - 7_200, now - 7_200))
    os.utime(fresh, (now, now))
    removed = files.sweep_temp(root, max_age_s=3_600, now=now)
    assert removed == 1
    assert os.path.exists(fresh) and not os.path.exists(stale)


def test_sweep_orphans_deletes_files_whose_row_is_gone_and_keeps_young_ones(tmp_path):
    root = files.ensure_dirs(files.root_for(str(tmp_path / "mail.db")))
    known = "fa_keep"
    orphan = "fa_orphan"
    young = "fa_young"
    for attachment_id in (known, orphan, young):
        final = files.final_path(root, 1_793_605_885_000, attachment_id)
        os.makedirs(os.path.dirname(final), exist_ok=True)
        with open(final, "wb") as handle:
            handle.write(b"bytes")
    now = 1_793_605_885.0
    for attachment_id in (known, orphan):
        final = files.final_path(root, 1_793_605_885_000, attachment_id)
        os.utime(final, (now - 7_200, now - 7_200))
    os.utime(files.final_path(root, 1_793_605_885_000, young), (now, now))

    removed = files.sweep_orphans(root, {known}, min_age_s=3_600, now=now)
    assert removed == 1
    assert os.path.exists(files.final_path(root, 1_793_605_885_000, known))
    assert not os.path.exists(files.final_path(root, 1_793_605_885_000, orphan))
    assert os.path.exists(files.final_path(root, 1_793_605_885_000, young)), \
        "刚 rename 完还没来得及写行的文件不算孤儿"


def test_delete_reports_whether_the_bytes_were_there(tmp_path):
    target = tmp_path / "one"
    target.write_bytes(b"x")
    assert files.delete(str(target)) is True
    assert files.delete(str(target)) is False
