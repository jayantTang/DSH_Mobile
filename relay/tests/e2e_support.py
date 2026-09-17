"""Helpers shared by the middle-tier integration run.

Kept apart from `integration_e2e.py` so the scenario reads as a scenario.
"""

from __future__ import annotations

import asyncio
import json
import os
import pathlib
import socket as socketlib
import subprocess
import sys
import time
from collections import deque

from aiohttp import WSMsgType

ROOT = pathlib.Path(__file__).resolve().parents[2]
RELAY_DIR = ROOT / "relay"
AGENT_DIR = ROOT / "agent" / "dsh-plugin-mobile-link"

STEP_TIMEOUT = 25.0
DEVICE_NAME = "E2E iPhone"
DEVICE_MODEL = "iPhone17,1"


class StepFailure(AssertionError):
    """A scenario step did not hold. Reported as a failure, never a crash."""


def log(message: str) -> None:
    print(f"[e2e] {message}", flush=True)


def check(condition: bool, message: str) -> None:
    if not condition:
        raise StepFailure(message)
    log(f"ok: {message}")


def local_dsh_port() -> int:
    """The port the local DSH instance is listening on (endpoint.json, else 54499)."""
    home = pathlib.Path(os.environ.get("DSH_HOME", pathlib.Path.home() / ".dsh"))
    try:
        return int(json.loads((home / "desktop-shell" / "endpoint.json").read_text())["port"])
    except (OSError, ValueError, KeyError, json.JSONDecodeError):
        return 54499


def free_port() -> int:
    with socketlib.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


def admin(db: str, *args: str) -> dict | list:
    """Run relay/admin.py as an operator would, and parse its JSON output."""
    result = subprocess.run(
        [sys.executable, str(RELAY_DIR / "admin.py"), "--db", db, *args],
        capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        raise StepFailure(f"admin.py {' '.join(args)} failed: {result.stderr.strip() or result.stdout.strip()}")
    return json.loads(result.stdout)


async def recv_json(ws, timeout: float = STEP_TIMEOUT) -> dict:
    message = await asyncio.wait_for(ws.receive(), timeout)
    if message.type != WSMsgType.TEXT:
        raise StepFailure(f"expected a text frame, got {message.type}: {message!r}")
    return json.loads(message.data)


class FrameReader:
    """Reads device frames while remembering ones a step did not consume.

    The tunnel is asynchronous: a `$events` ready frame can legitimately arrive
    while a step is still waiting for a `session/list` reply. Nothing may be
    dropped, so unmatched frames stay available to the next step.
    """

    def __init__(self, ws):
        self.ws = ws
        self.buffer: list[dict] = []
        self.seen: list[dict] = []

    def __repr__(self) -> str:
        return " | ".join(json.dumps(frame)[:200] for frame in self.seen[-6:])

    def take(self, predicate):
        for index, frame in enumerate(self.buffer):
            if predicate(frame):
                return self.buffer.pop(index)
        return None

    async def until(self, predicate, timeout: float = STEP_TIMEOUT) -> dict:
        buffered = self.take(predicate)
        if buffered is not None:
            return buffered
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise StepFailure(f"timed out waiting for a frame; saw: {self!r}")
            try:
                frame = await recv_json(self.ws, remaining)
            except asyncio.TimeoutError:
                raise StepFailure(f"timed out waiting for a frame; saw: {self!r}")
            self.seen.append(frame)
            if predicate(frame):
                return frame
            self.buffer.append(frame)

    async def quiet(self, seconds: float = 1.0) -> None:
        """Drain for a while, keeping anything that arrives."""
        deadline = time.monotonic() + seconds
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return
            try:
                frame = await recv_json(self.ws, remaining)
            except asyncio.TimeoutError:
                return
            self.seen.append(frame)
            self.buffer.append(frame)


def is_ready(frame: dict) -> bool:
    """A `$events` ready item, whether it arrived as an `event` or an `item`."""
    if frame.get("t") not in ("event", "item"):
        return False
    value = frame.get("value")
    return isinstance(value, dict) and value.get("type") == "ready"


async def read_status(path: pathlib.Path) -> dict | None:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


async def wait_status(path: pathlib.Path, predicate, timeout: float = 10.0) -> dict:
    """Poll the agent's status snapshot until it matches (writes are atomic)."""
    deadline = time.monotonic() + timeout
    last: dict | None = None
    while time.monotonic() < deadline:
        last = await read_status(path)
        if last is not None and predicate(last):
            return last
        await asyncio.sleep(0.1)
    raise StepFailure(f"agent status never matched; last snapshot was {last}")


def pick_followable(sessions: list[dict]) -> tuple[dict | None, dict | None]:
    """Choose a real, idle session and the `session/follow` address for it.

    Subagent (child) sessions need their durable parent address, so a top-level
    idle session is preferred; a child is only used as a fallback. Nothing here
    mutates anything — `session/follow` is a read-only subscription.
    """
    candidates = [item for item in sessions
                  if not item.get("running") and not item.get("parentSessionId")]
    if not candidates:
        candidates = [item for item in sessions if not item.get("running")]
    if not candidates:
        return None, None
    item = candidates[0]
    session_id = item["sessionId"]
    if item.get("parentSessionId"):
        address = {"kind": "subagent", "parentSessionId": item["parentSessionId"],
                   "childSessionId": session_id, "mode": "continuable"}
    else:
        address = {"kind": "session", "sessionId": session_id}
    return item, address


#: Buffer for the agent's own log lines, shared with the failure report.
def new_diagnostics() -> deque[str]:
    return deque(maxlen=400)
