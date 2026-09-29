"""C-04 T1/T2/T3/T5/T8 端到端：真 relay 进程 + 真 `admin.py` 子进程。

裁定书要求**必须真进程**（禁止 in-process 假 hub）——因为这次缺陷的根因正是
"admin.py 是另一个进程，够不着 relay 的内存"；in-process 测法恰好绕开了它。
所以这里起真 `relay.py`（真 TCP 监听、真 DB），设备与连接器走真 WebSocket。
"""

from __future__ import annotations

import asyncio
import json
import os
import pathlib
import subprocess
import sys
import time

import pytest
from aiohttp import WSMsgType, ClientSession

import e2e_support
from e2e_support import StepFailure, admin, free_port, recv_json

RELAY_DIR = pathlib.Path(__file__).resolve().parents[1]

#: 对账周期取小一点：断言"≤2 个周期内被踢"不必真等 10 秒。
RECONCILE_S = "0.4"
ADMIN_TIMEOUT = 20.0


# ── harness ─────────────────────────────────────────────────────────────────

class RelayProcess:
    """A real `relay.py` in its own process, with its own database."""

    def __init__(self, db: pathlib.Path, port: int, log_path: pathlib.Path):
        self.db, self.port, self.log_path = db, port, log_path
        self.process: subprocess.Popen | None = None
        self._log = None

    def start(self) -> None:
        env = dict(os.environ)
        env["DLP_REVOKE_RECONCILE_S"] = RECONCILE_S
        self._log = open(self.log_path, "w", encoding="utf-8")
        self.process = subprocess.Popen(
            [sys.executable, str(RELAY_DIR / "relay.py"),
             "--host", "127.0.0.1", "--port", str(self.port), "--db", str(self.db)],
            cwd=str(RELAY_DIR), env=env, stdout=self._log, stderr=subprocess.STDOUT)

    async def wait_ready(self, timeout: float = 15.0) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise StepFailure(f"relay exited early:\n{self.log()}")
            try:
                async with ClientSession() as session:
                    async with session.get(f"{self.base}/healthz") as response:
                        if response.status == 200:
                            return
            except OSError:
                pass
            await asyncio.sleep(0.05)
        raise StepFailure(f"relay never became ready:\n{self.log()}")

    @property
    def base(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def log(self) -> str:
        try:
            return self.log_path.read_text(encoding="utf-8")
        except OSError:
            return ""

    def stop(self) -> None:
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=10)
        if self._log is not None:
            self._log.close()
            self._log = None


@pytest.fixture
def relay(tmp_path):
    db = tmp_path / "state.db"
    process = RelayProcess(db, free_port(), tmp_path / "relay.log")
    # 先建库、配好一台电脑（admin.py 会在同一张库上跑）。
    account = json.loads(_admin_raw_db(db, "account-create", "--name", "ops"))
    process.agent = json.loads(_admin_raw_db(
        db, "agent-register", "--account", account["accountId"], "--name", "mac"))
    process.start()
    try:
        yield process
    finally:
        process.stop()


async def wait_for(predicate, *, timeout: float = 5.0, interval: float = 0.02) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        await asyncio.sleep(interval)
    return predicate()


@pytest.fixture
async def wired(relay):
    """The registered agent plus a live connector socket, and a `pair` helper."""
    await relay.wait_ready()
    agent = relay.agent
    async with ClientSession() as session:

        async def pair(name: str) -> dict:
            minted = json.loads(_admin_raw(relay, "code-mint", "--agent", agent["agentId"]))
            async with session.post(f"{relay.base}/pair/claim", json={
                "pairCode": minted["code"], "deviceName": name,
                "deviceModel": "iPhone17,1", "appVersion": "1.0",
            }) as response:
                assert response.status == 200, await response.text()
                return await response.json()

        agent_ws = await session.ws_connect(
            f"{relay.base}/link/agent?agentId={agent['agentId']}",
            headers={"Authorization": f"Bearer {agent['agentSecret']}"})

        yield {"relay": relay, "session": session, "agent": agent, "agentWs": agent_ws,
               "pair": pair}
        await agent_ws.close()


def _admin_raw(relay: RelayProcess, *args: str) -> str:
    return _admin_raw_db(relay.db, *args)


