#!/usr/bin/env python3
"""End-to-end proof of self-service enrollment (task A + B).

Runs the *real* relay, the *real* operator CLI and the *real* connector CLI —
no host and no phone are needed:

    relay/.venv/bin/python relay/tests/enroll_e2e.py

Steps:
  1. start the relay in-process on a free port over plain HTTP
  2. mint an invite code through `relay/admin.py invite-mint` (the operator's
     only involvement in someone else's install)
  3. run `node plugins/mobile-link/lib/cli.js enroll --invite <code>` into a throwaway
     `DSH_HOME`, i.e. exactly what a new user runs
  4. assert the identity file exists with mode 0600 and that the credential the
     CLI received is the one the relay will accept
  5. redeem nothing twice: the same code must fail the second time
  6. pair a phone with the enrolled identity, so the whole chain is exercised

Isolation: everything happens in a temporary directory; `DSH_HOME` is pointed at
it, so the real `~/.dsh/mobile-link/agent.json` is never touched.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import os
import pathlib
import shutil
import stat
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from aiohttp import ClientSession, web  # noqa: E402

import relay as relay_module  # noqa: E402
from e2e_support import AGENT_DIR, STEP_TIMEOUT, StepFailure, admin, check, free_port  # noqa: E402
from hub import Limits  # noqa: E402
from store import Store  # noqa: E402


async def run_enrollment(workdir: pathlib.Path) -> dict:
    db = str(workdir / "state.db")
    home = workdir / "dsh-home"
    (home / "mobile-link").mkdir(parents=True)

    store = Store(db)
    port = free_port()
    app = relay_module.create_app(store=store, limits=Limits(queue_depth=8))
    runner = web.AppRunner(app, access_log=None)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", port)
    await site.start()
    relay_url = f"ws://127.0.0.1:{port}"

    try:
        # 1. The operator mints one invite. Nothing else is provisioned.
        minted = admin(db, "invite-mint", "--note", "e2e", "--ttl-seconds", "600")
        code = minted["code"]
        check(bool(code) and code.count("-") == 3, f"invite-mint returned a code ({code!r})")
        check("enrollCommand" in minted, "invite-mint prints the command the invitee runs")
        listing = admin(db, "invite-list")
        check(len(listing) == 1 and listing[0]["usedAt"] is None, "the invite starts unused")

        # 2. The invitee runs the connector's enroll command.
        node = shutil.which("node") or "node"
        env = {**os.environ, "DSH_HOME": str(home)}
        proc = await asyncio.create_subprocess_exec(
            node, str(AGENT_DIR / "lib" / "cli.js"), "enroll",
            "--invite", code, "--relay", relay_url, "--name", "e2e machine",
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE, env=env,
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=STEP_TIMEOUT)
        check(proc.returncode == 0, f"enroll exited {proc.returncode}: {stderr.decode().strip()}")
        reported = json.loads(stdout.decode().split("\n这台电脑")[0])
        check(reported["agentId"].startswith("agt_"), f"enroll reported an agentId ({reported['agentId']})")

        # 3. The identity landed where the connector looks for it, mode 0600.
        state_file = home / "mobile-link" / "agent.json"
        check(state_file.exists(), f"identity file written to {state_file}")
        mode = stat.S_IMODE(state_file.stat().st_mode)
        check(mode == 0o600, f"identity file mode is {oct(mode)}, expected 0o600")
        identity = json.loads(state_file.read_text())
        check(identity["agentId"] == reported["agentId"], "the file holds the reported agentId")
        check(identity["relayUrl"] == relay_url, "the file holds the relay the invite named")

        # 4. That credential is the real thing: the relay accepts it.
        check(store.agent_by_secret(identity["agentSecret"]) is not None,
              "the relay recognises the enrolled secret")

        # 5. One-time: the same code is refused, and the refusal is specific.
        async with ClientSession() as session:
            async with session.post(f"{relay_url.replace('ws', 'http')}/agents/enroll",
                                    json={"inviteCode": code, "name": "second machine"}) as response:
                body = await response.json()
                check(response.status == 404, f"replaying the invite returns 404 (got {response.status})")
                check(body["error"]["code"] == "enroll/used", f"replay is reported as used ({body})")

            # 6. A wrong code is reported as unknown, not as used.
            async with session.post(f"{relay_url.replace('ws', 'http')}/agents/enroll",
                                    json={"inviteCode": "ZZZZ-ZZZZ-ZZZZ-ZZZZ", "name": "x"}) as response:
                body = await response.json()
                check(body["error"]["code"] == "enroll/unknown", f"a bad code is unknown ({body})")

            # 7. Pairing a phone with the enrolled identity works end to end.
            auth = {"Authorization": f"Bearer {identity['agentSecret']}"}
            async with session.post(f"{relay_url.replace('ws', 'http')}/pair/code",
                                    json={"ttlMs": 60_000}, headers=auth) as response:
                check(response.status == 200, "the enrolled agent can mint a pairing code")
                pair = await response.json()
            async with session.post(f"{relay_url.replace('ws', 'http')}/pair/claim",
                                    json={"pairCode": pair["code"], "deviceName": "e2e phone"}) as response:
                check(response.status == 200, "the phone claims the code")
                claim = await response.json()
                check(claim["agentId"] == identity["agentId"], "the phone paired with the enrolled computer")
                check(claim["deviceToken"].startswith("dt_"), "a device token came back")

        # `invite-list` hides used codes by default: an operator's outstanding
        # invites are the only ones worth seeing at a glance.
        check(admin(db, "invite-list") == [], "a used invite drops off the outstanding list")
        used = admin(db, "invite-list", "--all")
        check(len(used) == 1 and used[0]["usedAt"] is not None, "the invite is recorded as used")
        check(used[0]["usedByAgentId"] == identity["agentId"], "the used invite names the enrolled agent")

        # 8. The connector's status route knows the computer is registered.
        proc = await asyncio.create_subprocess_exec(
            node, "-e",
            "import(process.argv[1]).then(async (m) => {"
            " const { MobileLinkAgent } = m;"
            f" const agent = new MobileLinkAgent({{ relayUrl: '{relay_url}', stateFile: '{state_file}',"
            "   enabled: false, logger: { info(){}, warn(){}, error(){}, debug(){} } });"
            " console.log(JSON.stringify(agent.status().enroll)); })",
            str(AGENT_DIR / "lib" / "index.js"),
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE, env=env,
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=STEP_TIMEOUT)
        check(proc.returncode == 0, f"status probe exited {proc.returncode}: {stderr.decode().strip()}")
        enroll_status = json.loads(stdout.decode().strip().split("\n")[-1])
        check(enroll_status["registered"] is True, f"status reports registered ({enroll_status})")
        check(enroll_status["needsEnroll"] is False, "status does not ask for enrollment once registered")

        return {
            "invite": code,
            "agentId": identity["agentId"],
            "stateFile": str(state_file),
            "mode": oct(mode),
        }
    finally:
        with contextlib.suppress(Exception):
            await runner.cleanup()
        store.close()


def main() -> int:
    workdir = pathlib.Path(tempfile.mkdtemp(prefix="dsh-enroll-e2e-"))
    try:
        result = asyncio.run(run_enrollment(workdir))
    except StepFailure as error:
        print(f"\n[enroll-e2e] FAILED: {error}", file=sys.stderr)
        return 1
    except Exception as error:  # noqa: BLE001 - the CLI reports everything
        import traceback

        traceback.print_exc()
        print(f"\n[enroll-e2e] ERROR: {error}", file=sys.stderr)
        return 1
    finally:
        shutil.rmtree(workdir, ignore_errors=True)
    print(f"\n[enroll-e2e] PASSED: {json.dumps(result, indent=2)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
