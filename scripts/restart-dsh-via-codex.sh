#!/bin/bash
#
# Restart DSH through Codex, so the restart survives the DSH process it kills.
#
# The problem this solves: DSH cannot restart itself. Whatever command the
# running agent issues is a descendant of the DSH process, so killing DSH kills
# the command mid-flight and nothing is left to bring the server back. Codex,
# given this task, is a *separate* process tree, so it outlives the shutdown and
# can verify the boot that follows.
#
# Flow: Codex -> restart-dsh.sh (detached helper) -> result JSON -> verification.
#
# The verification is a real HTTP probe, not just the script's own claim: the
# auth fence answering means the server is up and enforcing, which is the same
# signal the UI depends on.
#
# Usage:  scripts/restart-dsh-via-codex.sh
# Output: the new URL on stdout, plus the codex transcript for the record.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESTART_SCRIPT="${REPO_DIR}/scripts/restart-dsh.sh"
RESULT_FILE="${HOME}/.dsh/restart-dsh-result.json"
CODEX_LOG="/tmp/restart-dsh-codex-$(date +%Y%m%d-%H%M%S).log"

if [ ! -x "${RESTART_SCRIPT}" ]; then
  echo "restart script missing or not executable: ${RESTART_SCRIPT}" >&2
  exit 3
fi
if ! command -v codex >/dev/null 2>&1; then
  echo "codex CLI not found on PATH" >&2
  exit 3
fi

# The prompt is this explicit on purpose. Codex has no context for any of it,
# and a vague instruction here means it improvises — possibly by killing DSH
# itself or by starting a second server on a new port, both of which are worse
# than doing nothing.
PROMPT=$(cat <<EOF
You are performing a controlled restart of a local DSH web server. Follow these
steps exactly and do not improvise.

1. Run this command, from the repository root, as-is:

   bash ${RESTART_SCRIPT}

2. Its exit code has these meanings — report the number you observe:
     0 = restarted and verified
     2 = came back with the target plugin DISABLED (recovery)
     3 = could not be restarted at all
   Note that the command is expected to take up to about 130 seconds when it
   needs the recovery path. Let it finish; do not kill it early.

3. Read ${RESULT_FILE} and report its "url", "mode" and "ok" fields verbatim.
   If "ok" is not true, report the last 15 lines of the file named in "log".

4. If the result has a non-null "url", verify the server independently with:

   curl -s -o /dev/null -w '%{http_code}' '<the url from the result>'

   An HTTP 401 means the server is up and its auth fence is enforcing. Treat
   401 as success. Any connection failure or 000 means it is NOT up.

5. Report exactly these lines and nothing else:
      EXIT: <code>
      OK: <true|false>
      MODE: <mode>
      URL: <url>
      PROBE: <http code>

Do not start another server. Do not use any port other than the one already in
use. Do not edit any files.
EOF
)

echo "restarting DSH via codex; transcript -> ${CODEX_LOG}" >&2

# --sandbox danger-full-access: the job is process control and a curl probe, so
# a read-only sandbox would fail at step 1. --ephemeral keeps this throwaway
# task out of Codex's saved session history.
codex exec \
  --sandbox danger-full-access \
  --skip-git-repo-check \
  --ephemeral \
  --color never \
  -C "${REPO_DIR}" \
  "${PROMPT}" 2>&1 | tee "${CODEX_LOG}" >&2

# Re-verify here as well: Codex reporting success is not evidence, and the URL
# it prints is the only way back into the UI after an external restart.
if [ -f "${RESULT_FILE}" ]; then
  URL=$(sed -n 's/.*"url" *: *"\([^"]*\)".*/\1/p' "${RESULT_FILE}" | head -1)
  if [ -n "${URL}" ]; then
    CODE=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "${URL}" || echo 000)
    echo
    echo "DSH is back at: ${URL}"
    echo "probe: HTTP ${CODE}  (401 = up and enforcing auth)"
    echo
    echo "DSH.app's window does NOT follow an external restart — it will still"
    echo "be showing the old page. Reload it with ⌘R, or open the URL above."
    exit 0
  fi
fi

echo "restart did not produce a URL; see ${CODEX_LOG} and ${RESULT_FILE}" >&2
exit 3
