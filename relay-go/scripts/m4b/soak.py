#!/usr/bin/env python3
"""M4b 任务 3：短时 soak（100 设备 × 10 fps × 10 分钟）。

口径与 `relay-go/tests/blackbox/performance/bench.py` 的 steady 注入一致：
  * 20 台电脑（agent）× 每台 5 台设备 = 100 台设备（每账户默认最多 8 台配对设备，
    不为此改限额）；
  * 每台设备每 100 ms 发一帧 `req`（方法 `bench/echo`），对应的 agent 原 id 回 `res`；
  * 设备首帧按 1 ms 错峰，避免"同步突发"测成客户端瓶颈。

采样（每 `--sample` 秒）：
  * relay 的 RSS：`libproc.proc_pid_rusage`（本机 `ps` 被沙箱禁用）；
  * goroutine：Go 的 `/debug/pprof/goroutine?debug=1` 首行 "total N"；
  * `/stats`：load、droppedFrames（设备+电脑）、队列字节、出口字节；
  * 客户端：发出/回显/丢失、错误、延迟分位数。

用法：
  .venv/bin/python relay-go/scripts/m4b/soak.py --seconds 600 --sample 15
  # 冒烟：--seconds 20 --sample 5 --devices 20 --agents 4
"""

from __future__ import annotations

import argparse
import asyncio
import ctypes
import json
import math
import os
import pathlib
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
from typing import Any

import aiohttp
from aiohttp import WSMsgType

ROOT = pathlib.Path(__file__).resolve().parents[3]
RELAY = ROOT / "relay-go" / "bin" / "dsh-relay"
BLACKBOX = ROOT / "relay" / "tests" / "blackbox"
sys.path.insert(0, str(BLACKBOX))

import support  # noqa: E402

BASE_PATH = "/dsh-link"
STEP_TIMEOUT = 30.0
# relay 的 --max-paired-devices 默认值（internal/config.DefaultMaxPairedDevices）；本脚本不改限额。
MAX_PAIRED_DEVICES = 8


def log(message: str) -> None:
    print(f"[m4b-soak] {message}", flush=True)


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


def run_admin(db: str, *args: str) -> dict | list:
    result = subprocess.run([str(RELAY), "admin", "--db", db, *args],
                            capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"admin {' '.join(args)} 失败: {result.stderr.strip()}")
    return json.loads(result.stdout)


# ── 进程 RSS / CPU（libproc；沙箱禁用了 ps） ────────────────────────────────
_libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
_libproc.proc_pid_rusage.restype = ctypes.c_int


def proc_rusage(pid: int) -> dict[str, float] | None:
    """读 pid 的 rusage_info_v4：RSS / footprint / user+sys CPU。"""
    buffer = ctypes.create_string_buffer(1024)
    if _libproc.proc_pid_rusage(pid, 4, buffer) != 0:
        return None
    user_ns = struct.unpack_from("<Q", buffer, 16)[0]
    system_ns = struct.unpack_from("<Q", buffer, 24)[0]
    resident = struct.unpack_from("<Q", buffer, 16 + 6 * 8)[0]
    footprint = struct.unpack_from("<Q", buffer, 16 + 7 * 8)[0]
    return {
        "rssMiB": resident / 2**20,
        "footprintMiB": footprint / 2**20,
        "cpuSeconds": (user_ns + system_ns) / 1e9,
    }


async def goroutines(session: aiohttp.ClientSession, pprof: str) -> int | None:
    try:
        async with session.get(f"http://{pprof}/debug/pprof/goroutine?debug=1") as response:
            text = await response.text()
    except (aiohttp.ClientError, asyncio.TimeoutError):
        return None
    match = re.search(r"goroutine profile: total (\d+)", text)
    return int(match.group(1)) if match else None


def percentile(values: list[float], quantile: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, int(round(quantile * (len(ordered) - 1)))))
    return ordered[index]


