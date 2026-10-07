#!/usr/bin/env python3
"""Set / clear the DSH default permission preset in $DSH_HOME/settings.yaml.

The key is the same one the Web GUI's General → permission row writes:

    permission:
      defaultPreset: danger-full-access

Presets shipped by DSH: read-only, workspace-write, danger-full-access.
`--clear` removes the override so the composed default applies again.

The edit is textual and minimal on purpose: settings.yaml is a live,
machine-managed document with other namespaces in it, so this script only
touches the `permission:` block and leaves everything else byte-identical.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import sys

VALID = ("read-only", "workspace-write", "danger-full-access")
KEY = "permission"


def settings_path() -> pathlib.Path:
    home = os.environ.get("DSH_HOME") or os.path.join(pathlib.Path.home(), ".dsh")
    return pathlib.Path(home) / "settings.yaml"


def set_preset(text: str, preset: str) -> tuple[str, bool]:
    """Return (new_text, changed). Replaces or appends the permission block."""
    lines = text.splitlines()
    start = None
    for index, line in enumerate(lines):
        if re.match(r"^%s\s*:" % KEY, line):
            start = index
            break
    block = ["%s:" % KEY, "  defaultPreset: %s" % preset]

    if start is None:
        body = "\n".join(lines).rstrip("\n")
        prefix = body + "\n\n" if body else ""
        return prefix + "\n".join(block) + "\n", True

    end = len(lines)
    for index in range(start + 1, len(lines)):
        if lines[index] and not lines[index][0].isspace() and not lines[index].lstrip().startswith("#"):
            end = index
            break
    new_lines = lines[:start] + block + lines[end:]
    return "\n".join(new_lines).rstrip("\n") + "\n", new_lines != lines


def clear_preset(text: str) -> tuple[str, bool]:
    """Return (new_text, changed) with the whole permission block removed."""
    lines = text.splitlines()
    start = None
    for index, line in enumerate(lines):
        if re.match(r"^%s\s*:" % KEY, line):
            start = index
            break
    if start is None:
        return text, False
    end = len(lines)
    for index in range(start + 1, len(lines)):
        if lines[index] and not lines[index][0].isspace() and not lines[index].lstrip().startswith("#"):
            end = index
            break
    new_lines = lines[:start] + lines[end:]
    return "\n".join(new_lines).rstrip("\n") + ("\n" if new_lines else ""), True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--preset", choices=VALID, help="default preset for sessions created later")
    group.add_argument("--clear", action="store_true", help="remove the override (back to the composed default)")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--path", help="override settings.yaml path (tests)")
    args = parser.parse_args()

    path = pathlib.Path(args.path) if args.path else settings_path()
    text = path.read_text(encoding="utf-8") if path.exists() else ""
    new_text, changed = clear_preset(text) if args.clear else set_preset(text, args.preset)

    if not changed:
        print("unchanged: %s" % path)
        return 0
    if args.dry_run:
        print(new_text, end="")
        return 0
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(new_text, encoding="utf-8")
    print("%s: %s" % ("cleared" if args.clear else "set %s in" % args.preset, path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
