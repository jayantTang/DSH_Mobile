#!/bin/bash
# Pick an available iPad simulator, install the current app there, and run the
# iPad layout acceptance case. No hard-coded UDID: another machine has its own.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
line="$(xcrun simctl list devices available | grep -E 'iPad.*(Booted|Shutdown)' | head -1 || true)"
udid="$(printf '%s' "$line" | sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/')"
if [ -z "$udid" ]; then
  echo "找不到可用的 iPad 模拟器" >&2
  exit 2
fi
cd "$ROOT"
./test/run.sh --sim "$udid" prepare --build >/tmp/dsh-ipad-prepare.log 2>&1
exec ./test/run.sh --sim "$udid" run test/acceptance/09-ipad-layout.md