async def provision(base: str, db: str, agents: int, devices_per_agent: int
                    ) -> list[tuple[support.Tenant, list[support.Device]]]:
    invites = run_admin(db, "invite-mint", "--ttl-seconds", "1800",
                        "--note", "m4b-soak", "--count", str(agents))
    if isinstance(invites, dict):
        invites = [invites]
    if not isinstance(invites, list) or len(invites) < agents:
        raise RuntimeError(f"邀请码数量不足：{invites}")
    plan: list[tuple[support.Tenant, list[support.Device]]] = []
    async with support.Client(base, timeout=60.0) as client:
        for index in range(agents):
            response = await client.post("/agents/enroll", json_body={
                "inviteCode": invites[index]["code"], "name": f"DSH-SOAK-Mac-{index:02d}"})
            if response.status != 200:
                raise RuntimeError(f"登记失败 {index}: {response.status} {response.text[:200]}")
            body = response.json()
            tenant = support.Tenant(account_id=body["accountId"], agent_id=body["agentId"],
                                    agent_secret=body["agentSecret"], name=body["agentName"])
            devices = []
            for device_index in range(devices_per_agent):
                device = await support.pair_device(
                    client, tenant, name=f"DSH-SOAK-iPhone-{index:02d}-{device_index:02d}")
                devices.append(device)
            plan.append((tenant, devices))
    return plan


async def open_sockets(session: aiohttp.ClientSession, factories: list[Any],
                       concurrency: int = 64) -> list[aiohttp.ClientWebSocketResponse]:
    gate = asyncio.Semaphore(concurrency)

    async def one(factory):
        async with gate:
            return await factory()

    return await asyncio.gather(*(one(factory) for factory in factories))


async def agent_echo(ws: aiohttp.ClientWebSocketResponse, stats: dict[str, Any]) -> None:
    while True:
        try:
            message = await ws.receive()
        except asyncio.CancelledError:
            raise
        except Exception as error:  # noqa: BLE001
            stats["errors"].append(f"agent 读取失败：{type(error).__name__}: {error}")
            return
        if message.type is WSMsgType.TEXT:
            try:
                frame = json.loads(message.data)
            except ValueError:
                stats["errors"].append("agent 收到非 JSON 帧")
                continue
            if frame.get("t") != "req":
                continue
            try:
                await ws.send_str(json.dumps({
                    "t": "res", "id": frame.get("id"), "ok": True,
                    "value": {"echo": frame.get("id")},
                    "deviceId": frame.get("deviceId"),
                }))
            except Exception as error:  # noqa: BLE001
                stats["errors"].append(f"agent 回显失败：{type(error).__name__}: {error}")
                return
        elif message.type in (WSMsgType.CLOSE, WSMsgType.CLOSING, WSMsgType.CLOSED):
            return
        elif message.type is WSMsgType.ERROR:
            stats["errors"].append(f"agent socket 错误：{ws.exception()}")
            return


