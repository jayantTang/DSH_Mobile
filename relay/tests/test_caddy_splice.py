"""Caddy splicing: the relay fragment must land inside the existing site block,
before any order-sensitive directive, and must be removable byte-for-byte.

The fixture mirrors the shape of the production Caddyfile on the relay host
(existing handles plus a `patent-landscape` block) without touching it.
"""

from __future__ import annotations

import json
import pathlib
import shutil
import subprocess

import pytest

import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "deploy"))

import caddy_splice as cs  # noqa: E402

SNIPPET_PATH = pathlib.Path(__file__).resolve().parents[1] / "deploy" / "Caddyfile.snippet"

PRODUCTION_LIKE = """\
{
	email admin@example.com
}

relay.example.com, example.com {
	encode gzip
	root * /srv/story

	handle /patent-landscape/* {
		reverse_proxy 127.0.0.1:9100
	}

	handle /api/* {
		reverse_proxy 127.0.0.1:9200
	}

	handle {
		file_server
	}

	log {
		output file /var/log/caddy/story.log
	}
}

other.example.com {
	respond "hello"
}
"""


def snippet() -> str:
    return SNIPPET_PATH.read_text()


def test_brace_delta_ignores_quotes_comments_and_placeholders():
    assert cs.brace_delta("site {") == 1
    assert cs.brace_delta("}") == -1
    assert cs.brace_delta("header_up X-Real-IP {remote_host}") == 0
    assert cs.brace_delta('header X "a { b"') == 0
    assert cs.brace_delta("handle /x/* { # trailing }") == 1
    assert cs.brace_delta("# }") == 0


def test_the_fragment_lands_inside_the_site_and_before_every_handle():
    updated, action = cs.splice(PRODUCTION_LIKE, snippet(), "relay.example.com")
    assert action == "inserted"
    lines = updated.splitlines()

    site_open = next(i for i, line in enumerate(lines)
                     if line.startswith("relay.example.com, example.com {"))
    site_close = next(i for i in range(site_open, len(lines)) if lines[i] == "}")
    begin = next(i for i, line in enumerate(lines) if cs.BEGIN in line)
    end = next(i for i, line in enumerate(lines) if cs.END in line)
    first_handle = next(i for i, line in enumerate(lines) if "handle /patent-landscape/*" in line)

    assert site_open < begin < end < first_handle < site_close
    assert "\thandle_path /dsh-link/* {" in updated
    assert "\t\treverse_proxy 127.0.0.1:8787 {" in updated
    assert "read_timeout 0" in updated and "write_timeout 0" in updated
    assert "flush_interval -1" in updated
    assert "header_up X-Real-IP {remote_host}" in updated
    # Every pre-existing line survives, in order.
    for original in ("handle /patent-landscape/* {", "reverse_proxy 127.0.0.1:9100",
                     "handle /api/* {", "file_server", "other.example.com {"):
        assert original in updated


def test_splicing_is_idempotent():
    once, _ = cs.splice(PRODUCTION_LIKE, snippet(), "relay.example.com")
    twice, action = cs.splice(once, snippet(), "relay.example.com")
    assert action == "replaced"
    assert twice == once
    assert once.count(cs.BEGIN) == 1 and once.count(cs.END) == 1


def test_removing_restores_the_original_file_exactly():
    updated, _ = cs.splice(PRODUCTION_LIKE, snippet(), "relay.example.com")
    restored, action = cs.remove(updated)
    assert action == "removed"
    assert restored == PRODUCTION_LIKE
    assert cs.remove(PRODUCTION_LIKE) == (PRODUCTION_LIKE, "absent")


def test_a_different_site_address_is_left_alone():
    with pytest.raises(cs.SpliceError, match="no site block"):
        cs.splice(PRODUCTION_LIKE, snippet(), "nope.example.com")


def test_multi_line_address_lists_are_supported():
    text = "a.example.com,\nrelay.example.com {\n\trespond \"hi\"\n}\n"
    updated, action = cs.splice(text, snippet(), "relay.example.com")
    assert action == "inserted"
    assert cs.BEGIN in updated
    assert "\trespond \"hi\"" in updated


def test_a_brace_only_opener_after_address_lines_is_supported():
    text = "relay.example.com\nexample.com\n{\n\trespond \"hi\"\n}\n"
    updated, action = cs.splice(text, snippet(), "relay.example.com")
    assert action == "inserted"
    lines = updated.splitlines()
    opener = lines.index("{")
    closer = lines.index("}", opener)
    begin = next(i for i, line in enumerate(lines) if cs.BEGIN in line)
    assert opener < begin < closer, "the fragment must be inside the site block"
    assert cs.remove(updated)[0] == text


