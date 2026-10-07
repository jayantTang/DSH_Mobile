#!/usr/bin/env python3
"""A long-lived local relay + the real connector, for the P-13c simulator run.

The relay's own e2e scenario (`files_down_resume_e2e.py`) starts everything for
the length of one function and tears it down again. That is the right shape for
an in-process assertion, but the acceptance this file exists for is driven from
**outside** the process: an iOS simulator app downloads through it, and its
interruption timing is not something the harness can await. So the pieces are
the same and the lifetime is inverted — start, print what the app needs, and
stay up until told to stop.

What it provisions, and why each piece is the real one:

  * the relay app from `relay/relay.py`, with the same `Limits` the CLI would
    build, so the byte accounting the acceptance reads is the shipping one;
  * a device paired through `POST /pair/claim`, whose token the app is given;
  * the **real connector** (`plugins/mobile-link/lib/cli.js`) as a subprocess,
    pointed at the live local DSH — the same code path a user's machine runs.

The fixture file is written into the workspace of a real session of this
repository, because the connector resolves `scopeId` to a session's workspace
and nothing outside it is readable.

Usage:
    p13c-accept-harness.py start --bytes 40000000 [--daily-mb 0] [--rate-kbps 0]
    p13c-accept-harness.py stop <state-file>
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import hashlib
import json
import os
import pathlib
import shutil
import signal
import sys
import tempfile
import time

REPOSITORY = pathlib.Path(__file__).resolve().parents[3]
RELAY_DIR = REPOSITORY / "relay"
CONNECTOR_DIR = REPOSITORY / "plugins" / "mobile-link"
sys.path.insert(0, str(RELAY_DIR))
sys.path.insert(0, str(RELAY_DIR / "tests"))

import relay as relay_module  # noqa: E402
from aiohttp import web  # noqa: E402
from hub import Limits  # noqa: E402
from store import Store  # noqa: E402

BASE_PATH = "/dsh-link"
FIXTURE_DIR = REPOSITORY / ".p13c-accept-scratch"


def pick_session_scope() -> str | None:
    """A real session id whose workspace is this repository.

    Same lookup as the relay's own e2e: DSH names a session directory after the
    workspace path, so the directory name is the lookup and the entry inside it
    is the id. Read-only.
    """
    tail = str(REPOSITORY).replace("/", "-").lstrip("-")
    sessions = pathlib.Path(os.environ.get("DSH_HOME", pathlib.Path.home() / ".dsh")) / "sessions"
    if not sessions.is_dir():
        return None
    for workspace in sorted(sessions.iterdir()):
        if not workspace.is_dir() or tail not in workspace.name:
            continue
        for entry in sorted(workspace.iterdir(), reverse=True):
            if entry.is_dir():
                return entry.name
    return None


def local_dsh_port() -> int:
    home = pathlib.Path(os.environ.get("DSH_HOME", pathlib.Path.home() / ".dsh"))
    try:
        return int(json.loads((home / "mobile-link" / "endpoint.json").read_text())["port"])
    except (OSError, ValueError, KeyError, json.JSONDecodeError):
        return 54499


def free_port() -> int:
    import socket
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


async def run_start(args: argparse.Namespace) -> int:
    scope_id = pick_session_scope()
    if scope_id is None:
        print("FAIL: no session of this repository exists on this machine")
        return 1

    FIXTURE_DIR.mkdir(exist_ok=True)
    body = bytes((i * 31 + 7) % 256 for i in range(args.bytes))
    fixture = FIXTURE_DIR / "p13c-accept.bin"
    fixture.write_bytes(body)
    digest = hashlib.sha256(body).hexdigest()

    workdir = pathlib.Path(tempfile.mkdtemp(prefix="p13c-accept-"))
    db_path = str(workdir / "state.db")
    port = args.port or free_port()
    base = f"http://127.0.0.1:{port}"
    public_base = f"{base}{BASE_PATH}"
    relay_url = f"ws://127.0.0.1:{port}{BASE_PATH}"

    store = Store(db_path)
    limits = Limits(queue_depth=args.queue_depth, device_bytes_per_second=args.rate_kbps * 125.0,
                    device_daily_bytes=int(args.daily_mb * 1024 * 1024))
    app = relay_module.create_app(store=store, limits=limits,
                                  pair_ttl_ms=120_000, base_path=BASE_PATH)
    runner = web.AppRunner(app, access_log=None)
    await runner.setup()
    await web.TCPSite(runner, "127.0.0.1", port).start()

    def admin(*argv: str) -> dict:
        import subprocess
        out = subprocess.check_output(
            [sys.executable, str(RELAY_DIR / "admin.py"), "--db", db_path, *argv],
            text=True,
        )
        return json.loads(out) if out.strip().startswith(("{", "[")) else {"raw": out}

    account = admin("account-create", "--name", "p13c acceptance")
    agent_record = admin("agent-register", "--account", account["accountId"], "--name", "p13c mac",
                         "--relay", relay_url, "--write-config", str(workdir / "agent.json"))
    minted = admin("code-mint", "--agent", agent_record["agentId"], "--ttl-seconds", "600")

    import aiohttp
    async with aiohttp.ClientSession() as session:
        async with session.post(f"{public_base}/pair/claim", json={
            "pairCode": minted["code"], "deviceName": args.device_name,
            "deviceModel": "simulator", "appVersion": "p13c-acceptance",
        }) as response:
            claimed = await response.json()
    if claimed.get("ok") is not True:
        print(f"FAIL: /pair/claim {claimed}")
        return 1

    status_file = workdir / "agent-status.json"
    identity_file = workdir / "agent-identity.json"
    log_path = pathlib.Path(args.log).resolve() if args.log else workdir / "connector.log"
    log_handle = log_path.open("ab")
    agent_process = await asyncio.create_subprocess_exec(
        "node", str(CONNECTOR_DIR / "lib" / "cli.js"),
        "--relay", relay_url,
        "--agent-id", agent_record["agentId"],
        "--agent-secret", agent_record["agentSecret"],
        "--state-file", str(identity_file),
        "--status-file", str(status_file),
        "--log-level", "debug",
        stdout=log_handle, stderr=asyncio.subprocess.STDOUT,
        cwd=str(CONNECTOR_DIR),
    )

    # Wait for the connector to be up and to have found the local DSH.
    connected = False
    for _ in range(300):
        await asyncio.sleep(0.1)
        try:
            status = json.loads(status_file.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        if status.get("connected") is True and status.get("dsh", {}).get("port"):
            connected = True
            break
    if not connected:
        print("FAIL: the connector never connected")
        agent_process.terminate()
        return 1

    state = {
        "scopeId": scope_id,
        "fixturePath": str(fixture),
        "fixtureBytes": len(body),
        "fixtureSha256": digest,
        "baseUrl": public_base,
        "relayUrl": relay_url,
        "port": port,
        "dbPath": db_path,
        "workdir": str(workdir),
        "deviceId": claimed["deviceId"],
        "deviceToken": claimed["deviceToken"],
        "agentId": claimed["agentId"],
        "localDshPort": local_dsh_port(),
        "connectorPid": agent_process.pid,
        "connectorLog": str(log_path),
        "startedAt": time.time(),
    }
    state_path = pathlib.Path(args.state).resolve()
    state_path.write_text(json.dumps(state, indent=2))
    print(json.dumps(state, indent=2))
    print(f"\n[harness] up. state={state_path}", flush=True)

    stopping = asyncio.Event()

    def _stop(*_a):
        stopping.set()

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        with contextlib.suppress(NotImplementedError):
            loop.add_signal_handler(sig, _stop)

    await stopping.wait()
    print("[harness] stopping", flush=True)
    agent_process.terminate()
    with contextlib.suppress(Exception):
        await asyncio.wait_for(agent_process.wait(), 10)
    log_handle.close()
    await runner.cleanup()
    store.close()
    shutil.rmtree(FIXTURE_DIR, ignore_errors=True)
    shutil.rmtree(workdir, ignore_errors=True)
    state_path.unlink(missing_ok=True)
    return 0


def run_stop(state_file: str) -> int:
    path = pathlib.Path(state_file)
    if not path.exists():
        print("nothing to stop")
        return 0
    state = json.loads(path.read_text())
    pid = state.get("connectorPid")
    if pid:
        with contextlib.suppress(ProcessLookupError, PermissionError):
            os.kill(pid, signal.SIGTERM)
    print(f"stopped connector {pid}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    start = sub.add_parser("start")
    start.add_argument("--bytes", type=int, default=40_000_000)
    start.add_argument("--daily-mb", type=float, default=0.0)
    start.add_argument("--rate-kbps", type=float, default=0.0)
    start.add_argument("--queue-depth", type=int, default=512)
    start.add_argument("--port", type=int, default=0)
    start.add_argument("--device-name", default="DSH-P13c")
    start.add_argument("--state", default="/tmp/p13c-accept-state.json")
    start.add_argument("--log", default="")
    stop = sub.add_parser("stop")
    stop.add_argument("state")
    args = parser.parse_args()
    if args.command == "start":
        return asyncio.run(run_start(args))
    return run_stop(args.state)


if __name__ == "__main__":
    raise SystemExit(main())
