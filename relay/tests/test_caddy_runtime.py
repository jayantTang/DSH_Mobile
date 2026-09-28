"""The public surface, driven through a *real* Caddy in front of a *real* relay.

Why this file exists
--------------------
``test_caddy_splice.py`` checks the fragment's text and the JSON Caddy compiles it
into. Both passed while the public path ``/dsh-link/stats`` was, in production,
answering **200 with the whole operator page** — device names, ids, byte counts.

The reason is Caddy's directive ordering: a bare ``respond @relay_stats`` is
evaluated *after* ``handle_path /dsh-link/*`` no matter where it is written, so
the request was proxied to the relay, which saw a loopback peer (the front end)
and happily served the page. The relay's own check cannot see the problem, and an
``adapt``-level assertion only sees the routes it thinks to look at.

Nothing short of a real request against a real Caddy catches that. So these tests
start ``caddy run`` on a free port with a production-shaped site block plus the
spliced fragment, start ``relay.py`` as its own process, and curl both.

They are skipped when the caddy binary is absent (the rest of the suite still
runs); ``test_caddy_splice.py`` keeps the cheap offline assertions.
"""

from __future__ import annotations

import json
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

import pytest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "deploy"))

import caddy_splice as cs  # noqa: E402

RELAY_DIR = pathlib.Path(__file__).resolve().parents[1]
SNIPPET_PATH = RELAY_DIR / "deploy" / "Caddyfile.snippet"
CADDY = shutil.which("caddy")

#: CI sets this: without a caddy the five tests below quietly turn into skips, and a
#: green run would then say nothing at all about the ordering hazard this file exists
#: for. Absent by default so a developer machine without caddy still runs the suite.
if CADDY is None and os.environ.get("DSH_REQUIRE_CADDY"):
    raise RuntimeError("DSH_REQUIRE_CADDY 已设置但没有 caddy：端到端那层会静默跳过")

pytestmark = pytest.mark.skipif(CADDY is None, reason="the caddy binary is not installed")

