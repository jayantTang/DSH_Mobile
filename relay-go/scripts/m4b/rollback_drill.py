#!/usr/bin/env python3
"""M4b 任务 4：回滚演练（Go → Python → Go），同一个临时库、同一个端口。

测什么：
  1. Go relay 建账户/电脑/设备，并写一条账户状态；
  2. 停 Go、起 Python relay 指向**同一个库**，/healthz 200，读出账户、设备、
     账户状态（两种实现读同一份 schema）；
  3. Python 期间写一条新账户状态、建一个新账户；
  4. 停 Python、再起 Go，/healthz 200，读出 Python 写进去的状态与账户。

每次切换都记录"发出 SIGTERM → 新进程 /healthz 返回 200"的墙钟，作为回滚耗时。
全程临时库、随机端口；不碰生产 `~/.dsh` 与真实部署。

用法：
  relay/.venv/bin/python relay-go/scripts/m4b/rollback_drill.py
"""

from __future__ import annotations

import asyncio
import json
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import tempfile
import time

import aiohttp

ROOT = pathlib.Path(__file__).resolve().parents[3]
RELAY = ROOT / "relay-go" / "bin" / "dsh-relay"
PYTHON = ROOT / "relay" / ".venv" / "bin" / "python"
PY_RELAY = ROOT / "relay" / "relay.py"
PY_ADMIN = ROOT / "relay" / "admin.py"
STEP_TIMEOUT = 25.0


class StepFailure(AssertionError):
    pass


def log(message: str) -> None:
    print(f"[m4b-rollback] {message}", flush=True)


def check(condition: bool, message: str) -> None:
    if not condition:
        raise StepFailure(message)
    log(f"ok: {message}")


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


