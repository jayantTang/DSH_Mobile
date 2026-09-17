#!/usr/bin/env python3
"""End-to-end proof of the DSH mobile-link middle tier.

Runs the *real* relay, the *real* Node agent, and a fake iOS device: no relay
host and no iPhone are needed.

    relay/.venv/bin/python relay/tests/integration_e2e.py

Steps:
  1. start the relay in-process on a free port over plain HTTP/WS
  2. provision account + agent + pairing code through relay/admin.py, then
     claim a device token through POST /pair/claim
  3. start the agent CLI against the local DSH instance on 127.0.0.1:54499
  4. connect the fake device over WS and
       * run `session/list` and assert real sessions come back
       * open `$events` and assert a `ready` frame with a `clientId`
       * open `session/follow` on a real idle session and assert frames flow
       * `cancel` that stream
  5. drop the device socket, reconnect, and run `session/list` again

Only read-only DSH endpoints are used (session/list, session/follow, $events).
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import os
import pathlib
import shutil
import sys
import tempfile
import time
from collections import deque
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from aiohttp import ClientSession, ClientTimeout, web  # noqa: E402

import relay as relay_module  # noqa: E402
from e2e_support import (  # noqa: E402
    AGENT_DIR, DEVICE_MODEL, DEVICE_NAME, STEP_TIMEOUT, FrameReader, StepFailure,
    admin, check, free_port, is_ready, local_dsh_port, new_diagnostics, pick_followable,
    wait_status,
)
from hub import Limits  # noqa: E402
from store import Store  # noqa: E402


async def mint_via_agent(node: str, relay_url: str, agent_record: dict) -> dict:
    """Run `cli.js --mint-pair-code`, i.e. the connector's real pairing path."""
    proc = await asyncio.create_subprocess_exec(
        node, str(AGENT_DIR / "lib" / "cli.js"), "--mint-pair-code",
        "--relay", relay_url,
        "--agent-id", agent_record["agentId"],
        "--agent-secret", agent_record["agentSecret"],
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        cwd=str(AGENT_DIR),
    )
    out, err = await proc.communicate()
    if proc.returncode != 0:
        raise StepFailure(f"cli.js --mint-pair-code failed: {err.decode('utf-8', 'replace').strip()}")
    try:
        return json.loads(out.decode("utf-8"))
    except json.JSONDecodeError as error:
        raise StepFailure(f"--mint-pair-code did not print JSON: {out[:200]!r} ({error})")


