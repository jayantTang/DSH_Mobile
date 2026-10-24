#!/usr/bin/env python3
"""中转性能基线（L2，手动执行，不被 pytest 收集）。

口径见 ``maintainers/设计/20261023-Go迁移测试基座.md`` §3 L2：同一台机器、
同一份客户端、同一套场景，各版本用同一份 JSON 对比。
本文件是**基线采集脚本**，不是验收用例；不进默认套件，文件名也不以 ``test_`` 开头。

用法::

    cd relay-go
    ../.venv/bin/python tests/blackbox/performance/bench.py --out /tmp/bench.json

    # 顺带跑 300 设备那一档（默认不含；100 设备不稳定时自动跳过并记录原因）
    ../.venv/bin/python tests/blackbox/performance/bench.py --out /tmp/bench.json --with-300

被测进程由 ``RELAY_CMD`` 决定（默认 ``relay-go/bin/dsh-relay serve``），管理命令由
``ADMIN_CMD`` 决定，与黑盒套件同一套口径。库在临时目录、端口随机，不碰真实部署。

指标怎么来的（不估算）：

* 启动：``Popen`` 到 ``/healthz`` 返回 200，5 次，原始毫秒全留。
* HTTP：固定并发、固定时长；每次请求记一次往返毫秒，RPS 用完成请求数除实测窗口。
* WS 回显：每台设备各带一台 agent，设备每帧带唯一 id，agent 收到后原 id 回执，
  延迟 = 设备发出到设备收到回显的墙钟差（含中转往返与 agent 侧处理）。
* 资源：每个场景都把被测进程包在 ``/usr/bin/time -l`` 里跑，读
  ``maximum resident set size``（字节）与 user+sys CPU 秒。本机 ``ps``/``psutil``
  不可用，这是唯一可信来源。
* 启动之外每个场景跑 3 次，报告给中位数，``runs`` 保留三次原始值。

范围：只覆盖单机、单进程、本机回环网络。2 小时 soak、磁盘满、慢客户端背压不在
本脚本内（见基线报告的“未覆盖项”）。默认全程约 1.5 分钟，``--with-300`` 另加约 1 分钟。
"""

from __future__ import annotations

import argparse
import asyncio
import datetime as dt
import json
import math
import multiprocessing
import os
import pathlib
import platform
import re
import resource
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from typing import Any, Callable

#: ``relay-go/tests/blackbox/performance/`` → ``blackbox`` → ``tests`` → ``relay-go``
BENCH_DIR = pathlib.Path(__file__).resolve().parent
BLACKBOX_DIR = BENCH_DIR.parent
TESTS_DIR = BLACKBOX_DIR.parent
RELAY_DIR = TESTS_DIR.parent
REPO_DIR = RELAY_DIR.parent

# 让 ``from blackbox import ...`` 可用；同时避免 pytest 的 rootdir 逻辑介入。
if str(TESTS_DIR) not in sys.path:
    sys.path.insert(0, str(TESTS_DIR))

import aiohttp  # noqa: E402
from aiohttp import WSMsgType  # noqa: E402

from blackbox import conftest, support  # noqa: E402

# ── 固定场景参数 ────────────────────────────────────────────────────────────

STARTUP_SAMPLES = 5
REPEATS = 3

HTTP_CONCURRENCY = 32
HTTP_SECONDS = 5.0

STATE_CONCURRENCY = 16
STATE_SECONDS = 5.0

WS_DEVICES = 100
WS_FPS = 10
WS_SECONDS = 10.0

WS_OPTIONAL_DEVICES = 300
#: 1000 设备档（``--with-1000``）：单线程客户端在这个量级会成为瓶颈，
#: 用多个客户端进程拆分（``--clients``，0 = 自动：1000 档 4 个，其余 1 个）。
WS_LARGE_DEVICES = 1000
#: steady 模式下相邻设备的首帧间隔默认值（毫秒）。1000 台设备摊开在 1 秒里，
#: 既避免了“一波 1000 帧”同时压在一个事件循环上，又不至于把窗口拉长太多。
DEFAULT_STAGGER_MS = 1.0
#: 100 设备那一档“稳定”的判定：回显率与错误数。不满足就不跑 300 设备。
WS_STABLE_ECHO_RATE = 0.99

#: 起进程后的就绪上限。超时表现成失败 + 日志尾巴，不挂死。
READY_TIMEOUT_S = 30.0
#: 诊断开关：留下每个场景的临时目录（relay.log、time.txt），默认清掉。
KEEP_WORKDIR = False
#: 单次 HTTP 请求上限（并发压测时用它把挂死变成一次可见的失败）。
HTTP_TIMEOUT_S = 10.0

_TIME_REAL = re.compile(r"^\s*([\d.]+) real\s+([\d.]+) user\s+([\d.]+) sys\s*$", re.MULTILINE)
_TIME_RSS = re.compile(r"^\s*(\d+)\s+maximum resident set size\s*$", re.MULTILINE)


# ── 通用小工具 ──────────────────────────────────────────────────────────────


def _now_iso() -> str:
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def _percentile(ordered: list[float], quantile: float) -> float:
    """最近秩法（nearest-rank）：排序后取第 ceil(q*n) 个。样本少时不会插值造数。"""
    index = min(len(ordered) - 1, max(0, math.ceil(quantile * len(ordered)) - 1))
    return ordered[index]


def _latency_summary(values: list[float]) -> dict[str, Any]:
    if not values:
        return {"count": 0, "meanMs": None, "p50Ms": None, "p95Ms": None,
                "p99Ms": None, "maxMs": None}
    ordered = sorted(values)
    return {
        "count": len(ordered),
        "meanMs": round(sum(ordered) / len(ordered), 3),
        "p50Ms": round(_percentile(ordered, 0.50), 3),
        "p95Ms": round(_percentile(ordered, 0.95), 3),
        "p99Ms": round(_percentile(ordered, 0.99), 3),
        "maxMs": round(ordered[-1], 3),
    }


def _median(values: list[Any], *, digits: int = 3) -> Any:
    clean = [value for value in values if value is not None]
    if not clean:
        return None
    median = statistics.median(clean)
    return int(median) if digits == 0 else round(median, digits)


def _tail(path: pathlib.Path, lines: int = 20) -> str:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""
    return "\n".join(text.splitlines()[-lines:])