async def device_echo(index: int, ws: aiohttp.ClientWebSocketResponse, *,
                      start_at: float, seconds: float, interval: float,
                      payload: str, latencies: list[float],
                      stats: dict[str, Any]) -> None:
    pending: dict[str, float] = {}

    async def send_loop() -> None:
        now = time.perf_counter()
        if start_at > now:
            await asyncio.sleep(start_at - now)
        deadline = time.perf_counter() + seconds
        next_at = time.perf_counter()
        sequence = 0
        while time.perf_counter() < deadline:
            frame_id = f"d{index}-{sequence}"
            sequence += 1
            pending[frame_id] = time.perf_counter()
            try:
                await ws.send_str(json.dumps({
                    "t": "req", "id": frame_id, "method": "bench/echo",
                    "args": {"padding": payload}}))
                stats["sent"] += 1
            except Exception as error:  # noqa: BLE001
                pending.pop(frame_id, None)
                stats["errors"].append(f"设备 {index} 发送失败：{type(error).__name__}: {error}")
                return
            next_at += interval
            delay = next_at - time.perf_counter()
            if delay > 0:
                await asyncio.sleep(delay)

    async def recv_loop() -> None:
        # 一直读到 socket 关闭或任务被取消：relay 每 15 秒 ping 一次、10 秒等 pong，
        # 没有协程在 receive 时 ping 不会被应答，25 秒后连接会被判死（link.go）。
        while True:
            try:
                message = await asyncio.wait_for(ws.receive(), timeout=1.0)
            except (asyncio.TimeoutError, TimeoutError):
                continue
            if message.type is WSMsgType.TEXT:
                try:
                    frame = json.loads(message.data)
                except ValueError:
                    stats["errors"].append(f"设备 {index} 收到非 JSON 帧")
                    continue
                if frame.get("t") == "res":
                    sent_at = pending.pop(frame.get("id"), None)
                    if sent_at is None:
                        stats["errors"].append(f"设备 {index} 收到无法对应的回显 {frame.get('id')!r}")
                    else:
                        latencies.append((time.perf_counter() - sent_at) * 1000.0)
                        stats["echoed"] += 1
                elif frame.get("t") == "error":
                    stats["errors"].append(f"设备 {index} 错误帧：{str(frame)[:120]}")
            elif message.type in (WSMsgType.CLOSE, WSMsgType.CLOSING, WSMsgType.CLOSED):
                return
            elif message.type is WSMsgType.ERROR:
                stats["errors"].append(f"设备 {index} socket 错误：{ws.exception()}")
                return

    sender = asyncio.create_task(send_loop())
    receiver = asyncio.create_task(recv_loop())
    try:
        await sender
        # 发送结束：留 2 秒把在途回显收完（期间照常读 socket，心跳有应答）。
        drain_deadline = time.perf_counter() + 2.0
        while pending and time.perf_counter() < drain_deadline:
            await asyncio.sleep(0.05)
        await receiver  # 只在 socket 关闭或任务被取消时返回
    finally:
        for task in (sender, receiver):
            if not task.done():
                task.cancel()
        await asyncio.gather(sender, receiver, return_exceptions=True)


def summarize(series: list[dict[str, Any]], fields: list[str]) -> dict[str, Any]:
    summary: dict[str, Any] = {}
    for field in fields:
        values = [sample[field] for sample in series if sample.get(field) is not None]
        if not values:
            continue
        summary[field] = {
            "first": round(values[0], 3),
            "max": round(max(values), 3),
            "last": round(values[-1], 3),
            "min": round(min(values), 3),
        }
    return summary