def test_the_global_options_block_is_not_mistaken_for_a_site():
    text = "{\n\tadmin off\n}\n\nrelay.example.com {\n\trespond \"hi\"\n}\n"
    updated, _ = cs.splice(text, snippet(), "relay.example.com")
    assert updated.index(cs.BEGIN) > updated.index("relay.example.com {")


def test_an_empty_caddyfile_is_refused():
    with pytest.raises(cs.SpliceError, match="empty"):
        cs.splice("\n\n", snippet(), "relay.example.com")


def test_unbalanced_braces_are_refused():
    text = "relay.example.com {\n\trespond \"hi\"\n"
    with pytest.raises(cs.SpliceError, match="unbalanced"):
        cs.splice(text, snippet(), "relay.example.com")


def test_cli_insert_and_remove_round_trip(tmp_path):
    caddyfile = tmp_path / "Caddyfile"
    caddyfile.write_text(PRODUCTION_LIKE)

    assert cs.main(["insert", str(caddyfile), str(SNIPPET_PATH), "relay.example.com"]) == 0
    spliced = caddyfile.read_text()
    assert cs.BEGIN in spliced
    assert cs.main(["check", str(caddyfile)]) == 0

    assert cs.main(["remove", str(caddyfile)]) == 0
    assert caddyfile.read_text() == PRODUCTION_LIKE


CADDY = shutil.which("caddy")


@pytest.mark.skipif(CADDY is None, reason="the caddy binary is not installed")
def test_real_caddy_accepts_the_spliced_config(tmp_path):
    """The strongest check available offline: Caddy itself adapts and loads it.

    Also pins the compiled route order — /dsh-link/* must be a sibling of the
    existing handle blocks and must come before the catch-all handle, or the
    site's own handler would swallow the relay's traffic.
    """
    # Only the log destination is rewritten: the production path is not
    # creatable by a test user, and nothing else about the fixture matters here.
    fixture = PRODUCTION_LIKE.replace("/var/log/caddy/story.log", str(tmp_path / "story.log"))
    caddyfile = tmp_path / "Caddyfile"
    caddyfile.write_text(fixture)

    assert subprocess.run([CADDY, "validate", "--config", str(caddyfile), "--adapter", "caddyfile"],
                          capture_output=True).returncode == 0, "the fixture itself must be valid"

    updated, _ = cs.splice(fixture, snippet(), "relay.example.com")
    caddyfile.write_text(updated)
    result = subprocess.run([CADDY, "validate", "--config", str(caddyfile), "--adapter", "caddyfile"],
                            capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr

    adapted = subprocess.run([CADDY, "adapt", "--config", str(caddyfile), "--adapter", "caddyfile"],
                             capture_output=True, text=True, check=True)
    config = json.loads(adapted.stdout)

    def paths_in(route):
        match = (route.get("match") or [{}])[0]
        return list(match.get("path") or [])

    def handlers_in(value, found=None):
        """Every handler object reachable from one route, subroutes included."""
        found = [] if found is None else found
        if isinstance(value, dict):
            if isinstance(value.get("handler"), str):
                found.append(value)
            for child in value.values():
                handlers_in(child, found)
        elif isinstance(value, list):
            for child in value:
                handlers_in(child, found)
        return found

    def site_routes(config):
        for route in config["apps"]["http"]["servers"]["srv0"]["routes"]:
            match = (route.get("match") or [{}])[0]
            if "relay.example.com" in (match.get("host") or []):
                for handler in route.get("handle", []):
                    if handler.get("handler") == "subroute":
                        return handler["routes"]
        raise AssertionError("the relay.example.com route is missing")

    routes = site_routes(config)
    relay_index = next(i for i, route in enumerate(routes) if paths_in(route) == ["/dsh-link/*"])
    relay_handlers = handlers_in(routes[relay_index])
    strip = next((h for h in relay_handlers if h["handler"] == "rewrite"), None)
    assert strip is not None, "handle_path must strip the prefix"
    assert strip.get("strip_path_prefix") == "/dsh-link"
    proxy = next(h for h in relay_handlers if h["handler"] == "reverse_proxy")
    assert proxy["upstreams"][0]["dial"] == "127.0.0.1:8787"
    transport = proxy.get("transport", {})
    assert transport.get("protocol") == "http"
    assert transport.get("read_timeout", 0) == 0 and transport.get("write_timeout", 0) == 0
    assert proxy.get("flush_interval") == -1

    catch_all = next(i for i, route in enumerate(routes)
                     if any(h["handler"] == "file_server" for h in handlers_in(route)))
    assert relay_index < catch_all, "/dsh-link/* must be matched before the catch-all handle"
    assert any(paths_in(route) == ["/patent-landscape/*"] for route in routes), "existing blocks survive"
