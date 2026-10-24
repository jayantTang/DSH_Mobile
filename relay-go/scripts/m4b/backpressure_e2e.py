#!/usr/bin/env python3
"""M4b 任务 2：慢客户端 / 背压的进程级证据。

构造：
  * 一台**完全不读**的设备 A（原始 TCP 完成 WS 握手后不再 recv）；
  * 一台正常读的设备 B；
  * 一个 agent 桩（aiohttp WS），向 A 灌 `item`（流式帧），再发 `err`（控制帧）。
  * relay 用 `--queue-depth 8 --queue-bytes 32768` 把队列压小，几十帧即可填满。

断言：
  1. `/stats` 里 A 的 `droppedFrames` 增长（流式帧按设计丢弃并计数）；
  2. 控制帧撞上满队列 → A 被 4008 关闭（原始字节里解析 close 帧；拿不到就用 relay
     日志的 "device send queue is full" 作为同级证据，报告里写明边界）；
  3. 同一台电脑上的正常设备 B 不受影响：灌 A 期间与 A 被关闭之后，B 都能继续收到帧。

证据边界：这里的 agent 是桩，不是真实连接器。真实连接器链路见
`real_connector_e2e.py`；Go 单测 `internal/hub/hub_test.go`（"慢连接按 4008 断开"）
覆盖帧分类与关闭码的单元级行为。

用法：
  .venv/bin/python relay-go/scripts/m4b/backpressure_e2e.py
"""

from __future__ import annotations

import asyncio
import base64
import inspect
import json
import os
import pathlib
import shutil
import socket
import ssl  # noqa: F401  (保留给未来 wss；当前只跑明文回环)
import struct
import subprocess
import sys
import tempfile
import time

import aiohttp
from aiohttp import WSMsgType

ROOT = pathlib.Path(__file__).resolve().parents[3]
RELAY = ROOT / "relay-go" / "bin" / "dsh-relay"
BASE_PATH = "/dsh-link"
QUEUE_DEPTH = 8
QUEUE_BYTES = 32768
FRAME_TEXT = "x" * 4096
STEP_TIMEOUT = 20.0


class StepFailure(AssertionError):
    pass


def log(message: str) -> None:
    print(f"[m4b-backpressure] {message}", flush=True)


def check(condition: bool, message: str) -> None:
    if not condition:
        raise StepFailure(message)
    log(f"ok: {message}")


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


def run_admin(db: str, *args: str) -> dict | list:
    result = subprocess.run([str(RELAY), "admin", "--db", db, *args],
                            capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise StepFailure(f"admin {' '.join(args)} 失败: {result.stderr.strip()}")
    return json.loads(result.stdout)


def parse_close_codes(buffer: bytes) -> list[int]:
    """从服务器→客户端的原始 WS 字节里找 close 帧（服务端帧不掩码）。"""
    codes: list[int] = []
    index = 0
    while index + 2 <= len(buffer):
        first, second = buffer[index], buffer[index + 1]
        opcode = first & 0x0F
        masked = bool(second & 0x80)
        length = second & 0x7F
        index += 2
        if length == 126:
            if index + 2 > len(buffer):
                break
            length = int.from_bytes(buffer[index:index + 2], "big")
            index += 2
        elif length == 127:
            if index + 8 > len(buffer):
                break
            length = int.from_bytes(buffer[index:index + 8], "big")
            index += 8
        if masked:
            index += 4
        if index + length > len(buffer):
            break
        payload = buffer[index:index + length]
        index += length
        if opcode == 0x8 and len(payload) >= 2:
            codes.append(int.from_bytes(payload[:2], "big"))
    return codes


class SlowDevice:
    """完成握手后不再读的原始设备。"""

    def __init__(self, host: str, port: int, path: str, token: str) -> None:
        self.sock = socket.create_connection((host, port), timeout=5)
        key = base64.b64encode(os.urandom(16)).decode()
        request = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host}:{port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            f"Authorization: Bearer {token}\r\n\r\n"
        )
        self.sock.sendall(request.encode())
        self.buffer = b""
        deadline = time.monotonic() + 5
        while b"\r\n\r\n" not in self.buffer:
            if time.monotonic() > deadline:
                raise StepFailure("慢设备 WS 握手超时")
            chunk = self.sock.recv(65536)
            if not chunk:
                raise StepFailure("慢设备 WS 握手被关闭")
            self.buffer += chunk
        head, _, rest = self.buffer.partition(b"\r\n\r\n")
        self.status_line = head.split(b"\r\n", 1)[0].decode(errors="replace")
        self.buffer = rest
        if "101" not in self.status_line:
            raise StepFailure(f"慢设备 WS 握手失败: {self.status_line}")

    def read_remaining(self, seconds: float = 5.0) -> list[int]:
        deadline = time.monotonic() + seconds
        self.sock.settimeout(0.5)
        while time.monotonic() < deadline:
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                continue
            except OSError:
                break
            if not chunk:
                break
            self.buffer += chunk
        codes = parse_close_codes(self.buffer)
        self.sock.close()
        return codes