def _command(variable: str, default: str) -> list[str]:
    """与 conftest 完全同一套命令解析（``RELAY_CMD`` / ``ADMIN_CMD``）。"""
    return conftest._command(variable, default)  # noqa: SLF001 - 基座里只有这一份实现


def _run_admin(db: pathlib.Path) -> Callable[..., Any]:
    """返回一个 ``admin(*args)``：与 conftest.RelayProcess.admin 同形状，不依赖进程对象。"""
    command = _command("ADMIN_CMD", conftest.DEFAULT_ADMIN_CMD)

    def run(*args: str) -> Any:
        result = subprocess.run(
            [*command, "--db", str(db), *args],
            capture_output=True, text=True, timeout=30, env=conftest.clean_env())
        if result.returncode != 0:
            raise RuntimeError(
                f"admin.py {' '.join(args)} 失败（code={result.returncode}）："
                f"{result.stderr.strip() or result.stdout.strip()}")
        text = result.stdout.strip()
        return json.loads(text) if text else None

    return run


def _git(*args: str) -> str | None:
    try:
        result = subprocess.run(
            ["git", "-C", str(REPO_DIR), *args],
            capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip() or None


def _cpu_model() -> str | None:
    if sys.platform == "darwin":
        try:
            result = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"],
                                    capture_output=True, text=True, timeout=3)
            if result.returncode == 0 and result.stdout.strip():
                return result.stdout.strip()
        except (OSError, subprocess.SubprocessError):
            pass
    try:
        text = pathlib.Path("/proc/cpuinfo").read_text(encoding="utf-8")
        for line in text.splitlines():
            if line.lower().startswith("model name"):
                return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return platform.processor() or None


def _memory_bytes() -> int | None:
    try:
        return int(os.sysconf("SC_PHYS_PAGES")) * int(os.sysconf("SC_PAGE_SIZE"))
    except (ValueError, OSError, AttributeError):
        return None


def _pytest_processes() -> list[str]:
    """跑基线时机器上还有没有 pytest（互相干扰的证据，不是判定）。"""
    try:
        result = subprocess.run(["pgrep", "-fl", "pytest"],
                                capture_output=True, text=True, timeout=3)
    except (OSError, subprocess.SubprocessError):
        return []
    if result.returncode != 0:
        return []
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def _environment() -> dict[str, Any]:
    return {
        "capturedAt": _now_iso(),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "cpuModel": _cpu_model(),
        "cpuCount": os.cpu_count(),
        "memoryBytes": _memory_bytes(),
        "pythonVersion": sys.version.split()[0],
        "aiohttpVersion": aiohttp.__version__,
        "relayDir": str(RELAY_DIR),
        "relayCommand": " ".join(_command("RELAY_CMD", conftest.DEFAULT_RELAY_CMD)),
        "adminCommand": " ".join(_command("ADMIN_CMD", conftest.DEFAULT_ADMIN_CMD)),
        "gitCommit": _git("rev-parse", "HEAD"),
        "gitCommitShort": _git("rev-parse", "--short", "HEAD"),
        # 只关心已被跟踪的改动：新增的黑盒/基线文件本身不算“业务代码变了”。
        "relayTrackedClean": _git("status", "--porcelain", "--untracked-files=no", "--", "relay") is None,
        "ulimitNofile": resource.getrlimit(resource.RLIMIT_NOFILE)[0],
        "loadAverage": [round(value, 3) for value in os.getloadavg()],
        "pytestProcesses": _pytest_processes(),
    }


# ── 被测进程：/usr/bin/time -l 包一层，拿 RSS 与 CPU ─────────────────────────


