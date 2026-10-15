"""M5 切换演练（DESIGN-20261015）：真 relay + 真 mail + 真 Caddy 的全链路。

覆盖切换当晚要发生的每一步，顺序即演练顺序：

1. 双服务并行（relay :A、mail :B，mail 指向 relay 的内部令牌接口）。
2. 切换前：一封信经**中转**提交（老路径直连），拿到取件凭据。
3. 迁表：migrate_from_relay.py 把 4 张表搬进 mail 的库。
4. Caddy 双片段上线：`/dsh-link/feedback/*` 从此到 mail，其余 `/dsh-link/*` 仍到中转。
5. 老凭据经**新路径**取件（迁移数据可读）；新提交落 mail 的库、不落中转的。
6. 配对设备的令牌经真实内部接口解析：带令牌的提交把线程绑到账号（I-1 全链路）。
7. `/dsh-link/stats` 公网仍 404（两个片段共存不破既有保证）。
8. **重启 mail 期间，经 Caddy 的 agent WSS 链路不断**——owner 拆分的原始诉求。

没有 caddy 的机器上跳过（与 relay/tests/test_caddy_runtime.py 同一条约定）；
生产切换本身（夜间窗口、真数据）不在本文件，等 owner 排期。
"""

from __future__ import annotations

import asyncio
import json
import os
import pathlib
import shutil
import socket
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request

import pytest

RELAY_DIR = pathlib.Path(__file__).resolve().parents[2] / "relay"
MAIL_DIR = pathlib.Path(__file__).resolve().parents[1]
RELAY_SPLICER = RELAY_DIR / "deploy" / "caddy_splice.py"
MAIL_SPLICER = MAIL_DIR / "deploy" / "caddy_splice.py"
RELAY_SNIPPET = RELAY_DIR / "deploy" / "Caddyfile.snippet"
MAIL_SNIPPET = MAIL_DIR / "deploy" / "Caddyfile.snippet"
MIGRATE = MAIL_DIR / "deploy" / "migrate_from_relay.py"
CADDY = shutil.which("caddy")

if CADDY is None and os.environ.get("DSH_REQUIRE_CADDY"):
    raise RuntimeError("DSH_REQUIRE_CADDY 已设置但没有 caddy：切换演练会静默跳过")

pytestmark = pytest.mark.skipif(CADDY is None, reason="the caddy binary is not installed")

SITE = """\
{{
	admin off
	auto_https off
}}

http://127.0.0.1:{proxy_port} {{
	handle /patent-landscape/* {{
		respond "patent"
	}}
	handle {{
		respond "site"
	}}
}}
"""


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


