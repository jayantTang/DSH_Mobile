#!/usr/bin/env python3
"""M8 文件通道真连接器联调：真实 cli.js + 临时 Go relay + 本机 DSH + 假设备。

链路（与生产同一条）：

    假设备/HTTP 客户端 → 临时 Go relay →（WebSocket 帧代理）→ 真实 cli.js → 本机 DSH

覆盖：
  * 上传 1 MB / 10 MB：``PUT /files/up``，连接器按 ``fsPutBegin`` / ``fsPutChunk`` /
    ``fsPutEnd`` 收，落盘在 ``$DSH_HOME/inbox/<sessionId>/<name>``，校验 SHA-256；
  * 下载同一文件：``GET /files/down``，校验 SHA-256、``Content-Length``、``ETag``；
  * Range 从中间续传：``Range: bytes=N-``，校验 206、``Content-Range``、拼接后哈希；
  * 客户端中断后带 Range 重试：校验可续传，且中转向连接器发 ``fsGetCancel``；
  * 上传请求体截断后重试：校验落盘哈希仍然正确。

帧序列由连接器↔中转之间的 WebSocket 帧代理旁路记录（两向文本帧，含 bid/seq/字节数），
报告里的"帧序列与耗时"就取自这里。

安全边界：
  * 临时 relay（随机端口、临时 DB）、单独临时 ``DSH_HOME``；
  * 不写 ``~/.dsh/mobile-link/agent.json``（脚本前后比对摘要）；
  * 不写 owner 的真实会话：sessionId 只作为 ``workspaceFileScopeId`` 的授权凭据，
    不读、不改任何会话内容；脚本前后比对所选会话目录与 projcache 的摘要；
  * 结束 SIGTERM 连接器与 relay，删临时目录，并验证两个端口已释放。

用法：
  .venv/bin/python relay-go/scripts/m8/real_connector_files_e2e.py \\
      [--evidence maintainers/m8-files-e2e-<ts>] [--keep] [--sizes 1048576,10485760]
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import json
import os
import pathlib
import random
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

import aiohttp

ROOT = pathlib.Path(__file__).resolve().parents[3]
RELAY = ROOT / "relay-go" / "bin" / "dsh-relay"
CONNECTOR_DIR = ROOT / "plugins" / "mobile-link"
CLI = CONNECTOR_DIR / "lib" / "cli.js"
DSH_HOME = pathlib.Path(os.environ.get("DSH_HOME", pathlib.Path.home() / ".dsh"))
ENDPOINT_FILE = DSH_HOME / "mobile-link" / "endpoint.json"
REAL_AGENT_FILE = DSH_HOME / "mobile-link" / "agent.json"
BASE_PATH = "/dsh-link"
STEP_TIMEOUT = 60.0


class StepFailure(AssertionError):
    """一步没达到验收口径。"""


def log(message: str) -> None:
    print(f"[m8-files] {message}", flush=True)


def check(condition: bool, message: str) -> None:
    if not condition:
        raise StepFailure(message)
    log(f"ok: {message}")


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


def digest_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def digest_file(path: pathlib.Path) -> str | None:
    try:
        hasher = hashlib.sha256()
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(1 << 20), b""):
                hasher.update(block)
        return hasher.hexdigest()
    except OSError:
        return None


def tree_digest(path: pathlib.Path) -> str | None:
    """目录内容摘要（路径 + 大小 + mtime），用来证明"没有写过"。"""
    if not path.exists():
        return None
    hasher = hashlib.sha256()
    entries = sorted(path.rglob("*")) if path.is_dir() else [path]
    for entry in entries:
        try:
            stat = entry.stat()
        except OSError:
            continue
        hasher.update(f"{entry}:{stat.st_size}:{stat.st_mtime_ns}".encode())
    return hasher.hexdigest()


def redacted(url: str) -> str:
    return re.sub(r"token=[^&\s\"']+", "token=<redacted>", url)


def redact_text(text: str) -> str:
    return re.sub(r"token=[^&\s\"']+", "token=<redacted>", text)


def run_admin(db: str, *args: str) -> dict:
    result = subprocess.run([str(RELAY), "admin", "--db", db, *args],
                            capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise StepFailure(f"admin {' '.join(args)} 失败: {result.stderr.strip() or result.stdout.strip()}")
    return json.loads(result.stdout)


# ── WebSocket 帧代理（帧序列证据） ─────────────────────────────────────────


def parse_frame(buffer: bytearray):
    """从缓冲区头部解析一帧；不完整返回 None。返回 (fin, opcode, payload, consumed)。"""
    if len(buffer) < 2:
        return None
    first, second = buffer[0], buffer[1]
    fin = bool(first & 0x80)
    opcode = first & 0x0F
    masked = bool(second & 0x80)
    length = second & 0x7F
    cursor = 2
    if length == 126:
        if len(buffer) < cursor + 2:
            return None
        length = int.from_bytes(buffer[cursor:cursor + 2], "big")
        cursor += 2
    elif length == 127:
        if len(buffer) < cursor + 8:
            return None
        length = int.from_bytes(buffer[cursor:cursor + 8], "big")
        cursor += 8
    mask = None
    if masked:
        if len(buffer) < cursor + 4:
            return None
        mask = bytes(buffer[cursor:cursor + 4])
        cursor += 4
    if len(buffer) < cursor + length:
        return None
    payload = bytes(buffer[cursor:cursor + length])
    if mask:
        payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    return fin, opcode, payload, cursor + length


class FrameRecorder:
    """记录两向文本帧；只留路由字段，不留 base64 正文。"""

    def __init__(self) -> None:
        self.started = time.monotonic()
        self.frames: list[dict] = []
        self.connections = 0

    def record(self, direction: str, payload: bytes) -> None:
        try:
            frame = json.loads(payload)
        except (UnicodeDecodeError, json.JSONDecodeError):
            return
        if not isinstance(frame, dict):
            return
        entry: dict = {
            "at": round(time.monotonic() - self.started, 4),
            "dir": direction,
            "t": frame.get("t"),
        }
        for key in ("bid", "seq", "offset", "bytes", "received", "replaces", "code", "eof",
                    "size", "version"):
            if key in frame:
                entry[key] = frame[key]
        data = frame.get("data")
        if isinstance(data, str):
            entry["dataBytes"] = len(data) // 4 * 3 - data.count("=")
        if isinstance(frame.get("error"), str):
            entry["error"] = frame["error"]
        if isinstance(frame.get("message"), str):
            entry["message"] = frame["message"][:200]
        self.frames.append(entry)

    def sequence(self, direction: str | None = None) -> list[dict]:
        return [frame for frame in self.frames
                if direction is None or frame["dir"] == direction]

    def since(self, index: int) -> list[dict]:
        return self.frames[index:]

    async def wait_for(self, predicate, timeout: float) -> dict | None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for frame in self.frames:
                if predicate(frame):
                    return frame
            await asyncio.sleep(0.02)
        return None

    def dump(self, path: pathlib.Path) -> None:
        with path.open("w") as handle:
            for frame in self.frames:
                handle.write(json.dumps(frame, ensure_ascii=False) + "\n")


async def pump(src: asyncio.StreamReader, dst: asyncio.StreamWriter, direction: str,
               recorder: FrameRecorder) -> None:
    """搬运一个方向；解析握手之后的帧，累积分片后交给记录器。"""
    buffer = bytearray()
    handshaked = False
    fragments = bytearray()
    fragment_opcode = 0
    try:
        while True:
            chunk = await src.read(1 << 16)
            if not chunk:
                break
            dst.write(chunk)
            await dst.drain()
            buffer.extend(chunk)
            if not handshaked:
                marker = buffer.find(b"\r\n\r\n")
                if marker == -1:
                    continue
                buffer = bytearray(buffer[marker + 4:])
                handshaked = True
            while True:
                parsed = parse_frame(buffer)
                if parsed is None:
                    break
                fin, opcode, payload, consumed = parsed
                del buffer[:consumed]
                if opcode == 0x8:          # close
                    continue
                if opcode in (0x9, 0xA):   # ping / pong
                    continue
                if opcode in (0x1, 0x2):
                    fragments = bytearray(payload)
                    fragment_opcode = opcode
                elif opcode == 0x0:
                    fragments.extend(payload)
                else:
                    continue
                if fin:
                    if fragment_opcode == 0x1:
                        recorder.record(direction, bytes(fragments))
                    fragments = bytearray()
                    fragment_opcode = 0
    except (ConnectionResetError, BrokenPipeError, asyncio.IncompleteReadError):
        pass
    finally:
        try:
            dst.close()
        except Exception:  # noqa: BLE001 - 关闭失败不影响结论
            pass


async def start_frame_proxy(upstream_port: int, recorder: FrameRecorder) -> int:
    """在随机端口上起一个 WS 帧代理，转发到临时 relay。返回监听端口。"""
    port = free_port()

    async def handle(client_reader: asyncio.StreamReader,
                     client_writer: asyncio.StreamWriter) -> None:
        recorder.connections += 1
        try:
            upstream_reader, upstream_writer = await asyncio.open_connection(
                "127.0.0.1", upstream_port)
        except OSError:
            client_writer.close()
            return
        await asyncio.gather(
            pump(client_reader, upstream_writer, "connector→relay", recorder),
            pump(upstream_reader, client_writer, "relay→connector", recorder),
        )

    server = await asyncio.start_server(handle, "127.0.0.1", port)
    return port, server


# ── HTTP 帮手 ──────────────────────────────────────────────────────────────


async def raw_interrupt_download(port: int, target: str, token: str,
                                 needle: int) -> dict:
    """发一个 GET，读到 needle 字节后强行断开（客户端中断）。"""
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    request = (f"GET {target} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
               f"Authorization: Bearer {token}\r\nConnection: close\r\n\r\n")
    writer.write(request.encode())
    await writer.drain()
    head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), STEP_TIMEOUT)
    headers = {}
    for line in head.split(b"\r\n")[1:]:
        if b":" in line:
            key, value = line.split(b":", 1)
            headers[key.decode().strip().lower()] = value.decode().strip()
    received = bytearray()
    while len(received) < needle:
        chunk = await asyncio.wait_for(reader.read(needle - len(received)), STEP_TIMEOUT)
        if not chunk:
            break
        received.extend(chunk)
    # 真正的中断：RST，不是优雅关闭。
    writer.transport.abort()
    return {
        "status": int(head.split(b" ")[1]),
        "contentLength": int(headers.get("content-length", "0")),
        "etag": headers.get("etag"),
        "received": len(received),
        "sha256Prefix": digest_bytes(bytes(received)),
    }


async def raw_interrupt_upload(port: int, target: str, token: str, declared: int,
                               sent: int) -> None:
    """声明 declared 字节、只发 sent 字节就断开（上传请求体截断）。"""
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    request = (f"PUT {target} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
               f"Authorization: Bearer {token}\r\n"
               f"Content-Length: {declared}\r\nConnection: close\r\n\r\n")
    writer.write(request.encode())
    writer.write(b"\x00" * sent)
    try:
        await writer.drain()
    except (BrokenPipeError, ConnectionResetError):
        pass  # 中转已经判定请求体长度不对并关掉了连接，这正是"截断"的形态
    await asyncio.sleep(0.4)
    writer.transport.abort()
    try:
        await asyncio.wait_for(reader.read(4096), 3.0)
    except (asyncio.TimeoutError, ConnectionResetError):
        pass


# ── 主流程 ─────────────────────────────────────────────────────────────────


async def run(workdir: pathlib.Path, sizes: list[int], result: dict) -> None:
    result.update({"steps": [], "sizes": sizes})
    steps = result["steps"]

    started_at = time.time()
    agent_before = digest_file(REAL_AGENT_FILE)
    endpoint_before = digest_file(ENDPOINT_FILE)
    endpoint = json.loads(ENDPOINT_FILE.read_text())
    dsh_url = endpoint["url"]
    log(f"本机 dsh: {redacted(dsh_url)}（source={endpoint.get('source')}）")

    db = str(workdir / "state.db")
    port = free_port()
    base = f"http://127.0.0.1:{port}"
    public = f"{base}{BASE_PATH}"
    relay_url = f"ws://127.0.0.1:{port}{BASE_PATH}"
    relay_log = workdir / "relay.log"
    connector_log = workdir / "connector.log"
    status_file = workdir / "agent-status.json"
    dsh_home = workdir / "dsh-home"
    inbox_root = dsh_home / "inbox"
    (dsh_home / "mobile-link").mkdir(parents=True, exist_ok=True)

    relay = subprocess.Popen(
        [str(RELAY), "serve", "--port", str(port), "--db", db,
         "--base-path", BASE_PATH, "--log-level", "debug"],
        stdout=relay_log.open("w"), stderr=subprocess.STDOUT, cwd=str(workdir))
    connector: subprocess.Popen | None = None
    recorder = FrameRecorder()
    proxy_server = None
    proxy_port: int | None = None
    device_headers: dict[str, str] = {}
    try:
        async with aiohttp.ClientSession() as session:
            deadline = time.monotonic() + 20
            while True:
                try:
                    async with session.get(f"{base}/healthz") as response:
                        health = await response.json()
                    break
                except (aiohttp.ClientError, asyncio.TimeoutError):
                    if time.monotonic() > deadline:
                        raise StepFailure("Go relay 20 秒内没有起来")
                    await asyncio.sleep(0.1)
        check(health.get("ok") is True, "临时 Go relay 健康检查通过")
        try:
            result["relayBuild"] = json.loads((ROOT / "relay-go" / "bin" / "build.json").read_text())
        except (OSError, json.JSONDecodeError):
            result["relayBuild"] = {}
        result["relayHealth"] = health

        account = run_admin(db, "account-create", "--name", "M8 文件通道联调")
        agent = run_admin(db, "agent-register", "--account", account["accountId"],
                          "--name", "M8 真实连接器 Mac", "--relay", relay_url)
        minted = run_admin(db, "code-mint", "--agent", agent["agentId"],
                           "--ttl-seconds", "120")
        async with aiohttp.ClientSession() as session:
            async with session.post(f"{public}/pair/claim", json={
                "pairCode": minted["code"], "deviceName": "DSH-M8-Files",
                "deviceModel": "iPhone17,1", "appVersion": "1.0.0"}) as response:
                claimed = await response.json()
        check(claimed.get("ok") is True, "假设备通过临时 relay 完成配对")
        device_headers = {"Authorization": f"Bearer {claimed['deviceToken']}"}
        result["agentId"] = agent["agentId"]
        result["deviceId"] = claimed["deviceId"]

        proxy_port, proxy_server = await start_frame_proxy(port, recorder)
        connector = subprocess.Popen(
            [shutil.which("node") or "node", str(CLI),
             "--relay", f"ws://127.0.0.1:{proxy_port}{BASE_PATH}",
             "--agent-id", agent["agentId"],
             "--agent-secret", agent["agentSecret"],
             "--state-file", str(workdir / "agent-identity.json"),
             "--status-file", str(status_file),
             "--dsh-url", dsh_url,
             "--log-level", "debug"],
            stdout=connector_log.open("w"), stderr=subprocess.STDOUT,
            cwd=str(CONNECTOR_DIR), env={**os.environ, "DSH_HOME": str(dsh_home)})

        deadline = time.monotonic() + 30
        status: dict = {}
        while time.monotonic() < deadline:
            try:
                status = json.loads(status_file.read_text())
            except (OSError, json.JSONDecodeError):
                status = {}
            if status.get("connected") and status.get("dsh", {}).get("port"):
                break
            await asyncio.sleep(0.1)
        check(status.get("connected") is True and status["dsh"]["port"] == endpoint["port"],
              f"真实连接器已连上帧代理与临时 relay，并认证到本机 dsh:{status['dsh']['port']}")
        result["connectorVersion"] = status.get("connectorVersion")
        result["hostVersion"] = status.get("hostVersion")
        result["proxyConnections"] = None

        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=STEP_TIMEOUT)) as session:
            ws = await session.ws_connect(f"{public}/link/device?agentId={agent['agentId']}",
                                         headers=device_headers)
            try:
                await ws.receive()  # hostStatus
                scope = await pick_scope(ws, workdir)
                result["scope"] = {key: value for key, value in scope.items()
                                   if key in ("sessionId", "cwd", "running", "reason")}
                scope_before = tree_digest(scope["sessionDir"]) if scope.get("sessionDir") else None
                cache_before = (tree_digest(scope["cachePath"])
                                if scope.get("cachePath") else None)
            finally:
                await ws.close()

        scope_id = scope["sessionId"]
        # 上传一侧的 sessionId 只被连接器当作 inbox 目录名（宿主不解析它），所以用
        # 纯合成值，绝不以真实会话命名落盘目录。
        upload_session = f"session-m8-temp-{int(time.time() * 1000):x}"
        result["uploadSessionId"] = upload_session
        log(f"scopeId={scope_id[:24]}…（{scope['reason']}）；upload sessionId={upload_session}")

        # ── 1. 上传 1 MB / 10 MB ────────────────────────────────────────────
        uploads: dict[int, dict] = {}
        for size in sizes:
            content = random.Random(size).randbytes(size)
            name = f"m8-{size}.bin"
            expected = digest_bytes(content)
            bid = f"app-up-{size}-{int(time.time() * 1000)}"
            mark = len(recorder.frames)
            started = time.monotonic()
            async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=300)) as session:
                async with session.put(
                        f"{public}/files/up?sessionId={upload_session}&name={name}&bid={bid}&bytes={size}",
                        data=content, headers=device_headers) as response:
                    payload = await response.json()
            elapsed = round(time.monotonic() - started, 3)
            frames = recorder.since(mark)
            incoming = [frame for frame in frames if frame["dir"] == "connector→relay"]
            outgoing = [frame for frame in frames if frame["dir"] == "relay→connector"]
            check(response.status == 200 and payload.get("ok") is True,
                  f"{size} 字节上传返回 200/ok（bid={bid}）")
            path = pathlib.Path(payload["path"])
            landed = digest_file(path)
            check(landed == expected,
                  f"{name} 落盘 SHA-256 一致 {expected[:16]}…（{payload['bytes']} 字节）")
            check(str(path).startswith(str(inbox_root)),
                  f"{name} 落在临时 DSH_HOME 的 inbox 下（{path.parent}）")
            seqs = [frame.get("seq") for frame in outgoing if frame["t"] == "fsPutChunk"]
            check(seqs == list(range(len(seqs))),
                  f"fsPutChunk 序号连续 0..{len(seqs) - 1}，每片 1 MiB")
            check(any(frame["t"] == "fsPutAck" for frame in incoming),
                  "连接器回了 fsPutAck")
            done_frame = next((frame for frame in incoming if frame["t"] == "fsPutDone"), None)
            check(done_frame is not None and done_frame.get("bytes") == size,
                  "连接器回了 fsPutDone 且字节数与声明一致")
            uploads[size] = {"content": content, "expected": expected, "path": path,
                             "name": name, "bid": bid, "elapsed": elapsed}
            steps.append({
                "name": f"upload {size} bytes",
                "ok": True,
                "ms": round(elapsed * 1000, 1),
                "sha256": expected,
                "path": str(path),
                "frames": frame_summary(frames),
            })

        # ── 2. 下载、Content-Length、ETag ───────────────────────────────────
        downloads: dict[int, dict] = {}
        for size in sizes:
            item = uploads[size]
            expected = item["expected"]
            mark = len(recorder.frames)
            started = time.monotonic()
            async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=300)) as session:
                async with session.get(
                        f"{public}/files/down?scopeId={scope_id}&path={quote_path(item['path'])}&bid=app-down-{size}",
                        headers=device_headers) as response:
                    body = await response.read()
                    status = response.status
                    headers = lower_headers(response)
            elapsed = round(time.monotonic() - started, 3)
            frames = recorder.since(mark)
            got = digest_bytes(body)
            check(status == 200 and got == expected,
                  f"{size} 字节下载 SHA-256 一致 {got[:16]}…")
            check(int(headers.get("content-length", "0")) == size,
                  f"Content-Length={headers.get('content-length')}（期望 {size}）")
            etag = headers.get("etag", "")
            check(etag.startswith('"dsh-') and etag.endswith(f'-{size}"'),
                  f"ETag 形状正确：{etag[:48]}…")
            check(headers.get("accept-ranges") == "bytes",
                  "下载响应声明 Accept-Ranges: bytes")
            chunks = [f for f in recorder.since(mark) if f["t"] == "fsGetChunk"]
            downloads[size] = {"elapsed": elapsed, "body": body,
                               "chunks": len(chunks), "etag": etag}
            steps.append({
                "name": f"download {size} bytes",
                "ok": True,
                "ms": round(elapsed * 1000, 1),
                "sha256": got,
                "contentLength": headers.get("content-length"),
                "etag": etag,
                "frames": frame_summary(frames),
            })

        # ── 3. Range 从中间续传 ─────────────────────────────────────────────
        size = max(sizes)
        item = uploads[size]
        body = downloads[size]["body"]
        offset = min(size // 2 + 12345, size - 1)
        mark = len(recorder.frames)
        started = time.monotonic()
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=300)) as session:
            async with session.get(
                    f"{public}/files/down?scopeId={scope_id}&path={quote_path(item['path'])}&bid=app-range",
                    headers={**device_headers, "Range": f"bytes={offset}-"}) as response:
                tail = await response.read()
                status = response.status
                headers = lower_headers(response)
        elapsed = round(time.monotonic() - started, 3)
        frames = recorder.since(mark)
        joined = body[:offset] + tail
        check(status == 206, f"Range 续传返回 206（offset={offset}）")
        check(headers.get("content-range") == f"bytes {offset}-{size - 1}/{size}",
              f"Content-Range={headers.get('content-range')}")
        check(headers.get("x-dsh-offset") == str(offset),
              f"X-DSH-Offset={headers.get('x-dsh-offset')}")
        check(int(headers.get("content-length", "0")) == size - offset,
              f"Content-Length={headers.get('content-length')}（期望 {size - offset}）")
        check(digest_bytes(joined) == item["expected"],
              "前半段 + Range 正文拼接后 SHA-256 一致")
        begins = [f for f in frames if f["t"] == "fsGetBegin"]
        check(begins and begins[0].get("offset") == offset,
              f"连接器收到的 fsGetBegin.offset={begins[0].get('offset') if begins else None}")
        check(begins and begins[0].get("replaces") == "app-range",
              "中转把 App 的 bid 作为 replaces 传给连接器，自己另铸新 bid")
        check(begins and begins[0].get("bid") != "app-range",
              "fsGetBegin.bid 是中转现铸的，不是 App 带入的")
        steps.append({
            "name": "range resume",
            "ok": True,
            "ms": round(elapsed * 1000, 1),
            "offset": offset,
            "sha256": digest_bytes(joined),
            "contentRange": headers.get("content-range"),
            "frames": frame_summary(frames),
        })

        # If-Range：ETag 未变继续续传；变了必须从 0 回整份（只改状态行会让正文缺开头）。
        mark = len(recorder.frames)
        started = time.monotonic()
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=120)) as session:
            async with session.get(
                    f"{public}/files/down?scopeId={scope_id}&path={quote_path(item['path'])}",
                    headers={**device_headers, "Range": f"bytes={offset}-",
                             "If-Range": downloads[size]["etag"]}) as response:
                keep = await response.read()
                keep_status = response.status
        check(keep_status == 206 and digest_bytes(body[:offset] + keep) == item["expected"],
              "If-Range 命中同一 ETag：仍从 offset 续传，拼接后哈希一致")
        mark = len(recorder.frames)
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=120)) as session:
            async with session.get(
                    f"{public}/files/down?scopeId={scope_id}&path={quote_path(item['path'])}",
                    headers={**device_headers, "Range": f"bytes={offset}-",
                             "If-Range": '"dsh-stale-version-1"'}) as response:
                restarted = await response.read()
                restarted_status = response.status
                restarted_headers = lower_headers(response)
        frames = recorder.since(mark)
        begins = [f for f in frames if f["t"] == "fsGetBegin"]
        check(restarted_status == 200 and restarted == body,
              "If-Range 与当前 ETag 不符：回 200 + 整份正文")
        check(len(begins) == 2 and begins[1].get("offset") == 0,
              "ETag 变化时中转放弃旧 run 并以 offset=0 重开 fetch")
        check(any(f["t"] == "fsGetCancel" for f in frames),
              "重开前叫停了旧的 fetch run")
        steps.append({
            "name": "if-range etag",
            "ok": True,
            "ms": round((time.monotonic() - started) * 1000, 1),
            "sameEtagStatus": keep_status,
            "staleEtagStatus": restarted_status,
            "frames": frame_summary(frames),
        })


        # ── 4. 客户端中断后带 Range 重试 ────────────────────────────────────
        needle = min(1_500_000, size // 3)
        mark = len(recorder.frames)
        started = time.monotonic()
        interrupted = await raw_interrupt_download(
            port, f"{BASE_PATH}/files/down?scopeId={scope_id}"
                  f"&path={quote_path(item['path'])}&bid=app-interrupted",
            claimed["deviceToken"], needle)
        check(interrupted["status"] == 200, "中断前的响应状态行是 200")
        check(0 < interrupted["received"] < size,
              f"客户端只收到 {interrupted['received']} 字节就被中断")
        cancel = await recorder.wait_for(
            lambda frame: frame["t"] == "fsGetCancel"
            and frame["dir"] == "relay→connector", 10.0)
        check(cancel is not None,
              "中断后中转向连接器发了 fsGetCancel（停止为没人读的下载继续读）")
        # 中断点必须落在文件的前缀上：拿完整正文的同一段比对（`Range: bytes=0-N`
        # 不被中转接受，它只认 `bytes=N-`，见 files.parseRange）。
        partial = body[:needle]
        check(digest_bytes(partial) == interrupted["sha256Prefix"],
              "中断时收到的前 N 字节与文件前缀一致（中断点可信）")

        mark2 = len(recorder.frames)
        resumed_started = time.monotonic()
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=300)) as session:
            async with session.get(
                    f"{public}/files/down?scopeId={scope_id}&path={quote_path(item['path'])}&bid=app-resumed",
                    headers={**device_headers, "Range": f"bytes={needle}-"}) as response:
                resumed = await response.read()
                resumed_status = response.status
                resumed_headers = lower_headers(response)
        resumed_elapsed = round(time.monotonic() - resumed_started, 3)
        check(resumed_status == 206, "中断后的 Range 重试返回 206")
        check(resumed_headers.get("content-range")
              == f"bytes {needle}-{size - 1}/{size}",
              f"重试的 Content-Range={resumed_headers.get('content-range')}")
        check(digest_bytes(partial + resumed) == item["expected"],
              "中断前收到的字节 + 续传正文拼接后 SHA-256 一致")
        steps.append({
            "name": "interrupt + range retry",
            "ok": True,
            "ms": round((time.monotonic() - started) * 1000, 1),
            "interruptAt": interrupted["received"],
            "cancelSeen": True,
            "resumeMs": round(resumed_elapsed * 1000, 1),
            "sha256": digest_bytes(partial + resumed),
            "frames": frame_summary(recorder.since(mark)),
        })

        # ── 5. 上传请求体截断后重试 ─────────────────────────────────────────
        # 声明一个大文件、只发 1.5 MB：让**第一片真的到达连接器**（fopen 已发生），
        # 才能在 lsof 里看到中断上传留下的资源。
        truncated_size = max(sizes)
        truncated_name = "m8-truncated.bin"
        truncated_bid = f"app-truncated-{int(time.time() * 1000)}"
        before = set(inbox_root.rglob("*")) if inbox_root.exists() else set()
        await raw_interrupt_upload(
            port,
            f"{BASE_PATH}/files/up?sessionId={upload_session}&name={truncated_name}"
            f"&bid={truncated_bid}&bytes={truncated_size}",
            claimed["deviceToken"], truncated_size, min(1_500_000, truncated_size - 1))
        await asyncio.sleep(1.0)
        truncated_path = inbox_root / upload_session / truncated_name
        fds_after_truncate = connector_open_files(connector.pid, "m8-truncated.bin")
        check(not truncated_path.exists(),
              "截断的上传没有留下最终文件名（半截文件不会被当成完整文件）")
        leftover = sorted(str(path.relative_to(inbox_root))
                          for path in (inbox_root / upload_session).glob(".*.part"))
        retry_mark = len(recorder.frames)
        retry_started = time.monotonic()
        retry_content = random.Random(truncated_size + 1).randbytes(truncated_size)
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=120)) as session:
            async with session.put(
                    f"{public}/files/up?sessionId={upload_session}&name={truncated_name}"
                    f"&bid={truncated_bid}-retry&bytes={truncated_size}",
                    data=retry_content, headers=device_headers) as response:
                retried = await response.json()
        check(response.status == 200 and digest_file(pathlib.Path(retried["path"]))
              == digest_bytes(retry_content),
              "截断后用新 bid 重传成功，落盘 SHA-256 一致")
        fds_after_retry = connector_open_files(connector.pid, "m8-truncated.bin")
        steps.append({
            "name": "upload truncated + retry",
            "ok": True,
            "ms": round((time.monotonic() - retry_started) * 1000, 1),
            "leftoverParts": leftover,
            "connectorOpenFilesAfterTruncate": fds_after_truncate,
            "connectorOpenFilesAfterRetry": fds_after_retry,
            "frames": frame_summary(recorder.since(retry_mark)),
        })

        # ── 6. 隔离与清理证据 ───────────────────────────────────────────────
        recorder.dump(workdir / "frames.jsonl")
        result["frameCounts"] = count_frames(recorder.frames)
        result["proxyConnections"] = recorder.connections
        result["scopeDigest"] = {
            "sessionUnchanged": (tree_digest(scope["sessionDir"])
                                 if scope.get("sessionDir") else None) == scope_before,
            "cacheUnchanged": (tree_digest(scope["cachePath"])
                               if scope.get("cachePath") else None) == cache_before,
        }
        real_mobile_link = DSH_HOME / "mobile-link"
        real_inbox = DSH_HOME / "inbox"
        result["realDshWrites"] = {
            "mobile-link": recently_touched(real_mobile_link, started_at),
            "inbox": recently_touched(real_inbox, started_at)[:10],
        }
        result["connectorJournal"] = str(dsh_home / "mobile-link" / "link-events.jsonl")
        result["connectorJournalExists"] = (dsh_home / "mobile-link" / "link-events.jsonl").exists()
        result["agentJsonUnchanged"] = digest_file(REAL_AGENT_FILE) == agent_before
        result["endpointJsonUnchanged"] = digest_file(ENDPOINT_FILE) == endpoint_before
        check(result["agentJsonUnchanged"] is True,
              "真实 ~/.dsh/mobile-link/agent.json 未被改写")
        check(result["scopeDigest"]["sessionUnchanged"] is True,
              "所选会话目录在联调前后摘要一致（只作 scopeId，未被读写）")
        result["inboxRoot"] = str(inbox_root)
        parent = pathlib.Path(tempfile.gettempdir())
        result["tempDirsLeftover"] = sorted(
            str(path.name) for path in parent.glob("m8-files-*")
            if path.resolve() != workdir.resolve())
    finally:
        if connector is not None and connector.poll() is None:
            connector.terminate()
            try:
                connector.wait(10)
            except subprocess.TimeoutExpired:
                connector.kill()
                connector.wait(5)
        if relay.poll() is None:
            relay.terminate()
            try:
                relay.wait(10)
            except subprocess.TimeoutExpired:
                relay.kill()
                relay.wait(5)
        if proxy_server is not None:
            proxy_server.close()
            await proxy_server.wait_closed()
        recorder.dump(workdir / "frames.jsonl")
        result["portsReleased"] = {
            "relay": port_closed(port),
            "proxy": port_closed(proxy_port) if proxy_port else None,
        }
        result["processesExited"] = {
            "connector": connector is None or connector.poll() is not None,
            "relay": relay.poll() is not None,
        }
        # 日志里的错误行，用于判断是 Go 还是连接器的问题
        errors, warnings, versions = scan_logs(connector_log, relay_log)
        result["errors"] = errors
        result["warnings"] = warnings
        result["versions"] = versions
        result["connectorLog"] = str(connector_log)
        result["relayLog"] = str(relay_log)


async def pick_scope(ws, workdir: pathlib.Path) -> dict:
    """经真实连接器挑一条**空闲、非子代理**的会话作为 scopeId。

    只把它当授权凭据：不读会话内容、不 follow、不写。挑完记录它所在目录的摘要。
    """
    await ws.send_str(json.dumps({"t": "req", "id": "scope", "method": "session/list",
                                  "args": {"_request": {}}}))
    deadline = time.monotonic() + STEP_TIMEOUT
    while True:
        message = await asyncio.wait_for(ws.receive(), deadline - time.monotonic())
        if message.type != aiohttp.WSMsgType.TEXT:
            raise StepFailure("等待 session/list 时收到非文本帧")
        frame = json.loads(message.data)
        if frame.get("t") == "res" and frame.get("id") == "scope":
            break
    check(frame.get("ok") is True, "session/list 经真实连接器成功")
    items = frame.get("value", {}).get("items", [])
    candidates = [item for item in items
                  if not item.get("running") and not item.get("parentSessionId")
                  and item.get("cwd")]
    if not candidates:
        raise StepFailure("没有可用于 scopeId 的空闲会话")
    item = candidates[0]
    session_id = item["sessionId"]
    cwd = item["cwd"]
    session_dir = None
    for group in (DSH_HOME / "sessions").glob("*"):
        candidate = group / session_id
        if candidate.exists():
            session_dir = candidate
            break
    cache_path = DSH_HOME / "storages" / "session_projcache" / "sessions" / f"{session_id}.json"
    return {
        "sessionId": session_id,
        "cwd": cwd,
        "running": item.get("running"),
        "reason": "空闲、非子代理；只作 workspaceFileScopeId",
        "sessionDir": session_dir,
        "cachePath": cache_path if cache_path.exists() else None,
    }


def lower_headers(response) -> dict[str, str]:
    """HTTP 头大小写不敏感：Go 把 ETag 规范化成 Etag，按小写取。"""
    return {key.lower(): value for key, value in response.headers.items()}


def quote_path(path: pathlib.Path) -> str:
    from urllib.parse import quote
    return quote(str(path), safe="")


def frame_summary(frames: list[dict]) -> dict:
    """给报告用的帧序列摘要：种类计数 + 关键帧。"""
    counts: dict[str, int] = {}
    for frame in frames:
        key = f"{frame['dir']}:{frame['t']}"
        counts[key] = counts.get(key, 0) + 1
    chunks = [frame for frame in frames
              if frame["t"] in ("fsPutChunk", "fsGetChunk")]
    order = [f"{frame['dir']}:{frame['t']}" for frame in frames
             if frame["t"] in ("fsPutBegin", "fsPutAck", "fsPutEnd", "fsPutDone",
                               "fsGetBegin", "fsGetAck", "fsGetEnd", "fsGetCancel",
                               "fsErr")]
    return {
        "counts": counts,
        "chunks": len(chunks),
        "chunkBytes": sum(frame.get("dataBytes", 0) for frame in chunks),
        "firstChunkAt": chunks[0]["at"] if chunks else None,
        "lastChunkAt": chunks[-1]["at"] if chunks else None,
        "control": order,
    }


def count_frames(frames: list[dict]) -> dict:
    counts: dict[str, int] = {}
    for frame in frames:
        key = f"{frame['dir']}:{frame['t']}"
        counts[key] = counts.get(key, 0) + 1
    return counts


def port_closed(port: int) -> bool:
    """端口上没人监听：连接被拒即释放（bind 会被 TIME_WAIT 误判为占用）。"""
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.3):
            return False
    except OSError:
        return True


def connector_open_files(pid: int, needle: str) -> list[str] | None:
    """连接器进程里打开着、路径含 needle 的文件（lsof 不可用返回 None）。"""
    try:
        result = subprocess.run(["lsof", "-p", str(pid), "-Fn"],
                                capture_output=True, text=True, timeout=5, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    opened = []
    for line in result.stdout.splitlines():
        if line.startswith("n") and needle in line:
            opened.append(line[1:])
    return opened


def recently_touched(root: pathlib.Path, since: float) -> list[str]:
    """列出 since 之后被修改的路径（隔离证据：真实 ~/.dsh 有没有被动过）。"""
    if not root.exists():
        return []
    hits: list[str] = []
    for entry in root.rglob("*"):
        try:
            stat = entry.stat()
        except OSError:
            continue
        if stat.st_mtime >= since:
            hits.append(str(entry))
        if len(hits) >= 20:
            break
    return hits


def scan_logs(connector_log: pathlib.Path, relay_log: pathlib.Path):
    errors: list[str] = []
    warnings: list[str] = []
    versions: dict[str, str] = {}
    for path, label in ((connector_log, "connector"), (relay_log, "relay")):
        if not path.exists():
            continue
        for line in path.read_text(errors="replace").splitlines():
            if "agent reports its versions" in line:
                try:
                    parsed = json.loads(line)
                    versions["connector"] = parsed.get("connector", "")
                    versions["host"] = parsed.get("host", "")
                except json.JSONDecodeError:
                    pass
            if "[error]" in line or '"level":"ERROR"' in line:
                errors.append(f"{label}: {line}"[:400])
            elif "[warn]" in line or '"level":"WARN"' in line:
                warnings.append(f"{label}: {line}"[:400])
    return errors, warnings, versions


def main() -> int:
    parser = argparse.ArgumentParser(description="M8 文件通道真连接器联调")
    parser.add_argument("--evidence", type=pathlib.Path, default=None)
    parser.add_argument("--keep", action="store_true")
    parser.add_argument("--sizes", default="1048576,10485760")
    args = parser.parse_args()
    sizes = [int(value) for value in args.sizes.split(",") if value.strip()]
    if not RELAY.exists():
        print(f"缺少 {RELAY}，先 cd relay-go && make build", file=sys.stderr)
        return 2
    started = time.monotonic()
    workdir = pathlib.Path(tempfile.mkdtemp(prefix="m8-files-"))
    result: dict = {}
    try:
        asyncio.run(run(workdir, sizes, result))
        result["elapsedSeconds"] = round(time.monotonic() - started, 2)
        log(f"PASSED in {result['elapsedSeconds']}s")
        print(json.dumps({key: value for key, value in result.items()
                          if key not in ("steps", "errors", "warnings")},
                         ensure_ascii=False, indent=2)[:4000])
        for entry in result["steps"]:
            print(f"  step {entry['name']:<28} {entry['ms']:>9.1f} ms  "
                  f"{json.dumps({k: v for k, v in entry.items() if k not in ('name', 'ms', 'ok', 'frames')}, ensure_ascii=False)[:200]}")
        return 0
    except StepFailure as error:
        log(f"FAILED: {error}")
        for path in workdir.glob("*.log"):
            tail = "\n".join(path.read_text(errors="replace").splitlines()[-30:])
            print(f"--- {path.name} tail ---\n{tail}", file=sys.stderr)
        result["failed"] = str(error)
        return 1
    finally:
        if args.evidence is not None:
            args.evidence.mkdir(parents=True, exist_ok=True)
            for path in workdir.glob("*.log"):
                (args.evidence / path.name).write_text(
                    redact_text(path.read_text(errors="replace")))
            frames = workdir / "frames.jsonl"
            if frames.exists():
                (args.evidence / "frames.jsonl").write_text(
                    redact_text(frames.read_text(errors="replace")))
            (args.evidence / "result.json").write_text(
                json.dumps(result, ensure_ascii=False, indent=2))
            log(f"evidence → {args.evidence}")
        if not args.keep:
            shutil.rmtree(workdir, ignore_errors=True)
        else:
            log(f"workdir kept: {workdir}")


if __name__ == "__main__":
    raise SystemExit(main())