class MeasuredRelay:
    """一个被 ``/usr/bin/time -l`` 包裹的中转进程。

    停止时给**被测进程**（而不是 ``time`` 外壳）发 SIGTERM：外壳要等到子进程退出
    才会写报告，所以杀错对象就拿不到 RSS。pid 由 ``sh -c 'echo $$; exec …'``
    写进文件——``exec`` 之后同一个 pid 就是 relay 本身。
    """

    def __init__(self, workdir: pathlib.Path, *, label: str = "relay",
                 extra_args: tuple[str, ...] = ()) -> None:
        self.workdir = workdir
        self.workdir.mkdir(parents=True, exist_ok=True)
        self.label = label
        #: 追加给被测进程的参数（例如 ``--bridge-bytes``）；口径仍由 RELAY_CMD 决定。
        self.extra_args = tuple(extra_args)
        self.db = self.workdir / "state.db"
        self.log_path = self.workdir / "relay.log"
        self.time_path = self.workdir / "time.txt"
        self.pid_path = self.workdir / "relay.pid"
        self.port = conftest.free_port()
        self.command = _command("RELAY_CMD", conftest.DEFAULT_RELAY_CMD)
        self.process: subprocess.Popen | None = None
        self._log = None

    @property
    def base(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def start(self) -> None:
        argv = [*self.command,
                "--host", "127.0.0.1", "--port", str(self.port), "--db", str(self.db),
                *self.extra_args]
        # $1 = pid 文件；shift 之后 "$@" 是真正的被测命令。
        shell = 'echo $$ > "$1"; shift; exec "$@"'
        self._log = open(self.log_path, "w", encoding="utf-8")
        self.process = subprocess.Popen(
            ["/usr/bin/time", "-l", "-o", str(self.time_path),
             "/bin/sh", "-c", shell, "sh", str(self.pid_path), *argv],
            cwd=str(RELAY_DIR), env=conftest.clean_env(),
            stdout=self._log, stderr=subprocess.STDOUT)

    def wait_ready(self, timeout: float = READY_TIMEOUT_S) -> None:
        _wait_healthz(self.process, self.base, timeout=timeout, log_path=self.log_path)

    def _relay_pid(self) -> int | None:
        try:
            return int(self.pid_path.read_text(encoding="utf-8").strip())
        except (OSError, ValueError):
            pass
        # 兜底：pid 文件还没落盘（启动失败）时，从外壳的子进程找。
        if self.process is None:
            return None
        try:
            result = subprocess.run(["pgrep", "-P", str(self.process.pid)],
                                    capture_output=True, text=True, timeout=2)
        except (OSError, subprocess.SubprocessError):
            return None
        pids = [int(token) for token in result.stdout.split() if token.isdigit()]
        return pids[0] if pids else None

    def stop(self, timeout: float = 15.0) -> None:
        if self.process is None:
            return
        relay_pid = self._relay_pid()
        if relay_pid is not None and self.process.poll() is None:
            try:
                os.kill(relay_pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        try:
            self.process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            if relay_pid is not None:
                try:
                    os.kill(relay_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            self.process.kill()
            self.process.wait(timeout=10)
        if self._log is not None:
            self._log.close()
            self._log = None

    def resources(self) -> dict[str, Any]:
        """``/usr/bin/time -l`` 的报告；拿不到时字段为 None 并带错误说明。"""
        try:
            text = self.time_path.read_text(encoding="utf-8")
        except OSError as error:
            return {"maxRssBytes": None, "cpuUserSeconds": None, "cpuSysSeconds": None,
                    "cpuTotalSeconds": None, "wallSeconds": None,
                    "error": f"读不到 time 报告：{error}"}
        cpu = _TIME_REAL.search(text)
        rss = _TIME_RSS.search(text)
        user = float(cpu.group(2)) if cpu else None
        system = float(cpu.group(3)) if cpu else None
        return {
            "maxRssBytes": int(rss.group(1)) if rss else None,
            "cpuUserSeconds": user,
            "cpuSysSeconds": system,
            "cpuTotalSeconds": round(user + system, 3) if user is not None and system is not None else None,
            "wallSeconds": float(cpu.group(1)) if cpu else None,
            "reportFile": str(self.time_path),
        }


def _wait_healthz(process: subprocess.Popen | None, base: str, *, timeout: float,
                  log_path: pathlib.Path | None = None) -> None:
    """轮询 ``/healthz`` 直到 200；进程提前退出就带日志尾巴报错。"""
    deadline = time.monotonic() + timeout
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        if process is not None and process.poll() is not None:
            tail = _tail(log_path) if log_path is not None else ""
            raise RuntimeError(
                f"中转进程提前退出（code={process.returncode}）：\n{tail}")
        try:
            with urllib.request.urlopen(f"{base}/healthz", timeout=1.0) as response:
                if response.status == 200:
                    return
        except (OSError, urllib.error.URLError) as error:
            last_error = error
        # 5 ms 采样：启动基线要的就是这个精度（conftest 的 20 ms 留给用例，够用）。
        time.sleep(0.005)
    tail = _tail(log_path) if log_path is not None else ""
    raise TimeoutError(f"{timeout}s 内没有就绪（最后一次错误：{last_error}）：\n{tail}")


# ── 启动时间 ────────────────────────────────────────────────────────────────


def _measure_startup_once(workdir: pathlib.Path) -> float:
    workdir.mkdir(parents=True, exist_ok=True)
    port = conftest.free_port()
    argv = [*_command("RELAY_CMD", conftest.DEFAULT_RELAY_CMD),
            "--host", "127.0.0.1", "--port", str(port),
            "--db", str(workdir / "state.db")]
    log_path = workdir / "relay.log"
    started = time.perf_counter()
    with open(log_path, "w", encoding="utf-8") as handle:
        process = subprocess.Popen(
            argv, cwd=str(RELAY_DIR), env=conftest.clean_env(),
            stdout=handle, stderr=subprocess.STDOUT)
    try:
        _wait_healthz(process, f"http://127.0.0.1:{port}",
                      timeout=READY_TIMEOUT_S, log_path=log_path)
        return (time.perf_counter() - started) * 1000.0
    finally:
        if process.poll() is None:
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)


def run_startup() -> dict[str, Any]:
    samples: list[float] = []
    with tempfile.TemporaryDirectory(prefix="dsh-bench-startup-") as root:
        for attempt in range(STARTUP_SAMPLES):
            samples.append(_measure_startup_once(pathlib.Path(root) / f"run{attempt}"))
            print(f"  第 {attempt + 1}/{STARTUP_SAMPLES} 次：{samples[-1]:.1f} ms")
    return {
        "samples": STARTUP_SAMPLES,
        "samplesMs": [round(value, 2) for value in samples],
        "medianMs": round(statistics.median(samples), 2),
        "minMs": round(min(samples), 2),
        "maxMs": round(max(samples), 2),
    }


# ── HTTP 压测 ───────────────────────────────────────────────────────────────


async def _http_load(base: str, path: str, *, concurrency: int, seconds: float,
                     token: str | None = None,
                     timeout: float = HTTP_TIMEOUT_S) -> dict[str, Any]:
    """固定并发、固定时长的 HTTP 读取；返回吞吐、延迟分位与状态码分布。"""
    latencies: list[float] = []
    statuses: dict[int, int] = {}
    server_error_codes: dict[str, int] = {}
    transport_errors: list[str] = []

    async with support.Client(base, timeout=timeout) as client:
        # 预热一次：连接建立与首帧路由的开销不计入测量窗口。
        warmup = await client.get(path, token=token)
        if warmup.status >= 500:
            raise RuntimeError(f"预热请求就返回 {warmup.status}：{warmup.text[:200]}")

        started = time.perf_counter()
        deadline = started + seconds

        async def worker() -> None:
            while time.perf_counter() < deadline:
                request_started = time.perf_counter()
                try:
                    response = await client.get(path, token=token)
                except Exception as error:  # noqa: BLE001 - 客户端异常本身就是指标
                    transport_errors.append(f"{type(error).__name__}: {error}")
                    continue
                latencies.append((time.perf_counter() - request_started) * 1000.0)
                statuses[response.status] = statuses.get(response.status, 0) + 1
                if response.status >= 500:
                    code = response.error_code or "unknown"
                    server_error_codes[code] = server_error_codes.get(code, 0) + 1

        await asyncio.gather(*(worker() for _ in range(concurrency)))
        elapsed = time.perf_counter() - started

    requests = len(latencies) + len(transport_errors)
    return {
        "concurrency": concurrency,
        "seconds": seconds,
        "requests": requests,
        "elapsedSeconds": round(elapsed, 3),
        "rps": round(requests / elapsed, 1) if elapsed > 0 else None,
        "statuses": {str(status): count for status, count in sorted(statuses.items())},
        "serverErrors": sum(count for status, count in statuses.items() if status >= 500),
        "serverErrorCodes": server_error_codes,
        "transportErrors": len(transport_errors),
        "transportErrorSamples": transport_errors[:3],
        "latency": _latency_summary(latencies),
    }


async def _account_state_load(base: str, db: pathlib.Path) -> dict[str, Any]:
    """在新库上建一个账户与设备，然后打 ``/account/state`` GET。"""
    async with support.Client(base, timeout=HTTP_TIMEOUT_S) as client:
        tenant = await support.enroll(client, _run_admin(db), name="BENCH-Mac-state")
        device = await support.pair_device(client, tenant, name="BENCH-iPhone-state")
        stamp = int(time.time() * 1000)
        first = await client.put("/account/state", token=device.token, json_body={"entries": [
            {"key": "benchWarm", "value": {"seq": 1}, "updatedAt": stamp}]})
        if first.status != 200:
            raise RuntimeError(f"账户状态预热写入失败：{first.status} {first.text[:200]}")
    return await _http_load(base, "/account/state",
                            concurrency=STATE_CONCURRENCY, seconds=STATE_SECONDS,
                            token=device.token)


def _aggregate_http(runs: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "rps": _median([run["rps"] for run in runs]),
        "p50Ms": _median([run["latency"]["p50Ms"] for run in runs]),
        "p95Ms": _median([run["latency"]["p95Ms"] for run in runs]),
        "p99Ms": _median([run["latency"]["p99Ms"] for run in runs]),
        "requests": _median([run["requests"] for run in runs], digits=0),
        "serverErrors": _median([run["serverErrors"] for run in runs], digits=0),
        "transportErrors": _median([run["transportErrors"] for run in runs], digits=0),
        "maxRssBytes": _median([run["resources"]["maxRssBytes"] for run in runs], digits=0),
        "cpuUserSeconds": _median([run["resources"]["cpuUserSeconds"] for run in runs]),
        "cpuSysSeconds": _median([run["resources"]["cpuSysSeconds"] for run in runs]),
        "cpuTotalSeconds": _median([run["resources"]["cpuTotalSeconds"] for run in runs]),
    }


def run_http_scenario(*, label: str, path: str, concurrency: int, seconds: float,
                      account_state: bool = False,
                      repeats: int = REPEATS) -> dict[str, Any]:
    runs: list[dict[str, Any]] = []
    with tempfile.TemporaryDirectory(prefix=f"dsh-bench-{label}-") as root:
        for attempt in range(repeats):
            relay = MeasuredRelay(pathlib.Path(root) / f"run{attempt}", label=label)
            relay.start()
            try:
                relay.wait_ready()
                if account_state:
                    metrics = asyncio.run(_account_state_load(relay.base, relay.db))
                else:
                    metrics = asyncio.run(_http_load(
                        relay.base, path, concurrency=concurrency, seconds=seconds))
            finally:
                relay.stop()
            metrics["resources"] = relay.resources()
            runs.append(metrics)
            print(f"  第 {attempt + 1}/{repeats} 次：{metrics['rps']} req/s，"
                  f"p50 {metrics['latency']['p50Ms']} ms，p99 {metrics['latency']['p99Ms']} ms，"
                  f"5xx {metrics['serverErrors']}，RSS {metrics['resources']['maxRssBytes']} B")
    return {
        "config": {"path": path, "concurrency": concurrency, "seconds": seconds,
                   "repeats": repeats},
        "runs": runs,
        "median": _aggregate_http(runs),
    }


# ── WebSocket 回显压测 ──────────────────────────────────────────────────────


async def _provision_devices(base: str, db: pathlib.Path, count: int) -> tuple[
        list[tuple[support.Tenant, support.Device]], dict[str, float]]:
    """一次铸够邀请码，然后**串行**登记 + 配对，每台设备各有一台 agent。

    准备阶段串行是有意的：``/pair/code`` 的 ``count_paired_devices`` 与
    ``/account/state`` 的 GET 共用一条未加锁的 SQLite 连接，并发调用会偶发 500。
    那正是本脚本单独测量、并如实记录的对象；准备阶段被它打断只会让 WS 场景跑不完。

    返回 ``(pairs, breakdown)``：breakdown 把供给成本拆成铸码 / 登记 / 配对三段，
    其中配对是 scrypt 的大头（每次把持久配对码重新派生校验）。
    """
    started = time.perf_counter()
    invites_started = time.perf_counter()
    invites = _run_admin(db)("invite-mint", "--ttl-seconds", "1800",
                             "--note", "bench", "--count", str(count))
    invite_seconds = time.perf_counter() - invites_started
    if isinstance(invites, dict):
        invites = [invites]
    if not isinstance(invites, list) or len(invites) < count:
        raise RuntimeError(f"邀请码数量不足：需要 {count}，拿到 {type(invites)}")

    enroll_seconds = 0.0
    pair_seconds = 0.0
    pairs: list[tuple[support.Tenant, support.Device]] = []
    async with support.Client(base, timeout=30.0) as client:
        for index in range(count):
            enroll_started = time.perf_counter()
            response = await client.post("/agents/enroll", json_body={
                "inviteCode": invites[index]["code"],
                "name": f"BENCH-Mac-{index:03d}",
            })
            enroll_seconds += time.perf_counter() - enroll_started
            if response.status != 200:
                raise RuntimeError(f"第 {index} 台 agent 登记失败："
                                   f"{response.status} {response.text[:200]}")
            body = response.json()
            tenant = support.Tenant(
                account_id=body["accountId"], agent_id=body["agentId"],
                agent_secret=body["agentSecret"], name=body["agentName"])
            pair_started = time.perf_counter()
            device = await support.pair_device(
                client, tenant, name=f"BENCH-iPhone-{index:03d}")
            pair_seconds += time.perf_counter() - pair_started
            pairs.append((tenant, device))
    return pairs, {
        "inviteSeconds": round(invite_seconds, 3),
        "enrollSeconds": round(enroll_seconds, 3),
        "pairSeconds": round(pair_seconds, 3),
        "totalSeconds": round(time.perf_counter() - started, 3),
    }


async def _agent_echo(ws: aiohttp.ClientWebSocketResponse, errors: list[str]) -> None:
    """agent 侧：收到带 ``deviceId`` 的 ``req`` 就原 id 回 ``res``（连接器的正常路径）。"""
    while True:
        try:
            message = await ws.receive()
        except asyncio.CancelledError:
            raise
        except Exception as error:  # noqa: BLE001 - 记录后退出，不吞掉整个场景
            errors.append(f"agent 读取失败：{type(error).__name__}: {error}")
            return
        if message.type is WSMsgType.TEXT:
            try:
                frame = json.loads(message.data)
            except ValueError:
                errors.append("agent 收到非 JSON 帧")
                continue
            if frame.get("t") != "req":
                # deviceAttach / deviceDetach / hostStatus 等控制帧与回显路径无关。
                continue
            reply = json.dumps({
                "t": "res", "id": frame.get("id"), "ok": True,
                "value": {"echo": frame.get("id")},
                "deviceId": frame.get("deviceId"),
            })
            try:
                await ws.send_str(reply)
            except Exception as error:  # noqa: BLE001
                errors.append(f"agent 回执失败：{type(error).__name__}: {error}")
                return
        elif message.type in (WSMsgType.CLOSE, WSMsgType.CLOSING, WSMsgType.CLOSED):
            return
        elif message.type is WSMsgType.ERROR:
            errors.append(f"agent socket 错误：{ws.exception()}")
            return


async def _device_echo(index: int, ws: aiohttp.ClientWebSocketResponse, *,
                       start_at: float, seconds: float, interval: float,
                       latencies: list[float], stats: dict[str, Any],
                       errors: list[str]) -> None:
    """一台设备的发送与回收：唯一 id 对应一帧，延迟按 id 配对。

    ``start_at`` 是这台设备的首帧时刻。同步突发模式里所有设备都等于窗口起点；
    错峰模式里按设备序号往后摊开——这样"一波 N 帧"不会同时压在一个事件循环上。
    """
    pending: dict[str, float] = {}
    sender_done = False

    async def send_loop() -> None:
        nonlocal sender_done
        sequence = 0
        now = time.perf_counter()
        if start_at > now:
            await asyncio.sleep(start_at - now)
        started_at = time.perf_counter()
        deadline = started_at + seconds
        next_at = started_at
        if stats["sendStart"] is None or started_at < stats["sendStart"]:
            stats["sendStart"] = started_at
        try:
            while time.perf_counter() < deadline:
                frame_id = f"d{index}-{sequence}"
                sequence += 1
                pending[frame_id] = time.perf_counter()
                try:
                    await ws.send_str(json.dumps(
                        {"t": "req", "id": frame_id, "method": "bench/echo"}))
                    stats["sent"] += 1
                except Exception as error:  # noqa: BLE001
                    pending.pop(frame_id, None)
                    errors.append(f"设备 {index} 发送失败：{type(error).__name__}: {error}")
                    # 连接已经不可写：继续循环只会在剩余窗口里刷同样的错误。
                    return
                next_at += interval
                delay = next_at - time.perf_counter()
                if delay > 0:
                    await asyncio.sleep(delay)
        finally:
            # 发送窗口只覆盖“发”，不把最后一段等回显的 drain 时间算进帧率。
            finished_at = time.perf_counter()
            if stats["sendEnd"] is None or finished_at > stats["sendEnd"]:
                stats["sendEnd"] = finished_at
            sender_done = True

    async def recv_loop() -> None:
        quiet_after_sender = 0
        while True:
            if sender_done and not pending:
                return
            try:
                message = await asyncio.wait_for(ws.receive(), timeout=1.0)
            except (asyncio.TimeoutError, TimeoutError):
                if sender_done:
                    quiet_after_sender += 1
                    # 发送结束后再给 2 秒安静窗口，仍未到的回显按丢失记录。
                    if quiet_after_sender >= 2:
                        return
                continue
            quiet_after_sender = 0
            if message.type is WSMsgType.TEXT:
                try:
                    frame = json.loads(message.data)
                except ValueError:
                    errors.append(f"设备 {index} 收到非 JSON 帧")
                    continue
                kind = frame.get("t")
                if kind == "res":
                    frame_id = frame.get("id")
                    sent_at = pending.pop(frame_id, None)
                    if sent_at is None:
                        errors.append(f"设备 {index} 收到无法对应的回显 {frame_id!r}")
                    else:
                        latencies.append((time.perf_counter() - sent_at) * 1000.0)
                        stats["echoed"] += 1
                elif kind == "error":
                    errors.append(f"设备 {index} 错误帧 {frame.get('code')}："
                                  f"{str(frame.get('message'))[:120]}")
            elif message.type in (WSMsgType.CLOSE, WSMsgType.CLOSING, WSMsgType.CLOSED):
                return
            elif message.type is WSMsgType.ERROR:
                errors.append(f"设备 {index} socket 错误：{ws.exception()}")
                return

    sender = asyncio.create_task(send_loop())
    receiver = asyncio.create_task(recv_loop())
    try:
        await sender
        await receiver
    finally:
        for task in (sender, receiver):
            if not task.done():
                task.cancel()
        await asyncio.gather(sender, receiver, return_exceptions=True)


async def _open_sockets(session: aiohttp.ClientSession, factories: list[Any], *,
                        concurrency: int = 64) -> list[aiohttp.ClientWebSocketResponse]:
    """并发建 WS，但限制同时在握手的条数。

    300 条连接一起发 SYN 会撞上监听队列上限（默认 backlog 128），
    表现是随机的 connection reset——那是客户端的建连方式问题，不该算进中转指标。
    """
    semaphore = asyncio.Semaphore(concurrency)

    async def one(factory: Any) -> aiohttp.ClientWebSocketResponse:
        async with semaphore:
            return await factory()

    return list(await asyncio.gather(*(one(factory) for factory in factories)))


async def _ws_echo_run(base: str, pairs: list[tuple[support.Tenant, support.Device]], *,
                       devices: int, fps: int, seconds: float, stagger_ms: float = 0.0,
                       index_offset: int = 0,
                       stride: int = 1) -> dict[str, Any]:
    selected = pairs[:devices]
    latencies: list[float] = []
    stats: dict[str, Any] = {"sent": 0, "echoed": 0, "sendStart": None, "sendEnd": None}
    errors: list[str] = []
    stagger_seconds = max(0.0, stagger_ms) / 1000.0

    # aiohttp 默认连接池上限是 100，而这里要同时开 2×设备数 条 WS；0 = 不限。
    connector = aiohttp.TCPConnector(limit=0)
    timeout = aiohttp.ClientTimeout(total=seconds + 60 + stagger_seconds * devices)
    async with aiohttp.ClientSession(connector=connector, timeout=timeout) as session:
        agent_sockets = await _open_sockets(session, [
            (lambda tenant=tenant: session.ws_connect(
                base + support.agent_socket_path(tenant),
                headers={"Authorization": f"Bearer {tenant.agent_token}"}))
            for tenant, _ in selected])
        device_sockets = await _open_sockets(session, [
            (lambda device=device: session.ws_connect(
                base + support.device_socket_path(device),
                headers={"Authorization": f"Bearer {device.token}"}))
            for _, device in selected])
        echo_tasks: list[asyncio.Task] = []
        try:
            # 握手帧：设备首帧 hostStatus、agent 侧 deviceAttach。必须先收掉，
            # 否则它们会混进回显计数的读取流里。
            hosts = await asyncio.gather(*(
                support.read_frame(ws, what="设备首帧") for ws in device_sockets))
            attaches = await asyncio.gather(*(
                support.read_frame(ws, what="agent 首帧") for ws in agent_sockets))
            for frame in hosts:
                if frame.get("t") != "hostStatus":
                    errors.append(f"设备首帧不是 hostStatus：{str(frame)[:120]}")
                elif not (frame.get("info") or {}).get("online"):
                    errors.append("设备首帧 hostStatus.online 为 false")
            for frame in attaches:
                if frame.get("t") != "deviceAttach":
                    errors.append(f"agent 首帧不是 deviceAttach：{str(frame)[:120]}")

            echo_tasks = [asyncio.create_task(_agent_echo(ws, errors))
                          for ws in agent_sockets]
            load_started = time.perf_counter()
            await asyncio.gather(*(
                _device_echo(index, ws,
                             start_at=load_started + (index_offset + index * stride) *
                             stagger_seconds,
                             seconds=seconds, interval=1.0 / fps,
                             latencies=latencies, stats=stats, errors=errors)
                for index, ws in enumerate(device_sockets)))
            load_elapsed = time.perf_counter() - load_started
        finally:
            for task in echo_tasks:
                task.cancel()
            if echo_tasks:
                await asyncio.gather(*echo_tasks, return_exceptions=True)
            await asyncio.gather(*(ws.close() for ws in device_sockets),
                                 return_exceptions=True)
            await asyncio.gather(*(ws.close() for ws in agent_sockets),
                                 return_exceptions=True)

    sent = stats["sent"]
    echoed = stats["echoed"]
    send_seconds = (stats["sendEnd"] - stats["sendStart"]
                    if stats["sendStart"] is not None and stats["sendEnd"] is not None else None)
    return {
        "devices": devices,
        "fps": fps,
        "seconds": seconds,
        "elapsedSeconds": round(load_elapsed, 3),
        "sendSeconds": round(send_seconds, 3) if send_seconds else None,
        "framesSent": sent,
        "framesEchoed": echoed,
        "missingFrames": sent - echoed,
        "echoRate": round(echoed / sent, 4) if sent else None,
        "framesPerSecond": round(sent / send_seconds, 1) if send_seconds else None,
        "errors": len(errors),
        "errorSamples": errors[:5],
        "latency": _latency_summary(latencies),
        "latencies": latencies,
    }


def _ws_worker(base: str, pairs: list[tuple[support.Tenant, support.Device]],
               fps: int, seconds: float, stagger_ms: float,
               index_offset: int, stride: int) -> dict[str, Any]:
    """一个压测客户端进程：只跑自己那一份设备（多进程拆分的入口）。

    ``spawn`` 子进程会重新 import 本文件；函数与参数因此都必须是可 pickle 的
    纯数据（Tenant/Device 是 frozen dataclass）。
    """
    return asyncio.run(_ws_echo_run(
        base, pairs, devices=len(pairs), fps=fps, seconds=seconds,
        stagger_ms=stagger_ms, index_offset=index_offset, stride=stride))


def _merge_ws_parts(parts: list[dict[str, Any]], *, devices: int, fps: int,
                    seconds: float, stagger_ms: float,
                    clients: int) -> dict[str, Any]:
    """把多个客户端进程的结果合成一份：延迟按原始样本重算分位，不平均分位数。"""
    latencies: list[float] = []
    sent = echoed = errors = 0
    send_seconds = 0.0
    elapsed = 0.0
    samples: list[str] = []
    for part in parts:
        latencies.extend(part.pop("latencies", []))
        sent += part["framesSent"]
        echoed += part["framesEchoed"]
        errors += part["errors"]
        send_seconds = max(send_seconds, part.get("sendSeconds") or 0.0)
        elapsed = max(elapsed, part["elapsedSeconds"])
        samples.extend(part.pop("errorSamples", [])[:2])
    return {
        "devices": devices,
        "fps": fps,
        "seconds": seconds,
        "staggerMs": stagger_ms,
        "clients": clients,
        "elapsedSeconds": round(elapsed, 3),
        "sendSeconds": round(send_seconds, 3) if send_seconds else None,
        "framesSent": sent,
        "framesEchoed": echoed,
        "missingFrames": sent - echoed,
        "echoRate": round(echoed / sent, 4) if sent else None,
        "framesPerSecond": round(sent / send_seconds, 1) if send_seconds else None,
        "errors": errors,
        "errorSamples": samples[:5],
        "latency": _latency_summary(latencies),
    }


def _run_ws_clients(base: str, pairs: list[tuple[support.Tenant, support.Device]], *,
                    fps: int, seconds: float, stagger_ms: float,
                    clients: int) -> dict[str, Any]:
    """按 ``clients`` 拆成多个进程跑；1 个进程就在本进程里跑（口径与旧版一致）。"""
    if clients <= 1 or len(pairs) <= 1:
        parts = [asyncio.run(_ws_echo_run(
            base, pairs, devices=len(pairs), fps=fps, seconds=seconds,
            stagger_ms=stagger_ms))]
        return _merge_ws_parts(parts, devices=len(pairs), fps=fps, seconds=seconds,
                               stagger_ms=stagger_ms, clients=1)
    clients = min(clients, len(pairs))
    chunks = [pairs[client::clients] for client in range(clients)]
    context = multiprocessing.get_context("spawn")
    with context.Pool(processes=clients) as pool:
        parts = pool.starmap(_ws_worker, [
            (base, chunk, fps, seconds, stagger_ms, client, clients)
            for client, chunk in enumerate(chunks)])
    return _merge_ws_parts(parts, devices=len(pairs), fps=fps, seconds=seconds,
                           stagger_ms=stagger_ms, clients=clients)


def _aggregate_ws(runs: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "framesSent": _median([run["framesSent"] for run in runs], digits=0),
        "framesEchoed": _median([run["framesEchoed"] for run in runs], digits=0),
        "missingFrames": _median([run["missingFrames"] for run in runs], digits=0),
        "echoRate": _median([run["echoRate"] for run in runs]),
        "framesPerSecond": _median([run["framesPerSecond"] for run in runs]),
        "errors": _median([run["errors"] for run in runs], digits=0),
        "p50Ms": _median([run["latency"]["p50Ms"] for run in runs]),
        "p95Ms": _median([run["latency"]["p95Ms"] for run in runs]),
        "p99Ms": _median([run["latency"]["p99Ms"] for run in runs]),
        "supplySeconds": _median([run["supplySeconds"] for run in runs]),
        "forwardSeconds": _median([run["forwardSeconds"] for run in runs]),
        "maxRssBytes": _median([run["resources"]["maxRssBytes"] for run in runs], digits=0),
        "cpuUserSeconds": _median([run["resources"]["cpuUserSeconds"] for run in runs]),
        "cpuSysSeconds": _median([run["resources"]["cpuSysSeconds"] for run in runs]),
        "cpuTotalSeconds": _median([run["resources"]["cpuTotalSeconds"] for run in runs]),
    }


def run_ws_scenario(*, devices: int, fps: int, seconds: float, mode: str,
                    stagger_ms: float, clients: int, label: str,
                    repeats: int) -> dict[str, Any]:
    runs: list[dict[str, Any]] = []
    root = pathlib.Path(tempfile.mkdtemp(prefix=f"dsh-bench-{label}-"))
    try:
        for attempt in range(repeats):
            relay = MeasuredRelay(root / f"run{attempt}", label=label)
            relay.start()
            try:
                relay.wait_ready()
                # 供给与转发分开计时：scrypt 的成本不该被算进转发窗口，
                # 但 RSS/CPU 仍是被测进程整条生命周期的（见报告的口径说明）。
                supply_started = time.perf_counter()
                pairs, supply = asyncio.run(
                    _provision_devices(relay.base, relay.db, devices))
                supply_seconds = time.perf_counter() - supply_started
                forward_started = time.perf_counter()
                metrics = _run_ws_clients(
                    relay.base, pairs, fps=fps, seconds=seconds,
                    stagger_ms=stagger_ms if mode == "steady" else 0.0,
                    clients=clients)
                forward_seconds = time.perf_counter() - forward_started
            finally:
                relay.stop()
            metrics["resources"] = relay.resources()
            metrics["supplySeconds"] = round(supply_seconds, 3)
            metrics["forwardSeconds"] = round(forward_seconds, 3)
            metrics["supply"] = supply
            runs.append(metrics)
            print(f"  第 {attempt + 1}/{repeats} 次：{metrics['framesEchoed']}/"
                  f"{metrics['framesSent']} 帧回显，p50 {metrics['latency']['p50Ms']} ms，"
                  f"p99 {metrics['latency']['p99Ms']} ms，错误 {metrics['errors']}，"
                  f"供给 {metrics['supplySeconds']} s / 转发 {metrics['forwardSeconds']} s，"
                  f"RSS {metrics['resources']['maxRssBytes']} B")
    finally:
        if not KEEP_WORKDIR:
            shutil.rmtree(root, ignore_errors=True)
        else:
            print(f"  [诊断] 临时目录保留在 {root}")
    return {
        "config": {"devices": devices, "fps": fps, "seconds": seconds,
                   "mode": mode, "staggerMs": stagger_ms if mode == "steady" else 0.0,
                   "clients": clients, "repeats": repeats},
        "runs": runs,
        "median": _aggregate_ws(runs),
    }


# ── 主流程 ──────────────────────────────────────────────────────────────────


def _stable_enough(ws_report: dict[str, Any]) -> tuple[bool, str]:
    for run in ws_report["runs"]:
        if run["errors"]:
            return False, f"有一次运行记录了 {run['errors']} 个错误"
        if run["echoRate"] is None or run["echoRate"] < WS_STABLE_ECHO_RATE:
            return False, f"回显率 {run['echoRate']} 低于 {WS_STABLE_ECHO_RATE}"
    return True, "100 设备三次运行均无错误且回显率达标"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="中转性能基线（手动执行；口径见 maintainers/设计/20261023-Go迁移测试基座.md）")
    parser.add_argument("--out", type=pathlib.Path,
                        help="把完整结果写成 JSON；不给就只打到 stdout")
    parser.add_argument("--with-300", action="store_true",
                        help="追加 300 设备档（100 设备不稳定时自动跳过）")
    parser.add_argument("--with-1000", action="store_true",
                        help="追加 1000 设备档（建议配 --clients 4）")
    parser.add_argument("--ws-modes", default="burst",
                        help="WS 注入模式：burst（同步突发，旧口径）/ steady（错峰），"
                             "逗号分隔；两种都跑写 burst,steady")
    parser.add_argument("--stagger-ms", type=float, default=DEFAULT_STAGGER_MS,
                        help=f"steady 模式下相邻设备的首帧间隔（毫秒，默认 "
                             f"{DEFAULT_STAGGER_MS:g}）")
    parser.add_argument("--clients", type=int, default=0,
                        help="WS 客户端进程数（0 = 自动：1000 档 4 个，其余 1 个）")
    parser.add_argument("--repeats", type=int, default=REPEATS,
                        help=f"每个场景的重复次数（默认 {REPEATS}）")
    parser.add_argument("--keep-workdir", action="store_true",
                        help="保留每个场景的临时目录（排查中转退出/崩溃时用）")
    args = parser.parse_args(argv)
    global KEEP_WORKDIR
    KEEP_WORKDIR = bool(args.keep_workdir)

    modes = [mode.strip() for mode in args.ws_modes.split(",") if mode.strip()]
    for mode in modes:
        if mode not in ("burst", "steady"):
            parser.error(f"未知的 --ws-modes 取值：{mode}（只认 burst / steady）")
    repeats = max(1, args.repeats)

    started = time.perf_counter()
    report: dict[str, Any] = {
        "generatedAt": _now_iso(),
        "environment": _environment(),
        "config": {
            "startupSamples": STARTUP_SAMPLES,
            "repeats": repeats,
            "http": {"path": "/healthz", "concurrency": HTTP_CONCURRENCY,
                     "seconds": HTTP_SECONDS},
            "accountState": {"path": "/account/state", "concurrency": STATE_CONCURRENCY,
                             "seconds": STATE_SECONDS},
            "ws": {"devices": WS_DEVICES, "fps": WS_FPS, "seconds": WS_SECONDS,
                   "modes": modes, "staggerMs": args.stagger_ms,
                   "clients": args.clients or None},
        },
        "notes": [
            "本机 ps/psutil 不可用；RSS 与 CPU 来自 /usr/bin/time -l 的 maximum resident "
            "set size 与 user+sys。",
            "启动之外每个场景跑 N 次（--repeats，默认 3），median 字段是中位数，"
            "runs 里是每次的原始值。",
            "供给（invite/enroll/pair 的 scrypt）与转发分开计时：supplySeconds 与 "
            "forwardSeconds 分别记录；RSS/CPU 仍是被测进程整条生命周期的。",
            "WS 的 burst 是同步突发（所有设备同一时刻起跑，端到端压力参考）；"
            "steady 把设备首帧按 --stagger-ms 摊开（测中转本身）。",
            "延迟均为客户端墙钟（含本地回环与中转往返），不做服务端插桩。",
            "未覆盖：2 小时 soak、磁盘满/只读库、慢客户端背压、跨机器网络。",
        ],
        "loadSamples": [{"at": "start", "loadAverage": [round(v, 3) for v in os.getloadavg()]}],
    }
    env = report["environment"]
    print("== 环境 ==")
    print(f"  {env['platform']} / {env['cpuModel']} / {env['cpuCount']} 核 / "
          f"{env['memoryBytes']} B 内存 / Python {env['pythonVersion']}")
    print(f"  RELAY_CMD={env['relayCommand']}")
    print(f"  load1/5/15={env['loadAverage']}  pytest 进程={len(env['pytestProcesses'])} 个")

    print(f"== 启动时间（{STARTUP_SAMPLES} 次）==")
    report["startup"] = run_startup()
    print(f"  中位数 {report['startup']['medianMs']} ms")

    print(f"== HTTP /healthz（并发 {HTTP_CONCURRENCY}，{HTTP_SECONDS:g} 秒 × {repeats}）==")
    report["httpHealthz"] = run_http_scenario(
        label="healthz", path="/healthz",
        concurrency=HTTP_CONCURRENCY, seconds=HTTP_SECONDS, repeats=repeats)
    report["loadSamples"].append(
        {"at": "afterHttpHealthz", "loadAverage": [round(v, 3) for v in os.getloadavg()]})

    print(f"== 账户状态 GET（并发 {STATE_CONCURRENCY}，{STATE_SECONDS:g} 秒 × {repeats}）==")
    report["accountState"] = run_http_scenario(
        label="account-state", path="/account/state",
        concurrency=STATE_CONCURRENCY, seconds=STATE_SECONDS, account_state=True,
        repeats=repeats)
    report["loadSamples"].append(
        {"at": "afterAccountState", "loadAverage": [round(v, 3) for v in os.getloadavg()]})

    # 场景表：(设备数, 报告键前缀, 标签)。100 档的 burst 沿用旧键名 wsEcho，
    # 让历史 JSON 与报告的口径可以直接对照。
    plan: list[tuple[int, str, str]] = [(WS_DEVICES, "wsEcho", "ws-100")]
    if args.with_300:
        plan.append((WS_OPTIONAL_DEVICES, "wsEcho300", "ws-300"))
    if args.with_1000:
        plan.append((WS_LARGE_DEVICES, "wsEcho1000", "ws-1000"))

    printed_keys: list[tuple[str, int, str]] = []
    for devices, key, label in plan:
        for mode in modes:
            scenario_key = key if mode == "burst" else f"{key}Steady"
            clients = args.clients or (4 if devices >= WS_LARGE_DEVICES else 1)
            title = f"WS 回显（{devices} 设备 × {WS_FPS} 帧/秒 × {WS_SECONDS:g} 秒，" \
                    f"{mode}" + (f"，错峰 {args.stagger_ms:g} ms" if mode == "steady" else "") + \
                    f"，{clients} 个客户端）"
            if devices == WS_OPTIONAL_DEVICES and key == "wsEcho300" and "wsEcho" in report:
                stable, reason = _stable_enough(report["wsEcho"])
                if not stable:
                    print(f"== 跳过 {devices} 设备档：{reason} ==")
                    report[scenario_key] = {"skipped": True, "reason": reason}
                    continue
            print(f"== {title} ==")
            report[scenario_key] = run_ws_scenario(
                devices=devices, fps=WS_FPS, seconds=WS_SECONDS, mode=mode,
                stagger_ms=args.stagger_ms, clients=clients, label=label,
                repeats=repeats)
            printed_keys.append((scenario_key, devices, mode))
        report["loadSamples"].append(
            {"at": f"afterWs{devices}", "loadAverage": [round(v, 3) for v in os.getloadavg()]})

    report["loadSamples"].append(
        {"at": "end", "loadAverage": [round(v, 3) for v in os.getloadavg()]})
    report["elapsedSeconds"] = round(time.perf_counter() - started, 1)

    payload = json.dumps(report, ensure_ascii=False, indent=2)
    if args.out is not None:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(payload + "\n", encoding="utf-8")
        print(f"\n已写入 {args.out}")

    print(f"\n== 汇总（{repeats} 次中位数）==")
    print(f"  启动            {report['startup']['medianMs']} ms")
    for key, title in (("httpHealthz", "HTTP /healthz"), ("accountState", "GET /account/state")):
        median = report[key]["median"]
        print(f"  {title:<15} {median['rps']} req/s  p50 {median['p50Ms']} ms  "
              f"p99 {median['p99Ms']} ms  5xx {median['serverErrors']}  "
              f"RSS {median['maxRssBytes']} B  CPU {median['cpuTotalSeconds']} s")
    for scenario_key, devices, mode in printed_keys:
        scenario = report[scenario_key]
        if scenario.get("skipped"):
            print(f"  WS {devices} {mode:<6} 跳过：{scenario['reason']}")
            continue
        median = scenario["median"]
        print(f"  WS {devices:<4} {mode:<6} {median['framesPerSecond']} 帧/s  "
              f"p50 {median['p50Ms']} ms  p95 {median['p95Ms']} ms  "
              f"p99 {median['p99Ms']} ms  回显 {median['echoRate']}  "
              f"错误 {median['errors']}  RSS {median['maxRssBytes']} B  "
              f"CPU {median['cpuTotalSeconds']} s  供给 {median['supplySeconds']} s  "
              f"转发 {median['forwardSeconds']} s")
    print(f"  总耗时 {report['elapsedSeconds']} s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