async def wait_for(predicate, description: str, timeout: float = STEP_TIMEOUT, interval: float = 0.05):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        value = predicate()
        last = await value if inspect.isawaitable(value) else value
        if last:
            return last
        await asyncio.sleep(interval)
    raise StepFailure(f"等待超时：{description}（最后观察 {last!r}）")


async def fetch_stats(session: aiohttp.ClientSession, base: str) -> dict:
    async with session.get(f"{base}/stats") as response:
        return await response.json()


def device_row(stats: dict, device_id: str) -> dict | None:
    for row in stats["snapshot"]["devices"]:
        if row["deviceId"] == device_id:
            return row
    return None


async def run(workdir: pathlib.Path) -> dict:
    db = str(workdir / "state.db")
    port = free_port()
    base = f"http://127.0.0.1:{port}"
    public = f"{base}{BASE_PATH}"
    ws_base = f"ws://127.0.0.1:{port}{BASE_PATH}"
    relay_log = workdir / "relay.log"
    relay = subprocess.Popen(
        [str(RELAY), "serve", "--port", str(port), "--db", db,
         "--base-path", BASE_PATH, "--queue-depth", str(QUEUE_DEPTH),
         "--queue-bytes", str(QUEUE_BYTES), "--log-level", "debug"],
        stdout=relay_log.open("w"), stderr=subprocess.STDOUT, cwd=str(workdir))
    slow: SlowDevice | None = None
    result: dict = {}
    try:
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=STEP_TIMEOUT)) as session:
            async def healthy() -> bool:
                try:
                    async with session.get(f"{base}/healthz") as response:
                        return response.status == 200
                except aiohttp.ClientError:
                    return False
            await wait_for(healthy, "Go relay 起来", timeout=20)

            account = run_admin(db, "account-create", "--name", "M4b 背压")
            agent = run_admin(db, "agent-register", "--account", account["accountId"],
                              "--name", "M4b 背压 Mac", "--relay", ws_base)

            devices = []
            for label in ("DSH-M4b-Slow", "DSH-M4b-Normal"):
                minted = run_admin(db, "code-mint", "--agent", agent["agentId"],
                                   "--ttl-seconds", "120")
                async with session.post(f"{public}/pair/claim", json={
                    "pairCode": minted["code"], "deviceName": label,
                    "deviceModel": "iPhone17,1", "appVersion": "1.0.0",
                }) as response:
                    claimed = await response.json()
                if response.status != 200 or not claimed.get("ok"):
                    raise StepFailure(f"认领 {label} 失败: {claimed}")
                devices.append(claimed)
            slow_claim, normal_claim = devices

            # agent 桩先连上，等两台设备的 deviceAttach。
            agent_ws = await session.ws_connect(
                f"{ws_base}/link/agent?agentId={agent['agentId']}",
                headers={"Authorization": f"Bearer {agent['agentSecret']}"})
            attached: set[str] = set()

            async def pump_agent() -> None:
                while True:
                    message = await agent_ws.receive()
                    if message.type != WSMsgType.TEXT:
                        return
                    frame = json.loads(message.data)
                    if frame.get("t") == "deviceAttach":
                        attached.add(frame.get("deviceId"))

            agent_reader = asyncio.create_task(pump_agent())

            # 慢设备：原始 socket 握手后不读。
            slow = SlowDevice("127.0.0.1", port,
                              f"{BASE_PATH}/link/device?agentId={agent['agentId']}",
                              slow_claim["deviceToken"])
            # 正常设备：aiohttp，持续读。
            normal_ws = await session.ws_connect(
                f"{ws_base}/link/device?agentId={agent['agentId']}",
                headers={"Authorization": f"Bearer {normal_claim['deviceToken']}"})
            normal_frames: list[dict] = []

            async def pump_normal() -> None:
                while True:
                    message = await normal_ws.receive()
                    if message.type != WSMsgType.TEXT:
                        return
                    normal_frames.append(json.loads(message.data))

            normal_reader = asyncio.create_task(pump_normal())

            await wait_for(lambda: _attached_both(attached, slow_claim, normal_claim),
                           "两台设备都出现在 agent 的 deviceAttach 里")
            await wait_for(lambda: _has_host_status(normal_frames),
                           "正常设备收到 hostStatus")

            # ── 1. 向慢设备灌流式帧 ─────────────────────────────────────────
            flooded = 0
            flood_started = time.monotonic()
            for index in range(2000):
                frame = {"t": "item", "id": f"a-{index}",
                         "value": {"type": "text", "text": FRAME_TEXT},
                         "deviceId": slow_claim["deviceId"]}
                await agent_ws.send_str(json.dumps(frame))
                flooded += 1
                if index % 200 == 199:
                    await asyncio.sleep(0)  # 让出事件循环，relay 才能读走
            flood_seconds = time.monotonic() - flood_started

            # 正常设备在同一时段收 5 帧（间隔发，避免它自己也撞上小队列）。
            normal_before = len(normal_frames)
            for index in range(5):
                await agent_ws.send_str(json.dumps({
                    "t": "item", "id": f"b-{index}",
                    "value": {"type": "text", "text": FRAME_TEXT},
                    "deviceId": normal_claim["deviceId"]}))
                await asyncio.sleep(0.03)

            async def slow_drops() -> dict | None:
                stats = await fetch_stats(session, base)
                row = device_row(stats, slow_claim["deviceId"])
                if row and row["droppedFrames"] > 0:
                    return row
                return None

            dropped_row = await wait_for(slow_drops, "慢设备的 droppedFrames 增长", timeout=10)
            check(dropped_row["droppedFrames"] > 0,
                  f"慢设备流式帧被丢弃并计数：droppedFrames={dropped_row['droppedFrames']}")

            # 正常设备在这段时间里必须照常收帧。
            await wait_for(lambda: len(normal_frames) - normal_before >= 5,
                           "灌慢设备期间正常设备收到 5 帧", timeout=10)
            check(True, f"同日另一台设备收到 {len(normal_frames) - normal_before} 帧，未被拖住")

            # ── 2. 控制帧撞满队列 → 4008 ────────────────────────────────────
            for index in range(30):
                await agent_ws.send_str(json.dumps({
                    "t": "err", "id": f"e-{index}",
                    "error": {"code": "test/overload", "message": "fill"},
                    "deviceId": slow_claim["deviceId"]}))
                await asyncio.sleep(0.01)

            async def slow_gone() -> bool:
                stats = await fetch_stats(session, base)
                return device_row(stats, slow_claim["deviceId"]) is None

            await wait_for(slow_gone, "慢设备被 relay 摘掉", timeout=10)
            check(True, "控制帧进不了满队列后，relay 把慢设备断开")

            # 正常设备仍然在线、还能收帧。
            await agent_ws.send_str(json.dumps({
                "t": "item", "id": "b-after",
                "value": {"type": "text", "text": FRAME_TEXT},
                "deviceId": normal_claim["deviceId"]}))
            await wait_for(lambda: any(f.get("id") == "b-after" for f in normal_frames),
                           "慢设备被断开后正常设备仍能收帧", timeout=10)
            check(True, "慢设备断开后，正常设备继续工作")

            stats = await fetch_stats(session, base)
            result.update({
                "framesFlooded": flooded,
                "floodSeconds": round(flood_seconds, 3),
                "slowDroppedFrames": dropped_row["droppedFrames"],
                "slowQueuedBytesAtSample": dropped_row["queuedBytes"],
                "normalFramesDuringFlood": len(normal_frames) - normal_before,
                "relayLoadDevicesAfterClose": stats["load"]["devices"],
                "limits": {"queueDepth": QUEUE_DEPTH, "queueBytes": QUEUE_BYTES},
            })

            agent_reader.cancel()
            normal_reader.cancel()
            await asyncio.gather(agent_reader, normal_reader, return_exceptions=True)
            await agent_ws.close()
            await normal_ws.close()
    finally:
        if slow is not None:
            result.setdefault("closeCodes", slow.read_remaining(5.0))
        if relay.poll() is None:
            relay.terminate()
            try:
                relay.wait(10)
            except subprocess.TimeoutExpired:
                relay.kill()
                relay.wait(5)

        log_lines = relay_log.read_text(errors="replace").splitlines() if relay_log.exists() else []
        result["sawDeviceDroppedLog"] = any(
            "device send queue is full; dropping the device" in line for line in log_lines)
        result["sawStreamDropLog"] = any(
            "dropped a stream frame for a slow device" in line for line in log_lines)
        result["closeCodes"] = result.get("closeCodes", [])
        result["closeCode4008Seen"] = 4008 in result["closeCodes"]
    return result