async def run_integration(diagnostics: deque[str] | None = None) -> dict:
    node = shutil.which("node")
    check(node is not None, f"node is on PATH ({node})")
    workdir = pathlib.Path(tempfile.mkdtemp(prefix="mobile-link-e2e-"))
    db_path = str(workdir / "state.db")
    port = free_port()
    # The relay is published as a path prefix on an existing site (Caddy's
    # handle_path strips it); the integration run mounts it the same way and
    # also asserts the un-prefixed form still answers.
    base_path = "/dsh-link"
    base = f"http://127.0.0.1:{port}"
    ws_base = f"ws://127.0.0.1:{port}"
    public_base = f"{base}{base_path}"
    relay_url = f"{ws_base}{base_path}"
    agent_process: asyncio.subprocess.Process | None = None
    relay_runner: web.AppRunner | None = None
    store: Store | None = None
    agent_lines = diagnostics if diagnostics is not None else new_diagnostics()
    result: dict = {}
    _pumps: list[asyncio.Task] = []

    try:
        # ── 1. relay ────────────────────────────────────────────────────────
        store = Store(db_path)
        app = relay_module.create_app(store=store, limits=Limits(queue_depth=512),
                                      pair_ttl_ms=120_000, base_path=base_path)
        relay_runner = web.AppRunner(app, access_log=None)
        await relay_runner.setup()
        await web.TCPSite(relay_runner, "127.0.0.1", port).start()
        async with ClientSession() as session:
            async with session.get(f"{base}/healthz") as response:
                health = await response.json()
            async with session.get(f"{public_base}/healthz") as prefixed:
                prefixed_health = await prefixed.json()
        check(health == {"ok": True, "version": 1}, f"relay /healthz == {health}")
        check(prefixed_health == health, f"the prefixed form {base_path}/healthz == {health}")

        # ── 2. provisioning through the operator CLI ────────────────────────
        account = admin(db_path, "account-create", "--name", "e2e account")
        agent_record = admin(
            db_path, "agent-register", "--account", account["accountId"], "--name", "e2e mac",
            "--relay", relay_url, "--write-config", str(workdir / "agent.json"),
        )
        minted = admin(db_path, "code-mint", "--agent", agent_record["agentId"], "--ttl-seconds", "120")
        check(len(minted["code"]) == 9, f"admin minted pairing code {minted['code']}")

        identity = json.loads((workdir / "agent.json").read_text())
        check(identity["agentId"] == agent_record["agentId"] and bool(identity["agentSecret"]),
              "admin.py wrote a usable agent.json")
        check((workdir / "agent.json").stat().st_mode & 0o777 == 0o600, "agent.json is mode 0600")

        async with ClientSession(timeout=ClientTimeout(total=STEP_TIMEOUT)) as session:
            async with session.post(f"{public_base}/pair/claim", json={
                "pairCode": minted["code"], "deviceName": DEVICE_NAME,
                "deviceModel": DEVICE_MODEL, "appVersion": "1.0.0",
            }) as response:
                claimed = await response.json()
        check(response.status == 200 and claimed.get("ok") is True, "POST /pair/claim issued a device token")
        device_token = claimed["deviceToken"]
        agent_id = claimed["agentId"]
        check(agent_id == agent_record["agentId"], "the claimed agent matches the provisioned agent")

        # ── 2b. the connector's own pairing path, through the prefixed relay ─
        minted_by_agent = await mint_via_agent(node, relay_url, agent_record)
        check(minted_by_agent["qrPayload"].startswith("dsh://pair?"),
              "the connector minted a dsh://pair deep link")
        deep_link = urlparse(minted_by_agent["qrPayload"])
        params = parse_qs(deep_link.query)
        check(deep_link.scheme == "dsh" and deep_link.netloc == "pair",
              f"the deep link is a dsh://pair URL ({deep_link.scheme}://{deep_link.netloc})")
        check(params["relay"][0] == relay_url,
              f"the deep link carries the prefixed relay URL {params['relay'][0]}")
        check(params["code"][0] == minted_by_agent["code"], "the deep link carries the pairing code")

        async with ClientSession(timeout=ClientTimeout(total=STEP_TIMEOUT)) as session:
            async with session.post(f"{public_base}/pair/claim", json={
                "pairCode": minted_by_agent["code"], "deviceName": "E2E QR device",
            }) as response:
                qr_claim = await response.json()
        check(response.status == 200 and qr_claim.get("ok") is True,
              "a code minted by the connector is claimable through the prefixed relay")
        admin(db_path, "device-revoke", "--device", qr_claim["deviceId"])

        # ── 3. the real agent against the real local DSH ────────────────────
        status_file = workdir / "agent-status.json"
        identity_file = workdir / "agent-identity.json"
        agent_process = await asyncio.create_subprocess_exec(
            node, str(AGENT_DIR / "lib" / "cli.js"),
            "--relay", relay_url,
            "--agent-id", agent_record["agentId"],
            "--agent-secret", agent_record["agentSecret"],
            "--state-file", str(identity_file),
            "--status-file", str(status_file),
            "--log-level", "debug",
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
            cwd=str(AGENT_DIR),
        )

        connected = asyncio.Event()

        async def pump_agent_output() -> None:
            assert agent_process is not None and agent_process.stdout is not None
            while True:
                line = await agent_process.stdout.readline()
                if not line:
                    return
                text = line.decode("utf-8", "replace").rstrip()
                agent_lines.append(text)
                if "MOBILE_LINK_STATE" in text and '"connected":true' in text:
                    connected.set()

        pump = asyncio.create_task(pump_agent_output())
        _pumps.append(pump)
        try:
            await asyncio.wait_for(connected.wait(), 30)
        except asyncio.TimeoutError:
            raise StepFailure("the agent never reported a connected state:\n" + "\n".join(agent_lines))
        check(True, f"agent connected to {relay_url} as {agent_record['agentId']}")

        persisted = json.loads(identity_file.read_text())
        check(persisted["agentId"] == agent_record["agentId"],
              "the agent persisted its identity to the state file")
        check(identity_file.stat().st_mode & 0o777 == 0o600, "the agent identity file is mode 0600")

        first_status = await wait_status(
            status_file, lambda s: s.get("connected") is True and s.get("dsh", {}).get("port"))
        check(first_status["agentId"] == agent_record["agentId"], "agent status snapshot reports connected")
        expected_port = local_dsh_port()
        check(first_status["dsh"]["port"] == expected_port,
              f"agent discovered the local DSH on port {first_status['dsh']['port']} (expected {expected_port})")

        # ── 4. the fake device ──────────────────────────────────────────────
        headers = {"Authorization": f"Bearer {device_token}"}
        async with ClientSession(timeout=ClientTimeout(total=STEP_TIMEOUT)) as session:
            ws = await session.ws_connect(f"{public_base}/link/device?agentId={agent_id}", headers=headers)
            reader = FrameReader(ws)
            try:
                status = await reader.until(lambda f: f.get("t") == "hostStatus")
                check(status["info"]["online"] is True, "device was told the host is online")

                await ws.send_str(json.dumps({"t": "req", "id": "1", "method": "session/list",
                                              "args": {"_request": {}}}))
                listed = await reader.until(lambda f: f.get("t") == "res" and f.get("id") == "1")
                check(listed.get("ok") is True, "session/list succeeded through the tunnel")
                sessions = listed["value"]["items"]
                check(len(sessions) > 0 and all("sessionId" in item for item in sessions),
                      f"session/list returned {len(sessions)} real sessions")

                # $events: the agent opens one stream per device, so a clientId exists.
                await ws.send_str(json.dumps({"t": "open", "id": "2", "endpoint": "$events", "args": {}}))
                ready_frame = await reader.until(is_ready)
                ready = ready_frame["value"]
                check(isinstance(ready.get("clientId"), str) and len(ready["clientId"]) > 8,
                      f"$events delivered a ready frame with clientId {ready['clientId']}")
                check(ready_frame.get("id") in (None, "2"),
                      "$events ready arrived on the DLP stream the device opened")

                idle, address = pick_followable(sessions)
                check(idle is not None, "found a real, non-running session to follow")
                target_session = idle["sessionId"]
                await ws.send_str(json.dumps({
                    "t": "open", "id": "3", "endpoint": "session/follow",
                    "args": {"request": {"address": address,
                                         "maxMessages": 10, "assistantStream": True}},
                }))
                snapshot = await reader.until(
                    lambda f: f.get("t") == "item" and f.get("id") == "3"
                    and isinstance(f.get("value"), dict) and f["value"].get("type") == "snapshot")
                check(snapshot["value"]["header"]["id"] == target_session,
                      f"session/follow streamed frames for {target_session[:24]}…")

                await ws.send_str(json.dumps({"t": "cancel", "id": "3"}))
                await reader.quiet(1.0)
                late = [frame for frame in reader.buffer if frame.get("id") == "3"]
                check(not late, "cancel stopped the session/follow stream")

                host = admin(db_path, "device-list", "--agent", agent_id)
                check(len(host) == 1 and host[0]["deviceId"] == claimed["deviceId"],
                      "admin device-list shows exactly the paired device")
            finally:
                await ws.close()

            # ── 5. the agent survives a device reconnect ────────────────────
            await wait_status(status_file, lambda s: s.get("deviceCount") == 0)
            check(True, "the agent cleaned up after the device disconnected")
            check(agent_process.returncode is None, "the agent process is still alive")

            ws2 = await session.ws_connect(f"{public_base}/link/device?agentId={agent_id}", headers=headers)
            reader2 = FrameReader(ws2)
            try:
                status2 = await reader2.until(lambda f: f.get("t") == "hostStatus")
                check(status2["info"]["online"] is True, "the reconnected device sees the host online")
                await ws2.send_str(json.dumps({"t": "req", "id": "1", "method": "session/list",
                                               "args": {"_request": {}}}))
                listed2 = await reader2.until(lambda f: f.get("t") == "res" and f.get("id") == "1")
                check(listed2.get("ok") is True and len(listed2["value"]["items"]) == len(sessions),
                      f"after reconnect session/list still returns {len(sessions)} sessions")

                await ws2.send_str(json.dumps({"t": "open", "id": "9", "endpoint": "$events", "args": {}}))
                ready2 = await reader2.until(is_ready)
                check(ready2["value"].get("clientId") != ready["clientId"],
                      "the reconnected device got its own $events clientId")
                result["clientIds"] = [ready["clientId"], ready2["value"]["clientId"]]
            finally:
                await ws2.close()

        result.update({
            "sessions": len(sessions),
            "sessionFollowed": target_session,
            "agentId": agent_id,
            "deviceId": claimed["deviceId"],
            "clientId": ready["clientId"],
            "relay": relay_url,
            "basePath": base_path,
            "qrPayload": minted_by_agent["qrPayload"],
        })
        return result
    finally:
        for task in _pumps:
            task.cancel()
        if agent_process is not None and agent_process.returncode is None:
            agent_process.terminate()
            with contextlib.suppress(asyncio.TimeoutError, ProcessLookupError):
                await asyncio.wait_for(agent_process.wait(), 10)
            if agent_process.returncode is None:
                agent_process.kill()
                with contextlib.suppress(Exception):
                    await agent_process.wait()
        if relay_runner is not None:
            await relay_runner.cleanup()
        if store is not None:
            store.close()
        shutil.rmtree(workdir, ignore_errors=True)


def main() -> int:
    import logging

    logging.basicConfig(
        level=logging.DEBUG if os.environ.get("DSH_E2E_DEBUG") == "1" else logging.WARNING,
        format="[relay] %(levelname)s %(message)s",
    )
    started = time.monotonic()
    diagnostics: deque[str] = deque(maxlen=400)

    def dump_diagnostics() -> None:
        if diagnostics:
            print("\n[e2e] last agent output:", file=sys.stderr)
            for line in list(diagnostics)[-25:]:
                print(f"    {line}", file=sys.stderr)

    try:
        result = asyncio.run(run_integration(diagnostics))
    except StepFailure as error:
        dump_diagnostics()
        print(f"\n[e2e] FAILED after {time.monotonic() - started:.1f}s: {error}", file=sys.stderr)
        return 1
    except Exception as error:  # noqa: BLE001 - the CLI must report everything
        import traceback

        traceback.print_exc()
        dump_diagnostics()
        print(f"\n[e2e] ERROR after {time.monotonic() - started:.1f}s: {error}", file=sys.stderr)
        return 1
    print(f"\n[e2e] PASSED in {time.monotonic() - started:.1f}s: {json.dumps(result, indent=2)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
