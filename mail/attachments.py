"""信件附件字节的磁盘侧：目录布局、权限、分块读写、清扫（设计 M1）。

这一层只回答"字节放在哪、怎么写进去、怎么读出来"：不认 HTTP，也不认数据库
（`store` 认识行，`api` 认识请求）。目录布局与权限因此只有这一份实现：

    <附件根>/tmp/<随机>.part          上传中的临时件
    <附件根>/<yyyy>/<mm>/<dd>/<id>    已存的字节（UTC 日期三层，文件名就是 attachmentId）

附件根默认是数据库同级的 `attachments/`（生产 `MAIL_DB=/var/lib/dsh-mail/mail.db`
→ `/var/lib/dsh-mail/attachments/`，已在 systemd 的 `ReadWritePaths` 之内）。
"""

from __future__ import annotations

import asyncio
import hashlib
import os
import secrets
import time
from typing import AsyncIterable, AsyncIterator, Iterable

#: 目录与文件的权限在这里定死：目录 0700、文件 0600（与单元里的 `UMask=0077` 同口径）。
DIR_MODE = 0o700
FILE_MODE = 0o600
#: 上传分块：与 aiohttp `request.content.readany()` 的自然粒度一致。
CHUNK_BYTES = 64 * 1024
TEMP_DIR_NAME = "tmp"


class AttachmentTooLarge(Exception):
    """写入的字节数超过声明值：临时件已经删掉，调用方按 413 处理。"""


class AttachmentPathError(Exception):
    """库里记的相对路径试图跳出附件根（不该发生，也不许容忍）。"""


def root_for(db_path: str) -> str:
    """附件根 = 数据库同级的 `attachments/`。"""
    return os.path.join(os.path.dirname(os.path.abspath(db_path)), "attachments")


def ensure_dirs(root: str) -> str:
    """建好根与 `tmp/`（幂等）；权限每次收紧到 0700。"""
    os.makedirs(root, exist_ok=True)
    os.chmod(root, DIR_MODE)
    temp = temp_dir(root)
    os.makedirs(temp, exist_ok=True)
    os.chmod(temp, DIR_MODE)
    return root


def temp_dir(root: str) -> str:
    return os.path.join(root, TEMP_DIR_NAME)


def temp_path(root: str) -> str:
    """一次上传的临时件路径（不在里面承载任何用户内容，名字不可猜）。"""
    return os.path.join(temp_dir(root), f"{secrets.token_hex(8)}.part")


def stored_path(stored_at_ms: int, attachment_id: str) -> str:
    """已存字节的相对路径：按**存盘时刻的 UTC 日期**分三层。"""
    day = time.strftime("%Y/%m/%d", time.gmtime(int(stored_at_ms) / 1000))
    return os.path.join(day, attachment_id)


def final_path(root: str, stored_at_ms: int, attachment_id: str) -> str:
    return os.path.join(root, stored_path(stored_at_ms, attachment_id))


def path_for(root: str, relative: str) -> str:
    """相对路径 → 绝对路径；跳出根的输入一律拒绝（库里的值可能被改坏）。"""
    candidate = os.path.abspath(os.path.join(root, relative))
    base = os.path.abspath(root) + os.sep
    if not candidate.startswith(base):
        raise AttachmentPathError(f"attachment path escapes the root: {relative!r}")
    return candidate


async def write_stream(temp_path: str, chunks: AsyncIterable[bytes],
                       *, declared_bytes: int) -> dict:
    """把字节流写进临时件：边写边数、边算 sha256，超限立刻停并删临时件。

    返回值里带 `head`（前 :data:`CHUNK_BYTES` 字节）：类型嗅探要用开头那几个字节，
    顺手留在内存里，不让调用方为了复核再把文件读一遍。

    磁盘写在 `asyncio.to_thread` 里（与 store 的调用同一约定）：8 MiB 的上传不许
    把事件循环按住，收件箱要在同一段时间里照常回答。
    """
    handle = await asyncio.to_thread(_open_for_write, temp_path)
    digest = hashlib.sha256()
    head = b""
    written = 0
    try:
        async for chunk in chunks:
            if not chunk:
                continue
            written += len(chunk)
            if written > declared_bytes:
                raise AttachmentTooLarge(
                    f"the upload exceeded the declared {declared_bytes} bytes")
            if len(head) < CHUNK_BYTES:
                head += chunk[:CHUNK_BYTES - len(head)]
            digest.update(chunk)
            await asyncio.to_thread(handle.write, chunk)
    except BaseException:
        await asyncio.to_thread(handle.close)
        delete(temp_path)
        raise
    await asyncio.to_thread(handle.close)
    return {"tempPath": temp_path, "byteSize": written, "sha256": digest.hexdigest(),
            "head": head}


def _open_for_write(path: str):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, FILE_MODE)
    os.chmod(path, FILE_MODE)
    return os.fdopen(descriptor, "wb")


def finish(temp_path: str, final_path: str) -> str:
    """临时件 → 最终位置（`os.replace`，同一文件系统内原子）；权限收紧到 0600。"""
    os.makedirs(os.path.dirname(final_path), exist_ok=True)
    os.replace(temp_path, final_path)
    os.chmod(final_path, FILE_MODE)
    return final_path


async def open_stream(path: str, chunk_bytes: int = CHUNK_BYTES) -> AsyncIterator[bytes]:
    """按 64 KiB 分块读已存的字节（取回端与清扫端共用这一份读法）。"""
    handle = await asyncio.to_thread(open, path, "rb")
    try:
        while True:
            chunk = await asyncio.to_thread(handle.read, chunk_bytes)
            if not chunk:
                break
            yield chunk
    finally:
        await asyncio.to_thread(handle.close)


def delete(path: str) -> bool:
    """删掉一个字节文件；本来就不在返回 False（删除是幂等的）。"""
    try:
        os.remove(path)
        return True
    except FileNotFoundError:
        return False


def sweep_temp(root: str, max_age_s: float, *, now: float | None = None) -> int:
    """删掉过期的 `tmp/*.part`（进程启动时与每小时清扫各跑一次）。"""
    stamp = time.time() if now is None else float(now)
    removed = 0
    for name in os.listdir(temp_dir(root)) if os.path.isdir(temp_dir(root)) else []:
        if not name.endswith(".part"):
            continue
        path = os.path.join(temp_dir(root), name)
        if stamp - os.path.getmtime(path) >= max_age_s:
            removed += 1 if delete(path) else 0
    return removed


def sweep_orphans(root: str, known_ids: Iterable[str], *, min_age_s: float = 0.0,
                  now: float | None = None) -> int:
    """删掉"有文件、没有行"的字节。

    `min_age_s` 是给竞态留的余量：先 `finish` 落盘、再写行的那一刻里，文件短暂地
    没有归属行；只清扫比这个时长更老的文件，就不会删掉正在完成的上传。
    """
    stamp = time.time() if now is None else float(now)
    known = set(known_ids)
    removed = 0
    for directory, _dirs, names in os.walk(root):
        if os.path.basename(directory) == TEMP_DIR_NAME:
            continue
        for name in names:
            if name in known:
                continue
            path = os.path.join(directory, name)
            if stamp - os.path.getmtime(path) < min_age_s:
                continue
            removed += 1 if delete(path) else 0
    return removed
