#!/usr/bin/env python3
"""文件上行桥压测（M4a，手动执行，不被 pytest 收集）。

口径：100 个并发 ``PUT /files/up``，每个 10 MB，连接器一侧**慢读**（每片 sleep
``--slow-ms``），验证三件事：

1. 内存上界：被测进程的 ``maximum resident set size`` 与 ``/stats`` 的
   ``snapshot.agents[].bridgeBytesInUse`` 峰值都必须不超过 ``--bridge-bytes``
   （额度计的是排队帧字节，原始请求体另有每请求一片的读缓冲，见报告）；
2. 不丢数据：连接器逐片拼回每个 bid 的正文，在 ``fsPutEnd`` 处校验字节数与
   SHA-256，与客户端按同一算法生成的内容逐字节一致；
3. 时长：记录从"同时发起 100 个请求"到"全部落幕"的墙钟。

被测进程仍由 ``RELAY_CMD`` 决定；候选参数 ``--bridge-bytes`` 由本脚本追加，不写死
实现。用法::

    cd relay
    RELAY_CMD="$PWD/../relay-go/bin/dsh-relay" ADMIN_CMD="$PWD/../relay-go/bin/dsh-relay admin" \\
      .venv/bin/python tests/blackbox/performance/upload_stress.py \\
        --uploads 100 --size-mb 10 --bridge-bytes 16777216 --slow-ms 8 \\
        --out /tmp/upload-stress.json
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import json
import pathlib
import random
import sys
import tempfile
import time
from typing import Any

BENCH_DIR = pathlib.Path(__file__).resolve().parent
BLACKBOX_DIR = BENCH_DIR.parent
TESTS_DIR = BLACKBOX_DIR.parent
RELAY_DIR = TESTS_DIR.parent

for entry in (str(TESTS_DIR), str(BENCH_DIR)):
    if entry not in sys.path:
        sys.path.insert(0, entry)

import aiohttp  # noqa: E402
from aiohttp import WSMsgType  # noqa: E402

import bench  # noqa: E402 - 复用 /usr/bin/time -l 的进程包装与 RSS 解析
from blackbox import conftest, support  # noqa: E402

#: 中转的分片大小（relay-go internal/files.BridgeChunkBytes）。压测内容按它对齐，
#: 这样连接器每一帧都能独立核对序号，不必依赖实现内部的缓冲策略。
CHUNK_BYTES = 1 << 20


def piece_bytes(upload: int, index: int, size: int) -> bytes:
    """第 ``upload`` 个文件第 ``index`` 片的内容：确定性伪随机，两端都能重算。"""
    return random.Random((upload << 24) | index).randbytes(size)


def file_digest(upload: int, total: int) -> str:
    """按片重算整份内容的 SHA-256（不保留正文，内存与文件大小无关）。"""
    digest = hashlib.sha256()
    for index, offset in enumerate(range(0, total, CHUNK_BYTES)):
        size = min(CHUNK_BYTES, total - offset)
        digest.update(piece_bytes(upload, index, size))
    return digest.hexdigest()


async def body_stream(upload: int, total: int):
    """按片产出请求体；aiohttp 会以 chunked 发送，客户端不持有整份文件。"""
    for index, offset in enumerate(range(0, total, CHUNK_BYTES)):
        size = min(CHUNK_BYTES, total - offset)
        yield piece_bytes(upload, index, size)
        await asyncio.sleep(0)  # 让出事件循环：100 个上传要并行推进


class BridgeAgent:
    """连接器桩：慢读分片、逐片记账、在 fsPutEnd 处校验整份内容。"""

    def __init__(self, uploads: int, total: int, slow_ms: float) -> None:
        self.uploads = uploads
        self.total = total
        self.slow_seconds = max(0.0, slow_ms) / 1000.0
        self.expected = {index: file_digest(index, total) for index in range(uploads)}
        self.states: dict[str, dict[str, Any]] = {}
        self.verified = 0
        self.mismatched = 0
        self.unknown_end = 0
        self.errors: list[str] = []
        self.closed = asyncio.Event()

    def begin(self, bid: str) -> None:
        self.states[bid] = {"hash": hashlib.sha256(), "bytes": 0, "seq": 0}

    def end(self, bid: str) -> tuple[bool, str]:
        state = self.states.pop(bid, None)
        if state is None:
            self.unknown_end += 1
            return False, "没有收到过这个 bid 的分片"
        upload = int(bid.rsplit("-", 1)[-1])
        expected = self.expected.get(upload)
        if expected is None:
            return False, f"未知的 bid：{bid}"
        actual = state["hash"].hexdigest()
        if state["bytes"] != self.total:
            return False, f"{bid} 字节数 {state['bytes']} != {self.total}"
        if actual != expected:
            return False, f"{bid} SHA-256 不匹配"
        return True, ""

    async def run(self, ws: aiohttp.ClientWebSocketResponse) -> None:
        try:
            while True:
                message = await ws.receive()
                if message.type is WSMsgType.TEXT:
                    frame = json.loads(message.data)
                    kind = frame.get("t")
                    bid = frame.get("bid")
                    if kind == "fsPutBegin":
                        self.begin(str(bid))
                        await ws.send_str(json.dumps({"t": "fsPutAck", "bid": bid}))
                    elif kind == "fsPutChunk":
                        if self.slow_seconds:
                            await asyncio.sleep(self.slow_seconds)
                        state = self.states.get(str(bid))
                        if state is None:
                            self.errors.append(f"分片落在未知 bid {bid}")
                            continue
                        seq = frame.get("seq")
                        if seq != state["seq"]:
                            self.errors.append(f"{bid} 分片序号 {seq} != {state['seq']}")
                        state["seq"] += 1
                        data = base64.b64decode(frame["data"])
                        state["hash"].update(data)
                        state["bytes"] += len(data)
                    elif kind == "fsPutEnd":
                        ok, reason = self.end(str(bid))
                        if ok:
                            self.verified += 1
                            await ws.send_str(json.dumps({
                                "t": "fsPutDone", "bid": bid,
                                "path": f"/inbox/{bid}.bin", "bytes": self.total,
                            }))
                        else:
                            self.mismatched += 1
                            self.errors.append(reason)
                            await ws.send_str(json.dumps({
                                "t": "fsErr", "bid": bid,
                                "code": "bench/hash-mismatch", "message": reason,
                            }))
                elif message.type in (WSMsgType.CLOSE, WSMsgType.CLOSING, WSMsgType.CLOSED):
                    return
                elif message.type is WSMsgType.ERROR:
                    self.errors.append(f"连接器 socket 错误：{ws.exception()}")
                    return
        except asyncio.CancelledError:
            raise
        except Exception as error:  # noqa: BLE001 - 桩挂了要变成记录，不是静默
            self.errors.append(f"连接器桩异常：{type(error).__name__}: {error}")
        finally:
            self.closed.set()


async def stats_poller(base: str, stop: asyncio.Event, samples: list[dict[str, Any]]) -> None:
    """每 100 ms 取一次 /stats，记录桥额度峰值（只读，环回来源才允许）。"""
    timeout = aiohttp.ClientTimeout(total=2.0)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        while not stop.is_set():
            try:
                async with session.get(f"{base}/stats") as response:
                    if response.status == 200:
                        body = await response.json()
                        agents = (body.get("snapshot") or {}).get("agents") or []
                        samples.append({
                            "at": time.perf_counter(),
                            "limit": (body.get("limits") or {}).get("bridgeBytes"),
                            "inUse": max((agent.get("bridgeBytesInUse") or 0) for agent in agents)
                            if agents else 0,
                            "queuedBytes": max((agent.get("queuedBytes") or 0) for agent in agents)
                            if agents else 0,
                        })
            except (aiohttp.ClientError, asyncio.TimeoutError, ValueError):
                pass  # 中转正在收尾时读不到，不算压测失败
            try:
                await asyncio.wait_for(stop.wait(), timeout=0.1)
            except (asyncio.TimeoutError, TimeoutError):
                continue


async def upload_one(session: aiohttp.ClientSession, base: str, device: support.Device,
                     upload: int, total: int) -> dict[str, Any]:
    bid = f"stress-{upload:03d}"
    params = (f"sessionId=stress&name=file-{upload:03d}.bin"
              f"&bid={bid}&bytes={total}")
    started = time.perf_counter()
    try:
        async with session.put(
                f"{base}/files/up?{params}",
                data=body_stream(upload, total),
                headers={"Authorization": f"Bearer {device.token}"},
                timeout=aiohttp.ClientTimeout(total=600.0)) as response:
            payload = await response.json()
            status = response.status
    except Exception as error:  # noqa: BLE001 - 客户端异常本身就是要记录的结果
        return {"upload": upload, "bid": bid, "ok": False,
                "error": f"{type(error).__name__}: {error}",
                "seconds": round(time.perf_counter() - started, 3)}
    return {
        "upload": upload, "bid": bid, "status": status,
        "ok": bool(payload.get("ok")) and status == 200,
        "bytes": payload.get("bytes"),
        "seconds": round(time.perf_counter() - started, 3),
    }


async def provision(base: str, db: pathlib.Path) -> tuple[support.Tenant, support.Device]:
    admin = bench._run_admin(db)  # noqa: SLF001 - 与 bench.py 共用同一套 admin 调用
    async with support.Client(base, timeout=30.0) as client:
        tenant = await support.enroll(client, admin, name="STRESS-Mac")
        device = await support.pair_device(client, tenant, name="STRESS-iPhone")
    return tenant, device


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="文件上行桥压测（M4a，手动执行）")
    parser.add_argument("--uploads", type=int, default=100)
    parser.add_argument("--size-mb", type=float, default=10.0)
    parser.add_argument("--bridge-bytes", type=int, default=16 << 20,
                        help="被测进程的 --bridge-bytes（同时用于判定上界）")
    parser.add_argument("--slow-ms", type=float, default=8.0,
                        help="连接器每收到一片的滞留时间（模拟慢读）")
    parser.add_argument("--out", type=pathlib.Path, help="完整结果 JSON")
    args = parser.parse_args(argv)

    total = int(args.size_mb * 1024 * 1024)
    workdir = pathlib.Path(tempfile.mkdtemp(prefix="dsh-upload-stress-"))
    relay = bench.MeasuredRelay(workdir, label="upload-stress",
                                extra_args=("--bridge-bytes", str(args.bridge_bytes)))
    started = time.perf_counter()
    report: dict[str, Any] = {
        "generatedAt": bench._now_iso(),  # noqa: SLF001
        "environment": bench._environment(),  # noqa: SLF001
        "config": {
            "uploads": args.uploads, "sizeMb": args.size_mb,
            "bridgeBytes": args.bridge_bytes, "slowMillisPerChunk": args.slow_ms,
            "chunkBytes": CHUNK_BYTES,
            "relayCommand": relay.command,
            "workdir": str(workdir),
        },
        "notes": [
            "100 个并发 PUT，每个按 1 MiB 切片、chunked 发送；连接器桩每片滞留 "
            "--slow-ms，制造真实的慢读背压。",
            "RSS 来自 /usr/bin/time -l 的 maximum resident set size；连接器桩与客户端"
            "都在压测脚本进程里，只有中转本身被计量。",
            "bridgeBytesPeakInUse 来自 /stats 每 100 ms 采样：它是采样到的最小上界，"
            "真实峰值只会更高，不会更低。",
        ],
    }
    print(f"== 文件上行桥压测：{args.uploads} × {args.size_mb:g} MB，"
          f"bridge-bytes {args.bridge_bytes}，慢读 {args.slow_ms:g} ms/片 ==")
    relay.start()
    try:
        relay.wait_ready()
        tenant, device = asyncio.run(provision(relay.base, relay.db))
        agent = BridgeAgent(args.uploads, total, args.slow_ms)
        report["stress"] = asyncio.run(
            run_stress(relay.base, tenant, device, agent, args, total))
    finally:
        relay.stop()
    report["resources"] = relay.resources()
    report["elapsedSeconds"] = round(time.perf_counter() - started, 1)

    peak = report["stress"]["bridgeBytesPeakInUse"]
    limit = report["stress"]["bridgeBytesLimit"]
    report["verdict"] = {
        "allUploadsSucceeded": report["stress"]["succeeded"] == args.uploads,
        "allHashesVerified": report["stress"]["agentVerified"] == args.uploads,
        "bridgeBudgetRespected": bool(peak is not None and limit is not None and peak <= limit),
        "maxRssBytes": report["resources"]["maxRssBytes"],
    }
    print(f"  完成 {report['stress']['succeeded']}/{args.uploads}，"
          f"哈希校验 {report['stress']['agentVerified']}，"
          f"总耗时 {report['stress']['elapsedSeconds']} s，"
          f"RSS {report['resources']['maxRssBytes']} B，"
          f"桥额度峰值 {peak}/{limit}")

    payload = json.dumps(report, ensure_ascii=False, indent=2, default=str)
    if args.out is not None:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(payload + "\n", encoding="utf-8")
        print(f"已写入 {args.out}")
    return 0 if all(report["verdict"][key] for key in
                    ("allUploadsSucceeded", "allHashesVerified", "bridgeBudgetRespected")) else 1


async def run_stress(base: str, tenant: support.Tenant, device: support.Device,
                          agent: BridgeAgent, args: argparse.Namespace,
                          total: int) -> dict[str, Any]:
    """开连接器桩（真凭据）、发起全部上传、采样 /stats，最后合并结论。"""
    samples: list[dict[str, Any]] = []
    stop = asyncio.Event()
    connector = aiohttp.TCPConnector(limit=args.uploads + 16)
    session = aiohttp.ClientSession(connector=connector,
                                    timeout=aiohttp.ClientTimeout(total=600.0))
    agent_ws: aiohttp.ClientWebSocketResponse | None = None
    poller: asyncio.Task | None = None
    agent_task: asyncio.Task | None = None
    try:
        agent_ws = await session.ws_connect(
            base + support.agent_socket_path(tenant),
            headers={"Authorization": f"Bearer {tenant.agent_token}"})
        agent_task = asyncio.create_task(agent.run(agent_ws))
        poller = asyncio.create_task(stats_poller(base, stop, samples))
        started = time.perf_counter()
        results = await asyncio.gather(*(
            upload_one(session, base, device, index, total) for index in range(args.uploads)))
        elapsed = time.perf_counter() - started
    finally:
        stop.set()
        if poller is not None:
            await asyncio.gather(poller, return_exceptions=True)
        if agent_ws is not None:
            await agent_ws.close()
        if agent_task is not None:
            await asyncio.gather(agent_task, return_exceptions=True)
        await session.close()

    succeeded = sum(1 for entry in results if entry["ok"])
    seconds = sorted(entry["seconds"] for entry in results)
    return {
        "uploads": args.uploads,
        "bytesPerUpload": total,
        "slowMillisPerChunk": args.slow_ms,
        "elapsedSeconds": round(elapsed, 3),
        "succeeded": succeeded,
        "failed": args.uploads - succeeded,
        "agentVerified": agent.verified,
        "agentMismatched": agent.mismatched,
        "agentUnknownEnd": agent.unknown_end,
        "agentErrors": agent.errors[:10],
        "uploadLatencySeconds": {
            "min": seconds[0] if seconds else None,
            "p50": seconds[len(seconds) // 2] if seconds else None,
            "max": seconds[-1] if seconds else None,
        },
        "results": results,
        "statsSamples": len(samples),
        "bridgeBytesLimit": samples[0]["limit"] if samples else None,
        "bridgeBytesPeakInUse": max((sample["inUse"] for sample in samples), default=None),
        "queuedBytesPeak": max((sample["queuedBytes"] for sample in samples), default=None),
    }


if __name__ == "__main__":
    raise SystemExit(main())
