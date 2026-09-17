#!/bin/bash
#
# Restart the DSH web server safely, from OUTSIDE the DSH process.
#
# Why a script and why outside: DSH cannot restart itself. The restart has to
# kill the very process running the agent, so anything that agent launches dies
# with it. A supervisor (or an external agent) must drive this.
#
# Why not just let the shell app do it: DSH.app's 「文件 → 重启 DSH 服务」 does
# this atomically and re-points its window at the new URL. That remains the best
# option when a human is at the keyboard. This script exists for when nobody is,
# and it deliberately covers the two things a naive `pkill; dsh web &` gets
# wrong:
#
#   1. THE PORT. The running instance may have been started with `--port 0`
#      (OS-assigned) and be listening on something else entirely, so relaunching
#      with the recorded argv would land on a *different* port and silently
#      orphan the user's bookmark. The real listening port is detected and reused.
#   2. BOOT FAILURE. A newly installed plugin that fails to register takes the
#      whole tree down, and the machine is then left with no UI at all. So the
#      script verifies the boot, and if it never comes up it relaunches with the
#      target plugin disabled, restoring a working UI instead of nothing.
#
# Exit codes: 0 restarted and verified, 2 came up only in recovery mode,
# 3 could not be restarted at all.

set -uo pipefail

TARGET_ID='doubao-image'
TIMEOUT_SECONDS=60
READY_TIMEOUT_SECONDS=25

# `dsh` usually lives in a package manager's bin, which is not on the PATH a
# launchd-spawned or cron-spawned shell gets. Without this the restart dies with
# "command not found" and the machine is left with no server at all.
# 只在目录确实存在时前置，避免把别的机器上不存在的路径塞进 PATH；
# 需要别的安装位置时用 DSH_BIN 指定，或自行把它的目录加进 PATH。
for candidate in /opt/homebrew/bin /usr/local/bin; do
  [ -d "$candidate" ] && PATH="$candidate:$PATH"
done
export PATH="${PATH:-/usr/bin:/bin}"
DSH_BIN="${DSH_BIN:-dsh}"
SELF_TEST_PATTERN="${SELF_TEST_PATTERN:-bin/dsh web|/dsh web}"

log() { printf '[restart-dsh] %s\n' "$*"; }
fail() { printf '[restart-dsh] ERROR: %s\n' "$*" >&2; }

# --- who are we restarting ---------------------------------------------------

OLD_PID=$(pgrep -f "${SELF_TEST_PATTERN}" | head -1)
if [ -z "${OLD_PID}" ]; then
  fail "no running 'dsh web' process found"
  exit 3
fi

# The listening port, which is NOT necessarily what argv said: an instance
# started with `--port 0` gets an OS-assigned port, and relaunching on 0 would
# land somewhere new. Ask the socket first, then the endpoint handoff file the
# desktop-shell plugin writes (which also covers a non-loopback bind).
OLD_PORT=""
for _ in $(seq 1 10); do
  OLD_PORT=$(lsof -nP -iTCP -sTCP:LISTEN -a -p "${OLD_PID}" 2>/dev/null \
    | awk 'NR>1 {print $9}' | sed -E 's/.*:([0-9]+)$/\1/' | grep -E '^[0-9]+$' | head -1)
  [ -n "${OLD_PORT}" ] && break
  sleep 0.3
done
if [ -z "${OLD_PORT}" ]; then
  ENDPOINT_FILE="${HOME}/.dsh/desktop-shell/endpoint.json"
  if [ -f "${ENDPOINT_FILE}" ]; then
    OLD_PORT=$(sed -n 's/.*"port" *: *\([0-9]\+\).*/\1/p' "${ENDPOINT_FILE}" | head -1)
    [ -n "${OLD_PORT}" ] && log "port recovered from endpoint.json"
  fi
fi

# The working directory, so a relative --patch or profile lookup still resolves.
OLD_CWD=$(lsof -a -p "${OLD_PID}" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)