def _attached_both(attached: set[str], slow: dict, normal: dict) -> bool:
    return slow["deviceId"] in attached and normal["deviceId"] in attached


def _has_host_status(frames: list[dict]) -> bool:
    return any(frame.get("t") == "hostStatus" for frame in frames)


def main() -> int:
    if not RELAY.exists():
        print(f"缺少 {RELAY}，先 cd relay-go && make build", file=sys.stderr)
        return 2
    started = time.monotonic()
    workdir = pathlib.Path(tempfile.mkdtemp(prefix="m4b-backpressure-"))
    try:
        result = asyncio.run(run(workdir))
        # 4008 的两种证据合并判定：原始 close 帧 > relay 日志里的断开日志。
        ok = result.get("closeCode4008Seen") or result.get("sawDeviceDroppedLog")
        result["verdict"] = "pass" if ok and result.get("slowDroppedFrames", 0) > 0 else "fail"
        log(f"{result['verdict'].upper()} in {time.monotonic() - started:.2f}s")
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0 if result["verdict"] == "pass" else 1
    except StepFailure as error:
        log(f"FAILED: {error}")
        for path in workdir.glob("*.log"):
            tail = "\n".join(path.read_text(errors="replace").splitlines()[-30:])
            print(f"--- {path.name} tail ---\n{tail}", file=sys.stderr)
        return 1
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