def go_admin(db: str, *args: str) -> dict | list:
    result = subprocess.run([str(RELAY), "admin", "--db", db, *args],
                            capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise StepFailure(f"Go admin {' '.join(args)} 失败: {result.stderr.strip()}")
    return json.loads(result.stdout)


def py_admin(db: str, *args: str) -> dict | list:
    result = subprocess.run([str(PYTHON), str(PY_ADMIN), "--db", db, *args],
                            capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise StepFailure(f"Python admin {' '.join(args)} 失败: {result.stderr.strip()}")
    return json.loads(result.stdout)


async def wait_healthz(base: str, timeout: float = STEP_TIMEOUT) -> float:
    started = time.monotonic()
    async with aiohttp.ClientSession() as session:
        while time.monotonic() - started < timeout:
            try:
                async with session.get(f"{base}/healthz") as response:
                    if response.status == 200:
                        return time.monotonic() - started
            except aiohttp.ClientError:
                pass
            await asyncio.sleep(0.005)
    raise StepFailure(f"{base}/healthz 在 {timeout}s 内没有 200")


def wait_port_free(port: int, timeout: float = 10.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with socket.socket() as probe:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                probe.bind(("127.0.0.1", port))
                return
            except OSError:
                time.sleep(0.02)
    raise StepFailure(f"端口 {port} 10 秒内没有释放")


def stop_process(process: subprocess.Popen, name: str) -> float:
    started = time.monotonic()
    process.terminate()
    try:
        process.wait(10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(5)
    elapsed = time.monotonic() - started
    log(f"{name} 退出耗时 {elapsed * 1000:.0f} ms（rc={process.returncode}）")
    return elapsed


async def state_entries(session: aiohttp.ClientSession, base: str, token: str) -> dict:
    async with session.get(f"{base}/account/state",
                           headers={"Authorization": f"Bearer {token}"}) as response:
        body = await response.json()
    if response.status != 200:
        raise StepFailure(f"/account/state 读失败: {response.status} {body}")
    return {key: entry["value"] for key, entry in body["entries"].items()}


async def put_state(session: aiohttp.ClientSession, base: str, token: str,
                    key: str, value: str) -> None:
    async with session.put(
            f"{base}/account/state",
            json={"entries": [{"key": key, "value": {"writer": value},
                               "updatedAt": int(time.time() * 1000)}]},
            headers={"Authorization": f"Bearer {token}"}) as response:
        body = await response.json()
    if response.status != 200:
        raise StepFailure(f"/account/state 写失败: {response.status} {body}")


def start_go(port: int, db: str, log_path: pathlib.Path) -> subprocess.Popen:
    return subprocess.Popen(
        [str(RELAY), "serve", "--port", str(port), "--db", db, "--log-level", "info"],
        stdout=log_path.open("w"), stderr=subprocess.STDOUT)


def start_python(port: int, db: str, log_path: pathlib.Path) -> subprocess.Popen:
    return subprocess.Popen(
        [str(PYTHON), str(PY_RELAY), "--port", str(port), "--db", db, "--log-level", "INFO"],
        stdout=log_path.open("w"), stderr=subprocess.STDOUT, cwd=str(ROOT / "relay"))


async def run(workdir: pathlib.Path) -> dict:
    db = str(workdir / "state.db")
    port = free_port()
    base = f"http://127.0.0.1:{port}"
    go_log = workdir / "go.log"
    py_log = workdir / "python.log"
    go = start_go(port, db, go_log)
    py: subprocess.Popen | None = None
    result: dict = {}
    try:
        await wait_healthz(base)
        account = go_admin(db, "account-create", "--name", "M4b 回滚账户")
        agent = go_admin(db, "agent-register", "--account", account["accountId"],
                         "--name", "M4b 回滚 Mac", "--relay", f"ws://127.0.0.1:{port}")
        minted = go_admin(db, "code-mint", "--agent", agent["agentId"], "--ttl-seconds", "120")

        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=STEP_TIMEOUT)) as session:
            async with session.post(f"{base}/pair/claim", json={
                "pairCode": minted["code"], "deviceName": "DSH-M4b-Rollback",
                "deviceModel": "iPhone17,1", "appVersion": "1.0.0",
            }) as response:
                claimed = await response.json()
        check(response.status == 200 and claimed.get("ok") is True,
              "Go relay 上完成一次真实配对（账户/电脑/设备就位）")
        token = claimed["deviceToken"]
        device_id = claimed["deviceId"]

        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=STEP_TIMEOUT)) as session:
            await put_state(session, base, token, "m4bSwitch", "go")
            go_state = await state_entries(session, base, token)
        check(go_state.get("m4bSwitch") == {"writer": "go"}, "Go 写了一条账户状态")

        # ── 切换 1：Go → Python（同一个库、同一个端口） ────────────────────
        switch_started = time.monotonic()
        stop_process(go, "go relay")
        wait_port_free(port)
        py = start_python(port, db, py_log)
        python_ready = await wait_healthz(base)
        switch_ms = (time.monotonic() - switch_started) * 1000
        log(f"Go → Python 切换完成：{switch_ms:.0f} ms（Python 自身 /healthz {python_ready * 1000:.0f} ms）")
        check(switch_ms < 5000, f"Go → Python 回滚耗时 {switch_ms:.0f} ms < 5000 ms")

        accounts = py_admin(db, "account-list")
        agents = py_admin(db, "agent-list")
        devices = py_admin(db, "device-list", "--agent", agent["agentId"])
        check(any(row["accountId"] == account["accountId"] for row in accounts),
              "Python 读到 Go 建的账户")
        check(any(row["agentId"] == agent["agentId"] for row in agents),
              "Python 读到 Go 建的电脑")
        check(len(devices) == 1 and devices[0]["deviceId"] == device_id,
              "Python 读到 Go 配对出的设备")

        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=STEP_TIMEOUT)) as session:
            py_state = await state_entries(session, base, token)
            check(py_state.get("m4bSwitch") == {"writer": "go"},
                  "Python relay 读出 Go 写的账户状态")
            await put_state(session, base, token, "m4bReverse", "python")
            py_state_after = await state_entries(session, base, token)
            check(py_state_after.get("m4bReverse") == {"writer": "python"},
                  "Python relay 写入一条新账户状态")
        python_account = py_admin(db, "account-create", "--name", "M4b Python 写的账户")
        log(f"Python admin 建了新账户 {python_account['accountId']}")

        # ── 切换 2：Python → Go（反向回滚） ────────────────────────────────
        switch_started = time.monotonic()
        stop_process(py, "python relay")
        py = None
        wait_port_free(port)
        go = start_go(port, db, go_log.with_name("go-again.log"))
        await wait_healthz(base)
        reverse_ms = (time.monotonic() - switch_started) * 1000
        log(f"Python → Go 切换完成：{reverse_ms:.0f} ms")
        check(reverse_ms < 5000, f"Python → Go 切换耗时 {reverse_ms:.0f} ms < 5000 ms")

        accounts_go = go_admin(db, "account-list")
        check(any(row["accountId"] == python_account["accountId"] for row in accounts_go),
              "Go admin 读到 Python 建的账户")
        devices_go = go_admin(db, "device-list", "--agent", agent["agentId"])
        check(len(devices_go) == 1 and devices_go[0]["deviceId"] == device_id,
              "Go admin 仍读到同一台设备")

        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=STEP_TIMEOUT)) as session:
            final_state = await state_entries(session, base, token)
        check(final_state.get("m4bSwitch") == {"writer": "go"},
              "Go relay 读出最初的账户状态")
        check(final_state.get("m4bReverse") == {"writer": "python"},
              "Go relay 读出 Python 写的账户状态")

        result.update({
            "goToPythonMs": round(switch_ms),
            "pythonToGoMs": round(reverse_ms),
            "accountId": account["accountId"],
            "deviceId": device_id,
            "accountsSeenByPython": len(accounts),
            "accountsSeenByGo": len(accounts_go),
            "stateKeysAfterRoundTrip": sorted(final_state),
        })
        return result
    finally:
        if py is not None and py.poll() is None:
            stop_process(py, "python relay")
        if go.poll() is None:
            stop_process(go, "go relay")
        result["pythonLogTail"] = (_tail(py_log, 6) if py_log.exists() else [])
        result["goLogTail"] = (_tail(go_log.with_name("go-again.log"), 6)
                               if go_log.with_name("go-again.log").exists() else [])


def _tail(path: pathlib.Path, lines: int) -> list[str]:
    try:
        return path.read_text(errors="replace").splitlines()[-lines:]
    except OSError:
        return []


def main() -> int:
    if not RELAY.exists() or not PYTHON.exists():
        print("缺少 relay-go/bin/dsh-relay 或 relay/.venv；先 make build / 建 venv", file=sys.stderr)
        return 2
    started = time.monotonic()
    workdir = pathlib.Path(tempfile.mkdtemp(prefix="m4b-rollback-"))
    try:
        result = asyncio.run(run(workdir))
        log(f"PASSED in {time.monotonic() - started:.2f}s")
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except StepFailure as error:
        log(f"FAILED: {error}")
        for path in workdir.glob("*.log"):
            print(f"--- {path.name} tail ---\n" + "\n".join(_tail(path, 20)), file=sys.stderr)
        return 1
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
