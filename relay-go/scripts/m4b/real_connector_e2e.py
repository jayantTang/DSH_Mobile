#!/usr/bin/env python3
"""M4b 任务 1：真实连接器 → Go relay → 本机 dsh 的只读联调。

链路：真实 `plugins/mobile-link/lib/cli.js`（连接器）连临时 Go relay，
      本机 dsh 地址从 `~/.dsh/mobile-link/endpoint.json` 读取（只读，不打印 token）。
假设备：RLP 设备 WebSocket，只做三件只读调用——`session/list`、`$events`、
      `session/follow` + `cancel`。

安全：
  * 临时库、随机端口、临时 status-file，不写 `~/.dsh/mobile-link/agent.json`；
  * 结束时 SIGTERM 连接器与 relay，删临时目录，校验真实 agent.json 未变化。

用法：
  .venv/bin/python relay-go/scripts/m4b/real_connector_e2e.py
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import os
import pathlib
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from collections import deque

import aiohttp
from aiohttp import WSMsgType

ROOT = pathlib.Path(__file__).resolve().parents[3]
RELAY = ROOT / "relay-go" / "bin" / "dsh-relay"
CONNECTOR_DIR = ROOT / "plugins" / "mobile-link"
CLI = CONNECTOR_DIR / "lib" / "cli.js"
DSH_HOME = pathlib.Path(os.environ.get("DSH_HOME", pathlib.Path.home() / ".dsh"))
ENDPOINT_FILE = DSH_HOME / "mobile-link" / "endpoint.json"
REAL_AGENT_FILE = DSH_HOME / "mobile-link" / "agent.json"
BASE_PATH = "/dsh-link"
STEP_TIMEOUT = 30.0


class StepFailure(AssertionError):
    pass


def log(message: str) -> None:
    print(f"[m4b-real] {message}", flush=True)


def check(condition: bool, message: str) -> None:
    if not condition:
        raise StepFailure(message)
    log(f"ok: {message}")


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


def redacted(url: str) -> str:
    """只在日志里露主机与端口，token 永远不进报告。"""
    if "token=" in url:
        return url.split("token=", 1)[0] + "token=<redacted>"
    return url


def digest(path: pathlib.Path) -> str | None:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError:
        return None


def run_admin(db: str, *args: str) -> dict | list:
    result = subprocess.run([str(RELAY), "admin", "--db", db, *args],
                            capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise StepFailure(f"admin {' '.join(args)} 失败: {result.stderr.strip() or result.stdout.strip()}")
    return json.loads(result.stdout)


class FrameReader:
    """保留没被本步消费的帧——隧道是异步的，控制帧可以插在任意两步之间。"""

    def __init__(self, ws):
        self.ws = ws
        self.buffer: list[dict] = []
        self.seen: list[dict] = []

    def __repr__(self) -> str:
        return " | ".join(json.dumps(frame)[:180] for frame in self.seen[-6:])

    def take(self, predicate):
        for index, frame in enumerate(self.buffer):
            if predicate(frame):
                return self.buffer.pop(index)
        return None

    async def until(self, predicate, timeout: float = STEP_TIMEOUT) -> tuple[dict, int]:
        buffered = self.take(predicate)
        if buffered is not None:
            return buffered, len(self.seen)
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise StepFailure(f"等待帧超时，已见到: {self!r}")
            message = await asyncio.wait_for(self.ws.receive(), remaining)
            if message.type != WSMsgType.TEXT:
                raise StepFailure(f"期望文本帧，收到 {message.type}: {message!r}")
            frame = json.loads(message.data)
            self.seen.append(frame)
            if predicate(frame):
                return frame, len(self.seen)
            self.buffer.append(frame)

    async def drain(self, seconds: float) -> list[dict]:
        """在窗口内收帧并返回这段窗口新收到的全部帧。"""
        fresh: list[dict] = []
        deadline = time.monotonic() + seconds
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return fresh
            try:
                message = await asyncio.wait_for(self.ws.receive(), remaining)
            except asyncio.TimeoutError:
                return fresh
            if message.type != WSMsgType.TEXT:
                return fresh
            frame = json.loads(message.data)
            self.seen.append(frame)
            fresh.append(frame)


def is_ready(frame: dict) -> bool:
    if frame.get("t") not in ("event", "item"):
        return False
    value = frame.get("value")
    return isinstance(value, dict) and value.get("type") == "ready"


def pick_followable(sessions: list[dict]) -> tuple[dict | None, dict | None]:
    candidates = [item for item in sessions
                  if not item.get("running") and not item.get("parentSessionId")]
    if not candidates:
        candidates = [item for item in sessions if not item.get("running")]
    if not candidates:
        return None, None
    item = candidates[0]
    session_id = item["sessionId"]
    if item.get("parentSessionId"):
        address = {"kind": "subagent", "parentSessionId": item["parentSessionId"],
                   "childSessionId": session_id, "mode": "continuable"}
    else:
        address = {"kind": "session", "sessionId": session_id}
    return item, address


def local_session_ids() -> set[str]:
    """本机 dsh 的会话目录名（只读）。用来证明 `session/list` 返回的是真实会话。"""
    ids: set[str] = set()
    root = DSH_HOME / "sessions"
    try:
        for path in root.glob("*/session-*"):
            ids.add(path.name)
    except OSError:
        return ids
    return ids


async def wait_status(path: pathlib.Path, predicate, timeout: float = 30.0) -> dict:
    deadline = time.monotonic() + timeout
    last: dict | None = None
    while time.monotonic() < deadline:
        try:
            last = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            last = None
        if isinstance(last, dict) and predicate(last):
            return last
        await asyncio.sleep(0.1)
    raise StepFailure(f"连接器状态未达预期，最后一份: {last}")


async def run(workdir: pathlib.Path) -> dict:
    agent_before = digest(REAL_AGENT_FILE)
    endpoint = json.loads(ENDPOINT_FILE.read_text())
    dsh_url = endpoint["url"]
    log(f"本机 dsh: {redacted(dsh_url)} (source={endpoint.get('source')})")

    db = str(workdir / "state.db")
    port = free_port()
    base = f"http://127.0.0.1:{port}"
    public = f"{base}{BASE_PATH}"
    relay_url = f"ws://127.0.0.1:{port}{BASE_PATH}"
    relay_log = workdir / "relay.log"
    connector_log = workdir / "connector.log"
    status_file = workdir / "agent-status.json"
    state_file = workdir / "agent-identity.json"
    # 连接器的日志流水与 handoff 文件也落在临时 DSH_HOME：真实 ~/.dsh 一个字节都不写。
    dsh_home = workdir / "dsh-home"
    (dsh_home / "mobile-link").mkdir(parents=True, exist_ok=True)

    relay = subprocess.Popen(
        [str(RELAY), "serve", "--port", str(port), "--db", db,
         "--base-path", BASE_PATH, "--log-level", "debug"],
        stdout=relay_log.open("w"), stderr=subprocess.STDOUT, cwd=str(workdir))
    connector: subprocess.Popen | None = None
    result: dict = {}

    try:
        # ── 1. relay 健康检查（带前缀与不带前缀） ───────────────────────────
        async with aiohttp.ClientSession() as session:
            deadline = time.monotonic() + 20
            while True:
                try:
                    async with session.get(f"{base}/healthz") as response:
                        health = await response.json()
                    async with session.get(f"{public}/healthz") as prefixed:
                        prefixed_health = await prefixed.json()
                    break
                except (aiohttp.ClientError, asyncio.TimeoutError):
                    if time.monotonic() > deadline:
                        raise StepFailure("Go relay 20 秒内没有起来")
                    await asyncio.sleep(0.1)
        check(health.get("ok") is True and prefixed_health == health,
              f"Go relay /healthz 与 {BASE_PATH}/healthz 都返回 ok")

        # ── 2. Go admin 建账户/电脑 + 配对码 + 假设备认领 ────────────────────
        account = run_admin(db, "account-create", "--name", "M4b 真实联调")
        agent = run_admin(db, "agent-register", "--account", account["accountId"],
                          "--name", "M4b 真实连接器 Mac", "--relay", relay_url)
        minted = run_admin(db, "code-mint", "--agent", agent["agentId"],
                           "--ttl-seconds", "120")
        check(len(minted["code"]) == 9, f"Go admin 铸出配对码 {minted['code']}")

        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=STEP_TIMEOUT)) as session:
            async with session.post(f"{public}/pair/claim", json={
                "pairCode": minted["code"], "deviceName": "DSH-M4b-Real",
                "deviceModel": "iPhone17,1", "appVersion": "1.0.0",
            }) as response:
                claimed = await response.json()
        check(response.status == 200 and claimed.get("ok") is True,
              "假设备通过 Go relay 认领到设备令牌")
        check(claimed["agentId"] == agent["agentId"], "认领到的电脑与 Go admin 建的一致")
        device_token = claimed["deviceToken"]

        # ── 3. 真实连接器 CLI 指向 Go relay 与本机 dsh ──────────────────────
        connector = subprocess.Popen(
            [shutil.which("node") or "node", str(CLI),
             "--relay", relay_url,
             "--agent-id", agent["agentId"],
             "--agent-secret", agent["agentSecret"],
             "--state-file", str(state_file),
             "--status-file", str(status_file),
             "--dsh-url", dsh_url,
             "--log-level", "debug"],
            stdout=connector_log.open("w"), stderr=subprocess.STDOUT,
            cwd=str(CONNECTOR_DIR),
            env={**os.environ, "DSH_HOME": str(dsh_home)})

        status = await wait_status(
            status_file,
            lambda s: s.get("connected") is True and s.get("dsh", {}).get("port"))
        check(status["agentId"] == agent["agentId"], "连接器状态文件报告已连上 Go relay")
        check(status["dsh"]["port"] == endpoint["port"],
              f"连接器认证到本机 dsh 端口 {status['dsh']['port']}")
        check(status["dsh"]["source"] == "config", "本机地址来自 --dsh-url（config）")

        # ── 4. 假设备：三件只读调用 ─────────────────────────────────────────
        headers = {"Authorization": f"Bearer {device_token}"}
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=STEP_TIMEOUT)) as session:
            ws = await session.ws_connect(f"{public}/link/device?agentId={agent['agentId']}",
                                         headers=headers)
            reader = FrameReader(ws)
            try:
                status_frame, _ = await reader.until(lambda f: f.get("t") == "hostStatus")
                check(status_frame["info"]["online"] is True, "设备收到 hostStatus(online)")

                await ws.send_str(json.dumps({"t": "req", "id": "1", "method": "session/list",
                                              "args": {"_request": {}}}))
                listed, _ = await reader.until(
                    lambda f: f.get("t") == "res" and f.get("id") == "1")
                check(listed.get("ok") is True, "session/list 经真实连接器成功")
                sessions = listed["value"]["items"]
                check(len(sessions) > 0 and all("sessionId" in item for item in sessions),
                      f"session/list 返回 {len(sessions)} 条会话")
                real_ids = local_session_ids()
                matched = sorted({item["sessionId"] for item in sessions} & real_ids)
                check(len(matched) > 0,
                      f"{len(matched)} 个会话 id 与本机会话目录逐字对应（证明是真实会话）")

                await ws.send_str(json.dumps({"t": "open", "id": "2", "endpoint": "$events",
                                              "args": {}}))
                ready_frame, _ = await reader.until(is_ready)
                ready = ready_frame["value"]
                check(isinstance(ready.get("clientId"), str) and len(ready["clientId"]) > 8,
                      f"$events 返回 ready 帧，clientId 长度 {len(ready['clientId'])}")

                idle, address = pick_followable(sessions)
                check(idle is not None, "找到一条非运行中的真实会话用于 follow")
                target = idle["sessionId"]
                await ws.send_str(json.dumps({
                    "t": "open", "id": "3", "endpoint": "session/follow",
                    "args": {"request": {"address": address,
                                         "maxMessages": 10, "assistantStream": True}},
                }))
                snapshot, _ = await reader.until(
                    lambda f: f.get("t") == "item" and f.get("id") == "3"
                    and isinstance(f.get("value"), dict)
                    and f["value"].get("type") == "snapshot")
                check(snapshot["value"]["header"]["id"] == target,
                      f"session/follow 返回 {target[:24]}… 的快照")

                await ws.send_str(json.dumps({"t": "cancel", "id": "3"}))
                await reader.drain(0.5)  # 先吃掉 cancel 前已经在路上的帧
                late = await reader.drain(1.5)
                stray = [frame for frame in late
                         if frame.get("id") == "3" and frame.get("t") in ("item", "event", "end")]
                check(not stray, "cancel 之后 1.5 秒内没有该流的后续帧")

                status_devices = await wait_status(status_file,
                                                  lambda s: s.get("deviceCount") == 1)
                check(status_devices["deviceCount"] == 1, "连接器状态报告 1 台设备在线")
            finally:
                await ws.close()

        # 连接器对"手机暂时不在"是**值班**而不是删除：记录留着、$events 流留着，
        # 直到设备被撤销（contracts/…；router.js detachDevice 的注释）。
        # 所以这里断言的是 offlineSince 被置上，而不是 deviceCount 归零。
        offline = await wait_status(
            status_file,
            lambda s: bool(s.get("devices")) and s["devices"][0].get("offlineSince"))
        check(offline["devices"][0]["offlineSince"] is not None,
              "设备断开后连接器把记录置为离线值班（$events 流保留）")
        check(connector.poll() is None, "连接器进程仍然存活")
        async with aiohttp.ClientSession() as session:
            async with session.get(f"{base}/stats") as response:
                stats = await response.json()
        check(stats["load"]["devices"] == 0 and not stats["snapshot"]["devices"],
              "Go relay 侧已把设备从在线表里摘掉（/stats load.devices = 0）")

        result.update({
            "relay": relay_url,
            "sessions": len(sessions),
            "sessionMatchLocalDirs": len(matched),
            "sessionFollowed": target,
            "clientIdLength": len(ready["clientId"]),
            "agentId": agent["agentId"],
            "deviceId": claimed["deviceId"],
            "connectorRetainsOfflineRecord": True,
            "relayLoadDevicesAfterClose": stats["load"]["devices"],
        })
        return result
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

        # 日志摘要：错误/警告行数 + 最后几行，正文留在临时目录（随目录删除）。
        error_lines: list[str] = []
        warn_lines: list[str] = []
        for path, label in ((connector_log, "connector"), (relay_log, "relay")):
            if not path.exists():
                continue
            for line in path.read_text(errors="replace").splitlines():
                if "[error]" in line or '"level":"ERROR"' in line:
                    error_lines.append(f"{label}: {line}")
                elif "[warn]" in line or '"level":"WARN"' in line:
                    warn_lines.append(f"{label}: {line}")
        result["connectorErrors"] = error_lines
        result["warnings"] = warn_lines
        result["agentJsonUnchanged"] = digest(REAL_AGENT_FILE) == agent_before


TOKEN_PATTERN = re.compile(r"token=[^&\s\"']+")


def redact_text(text: str) -> str:
    """日志里可能出现带 launch token 的 dsh 地址；落盘前统一脱敏。"""
    return TOKEN_PATTERN.sub("token=<redacted>", text)


def main() -> int:
    parser = argparse.ArgumentParser(description="M4b 真实连接器只读联调")
    parser.add_argument("--evidence", type=pathlib.Path, default=None,
                        help="把连接器/中转日志（token 已脱敏）与结果 JSON 落到该目录")
    args = parser.parse_args()
    if not RELAY.exists():
        print(f"缺少 {RELAY}，先 cd relay-go && make build", file=sys.stderr)
        return 2
    started = time.monotonic()
    workdir = pathlib.Path(tempfile.mkdtemp(prefix="m4b-real-"))
    result: dict = {}
    try:
        result = asyncio.run(run(workdir))
        log(f"PASSED in {time.monotonic() - started:.2f}s")
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except StepFailure as error:
        log(f"FAILED: {error}")
        for path in workdir.glob("*.log"):
            tail = "\n".join(path.read_text(errors="replace").splitlines()[-25:])
            print(f"--- {path.name} tail ---\n{tail}", file=sys.stderr)
        return 1
    finally:
        if args.evidence is not None:
            args.evidence.mkdir(parents=True, exist_ok=True)
            for path in workdir.glob("*.log"):
                (args.evidence / path.name).write_text(redact_text(path.read_text(errors="replace")))
            (args.evidence / "result.json").write_text(
                json.dumps(result, ensure_ascii=False, indent=2))
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