def wait_for_port(port: int, timeout: float = 15.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with socket.socket() as probe:
            probe.settimeout(0.25)
            if probe.connect_ex(("127.0.0.1", port)) == 0:
                return
        time.sleep(0.05)
    raise AssertionError(f"nothing came up on 127.0.0.1:{port} within {timeout}s")


def request(method: str, url: str, payload: dict | None = None,
            headers: dict | None = None) -> tuple[int, dict | str]:
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"content-type": "application/json", **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            body = response.read().decode("utf-8", "replace")
            return response.status, (json.loads(body) if body.strip().startswith("{") else body)
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", "replace")
        return error.code, (json.loads(body) if body.strip().startswith("{") else body)


def run_cli(*argv: str) -> dict:
    result = subprocess.run([sys.executable, *argv], capture_output=True, text=True, check=True)
    return json.loads(result.stdout)


@pytest.fixture
def stack(tmp_path):
    """真 relay + 真 mail + 真 Caddy，按切换当晚的顺序搭起来。"""
    relay_port, mail_port, proxy_port = free_port(), free_port(), free_port()
    relay_db = tmp_path / "state.db"
    mail_db = tmp_path / "mail.db"
    processes: list[subprocess.Popen] = []

    def start(python: str, script: pathlib.Path, *args: str) -> subprocess.Popen:
        proc = subprocess.Popen([python, str(script), *args],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        processes.append(proc)
        return proc

    # 1. 双服务并行；mail 的内部解析指向**真中转**（不是假对象）。
    start(sys.executable, RELAY_DIR / "relay.py", "--host", "127.0.0.1",
          "--port", str(relay_port), "--db", str(relay_db))
    wait_for_port(relay_port)
    start(sys.executable, MAIL_DIR / "mail.py", "--host", "127.0.0.1",
          "--port", str(mail_port), "--db", str(mail_db),
          "--relay-internal-url", f"http://127.0.0.1:{relay_port}")
    wait_for_port(mail_port)

    # 2. 切换前：一封信走老路径（中转自己的 /feedback/*）。
    status, letter = request("POST", f"http://127.0.0.1:{relay_port}/feedback/submit",
                             {"text": "切换前经中转提交的信", "subject": "老路径"})
    assert status == 200, letter

    # 3. 迁表（真实脚本、真实两库）。
    subprocess.run([sys.executable, str(MIGRATE), "--from", str(relay_db),
                    "--to", str(mail_db)], capture_output=True, text=True, check=True)

    # 4. Caddy 双片段：各用各的 splicer（生产部署脚本就是这么拼的）。
    caddyfile = tmp_path / "Caddyfile"
    caddyfile.write_text(SITE.format(proxy_port=proxy_port))
    site = f"127.0.0.1:{proxy_port}"
    for splicer, snippet in ((RELAY_SPLICER, RELAY_SNIPPET), (MAIL_SPLICER, MAIL_SNIPPET)):
        subprocess.run([sys.executable, str(splicer), "insert", str(caddyfile),
                        str(snippet), site], capture_output=True, text=True, check=True)
    spliced = caddyfile.read_text()
    spliced = spliced.replace("127.0.0.1:8787", f"127.0.0.1:{relay_port}")
    spliced = spliced.replace("127.0.0.1:8788", f"127.0.0.1:{mail_port}")
    caddyfile.write_text(spliced)
    caddy_proc = subprocess.Popen(
        [CADDY, "run", "--config", str(caddyfile), "--adapter", "caddyfile"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    processes.append(caddy_proc)
    wait_for_port(proxy_port)

    try:
        yield {
            "relay_port": relay_port, "mail_port": mail_port, "proxy_port": proxy_port,
            "relay_db": relay_db, "mail_db": mail_db,
            "letter": letter, "processes": processes,
            "start": start,
        }
    finally:
        for proc in processes:
            proc.terminate()
        for proc in processes:
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()


async def test_the_full_cutover_rehearsal(stack):
    import aiohttp  # noqa: PLC0415 —— 演练里只有 WSS 那步需要它

    proxy = f"http://127.0.0.1:{stack['proxy_port']}"
    relay_db, mail_db = stack["relay_db"], stack["mail_db"]

    # 5a. 老凭据经新路径取件：迁移过来的信在 mail 那边读得到。
    status, inbox = request("POST", f"{proxy}/dsh-link/feedback/inbox", {
        "tickets": [{"threadId": stack["letter"]["threadId"],
                     "ticketKey": stack["letter"]["ticketKey"]}]})
    assert status == 200, inbox
    assert [t["threadId"] for t in inbox["threads"]] == [stack["letter"]["threadId"]]
    assert inbox["threads"][0]["subject"] == "老路径"

    # 5b. 新提交经公网路径落 mail 的库，不落中转的。
    status, fresh = request("POST", f"{proxy}/dsh-link/feedback/submit",
                            {"text": "切换后经新路径提交的信"})
    assert status == 200, fresh

    def thread_ids(db: pathlib.Path) -> set[str]:
        conn = sqlite3.connect(db)
        try:
            return {row[0] for row in conn.execute("SELECT threadId FROM feedbackThreads")}
        finally:
            conn.close()

    mail_threads = thread_ids(mail_db)
    assert {stack["letter"]["threadId"], fresh["threadId"]} <= mail_threads
    assert fresh["threadId"] not in thread_ids(relay_db), "新信必须只落 mail"

    # 5c. 其余 /dsh-link/* 仍到中转（healthz 的形状是两服务可区分的判据）。
    status, health = request("GET", f"{proxy}/dsh-link/healthz")
    assert status == 200 and isinstance(health, dict) and "version" in health, health

    # 6. 配对设备的令牌经真实内部接口解析（I-1 全链路，非假对象）。
    account = run_cli(str(RELAY_DIR / "admin.py"), "--db", str(relay_db),
                      "account-create", "--name", "演练账号")
    agent = run_cli(str(RELAY_DIR / "admin.py"), "--db", str(relay_db),
                    "agent-register", "--account", account["accountId"], "--name", "演练电脑")
    code = run_cli(str(RELAY_DIR / "admin.py"), "--db", str(relay_db),
                   "code-mint", "--agent", agent["agentId"])
    status, claimed = request("POST", f"http://127.0.0.1:{stack['relay_port']}/pair/claim",
                              {"pairCode": code["code"], "deviceName": "DSH-Rehearsal",
                               "model": "iPhone17,1"})
    assert status == 200, claimed
    status, bound = request("POST", f"{proxy}/dsh-link/feedback/submit",
                            {"text": "配对设备经内部接口解析的提交"},
                            headers={"Authorization": f"Bearer {claimed['deviceToken']}"})
    assert status == 200, bound
    conn = sqlite3.connect(mail_db)
    try:
        row = conn.execute("SELECT accountId FROM feedbackThreads WHERE threadId=?",
                           (bound["threadId"],)).fetchone()
    finally:
        conn.close()
    assert row and row[0] == account["accountId"], "令牌应经中转解析并绑到账号"

    # 7. /dsh-link/stats 公网仍 404：两个片段共存不破既有保证。
    status, _ = request("GET", f"{proxy}/dsh-link/stats")
    assert status == 404

    # 8. 重启 mail 期间，经 Caddy 的 agent WSS 链路不断（owner 的原始诉求）。
    async with aiohttp.ClientSession() as session:
        ws = await session.ws_connect(
            f"ws://127.0.0.1:{stack['proxy_port']}/dsh-link/link/agent?agentId={agent['agentId']}",
            headers={"Authorization": f"Bearer {agent['agentSecret']}"})
        try:
            # mail 硬杀 + 重启：链路应当全程无感。
            mail_proc = next(p for p in stack["processes"]
                             if "mail.py" in " ".join(p.args))
            mail_proc.kill()
            mail_proc.wait(timeout=5)
            restarted = stack["start"](sys.executable, MAIL_DIR / "mail.py",
                                       "--host", "127.0.0.1", "--port", str(stack["mail_port"]),
                                       "--db", str(mail_db),
                                       "--relay-internal-url",
                                       f"http://127.0.0.1:{stack['relay_port']}")
            wait_for_port(stack["mail_port"])
            await asyncio.sleep(1.0)

            assert not ws.closed, "mail 的重启不许碰到经 Caddy 的链路"
            assert restarted.poll() is None, "mail 重启后应当活着"
            # 链路还活着的一个正向证据：中转继续经 Caddy 应答。
            status, _ = request("GET", f"{proxy}/dsh-link/healthz")
            assert status == 200

            # mail 恢复后信件立刻可用（无状态服务 + 库在外部）。
            status, _ = request("POST", f"{proxy}/dsh-link/feedback/inbox",
                                {"tickets": [{"threadId": fresh["threadId"],
                                              "ticketKey": fresh["ticketKey"]}]})
            assert status == 200, "mail 重启后取件恢复"
        finally:
            await ws.close()
