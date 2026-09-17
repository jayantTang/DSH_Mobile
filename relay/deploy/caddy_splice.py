"""Splice the relay's route fragment into an existing Caddy site block.

The relay is published as a *path prefix* on an existing site
(``https://relay.example.com/dsh-link``), so the fragment is not a site block
of its own — it must be inserted **inside** the existing site block, before the
first ``handle``/``handle_path``/``route`` directive, otherwise a catch-all
``handle`` block declared earlier would swallow ``/dsh-link/*``.

The fragment is wrapped in two marker comments, so:

* re-running the insert replaces the block in place (idempotent), and
* deleting the two marked lines (or ``remove``) reverts the Caddyfile exactly.

Nothing else in the file is touched, and the caller validates the result with
``caddy validate`` before reloading.

    python3 caddy_splice.py insert /etc/caddy/Caddyfile Caddyfile.snippet relay.example.com
    python3 caddy_splice.py remove /etc/caddy/Caddyfile
"""

from __future__ import annotations

import argparse
import pathlib
import sys

BEGIN = "# >>> dsh-relay managed block (managed by relay/deploy/deploy.sh) >>>"
END = "# <<< dsh-relay managed block <<<"

#: Directives whose first match wins, so the relay fragment must precede them.
HANDLE_DIRECTIVES = ("handle", "handle_path", "route", "reverse_proxy")


class SpliceError(RuntimeError):
    """The Caddyfile could not be edited safely; the caller must not write it."""


def brace_delta(line: str) -> int:
    """Net ``{``/``}`` count of one line, ignoring quoted text and comments."""
    delta = 0
    in_quote = False
    escaped = False
    for char in line:
        if in_quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_quote = False
            continue
        if char == '"':
            in_quote = True
        elif char == "#":
            break
        elif char == "{":
            delta += 1
        elif char == "}":
            delta -= 1
    return delta


def _is_global_options(index: int, lines: list[str]) -> bool:
    """The opening ``{`` of the global options block is not a site block."""
    for i, line in enumerate(lines):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        return i == index and stripped == "{"
    return False


def _address_tokens(lines: list[str], index: int) -> list[str]:
    """Address list of the site block whose opening brace is on ``index``."""
    head = lines[index].strip()
    if head == "{":
        # Addresses may sit on the lines just above a brace-only opener.
        collected: list[str] = []
        walk = index - 1
        while walk >= 0:
            candidate = lines[walk].strip()
            if not candidate or candidate.startswith("#"):
                break
            if candidate.endswith(("{", "}")):
                break
            collected.insert(0, candidate)
            walk -= 1
        head = " ".join(collected)
    else:
        head = head[:-1]
    return [token for token in head.replace(",", " ").split() if token]


def find_site_block(lines: list[str], site: str) -> int:
    """Index of the line opening the site block that serves ``site``."""
    wanted = site.split("://")[-1].split(":")[0].strip()
    for index, line in enumerate(lines):
        stripped = line.strip()
        if not stripped or line[:1].isspace() or stripped.startswith("#"):
            continue
        if not stripped.endswith("{"):
            continue
        if _is_global_options(index, lines):
            continue
        for token in _address_tokens(lines, index):
            host = token.split("://")[-1].split(":")[0]
            if host == wanted:
                return index
    raise SpliceError(
        f"no site block for {site!r} found at column 0; add the marked block manually "
        f"inside that site block (see deploy/Caddyfile.snippet)"
    )


def block_end(lines: list[str], open_index: int) -> int:
    """Index of the line holding the closing brace of a block."""
    depth = 0
    for index in range(open_index, len(lines)):
        depth += brace_delta(lines[index])
        if depth <= 0:
            return index
    raise SpliceError("unbalanced braces: the site block never closes")


def insertion_index(lines: list[str], open_index: int, close_index: int) -> int:
    """Where the fragment goes: before the first order-sensitive directive."""
    depth = 0
    for index in range(open_index, close_index + 1):
        stripped = lines[index].strip()
        if depth == 1 and stripped and not stripped.startswith("#"):
            token = stripped.split()[0]
            if token in HANDLE_DIRECTIVES:
                return index
        depth += brace_delta(lines[index])
    return close_index


def marker_range(lines: list[str]) -> tuple[int, int] | None:
    begin = next((i for i, line in enumerate(lines) if BEGIN in line), None)
    end = next((i for i, line in enumerate(lines) if END in line), None)
    if begin is None or end is None or end < begin:
        return None
    return begin, end


def render_block(snippet: str, indent: str = "\t") -> list[str]:
    """The marked block. Its leading blank line is *inside* the markers, so a
    later remove() cannot swallow a blank line the operator wrote."""
    body = snippet.rstrip("\n").splitlines()
    rendered = [f"{indent}{BEGIN}\n", "\n"]
    rendered.extend(f"{indent}{line}\n" if line.strip() else "\n" for line in body)
    rendered.extend(["\n", f"{indent}{END}\n"])
    return rendered


def splice(text: str, snippet: str, site: str) -> tuple[str, str]:
    """Insert or replace the marked fragment; returns ``(text, action)``."""
    lines = text.splitlines(keepends=True)
    block = render_block(snippet)
    existing = marker_range(lines)
    if existing is not None:
        begin, end = existing
        return "".join(lines[:begin] + block + lines[end + 1:]), "replaced"
    if not text.strip():
        raise SpliceError("the Caddyfile is empty; refusing to guess where the site block is")
    open_index = find_site_block(lines, site)
    close_index = block_end(lines, open_index)
    at = insertion_index(lines, open_index, close_index)
    return "".join(lines[:at] + block + lines[at:]), "inserted"


def remove(text: str) -> tuple[str, str]:
    """Drop the marked fragment; returns ``(text, action)``."""
    lines = text.splitlines(keepends=True)
    existing = marker_range(lines)
    if existing is None:
        return text, "absent"
    begin, end = existing
    return "".join(lines[:begin] + lines[end + 1:]), "removed"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="caddy_splice.py", description=__doc__)
    parser.add_argument("action", choices=("insert", "remove", "check"))
    parser.add_argument("caddyfile")
    parser.add_argument("snippet", nargs="?")
    parser.add_argument("site", nargs="?", default="relay.example.com")
    args = parser.parse_args(argv)

    path = pathlib.Path(args.caddyfile)
    text = path.read_text() if path.exists() else ""
    try:
        if args.action == "insert":
            if not args.snippet:
                raise SpliceError("insert needs a snippet path")
            updated, action = splice(text, pathlib.Path(args.snippet).read_text(), args.site)
        elif args.action == "remove":
            updated, action = remove(text)
        else:
            action = "present" if marker_range(text.splitlines(keepends=True)) else "absent"
            print(action)
            return 0
    except SpliceError as error:
        sys.stderr.write(f"caddy_splice.py: {error}\n")
        return 1

    if updated != text:
        path.write_text(updated)
    print(action)
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
