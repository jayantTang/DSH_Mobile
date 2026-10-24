#!/usr/bin/env python3
"""探针：真实连接器经 Go relay 调用本机 DSH 的 workspaceFiles/*（只读）。

目的只有一个：在写 M8 文件通道联调脚本之前，先确认
  1. 哪个 sessionId 能当 `workspaceFileScopeId`；
  2. `workspaceFiles/stat` 是否接受工作区之外的绝对路径。

全程只读，不写 `~/.dsh`（连接器的 DSH_HOME 指向临时目录）。

用法：
  .venv/bin/python relay-go/scripts/m8/probe_workspace.py
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import pathlib
import shutil
import socket
import subprocess
import tempfile
import time

import aiohttp
from aiohttp import WSMsgType

ROOT = pathlib.Path(__file__).resolve().parents[3]
RELAY = ROOT / "relay-go" / "bin" / "dsh-relay"
CONNECTOR_DIR = ROOT / "plugins" / "mobile-link"
CLI = CONNECTOR_DIR / "lib" / "cli.js"
DSH_HOME = pathlib.Path(os.environ.get("DSH_HOME", pathlib.Path.home() / ".dsh"))
ENDPOINT_FILE = DSH_HOME / "mobile-link" / "endpoint.json"
BASE_PATH = "/dsh-link"


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


def run_admin(db: str, *args: str) -> dict:
    result = subprocess.run([str(RELAY), "admin", "--db", db, *args],
                            capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"admin {' '.join(args)}: {result.stderr or result.stdout}")
    return json.loads(result.stdout)


async def call(ws, reader, method: str, args: dict, *, rid: str) -> dict:
    await ws.send_str(json.dumps({"t": "req", "id": rid, "method": method, "args": args}))
    deadline = time.monotonic() + 30
    while True:
        message = await asyncio.wait_for(ws.receive(), deadline - time.monotonic())
        if message.type != WSMsgType.TEXT:
            raise RuntimeError(f"非文本帧 {message.type}")
        frame = json.loads(message.data)
        reader.append(frame)
        if frame.get("t") == "res" and frame.get("id") == rid:
            return frame


async def main_async(workdir: pathlib.Path) -> None:
    endpoint = json.loads(ENDPOINT_FILE.read_text())
    dsh_url = endpoint["url"]
    db = str(workdir / "state.db")
    port = free_port()
    base = f"http://127.0.0.1:{port}"
    public = f"{base}{BASE_PATH}"
    relay_url = f"ws://127.0.0.1:{port}{BASE_PATH}"
    dsh_home = workdir / "dsh-home"
    (dsh_home / "mobile-link").mkdir(parents=True, exist_ok=True)

    relay = subprocess.Popen(
        [str(RELAY), "serve", "--port", str(port), "--db", db,
         "--base-path", BASE_PATH, "--log-level", "debug"],
        stdout=(workdir / "relay.log").open("w"), stderr=subprocess.STDOUT, cwd=str(workdir))
    connector = None
    try:
        async with aiohttp.ClientSession() as session:
            deadline = time.monotonic() + 20
            while True:
                try:
                    async with session.get(f"{base}/healthz") as response:
                        await response.json()
                    break
                except (aiohttp.ClientError, asyncio.TimeoutError):
                    if time.monotonic() > deadline:
                        raise RuntimeError("relay 没起来")
                    await asyncio.sleep(0.1)

        account = run_admin(db, "account-create", "--name", "M8 probe")
        agent = run_admin(db, "agent-register", "--account", account["accountId"],
                          "--name", "M8 probe Mac", "--relay", relay_url)
        minted = run_admin(db, "code-mint", "--agent", agent["agentId"], "--ttl-seconds", "120")
        async with aiohttp.ClientSession() as session:
            async with session.post(f"{public}/pair/claim", json={
                "pairCode": minted["code"], "deviceName": "DSH-M8-Probe",
                "deviceModel": "iPhone17,1", "appVersion": "1.0.0"}) as response:
                claimed = await response.json()

        status_file = workdir / "agent-status.json"
        connector = subprocess.Popen(
            [shutil.which("node") or "node", str(CLI),
             "--relay", relay_url,
             "--agent-id", agent["agentId"],
             "--agent-secret", agent["agentSecret"],
             "--state-file", str(workdir / "agent-identity.json"),
             "--status-file", str(status_file),
             "--dsh-url", dsh_url,
             "--log-level", "debug"],
            stdout=(workdir / "connector.log").open("w"), stderr=subprocess.STDOUT,
            cwd=str(CONNECTOR_DIR), env={**os.environ, "DSH_HOME": str(dsh_home)})

        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                status = json.loads(status_file.read_text())
            except (OSError, json.JSONDecodeError):
                status = {}
            if status.get("connected") and status.get("dsh", {}).get("port"):
                break
            await asyncio.sleep(0.1)
        print("status:", json.dumps({k: status.get(k) for k in ("connected", "agentId")},
                                    ensure_ascii=False))
        print("dsh:", json.dumps(status.get("dsh", {}), ensure_ascii=False))

        headers = {"Authorization": f"Bearer {claimed['deviceToken']}"}
        reader: list[dict] = []
        async with aiohttp.ClientSession() as session:
            ws = await session.ws_connect(f"{public}/link/device?agentId={agent['agentId']}",
                                         headers=headers)
            try:
                async with session.get(f"{base}/stats") as response:
                    stats = await response.json()
                print("stats agent:", json.dumps(stats.get("snapshot", {}).get("agents", [])[:1],
                                                 ensure_ascii=False)[:400])
                listed = await call(ws, reader, "session/list", {"_request": {}}, rid="1")
                print("session/list ok:", listed.get("ok"))
                items = listed.get("value", {}).get("items", [])
                print("sessions:", [(item.get("sessionId", "")[:12],
                                     item.get("title", "")[:20],
                                     item.get("running"), item.get("parentSessionId")) for item in items[:8]])
                print("first item keys:", sorted(items[0].keys()) if items else [])
                for item in items[:6]:
                    print("item:", json.dumps(item, ensure_ascii=False)[:400])

                # 合成 scope：随机 ID 与 "session-<uuid>" 形状各试一次。
                import uuid
                candidates = [f"session-m8-temp-{uuid.uuid4().hex}", f"m8-temp-{uuid.uuid4().hex}"]
                outside = workdir / "probe-synthetic.bin"
                outside.write_bytes(b"synthetic" * 10)
                for scope in candidates:
                    frame = await call(ws, reader, "workspaceFiles/stat", {
                        "workspaceFileScopeId": scope, "path": str(outside)},
                        rid=f"synth-{scope[:8]}")
                    print(f"stat[synthetic {scope[:20]}]:",
                          json.dumps({"ok": frame.get("ok"),
                                      "value": frame.get("value") or frame.get("error")},
                                     ensure_ascii=False)[:300])
                    frame = await call(ws, reader, "workspaceFiles/list", {
                        "workspaceFileScopeId": scope, "path": "."}, rid=f"synth-list-{scope[:8]}")
                    print(f"list[synthetic {scope[:20]}]:",
                          json.dumps({"ok": frame.get("ok"),
                                      "value": frame.get("value") or frame.get("error")},
                                     ensure_ascii=False)[:300])

                # 两个探测目标：临时目录（工作区外）与仓库内的 README。
                outside = workdir / "probe-outside.bin"
                outside.write_bytes(b"probe" * 100)
                targets = [("outside-tmp", str(outside)),
                           ("inside-repo", str(ROOT / "README.md"))]
                for index, item in enumerate(items[:3]):
                    sid = item["sessionId"]
                    for label, path in targets:
                        frame = await call(ws, reader, "workspaceFiles/stat", {
                            "workspaceFileScopeId": sid, "path": path},
                            rid=f"stat-{index}-{label}")
                        value = frame.get("value") if frame.get("ok") else frame.get("error")
                        print(f"stat[{sid[:12]}][{label}]:",
                              json.dumps({"ok": frame.get("ok"), "value": value},
                                         ensure_ascii=False)[:300])
                    frame = await call(ws, reader, "workspaceFiles/list", {
                        "workspaceFileScopeId": sid, "path": "."}, rid=f"list-{index}")
                    print(f"list[{sid[:12]}]:", json.dumps(
                        {"ok": frame.get("ok"),
                         "value": (frame.get("value") or frame.get("error"))},
                        ensure_ascii=False)[:300])
            finally:
                await ws.close()
    finally:
        for proc in (connector, relay):
            if proc is not None and proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(10)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(5)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--keep", action="store_true")
    args = parser.parse_args()
    workdir = pathlib.Path(tempfile.mkdtemp(prefix="m8-probe-"))
    print("workdir:", workdir)
    try:
        asyncio.run(main_async(workdir))
        return 0
    finally:
        if not args.keep:
            for name in ("connector.log", "relay.log"):
                path = workdir / name
                if path.exists():
                    print(f"--- {name} tail ---")
                    print("\n".join(path.read_text(errors="replace").splitlines()[-15:]))
            shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
