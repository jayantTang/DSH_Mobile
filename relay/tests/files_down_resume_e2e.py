#!/usr/bin/env python3
"""End-to-end proof that a download through the real relay is **resumable** (P-13b).

`integration_e2e.py` proves the middle tier moves bytes. This proves the
*different* thing P-13b changed: that the bytes come back in a shape the system
will resume from. That distinction is the whole reason for the step — the batch-2
experiment was misled by reading a response shape that could never have produced
resume data, so the shape has to be asserted against a real connector, not a stub.

Real relay, **real Node connector**, real local DSH, real workspace file. Nothing
is stubbed: the connector does the `workspaceFiles/stat` that produces the size
and version, and the relay turns them into headers.

    relay/.venv/bin/python relay/tests/files_down_resume_e2e.py

Steps:
  1. start the relay in-process on a free port
  2. provision account/agent/pairing code and start the real connector CLI
  3. write a scratch file **inside the session's workspace**, so the connector's
     stat and read both resolve it
  4. `GET /files/down` with no range   → 200 + `Content-Length` + `ETag`
  5. `GET /files/down` with a range    → 206 + full `Content-Range` + correct bytes
  6. `GET` with the matching `If-Range`→ 206, resumed from the offset
  7. `GET` with a stale `If-Range`     → 200, whole file (never a splice)
  8. delete the scratch file
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import pathlib
import shutil
import sys
import tempfile
from collections import deque
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from aiohttp import ClientSession, ClientTimeout, web  # noqa: E402

import relay as relay_module  # noqa: E402
from e2e_support import (  # noqa: E402
    AGENT_DIR, DEVICE_MODEL, DEVICE_NAME, STEP_TIMEOUT, StepFailure, admin,
    check, free_port, local_dsh_port, new_diagnostics, recv_json, wait_status,
)
from hub import Limits  # noqa: E402
from store import Store  # noqa: E402

REPOSITORY = pathlib.Path(__file__).resolve().parents[2]


async def run_resume_e2e(diagnostics: deque[str] | None = None) -> dict:
    node = shutil.which("node")
    check(node is not None, f"node is on PATH ({node})")
    workdir = pathlib.Path(tempfile.mkdtemp(prefix="files-down-resume-e2e-"))
    db_path = str(workdir / "state.db")
    port = free_port()
    base_path = "/dsh-link"
    base = f"http://127.0.0.1:{port}"
    public_base = f"{base}{base_path}"
    relay_url = f"ws://127.0.0.1:{port}{base_path}"
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
        check(True, f"relay listening on {base}{base_path}")

        # ── 2. provisioning + the real connector ────────────────────────────
        account = admin(db_path, "account-create", "--name", "resume e2e")
        agent_record = admin(
            db_path, "agent-register", "--account", account["accountId"], "--name", "resume mac",
            "--relay", relay_url, "--write-config", str(workdir / "agent.json"),
        )
        minted = admin(db_path, "code-mint", "--agent", agent_record["agentId"], "--ttl-seconds", "120")

        async with ClientSession(timeout=ClientTimeout(total=STEP_TIMEOUT)) as session:
            async with session.post(f"{public_base}/pair/claim", json={
                "pairCode": minted["code"], "deviceName": DEVICE_NAME,
                "deviceModel": DEVICE_MODEL, "appVersion": "1.0.0",
            }) as response:
                claimed = await response.json()
        check(response.status == 200 and claimed.get("ok") is True,
              "POST /pair/claim issued a device token")
        device_token = claimed["deviceToken"]
        agent_id = claimed["agentId"]

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

        _pumps.append(asyncio.create_task(pump_agent_output()))
        try:
            await asyncio.wait_for(connected.wait(), 30)
        except asyncio.TimeoutError:
            raise StepFailure("the agent never connected:\n" + "\n".join(agent_lines))
        check(True, "the real connector connected to the relay")
        first_status = await wait_status(
            status_file, lambda s: s.get("connected") is True and s.get("dsh", {}).get("port"))
        check(first_status["dsh"]["port"] == local_dsh_port(),
              f"the connector found the local DSH on {first_status['dsh']['port']}")

        # ── 3. a scratch file inside the workspace ──────────────────────────
        # The connector resolves `scopeId` to a session's workspace, and the
        # repository is what this run's session has. The file is written under a
        # clearly-named scratch directory and removed in the `finally`.
        # The scope is a **session id**, and the fixture has to sit inside that
        # session's workspace. `session/list` over the tunnel was the first
        # attempt and is a poor one here: the reply is large enough to arrive
        # split across frames, so the test would be measuring frame reassembly.
        # A session directory on disk is the same fact without the transport.
        scope_id = pick_session_scope()
        check(scope_id is not None, "found a session whose workspace is this repository")
        scratch = REPOSITORY / ".resume-e2e-scratch"
        scratch.mkdir(exist_ok=True)
        # 3 MB: big enough that a range read is not the whole file, small enough
        # that the run stays fast.
        body = bytes((i * 31 + 7) % 256 for i in range(3 * 1024 * 1024))
        target = scratch / "resume-fixture.bin"
        target.write_bytes(body)
        digest = hashlib.sha256(body).hexdigest()
        result["fixtureBytes"] = len(body)
        result["fixtureSha256"] = digest
        check(True, f"wrote a {len(body)}-byte fixture (sha256 {digest[:12]}…)")

        headers = {"Authorization": f"Bearer {device_token}"}
        url = (f"{public_base}/files/down?scopeId={scope_id}"
               f"&path={target}&bid=resume-e2e-1")

        async with ClientSession(timeout=ClientTimeout(total=STEP_TIMEOUT)) as session:
            # ── 4. a plain download states its total and a token ────────────
            async with session.get(url, headers=headers) as response:
                downloaded = await response.read()
            check(response.status == 200, f"a full download answers 200 (got {response.status})")
            check(downloaded == body, "the full download matches the file byte for byte")
            check(response.headers.get("Content-Length") == str(len(body)),
                  f"Content-Length is the total ({response.headers.get('Content-Length')})")
            check(response.headers.get("Accept-Ranges") == "bytes",
                  "Accept-Ranges: bytes is advertised")
            etag = response.headers.get("ETag")
            check(etag is not None and etag.startswith('"dsh-'),
                  f"an ETag is derived from the version ({etag})")
            result["etag"] = etag

            # ── 5. a ranged download is a real 206 ──────────────────────────
            offset = 1_000_000
            async with session.get(url + "&bid=resume-e2e-2", headers={
                **headers, "Range": f"bytes={offset}-",
            }) as response:
                tail = await response.read()
            check(response.status == 206, f"a ranged download answers 206 (got {response.status})")
            check(tail == body[offset:], "the ranged body is the tail of the file")
            check(response.headers.get("Content-Range") == f"bytes {offset}-{len(body) - 1}/{len(body)}",
                  f"Content-Range is the **full** interval ({response.headers.get('Content-Range')})")
            check(response.headers.get("Content-Length") == str(len(body) - offset),
                  "Content-Length is the remaining bytes")
            result["rangedBytes"] = len(tail)

            # ── 6. If-Range with the current token resumes ──────────────────
            async with session.get(url + "&bid=resume-e2e-3", headers={
                **headers, "Range": f"bytes={offset}-", "If-Range": etag,
            }) as response:
                resumed = await response.read()
            check(response.status == 206, "a matching If-Range still answers 206")
            check(resumed == body[offset:], "the resumed body matches the tail")
            result["resumedBytes"] = len(resumed)

            # ── 7. If-Range with a stale token restarts ─────────────────────
            # The correctness backstop: the file changed under the transfer, so
            # old prefix + new suffix would be a file that never existed.
            async with session.get(url + "&bid=resume-e2e-4", headers={
                **headers, "Range": f"bytes={offset}-", "If-Range": '"dsh-v0-0"',
            }) as response:
                restarted = await response.read()
            check(response.status == 200,
                  f"a stale If-Range restarts from zero (got {response.status})")
            check(restarted == body, "the restarted body is the whole file, not a splice")
            check(hashlib.sha256(restarted).hexdigest() == digest,
                  "the restarted bytes hash to the source")
            result["restartedBytes"] = len(restarted)

        check(True, "P-13b: the download is resumable end to end")
    finally:
        for task in _pumps:
            task.cancel()
        if agent_process is not None:
            agent_process.terminate()
            with contextlib_suppress():
                await asyncio.wait_for(agent_process.wait(), 10)
        scratch = REPOSITORY / ".resume-e2e-scratch"
        shutil.rmtree(scratch, ignore_errors=True)
        if relay_runner is not None:
            await relay_runner.cleanup()
        if store is not None:
            store.close()
        shutil.rmtree(workdir, ignore_errors=True)
    return result


class contextlib_suppress:
    """`contextlib.suppress(Exception)`, inlined to keep the import list flat."""

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return True


def pick_session_scope() -> str | None:
    """A real session id whose workspace is this repository.

    DSH names a session directory after the workspace it belongs to, so the
    directory name is the lookup and the entry inside it is the id. Read-only,
    and it targets this repository's own sessions — the fixture written below
    has to resolve under the same workspace root the connector will use.
    """
    # The directory is the workspace path with its separators turned into
    # dashes (plus a leading dash for the root). Matching on the path's tail
    # rather than reconstructing the exact spelling: the escaping is DSH's to
    # choose, and a test that hard-codes it breaks the next time it changes.
    tail = str(REPOSITORY).replace("/", "-").lstrip("-")
    sessions = pathlib.Path.home() / ".dsh" / "sessions"
    if not sessions.is_dir():
        return None
    for workspace in sorted(sessions.iterdir()):
        if not workspace.is_dir() or tail not in workspace.name:
            continue
        for entry in sorted(workspace.iterdir(), reverse=True):
            if entry.is_dir():
                return entry.name
    return None


async def main() -> int:
    try:
        result = await run_resume_e2e()
    except StepFailure as failure:
        print(f"FAIL: {failure}")
        return 1
    print("PASS")
    for key, value in result.items():
        print(f"  {key} = {value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