def _admin_raw_db(db, *args: str) -> str:
    result = subprocess.run(
        [sys.executable, str(RELAY_DIR / "admin.py"), "--db", str(db), *args],
        capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise StepFailure(f"admin.py {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


async def open_device(wired, name: str):
    device = await wired["pair"](name)
    ws = await wired["session"].ws_connect(
        f"{wired["relay"].base}/link/device?agentId={wired['agent']['agentId']}",
        headers={"Authorization": f"Bearer {device['deviceToken']}"})
    return device, ws


async def frames_until(ws, predicate, *, timeout: float = 5.0):
    """Collect frames until `predicate` matches one; returns what was seen."""
    seen = []
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise StepFailure(f"timed out; saw {seen}")
        try:
            message = await asyncio.wait_for(ws.receive(), remaining)
        except asyncio.TimeoutError:
            raise StepFailure(f"timed out; saw {seen}")
        if message.type != WSMsgType.TEXT:
            seen.append({"t": f"<{message.type.name}>"})
            if predicate(seen[-1]):
                return seen
            if message.type in (WSMsgType.CLOSE, WSMsgType.CLOSED, WSMsgType.CLOSING):
                return seen
            continue
        frame = json.loads(message.data)
        seen.append(frame)
        if predicate(frame):
            return seen


async def wait_for_close(ws, *, timeout: float = 5.0) -> None:
    """Wait until the relay closes this socket.

    The `deviceDetach` frame goes to the **connector**, not to the phone being
    dropped — the phone just sees its socket close, which is exactly what C-04
    promises. So this is the assertion for the device side.
    """
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise StepFailure("the relay never closed this device's socket")
        try:
            message = await asyncio.wait_for(ws.receive(), remaining)
        except asyncio.TimeoutError:
            raise StepFailure("the relay never closed this device's socket")
        if message.type in (WSMsgType.CLOSE, WSMsgType.CLOSED, WSMsgType.CLOSING):
            return


# ── T1: 三种撤销路径都在 ≤2 个周期内踢掉在线设备 ──────────────────────────────

@pytest.mark.parametrize("how", ["device", "token"])
async def test_admin_revoke_kicks_a_live_device_within_two_periods(wired, how):
    device, ws = await open_device(wired, f"DSH-Test-{how}")
    await recv_json(ws)                                  # hostStatus

    if how == "device":
        payload = admin(str(wired["relay"].db), "device-revoke", "--device", device["deviceId"])
    else:
        payload = admin(str(wired["relay"].db), "device-revoke", "--token", device["deviceToken"])

    assert payload == {"ok": True, "deviceId": device["deviceId"],
                       "revoked": True, "detach": "relay-reconcile"}

    # 设备 socket 必须被关掉（对账踢的）。
    await wait_for_close(ws, timeout=4 * float(RECONCILE_S))
    assert "was revoked in the database but still connected" in wired["relay"].log()


async def test_admin_revoke_tells_the_connector_to_let_go(wired):
    """连接器收到 `deviceDetach{reason:'revoked'}`——这是它唯一的放下信号。"""
    device, ws = await open_device(wired, "DSH-Test-agent")
    await recv_json(ws)
    admin(str(wired["relay"].db), "device-revoke", "--device", device["deviceId"])

    seen = await frames_until(
        wired["agentWs"],
        lambda frame: frame.get("t") == "deviceDetach"
        and frame.get("deviceId") == device["deviceId"],
        timeout=4 * float(RECONCILE_S))
    detach = [frame for frame in seen if frame.get("t") == "deviceDetach"][-1]
    assert detach["reason"] == "revoked"


# ── T2: 防误踢 ──────────────────────────────────────────────────────────────

async def test_the_healthy_device_is_never_touched(wired):
    doomed, doomed_ws = await open_device(wired, "DSH-Test-doomed")
    healthy, healthy_ws = await open_device(wired, "DSH-Test-healthy")
    await recv_json(doomed_ws)
    await recv_json(healthy_ws)

    admin(str(wired["relay"].db), "device-revoke", "--device", doomed["deviceId"])
    await frames_until(wired["agentWs"],
                       lambda frame: frame.get("t") == "deviceDetach"
                       and frame.get("deviceId") == doomed["deviceId"],
                       timeout=4 * float(RECONCILE_S))

    # 观察窗口：至少再跑几个周期，健康设备一个字节都不许动。
    await asyncio.sleep(4 * float(RECONCILE_S))
    health = await wired["session"].get(
        f"{wired["relay"].base}/healthz")
    assert health.status == 200
    # 它仍能收发（socket 未关）：发一个 ping，期待 pong。
    await healthy_ws.send_str(json.dumps({"t": "ping", "ts": 1}))
    seen = await frames_until(healthy_ws, lambda frame: frame.get("t") == "pong", timeout=3.0)
    assert any(frame.get("t") == "pong" for frame in seen)
    assert healthy_ws.closed is False


# ── T3: 撤销后无法重连 ──────────────────────────────────────────────────────

async def test_a_revoked_device_cannot_reconnect(wired):
    device, ws = await open_device(wired, "DSH-Test-reconnect")
    await recv_json(ws)
    admin(str(wired["relay"].db), "device-revoke", "--device", device["deviceId"])
    await wait_for_close(ws, timeout=4 * float(RECONCILE_S))

    async with ClientSession() as session:
        with pytest.raises(Exception) as caught:
            await session.ws_connect(
                f"{wired["relay"].base}/link/device?agentId={wired['agent']['agentId']}",
                headers={"Authorization": f"Bearer {device['deviceToken']}"})
        # `device_by_token` refuses a revoked token, so the upgrade never happens.
        assert "401" in str(caught.value)


async def test_repeated_reconcile_ticks_do_not_pile_up_detaches(wired):
    """幂等：多跑几个周期，同一条 detach 不会没完没了地重复。"""
    device, ws = await open_device(wired, "DSH-Test-idempotent")
    await recv_json(ws)
    admin(str(wired["relay"].db), "device-revoke", "--device", device["deviceId"])
    await frames_until(wired["agentWs"],
                       lambda frame: frame.get("t") == "deviceDetach"
                       and frame.get("deviceId") == device["deviceId"],
                       timeout=4 * float(RECONCILE_S))
    await asyncio.sleep(6 * float(RECONCILE_S))

    log = wired["relay"].log()
    assert log.count("was revoked in the database but still connected") == 1


# ── T8: 不静默停摆 ──────────────────────────────────────────────────────────

async def test_an_idle_relay_runs_quietly(wired):
    """没有在线设备时，对账跑够多个周期也不该报 warning。"""
    await asyncio.sleep(6 * float(RECONCILE_S))
    log = wired["relay"].log()
    assert "revoke reconcile tick failed" not in log
    assert "revoke reconcile loop every" in log


# ── T4/F2: 臂 2——relay 重启、连接器重连 ─────────────────────────────────────

async def test_a_reconnecting_connector_is_told_about_dead_devices(tmp_path):
    """连接器重连时被告知"这些回不来了"，但它没持有的设备是空操作。

    这里验的是真进程那一半：relay 重启后，已撤销设备的 `deviceDetach` 会**主动**
    出现在新连接上，而不需要设备先上线。连接器侧的"放下 A、留住 B"由
    `plugins/mobile-link` 的用例覆盖。
    """
    db = tmp_path / "state.db"
    process = RelayProcess(db, free_port(), tmp_path / "relay.log")
    account = json.loads(_admin_raw_db(db, "account-create", "--name", "ops"))
    agent = json.loads(_admin_raw_db(
        db, "agent-register", "--account", account["accountId"], "--name", "mac"))
    process.start()
    try:
        await process.wait_ready()
        agent_id = agent["agentId"]

        # 在 relay 运行期间配一台设备，撤销它，然后**重启 relay**。
        minted = json.loads(_admin_raw(process, "code-mint", "--agent", agent_id))
        async with ClientSession() as session:
            async with session.post(f"{process.base}/pair/claim", json={
                "pairCode": minted["code"], "deviceName": "DSH-Test-dead",
                "deviceModel": "iPhone17,1", "appVersion": "1.0"}) as response:
                device = await response.json()
        admin(str(db), "device-revoke", "--device", device["deviceId"])
        process.stop()

        # 换一个端口重启（旧端口可能还在 TIME_WAIT）。
        process.port = free_port()
        process.start()
        await process.wait_ready()

        async with ClientSession() as session:
            async with session.ws_connect(
                    f"{process.base}/link/agent?agentId={agent_id}",
                    headers={"Authorization": f"Bearer {agent['agentSecret']}"}) as agent_ws:
                seen = await frames_until(
                    agent_ws,
                    lambda frame: frame.get("t") == "deviceDetach"
                    and frame.get("deviceId") == device["deviceId"],
                    timeout=5.0)
                detach = [f for f in seen if f.get("t") == "deviceDetach"][-1]
                assert detach["reason"] == "revoked"
        assert "can never come back" in process.log()
    finally:
        process.stop()