async def run(args: argparse.Namespace, workdir: pathlib.Path) -> dict[str, Any]:
    db = str(workdir / "state.db")
    port = free_port()
    pprof_port = free_port()
    base = f"http://127.0.0.1:{port}"
    public = f"{base}{BASE_PATH}"
    ws_base = f"ws://127.0.0.1:{port}{BASE_PATH}"
    pprof = f"127.0.0.1:{pprof_port}"
    relay_log = workdir / "relay.log"
    relay = subprocess.Popen(
        [str(RELAY), "serve", "--port", str(port), "--db", db,
         "--base-path", BASE_PATH, "--pprof-addr", pprof, "--log-level", "info"],
        stdout=relay_log.open("w"), stderr=subprocess.STDOUT, cwd=str(workdir))

    devices: list[aiohttp.ClientWebSocketResponse] = []
    agents: list[aiohttp.ClientWebSocketResponse] = []
    socket_session: aiohttp.ClientSession | None = None
    tasks: list[asyncio.Task] = []
    stats: dict[str, Any] = {"sent": 0, "echoed": 0, "errors": []}
    latencies: list[float] = []
    series: list[dict[str, Any]] = []
    result: dict[str, Any] = {}
    started = time.monotonic()

    try:
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=STEP_TIMEOUT)) as session:
            async def healthy() -> bool:
                try:
                    async with session.get(f"{base}/healthz") as response:
                        return response.status == 200
                except aiohttp.ClientError:
                    return False

            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                if await healthy():
                    break
                await asyncio.sleep(0.05)
            else:
                raise RuntimeError("Go relay 没有起来")

            log(f"供给 {args.agents} 台电脑 × {args.devices // args.agents} 台设备…")
            supply_started = time.monotonic()
            plan = await provision(base, db, args.agents, args.devices // args.agents)
            supply_seconds = time.monotonic() - supply_started
            log(f"供给完成 {supply_seconds:.1f}s")

            # 打开全部 socket（100 设备 + 10 agent）。
            connector = aiohttp.TCPConnector(limit=0)
            socket_session = aiohttp.ClientSession(
                connector=connector,
                timeout=aiohttp.ClientTimeout(total=args.seconds + 180))
            agent_sockets = await open_sockets(socket_session, [
                (lambda tenant=tenant: socket_session.ws_connect(
                    ws_base + support.agent_socket_path(tenant),
                    headers={"Authorization": f"Bearer {tenant.agent_token}"}))
                for tenant, _ in plan])
            device_sockets = await open_sockets(socket_session, [
                (lambda device=device: socket_session.ws_connect(
                    ws_base + support.device_socket_path(device),
                    headers={"Authorization": f"Bearer {device.token}"}))
                for _, tenant_devices in plan for device in tenant_devices])
            agents = list(agent_sockets)
            devices = list(device_sockets)

            # 握手帧：设备首帧 hostStatus、agent 侧 deviceAttach。
            hosts = await asyncio.gather(*(support.read_frame(ws, what="设备首帧")
                                           for ws in devices))
            attaches = await asyncio.gather(*(support.read_frame(ws, what="agent 首帧")
                                              for ws in agents))
            for frame in hosts:
                if frame.get("t") != "hostStatus" or not (frame.get("info") or {}).get("online"):
                    stats["errors"].append(f"设备首帧异常：{str(frame)[:120]}")
            for frame in attaches:
                if frame.get("t") != "deviceAttach":
                    stats["errors"].append(f"agent 首帧异常：{str(frame)[:120]}")

            tasks = [asyncio.create_task(agent_echo(ws, stats)) for ws in agents]
            tasks += [asyncio.create_task(device_echo(
                index, ws, start_at=time.perf_counter() + index * 0.001,
                seconds=args.seconds, interval=1.0 / args.fps,
                payload="x" * args.payload, latencies=latencies, stats=stats))
                for index, ws in enumerate(devices)]

            # 第一个采样点：负载刚开始，作为基线。
            async def sample() -> dict[str, Any]:
                usage = proc_rusage(relay.pid) or {}
                async with session.get(f"{base}/stats") as response:
                    snapshot = await response.json()
                dropped = sum(row["droppedFrames"] for row in snapshot["snapshot"]["devices"])
                dropped += sum(row["droppedFrames"] for row in snapshot["snapshot"]["agents"])
                queued = sum(row["queuedBytes"] for row in snapshot["snapshot"]["agents"])
                return {
                    "atSeconds": round(time.monotonic() - started, 1),
                    "rssMiB": usage.get("rssMiB"),
                    "footprintMiB": usage.get("footprintMiB"),
                    "cpuSeconds": usage.get("cpuSeconds"),
                    "goroutines": await goroutines(session, pprof),
                    "loadAgents": snapshot["load"]["agents"],
                    "loadDevices": snapshot["load"]["devices"],
                    "droppedFrames": dropped,
                    "agentQueuedBytes": queued,
                    "egressBytes": snapshot["traffic"]["totalEgressBytes"],
                    "sent": stats["sent"],
                    "echoed": stats["echoed"],
                    "clientErrors": len(stats["errors"]),
                }

            series.append(await sample())
            log(f"基线采样: {json.dumps(series[-1], ensure_ascii=False)}")

            next_sample = time.monotonic() + args.sample
            # 发送任务按 args.seconds 跑，留 5 秒收在途回显；到点就取消（读循环不会自己结束）。
            while time.monotonic() - started < args.seconds + 5:
                if not any(not task.done() for task in tasks):
                    break
                now = time.monotonic()
                if now >= next_sample:
                    series.append(await sample())
                    next_sample += args.sample
                await asyncio.sleep(0.2)
            log(f"注入结束：sent={stats['sent']} echoed={stats['echoed']}，开始收尾")

            # 到点收尾：agent 读循环与设备读循环都是长期任务，必须先取消再等，
            # 否则 gather 会一直挂着（agent 循环只有在 socket 关闭时才返回）。
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            # 最后 drain：等队列清空再取终值。
            await asyncio.sleep(1.0)
            series.append(await sample())

            sent = stats["sent"]
            echoed = stats["echoed"]
            result.update({
                "devices": args.devices,
                "agents": args.agents,
                "fps": args.fps,
                "seconds": args.seconds,
                "payloadBytes": args.payload,
                "supplySeconds": round(supply_seconds, 1),
                "wallSeconds": round(time.monotonic() - started, 1),
                "framesSent": sent,
                "framesEchoed": echoed,
                "missingFrames": sent - echoed,
                "clientErrors": len(stats["errors"]),
                "errorSamples": stats["errors"][:10],
                "latencyMs": {
                    "p50": round(percentile(latencies, 0.50), 3),
                    "p95": round(percentile(latencies, 0.95), 3),
                    "p99": round(percentile(latencies, 0.99), 3),
                    "max": round(max(latencies), 3) if latencies else None,
                },
                "samples": series,
                "growth": summarize(series, ["rssMiB", "footprintMiB", "goroutines",
                                             "droppedFrames", "cpuSeconds",
                                             "agentQueuedBytes"]),
                "finalDroppedFrames": series[-1]["droppedFrames"],
                "finalGoroutines": series[-1]["goroutines"],
            })
            return result
    finally:
        for task in tasks:
            if not task.done():
                task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        for ws in list(devices) + list(agents):
            try:
                await ws.close()
            except Exception:  # noqa: BLE001
                pass
        if devices or agents:
            await asyncio.sleep(0.5)
        if socket_session is not None:
            await socket_session.close()
        if relay.poll() is None:
            relay.terminate()
            try:
                relay.wait(10)
            except subprocess.TimeoutExpired:
                relay.kill()
                relay.wait(5)
        log_lines = relay_log.read_text(errors="replace").splitlines() if relay_log.exists() else []
        result["relayLogErrors"] = [line for line in log_lines
                                    if '"level":"ERROR"' in line or '"level":"WARN"' in line][:10]
        result["relayLogErrorCount"] = sum(
            1 for line in log_lines if '"level":"ERROR"' in line or '"level":"WARN"' in line)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="M4b 短时 soak")
    parser.add_argument("--seconds", type=float, default=600)
    parser.add_argument("--fps", type=float, default=10)
    parser.add_argument("--devices", type=int, default=100)
    parser.add_argument("--agents", type=int, default=20)
    parser.add_argument("--sample", type=float, default=15)
    parser.add_argument("--payload", type=int, default=256)
    parser.add_argument("--out", type=pathlib.Path, default=None)
    args = parser.parse_args(argv)
    if args.devices % args.agents != 0:
        parser.error("--devices 必须是 --agents 的整数倍")
    if args.devices // args.agents > MAX_PAIRED_DEVICES:
        parser.error(f"每台电脑最多 {MAX_PAIRED_DEVICES} 台设备（relay 配对上限），"
                     f"{args.devices} 台设备 / {args.agents} 台电脑 = "
                     f"{args.devices // args.agents} 台超限；加大 --agents 或减少 --devices")
    if not RELAY.exists():
        print(f"缺少 {RELAY}，先 cd relay-go && make build", file=sys.stderr)
        return 2
    workdir = pathlib.Path(tempfile.mkdtemp(prefix="m4b-soak-"))
    started = time.monotonic()
    try:
        result = asyncio.run(run(args, workdir))
        result["elapsedSeconds"] = round(time.monotonic() - started, 1)
        log(f"DONE in {result['elapsedSeconds']}s: sent={result['framesSent']} "
            f"echoed={result['framesEchoed']} dropped={result['finalDroppedFrames']} "
            f"goroutines={result['finalGoroutines']}")
        if args.out:
            args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2))
            log(f"原始数据写到 {args.out}")
        print(json.dumps({key: value for key, value in result.items() if key != "samples"},
                         ensure_ascii=False, indent=2))
        return 0
    except Exception as error:  # noqa: BLE001 - 失败要留完整日志
        import traceback
        traceback.print_exc()
        for path in workdir.glob("*.log"):
            tail = "\n".join(path.read_text(errors="replace").splitlines()[-30:])
            print(f"--- {path.name} tail ---\n{tail}", file=sys.stderr)
        log(f"FAILED: {error}")
        return 1
    finally:
        if not args.out:
            shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