#: Deliberately the shape of the production Caddyfile: other handle blocks that
#: also want /dsh-link-adjacent paths, and a catch-all last. A site block with
#: only the fragment in it would not reproduce the ordering hazard.
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
    """Block until something accepts on ``port`` (or fail loudly)."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with socket.socket() as probe:
            probe.settimeout(0.25)
            if probe.connect_ex(("127.0.0.1", port)) == 0:
                return
        time.sleep(0.05)
    raise AssertionError(f"nothing came up on 127.0.0.1:{port} within {timeout}s")


def get(url: str) -> tuple[int, str]:
    """GET ``url``, returning ``(status, body)``. A 4xx/5xx is a result, not an error."""
    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            return response.status, response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode("utf-8", "replace")


@pytest.fixture
def stack(tmp_path):
    """A real relay process behind a real Caddy, wired the way deploy.sh wires them.

    The fragment's ``reverse_proxy 127.0.0.1:8787`` is the one thing rewritten:
    the relay cannot have port 8787 on a developer machine, and nothing else about
    the arrangement (directive order, prefix stripping, catch-all) matters.
    """
    relay_port = free_port()
    proxy_port = free_port()
    db = tmp_path / "state.db"

    caddyfile = tmp_path / "Caddyfile"
    caddyfile.write_text(SITE.format(proxy_port=proxy_port))
    # Splice exactly as deploy.sh does, then point the proxy at our relay.
    spliced, action = cs.splice(caddyfile.read_text(), SNIPPET_PATH.read_text(),
                                f"127.0.0.1:{proxy_port}")
    assert action == "inserted", action
    spliced = spliced.replace("127.0.0.1:8787", f"127.0.0.1:{relay_port}")
    assert f"127.0.0.1:{relay_port}" in spliced, "the upstream must be redirected"
    caddyfile.write_text(spliced)

    env = {**os.environ, "DLP_DB": str(db)}
    relay = subprocess.Popen(
        [sys.executable, str(RELAY_DIR / "relay.py"), "--host", "127.0.0.1",
         "--port", str(relay_port)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
    )
    caddy = subprocess.Popen(
        [CADDY, "run", "--config", str(caddyfile), "--adapter", "caddyfile"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    try:
        wait_for_port(relay_port)
        wait_for_port(proxy_port)
        # The relay logs "listening" only after its startup hooks ran; a request
        # before that would make a 5xx ambiguous with a real refusal.
        time.sleep(0.3)
        yield {"relay_port": relay_port, "proxy_port": proxy_port,
               "caddyfile": caddyfile, "relay": relay, "caddy": caddy}
    finally:
        for process in (caddy, relay):
            process.terminate()
        for process in (caddy, relay):
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:  # pragma: no cover - stubborn child
                process.kill()
                process.wait(timeout=5)


def test_the_public_stats_path_is_refused(stack):
    """The exact request the test report made: it must be 404, not 200 + JSON.

    This is the regression guard for CI-01. The old fragment answered 200 with
    the full page; ``assert status == 404`` is what would have caught it, and the
    body check keeps a future "404-looking" page from passing by accident.
    """
    status, body = get(f"http://127.0.0.1:{stack['proxy_port']}/dsh-link/stats")
    assert status == 404, f"the public /stats path leaked: {status} {body[:400]}"
    assert "deviceId" not in body and "totalEgressBytes" not in body, \
        f"the refusal body still carries operator data: {body[:400]}"


def test_the_bare_stats_path_is_refused_too(stack):
    """``/stats`` without the prefix is not a public entry point either.

    It matters because the relay also accepts the un-stripped form: a site config
    that accidentally exposes the bare path must not hand out the page.
    """
    status, body = get(f"http://127.0.0.1:{stack['proxy_port']}/stats")
    assert status == 404, f"the bare /stats path leaked: {status} {body[:400]}"


def test_loopback_still_gets_the_real_page(stack):
    """The refusal must not have broken the way an operator reads it.

    Reached directly on the relay's own port, which is how the README and the
    fragment comment tell an operator to read it (``curl -s localhost:8787/stats``).
    """
    status, body = get(f"http://127.0.0.1:{stack['relay_port']}/stats")
    assert status == 200, f"loopback must still read the page, got {status}"
    payload = json.loads(body)
    # The structure is a contract: scripts/dev/watch-relay.mjs reads it.
    assert payload["ok"] is True
    assert set(payload) >= {"ok", "version", "limits", "load", "traffic", "snapshot", "today"}


def test_healthz_stays_public_through_the_proxy(stack):
    """The deploy script waits on ``/healthz``; the refuse must not catch it.

    This is the "did I break the public surface while closing one path" check —
    a reject rule that is too greedy shows up here and nowhere else.
    """
    status, body = get(f"http://127.0.0.1:{stack['proxy_port']}/dsh-link/healthz")
    assert status == 200, f"/healthz must stay reachable, got {status}: {body[:200]}"
    assert json.loads(body)["ok"] is True


def test_dsh_link_traffic_still_reaches_the_relay(stack):
    """``/dsh-link/*`` must still be proxied — the refuse is one path, not the block.

    A relay 404 for a path it does not serve is the proof that the request
    travelled through Caddy to the relay and was answered by the relay, rather
    than being swallowed by a matcher that grew too wide. aiohttp's own
    unknown-route body is the plain text ``404: Not Found``, which is exactly
    what the fragment's ``respond "Not Found" 404`` would *not* produce (Caddy
    sends no body, and the reason phrase is not in it).
    """
    status, body = get(f"http://127.0.0.1:{stack['proxy_port']}/dsh-link/no-such-endpoint")
    assert status == 404, status
    assert body.strip() == "404: Not Found", \
        f"this 404 should come from the relay, not from Caddy: {body[:200]!r}"