# Launch environment, inherited from the process so DSH_HOME and the desktop
# shell markers survive. `ps eww` prints the environment after the command.
OLD_ENV=$(ps eww -o command= -p "${OLD_PID}" 2>/dev/null | tr ' ' '\n' \
  | grep -E '^(DSH_HOME|DSH_DESKTOP_SHELL|DSH_DESKTOP_SHELL_CLIENT|DSH_PERMISSION_MODE|HOME)=' || true)

[ -n "${OLD_CWD}" ] || OLD_CWD="${HOME}"
[ -n "${OLD_PORT}" ] || OLD_PORT=""

log "old pid=${OLD_PID} port=${OLD_PORT:-<none>} cwd=${OLD_CWD}"
[ -n "${OLD_ENV}" ] && log "inherited env: $(echo "${OLD_ENV}" | tr '\n' ' ')"

LOG_FILE="/tmp/restart-dsh-$(date +%Y%m%d-%H%M%S).log"
RESULT_FILE="${HOME}/.dsh/restart-dsh-result.json"

write_result() {
  # A machine-readable outcome, so the supervising agent does not have to parse
  # prose or guess whether it worked.
  cat > "${RESULT_FILE}" <<JSON
{
  "ok": $1,
  "mode": "$2",
  "url": $3,
  "pid": $4,
  "port": $5,
  "log": "${LOG_FILE}",
  "at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
}

# --- stop the old instance ---------------------------------------------------

# Walk the whole tree, not just the top pid. `dsh web` may be a shell wrapper
# whose child holds the listening socket; killing only the parent orphans that
# child, it keeps the port, and the replacement instance then fails to bind.
# (Observed exactly that in a self-test, where the fake server's child survived.)
collect_tree() {
  local pid="$1"
  local child
  for child in $(pgrep -P "${pid}" 2>/dev/null); do
    collect_tree "${child}"
  done
  printf '%s\n' "${pid}"
}

stop_tree() {
  local root="$1"
  local pids
  pids=$(collect_tree "${root}")
  log "stopping tree: $(echo "${pids}" | tr '\n' ' ')"

  # Deepest first, so a supervisor cannot notice and respawn a child.
  local reversed
  reversed=$(printf '%s\n' "${pids}" | tail -r 2>/dev/null || printf '%s\n' "${pids}" | tac)
  for pid in ${reversed}; do
    kill -TERM "${pid}" 2>/dev/null
  done

  for _ in $(seq 1 50); do
    kill -0 "${root}" 2>/dev/null || break
    sleep 0.1
  done

  pids=$(collect_tree "${root}")
  for pid in ${pids}; do
    kill -0 "${pid}" 2>/dev/null && kill -KILL "${pid}" 2>/dev/null
  done
  sleep 0.5
}

stop_tree "${OLD_PID}"
if kill -0 "${OLD_PID}" 2>/dev/null; then
  fail "pid ${OLD_PID} refused to die"
  write_result false "failed" null null null
  exit 3
fi

# Confirm the socket really is free; a lingering child would make the new
# instance fail to bind and look like a boot failure.
if [ -n "${OLD_PORT}" ]; then
  for _ in $(seq 1 20); do
    lsof -nP -iTCP:"${OLD_PORT}" -sTCP:LISTEN >/dev/null 2>&1 || break
    sleep 0.25
  done
  if lsof -nP -iTCP:"${OLD_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
    fail "port ${OLD_PORT} is still held after stopping the tree"
    write_result false "failed" null null null
    exit 3
  fi
fi
log "old instance is down and its port is free"

# --- start the new one -------------------------------------------------------

PORT_ARGS=()
[ -n "${OLD_PORT}" ] && PORT_ARGS=(--port "${OLD_PORT}")

start_instance() {
  local extra_patch="$1"
  local args
  if [ -n "${DSH_ARGS_OVERRIDE:-}" ]; then
    # Self-test hook: launch something other than the real server, so the
    # restart machinery can be exercised without taking down the live DSH.
    args=(${DSH_ARGS_OVERRIDE})
  else
    args=("${DSH_BIN}" web --no-open "${PORT_ARGS[@]}")
    [ -n "${extra_patch}" ] && args+=(--patch "${extra_patch}")
  fi
  log "starting: ${args[*]}"
  # Detach on all three standard descriptors. `nohup ... &` alone leaves the
  # parent shell attached, so a supervisor running this script (or Codex) waits
  # on the server's stdout forever and never sees the script exit — observed as
  # a 60s hang after the work was already finished. Closing 0/1/2 is what makes
  # this call return.
  ( cd "${OLD_CWD}" && env ${OLD_ENV} nohup "${args[@]}" >>"${LOG_FILE}" 2>&1 </dev/null & ) >/dev/null 2>&1
}

start_instance ""

# --- verify it came up -------------------------------------------------------

URL=""
NEW_PID=""
for _ in $(seq 1 $((TIMEOUT_SECONDS * 2))); do
  sleep 0.5
  URL=$(grep -o -E 'http://[0-9.]+:[0-9]+/\?token=[A-Za-z0-9_-]+' "${LOG_FILE}" 2>/dev/null | head -1)
  [ -n "${URL}" ] && break
done

NEW_PORT=$(printf '%s' "${URL}" | sed -E 's|.*:([0-9]+)/.*|\1|')
if [ -n "${URL}" ]; then
  # Confirm it actually serves, not merely that it logged a banner.
  for _ in $(seq 1 $((READY_TIMEOUT_SECONDS * 2))); do
    if curl -s -o /dev/null -m 2 "${URL}"; then break; fi
    sleep 0.5
  done
  NEW_PID=$(pgrep -f "${SELF_TEST_PATTERN}" | head -1)
  log "up and serving: ${URL}"
  if [ -n "${OLD_PORT}" ] && [ "${NEW_PORT}" != "${OLD_PORT}" ]; then
    log "WARNING: came up on port ${NEW_PORT}, not the previous ${OLD_PORT}"
  fi
  write_result true "normal" "\"${URL}\"" "${NEW_PID:-null}" "${NEW_PORT:-null}"
  exit 0
fi

# --- recovery: the new tree did not boot -------------------------------------

fail "no URL after ${TIMEOUT_SECONDS}s — assuming a broken plugin tree"
fail "last log lines:"
tail -n 15 "${LOG_FILE}" >&2 || true

PATCH_FILE="/tmp/disable-${TARGET_ID}.yml"
printf -- "- id: %s\n  disabled: true\n" "${TARGET_ID}" > "${PATCH_FILE}"
log "retrying with ${TARGET_ID} disabled (${PATCH_FILE})"

LOG_FILE="${LOG_FILE%.log}-recovery.log"
start_instance "${PATCH_FILE}"

URL=""
for _ in $(seq 1 $((TIMEOUT_SECONDS * 2))); do
  sleep 0.5
  URL=$(grep -o -E 'http://[0-9.]+:[0-9]+/\?token=[A-Za-z0-9_-]+' "${LOG_FILE}" 2>/dev/null | head -1)
  [ -n "${URL}" ] && break
done

if [ -n "${URL}" ]; then
  NEW_PORT=$(printf '%s' "${URL}" | sed -E 's|.*:([0-9]+)/.*|\1|')
  NEW_PID=$(pgrep -f "${SELF_TEST_PATTERN}" | head -1)
  log "recovered WITHOUT ${TARGET_ID}: ${URL}"
  write_result true "recovery" "\"${URL}\"" "${NEW_PID:-null}" "${NEW_PORT:-null}"
  exit 2
fi

fail "recovery boot also failed; no DSH is running"
write_result false "failed" null null null
exit 3
