"""黑盒测试的进程夹具：起一个真中转、给它临时库、随机端口，用完清理。

用例只认两个环境变量：

``RELAY_CMD``
    被测中转的启动命令。默认是本仓库的 Go 二进制
    （``relay-go/bin/dsh-relay serve``）；换别的实现就写成
    ``RELAY_CMD="./dsh-relay"``。命令后面会被追加
    ``--host 127.0.0.1 --port <随机端口> --db <临时库>``。

``ADMIN_CMD``
    管理面命令（初始化数据用，不属于被测协议）。默认是
    ``relay-go/bin/dsh-relay admin``；调用时追加 ``--db <临时库> <子命令>``，
    它必须把 JSON 打到 stdout。

隔离：临时目录来自 ``tmp_path_factory``，数据库是临时文件，端口随机；
子进程环境里所有 ``DLP_*`` 变量都被清掉，避免继承真实部署的配置。
"""

from __future__ import annotations

import json
import os
import pathlib
import shlex
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from typing import Any, Iterator

import pytest

from . import support

#: 仓库里的 ``relay-go/`` 目录（本文件在 ``relay-go/tests/blackbox/``）。
RELAY_DIR = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_BIN = RELAY_DIR / "bin" / "dsh-relay"

DEFAULT_RELAY_CMD = f"{shlex.quote(str(DEFAULT_BIN))} serve"
DEFAULT_ADMIN_CMD = f"{shlex.quote(str(DEFAULT_BIN))} admin"

#: 等 ``/healthz`` 的上限。启动慢要表现成"启动失败 + 日志尾巴"，不是挂死。
STARTUP_TIMEOUT_S = float(os.environ.get("BLACKBOX_STARTUP_TIMEOUT_S", "20"))
#: 单次管理命令的上限。
ADMIN_TIMEOUT_S = 30.0


def free_port() -> int:
    """要一个此刻空闲的端口（监听前可能有竞争，够用）。"""
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


def _command(variable: str, default: str) -> list[str]:
    raw = os.environ.get(variable, "").strip() or default
    parts = shlex.split(raw)
    assert parts, f"{variable} 是空命令"
    return parts


def clean_env() -> dict[str, str]:
    """子进程环境：不继承任何 ``DLP_*``，避免读到本机真实部署的配置。"""
    env = {key: value for key, value in os.environ.items() if not key.startswith("DLP_")}
    # 推送默认关闭：黑盒用例不碰 APNs，也不该因为本机配了钥匙而改变行为。
    env["DLP_APNS_ENABLED"] = "0"
    return env


class RelayProcess:
    """一个真的中转进程，自带临时库与日志文件。"""

    def __init__(self, workdir: pathlib.Path, *, extra_args: tuple[str, ...] = (),
                 label: str = "relay") -> None:
        self.workdir = workdir
        self.workdir.mkdir(parents=True, exist_ok=True)
        self.label = label
        self.db = workdir / "state.db"
        self.log_path = workdir / "relay.log"
        self.port = free_port()
        self.extra_args = tuple(extra_args)
        self.command = _command("RELAY_CMD", DEFAULT_RELAY_CMD)
        self.admin_command = _command("ADMIN_CMD", DEFAULT_ADMIN_CMD)
        self.process: subprocess.Popen | None = None
        self._log = None

    # ── 进程 ────────────────────────────────────────────────────────────

    def start(self) -> None:
        self._log = open(self.log_path, "w", encoding="utf-8")
        argv = [*self.command,
                "--host", "127.0.0.1", "--port", str(self.port), "--db", str(self.db),
                *self.extra_args]
        self.process = subprocess.Popen(
            argv, cwd=str(RELAY_DIR), env=clean_env(),
            stdout=self._log, stderr=subprocess.STDOUT)

    def wait_ready(self, timeout: float = STARTUP_TIMEOUT_S) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.process is not None and self.process.poll() is not None:
                raise AssertionError(
                    f"中转进程提前退出（code={self.process.returncode}）：\n{self.logs()[-2000:]}")
            try:
                with urllib.request.urlopen(f"{self.base}/healthz", timeout=1.0) as response:
                    if response.status == 200:
                        return
            except (OSError, urllib.error.URLError):
                pass
            time.sleep(0.02)
        raise AssertionError(f"中转在 {timeout}s 内没有就绪：\n{self.logs()[-2000:]}")

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

    # ── 观测 ────────────────────────────────────────────────────────────

    @property
    def base(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def logs(self) -> str:
        try:
            return self.log_path.read_text(encoding="utf-8")
        except OSError:
            return ""

    # ── 管理面 ──────────────────────────────────────────────────────────

    def admin(self, *args: str) -> Any:
        """跑一次 ``ADMIN_CMD --db <临时库> ...``，解析它的 JSON 输出。"""
        result = subprocess.run(
            [*self.admin_command, "--db", str(self.db), *args],
            capture_output=True, text=True, timeout=ADMIN_TIMEOUT_S, env=clean_env())
        assert result.returncode == 0, (
            f"admin.py {' '.join(args)} 失败（code={result.returncode}）："
            f"{result.stderr.strip() or result.stdout.strip()}")
        text = result.stdout.strip()
        return json.loads(text) if text else None


# ── 夹具 ────────────────────────────────────────────────────────────────────


@pytest.fixture(scope="session")
def relay(tmp_path_factory: pytest.TempPathFactory) -> Iterator[RelayProcess]:
    """整个会话共用的一个中转进程（默认限额：设备上限不限）。"""
    instance = RelayProcess(tmp_path_factory.mktemp("blackbox-relay"), label="relay")
    instance.start()
    try:
        instance.wait_ready()
        yield instance
    finally:
        instance.stop()


@pytest.fixture(scope="session")
def device_limit_relay(tmp_path_factory: pytest.TempPathFactory) -> Iterator[RelayProcess]:
    """每 agent 只允许一台设备在线的中转：用来验证拒连帧与关闭码 4012。"""
    instance = RelayProcess(tmp_path_factory.mktemp("blackbox-device-limit"),
                            extra_args=("--max-devices-per-agent", "1"),
                            label="device-limit")
    instance.start()
    try:
        instance.wait_ready()
        yield instance
    finally:
        instance.stop()


@pytest.fixture
async def client(relay: RelayProcess) -> Any:
    """默认中转的 HTTP/WS 客户端。"""
    async with support.Client(relay.base) as instance:
        yield instance


@pytest.fixture
async def tenant(relay: RelayProcess, client: support.Client) -> support.Tenant:
    """一整套隔离好的身份：新账户 + 新 agent（每次用例一份）。"""
    return await support.enroll(client, relay.admin)


@pytest.fixture
async def device(client: support.Client, tenant: support.Tenant) -> support.Device:
    """``tenant`` 名下的一台已配对设备。"""
    return await support.pair_device(client, tenant)


def pytest_terminal_summary(terminalreporter: Any, *_args: Any) -> None:
    """把探针记下的数字打出来。

    ``-q`` 会把用例自己的 stdout 藏起来，而"并发探针这次撞了几次 5xx"是必须
    看得见的信息，所以放在收尾摘要里打，不依赖 ``-rA`` / ``-s``。
    """
    if not support.PROBE_NOTES:
        return
    terminalreporter.write_sep("-", "黑盒探针")
    for line in support.PROBE_NOTES:
        terminalreporter.write_line(line)
