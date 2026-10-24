#!/usr/bin/env bash
#
# dsh-relay 中转的 Python ↔ Go 切换脚本。
#
#   sudo switch.sh --to-go        Python → Go（停旧 → WAL checkpoint → 备份 → 启动 → 健康检查）
#   sudo switch.sh --to-python    Go → Python（停旧 → WAL checkpoint → 启动 → 健康检查）
#        switch.sh --status       只读：两个 unit 的状态、端口监听、健康与数据库
#
# 设计约束（见 maintainers/design/DESIGN-20261023-go-relay-rewrite.md §10）：
#   * 两种实现同 schema、同端口、同路径；切换只换进程，不换数据库；
#   * --to-go 失败自动回到 Python；--to-python 失败默认回到 Go（可用
#     DSH_RELAY_AUTO_ROLLBACK=0 关闭）；
#   * 每次切换在审计日志里写 begin / ok（或 rollback / failed）各一行；
#   * 本脚本不碰 Caddy、不改 relay/*.py 与 relay-go 源码。
#
# 退出码：0 成功（含幂等 no-op）；1 切换失败（已尝试回滚）；2 用法或前置条件不满足。
#
# 可覆盖的环境变量（生产默认值即下面的值）：
#   DSH_RELAY_USER / DSH_RELAY_HOME / DSH_RELAY_GO_HOME / DSH_RELAY_GO_BIN
#   DSH_RELAY_DATA / DSH_RELAY_DB / DSH_RELAY_HOST / DSH_RELAY_PORT
#   DSH_RELAY_BASE_PATH / DSH_RELAY_PYTHON_UNIT / DSH_RELAY_GO_UNIT
#   DSH_RELAY_BACKUP_DIR / DSH_RELAY_SWITCH_LOG / DSH_RELAY_SWITCH_LOCK
#   DSH_RELAY_HEALTH_TIMEOUT / DSH_RELAY_STOP_TIMEOUT
#   DSH_RELAY_AUTO_ROLLBACK / DSH_RELAY_RESTORE_ON_FAIL
#   DSH_RELAY_GO_SHA256（可选：校验待启动二进制的 sha256）
#   DSH_RELAY_ALLOW_NO_PYTHON=1（仅当确认不再需要 Python 回滚目标时）
#   DSH_RELAY_ALLOW_NO_GO=1（仅当确认不再需要 Go 回滚目标时）

set -euo pipefail

# ── 部署位置与身份（与 relay/deploy/deploy.sh 保持同一套）───────────────────
SERVICE_USER="${DSH_RELAY_USER:-dsh-relay}"
PY_HOME="${DSH_RELAY_HOME:-/opt/dsh-relay}"
GO_HOME="${DSH_RELAY_GO_HOME:-/opt/dsh-relay-go}"
GO_BIN="${DSH_RELAY_GO_BIN:-$GO_HOME/bin/dsh-relay}"
DATA_DIR="${DSH_RELAY_DATA:-/var/lib/dsh-relay}"
DB="${DSH_RELAY_DB:-$DATA_DIR/state.db}"
HOST="${DSH_RELAY_HOST:-127.0.0.1}"
PORT="${DSH_RELAY_PORT:-8787}"
BASE_PATH="${DSH_RELAY_BASE_PATH:-/dsh-link}"
PY_UNIT="${DSH_RELAY_PYTHON_UNIT:-dsh-relay.service}"
GO_UNIT="${DSH_RELAY_GO_UNIT:-dsh-relay-go.service}"
BACKUP_ROOT="${DSH_RELAY_BACKUP_DIR:-/var/backups/dsh-relay}"
AUDIT_LOG="${DSH_RELAY_SWITCH_LOG:-/var/log/dsh-relay-switch.log}"
LOCK_FILE="${DSH_RELAY_SWITCH_LOCK:-/run/dsh-relay-switch.lock}"
HEALTH_TIMEOUT="${DSH_RELAY_HEALTH_TIMEOUT:-30}"
STOP_TIMEOUT="${DSH_RELAY_STOP_TIMEOUT:-20}"
AUTO_ROLLBACK="${DSH_RELAY_AUTO_ROLLBACK:-1}"
RESTORE_ON_FAIL="${DSH_RELAY_RESTORE_ON_FAIL:-0}"

# 探测地址：监听 0.0.0.0 / :: 时改从环回去连（/stats 与 /healthz 都只认环回）。
case "$HOST" in
  ""|0.0.0.0) PROBE_ADDR="127.0.0.1" ;;
  ::) PROBE_ADDR="[::1]" ;;
  *:*) PROBE_ADDR="[$HOST]" ;;
  *) PROBE_ADDR="$HOST" ;;
esac
BASE_URL="http://${PROBE_ADDR}:${PORT}"
PREFIX="${BASE_PATH%/}"

MODE=""
START_SECONDS=0
ROLLBACK_ARMED=0
BACKUP_DIR=""
ACTOR="${SUDO_USER:-$(id -un 2>/dev/null || echo unknown)}"
HOSTNAME_VALUE="$(hostname 2>/dev/null || echo unknown)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dsh-relay-switch.XXXXXX")"

# Python 只用于四件事：WAL checkpoint、备份库校验、JSON 字段核对、build.json 版本。
# 没有 Python 的机器仍可执行 --status；--to-go 在目标已健康时也可 no-op，但真要切换
# 时必须用 Python 做 checkpoint 与备份校验（preflight 会明确拒绝）。
pick_python() {
  local candidate
  for candidate in "$PY_HOME/.venv/bin/python" \
                   "$(command -v python3 2>/dev/null || true)" \
                   "$(command -v python 2>/dev/null || true)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}
PY_RUN="$(pick_python || true)"

# ── 基础输出与审计 ──────────────────────────────────────────────────────────
say()  { printf 'switch.sh: %s\n' "$*"; }
warn() { printf 'switch.sh: WARN: %s\n' "$*" >&2; }
die()  { printf 'switch.sh: error: %s\n' "$*" >&2; exit 2; }

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# 审计行是 key=value；把值里的空白换成下划线，保证一行一条、可直接 grep。
sanitize() { printf '%s' "$1" | tr ' \t\n' '___'; }

usage() {
  cat <<'EOF'
用法：
  switch.sh --to-go       从 Python 切到 Go：停旧 unit → WAL checkpoint → 备份库 →
                          启动 dsh-relay-go → 健康检查（/healthz、/stats）；失败自动回滚
  switch.sh --to-python   从 Go 切回 Python：停 Go → checkpoint → 启动 dsh-relay →
                          健康检查；失败默认回滚到 Go
  switch.sh --status      只读：两个 unit 的状态、8787 监听、健康、数据库与备份

重复执行同一动作是幂等的：目标 unit 已健康时不重启、不新增备份。
切换前后各写一行审计日志（默认 /var/log/dsh-relay-switch.log）。

关键环境变量：
  DSH_RELAY_AUTO_ROLLBACK=0   失败时不自动回滚（默认 1）
  DSH_RELAY_RESTORE_ON_FAIL=1 回滚时先用本次备份覆盖数据库（默认 0；会丢弃备份后的写入）
  DSH_RELAY_GO_SHA256=<hex>   启动前校验 /opt/dsh-relay-go/bin/dsh-relay 的 sha256
  DSH_RELAY_HEALTH_TIMEOUT=30 健康检查等待秒数
EOF
}

audit() {
  local line
  line="$(printf 'ts=%s host=%s actor=%s mode=%s %s' \
    "$(now_utc)" "$HOSTNAME_VALUE" "$ACTOR" "$MODE" "$*")"
  if ! printf '%s\n' "$line" >>"$AUDIT_LOG" 2>/dev/null; then
    warn "无法追加审计日志 $AUDIT_LOG"
  fi
  say "audit: $line"
}

cleanup_tmp() { rm -rf "$TMP_DIR"; }

# 兜底：任何未预期的中途退出（set -e、SIGTERM 之外）都在这里尝试回滚。
# 正常成功路径会先把 ROLLBACK_ARMED 置 0，因此不会重复回滚。
finish() {
  local rc=$?
  trap - EXIT
  set +e
  if [ "$ROLLBACK_ARMED" = "1" ]; then
    ROLLBACK_ARMED=0
    warn "脚本在切换完成前退出（rc=${rc}），执行兜底回滚"
    fail_switch "unexpected-exit rc=$rc"
  fi
  cleanup_tmp
  exit "$rc"
}
trap finish EXIT
# Ctrl-C / SSH 断开 / SIGTERM 时也走 EXIT 兜底：正在切换就回滚，不在切换就清理退出。
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# ── 命令与 systemd 小工具 ───────────────────────────────────────────────────
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "需要 root 运行（sudo $0 ${MODE}）"
}

acquire_lock() {
  need_cmd flock
  mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
  exec 9>"$LOCK_FILE" || die "无法打开锁文件：$LOCK_FILE"
  flock -n 9 || die "已有另一个 switch.sh 在运行（锁：${LOCK_FILE}）"
}

ensure_audit_log() {
  local dir
  dir="$(dirname "$AUDIT_LOG")"
  mkdir -p "$dir" 2>/dev/null || die "无法创建审计日志目录：$dir"
  : >>"$AUDIT_LOG" 2>/dev/null || die "无法写入审计日志：$AUDIT_LOG"
  chmod 0644 "$AUDIT_LOG" 2>/dev/null || true
}

unit_exists() { systemctl cat "$1" >/dev/null 2>&1; }

unit_state() {
  local state
  state="$(systemctl is-active "$1" 2>/dev/null || true)"
  printf '%s' "${state:-unknown}"
}

main_pid() {
  local pid
  pid="$(systemctl show -p MainPID --value "$1" 2>/dev/null)" || return 1
  printf '%s' "$pid" | tr -d '[:space:]'
}

enable_unit() {
  unit_exists "$1" || return 0
  if ! systemctl enable "$1" >/dev/null 2>&1; then
    warn "systemctl enable $1 失败；重启后不会自动拉起该实现"
    return 1
  fi
  return 0
}

disable_unit() {
  unit_exists "$1" || return 0
  systemctl disable "$1" >/dev/null 2>&1 \
    || warn "systemctl disable $1 失败；重启后可能与目标 unit 争抢 $PORT"
}

# 8787 上当前监听的 pid 列表（空格分隔）。ss 失败时返回非零，不能把"读不到"当成"没占用"。
listener_pids() {
  local out
  out="$(ss -lntpH "sport = :$PORT" 2>/dev/null)" || return 1
  printf '%s\n' "$out" \
    | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' \
    | sort -u | tr '\n' ' '
}

wait_port_free() {
  local i pids
  local attempts=$((STOP_TIMEOUT * 4))
  for ((i = 0; i < attempts; i++)); do
    pids="$(listener_pids)" || { warn "无法读取 $PORT 的监听进程（ss 失败）"; return 1; }
    if [ -z "$pids" ]; then
      return 0
    fi
    sleep 0.25
  done
  warn "端口 $PORT 在 ${STOP_TIMEOUT}s 内没有释放；仍被占用：$(printf '%s' "${pids:-未知}" | sed 's/ $//')"
  return 1
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# ── HTTP 健康检查 ───────────────────────────────────────────────────────────
http_probe() {
  local url=$1 body=$2 code
  # Python 版的 /stats 会按 Accept 决定是否渲染 HTML；显式要 JSON，两种实现同口径。
  if ! code="$(curl -sS --noproxy '*' --max-time 5 -H 'Accept: application/json' \
       -o "$body" -w '%{http_code}' "$url" 2>"$TMP_DIR/curl.err")"; then
    warn "请求 $url 失败：$(head -c 300 "$TMP_DIR/curl.err" 2>/dev/null)"
    return 1
  fi
  if [ "$code" != "200" ]; then
    warn "请求 $url 返回 HTTP ${code}：$(head -c 300 "$body" 2>/dev/null)"
    return 1
  fi
  return 0
}

json_ok() {
  if [ -n "$PY_RUN" ]; then
    "$PY_RUN" -c 'import json, sys
try:
    payload = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(1)
sys.exit(0 if payload.get("ok") is True else 1)' "$1"
  else
    grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' "$1"
  fi
}

json_relay_version() {
  if [ -n "$PY_RUN" ]; then
    "$PY_RUN" -c 'import json, sys
try:
    payload = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print("?")
    sys.exit(0)
print(payload.get("relayVersion") or "?")' "$1" 2>/dev/null || printf '?'
  else
    sed -n 's/.*"relayVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -n1
  fi
}

# check_impl 是"这个 unit 确实在服务"的完整判据：
#   active + 主进程存在 + 命令行属于该实现 + 8787 的监听者就是它 + 两个健康端点。
# 只看 systemctl 会被"unit active 但进程已经不再监听"骗过去。
check_impl() {
  local impl=$1 unit=$2 pid cmd pids
  systemctl is-active --quiet "$unit" 2>/dev/null \
    || { say "  $unit 不是 active"; return 1; }

  pid="$(main_pid "$unit" 2>/dev/null || true)"
  case "$pid" in
    ""|0) say "  $unit 没有主进程"; return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null \
    || [ -d "/proc/$pid" ] \
    || ps -p "$pid" >/dev/null 2>&1 \
    || { say "  $unit 的主进程 $pid 不存在"; return 1; }

  cmd=""
  # Linux 生产走 /proc（root 可读，不依赖 ps 的宽度与实现）；取不到时退回 ps。
  # 两者都拿不到时不把"看不见"误判成"不是这个实现"，只跳过这一项——
  # 监听 PID、unit 状态与两个健康端点仍然必须全部对上。
  if [ -r "/proc/$pid/cmdline" ]; then
    cmd="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | tr -s ' ')"
  elif command -v ps >/dev/null 2>&1; then
    cmd="$(ps -ww -o args= -p "$pid" 2>/dev/null | tr -s ' ' || true)"
  fi
  if [ -n "$cmd" ]; then
    case "$impl" in
      go)
        case "$cmd" in
          *"$GO_BIN"*) ;;
          *) say "  $unit 主进程不是 ${GO_BIN}：$cmd"; return 1 ;;
        esac
        ;;
      python)
        case "$cmd" in
          *"relay.py"*) ;;
          *) say "  $unit 主进程不是 relay.py：$cmd"; return 1 ;;
        esac
        ;;
    esac
  fi

  # 只有 root 能稳定拿到其他用户 socket 的 pid；--status 允许非 root，跳过这一项。
  if [ "$(id -u)" -eq 0 ]; then
    pids="$(listener_pids 2>/dev/null || true)"
    pids=" $(printf '%s' "$pids" | tr -s ' ') "
    case "$pids" in
      *" $pid "*) ;;
      *) say "  $PORT 的监听进程不是 $unit 的主进程 ${pid}（监听 pid：${pids:-无}）"; return 1 ;;
    esac
  fi

  http_probe "$BASE_URL/healthz" "$TMP_DIR/health.json" || return 1
  json_ok "$TMP_DIR/health.json" || { say "  /healthz 返回的不是 ok"; return 1; }

  if [ -n "$PREFIX" ] && [ "$PREFIX" != "/" ]; then
    http_probe "$BASE_URL$PREFIX/healthz" "$TMP_DIR/health-prefixed.json" || return 1
    json_ok "$TMP_DIR/health-prefixed.json" \
      || { say "  $PREFIX/healthz 返回的不是 ok"; return 1; }
  fi

  http_probe "$BASE_URL/stats" "$TMP_DIR/stats.json" || return 1
  json_ok "$TMP_DIR/stats.json" || { say "  /stats 返回的不是 ok"; return 1; }
  return 0
}

wait_health() {
  local impl=$1 unit=$2 deadline=$((SECONDS + HEALTH_TIMEOUT))
  while :; do
    if check_impl "$impl" "$unit" >/dev/null 2>&1; then
      say "$unit 健康检查通过"
      return 0
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      break
    fi
    sleep 0.5
  done
  warn "$unit 在 ${HEALTH_TIMEOUT}s 内没有通过健康检查："
  check_impl "$impl" "$unit" || true
  return 1
}

diagnose() {
  local unit=$1
  warn "── $unit 诊断 ──"
  systemctl status "$unit" --no-pager --lines=20 2>&1 | sed 's/^/  /' >&2 || true
  if command -v journalctl >/dev/null 2>&1; then
    journalctl -u "$unit" -n 30 --no-pager 2>&1 | tail -n 30 | sed 's/^/  /' >&2 || true
  fi
}

# ── 数据库：checkpoint、备份、校验、恢复 ────────────────────────────────────
checkpoint_db() {
  local output
  if ! output="$("$PY_RUN" - "$DB" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1], timeout=15)
try:
    busy, log_frames, checkpointed = connection.execute(
        "PRAGMA wal_checkpoint(TRUNCATE)"
    ).fetchone()
finally:
    connection.close()
print("busy=%s log=%s checkpointed=%s" % (busy, log_frames, checkpointed))
raise SystemExit(1 if busy else 0)
PY
)"; then
    warn "WAL checkpoint 失败（${output:-无输出}）"
    return 1
  fi
  say "WAL checkpoint：$output"
  # TRUNCATE 成功时 -wal 应为空；仍非空说明还有连接持有 WAL，不能继续。
  if [ -s "$DB-wal" ]; then
    warn "checkpoint 后 $DB-wal 仍非空"
    return 1
  fi
  return 0
}

backup_integrity() {
  local target=$1 result
  if ! result="$("$PY_RUN" - "$target" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
try:
    print(connection.execute("PRAGMA integrity_check").fetchone()[0])
finally:
    connection.close()
PY
)"; then
    warn "无法对备份库执行 integrity_check：$target"
    return 1
  fi
  if [ "$result" != "ok" ]; then
    warn "备份库 integrity_check=${result}（${target}）"
    return 1
  fi
  return 0
}

sqlite_user_version() {
  "$PY_RUN" - "$1" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
try:
    print(connection.execute("PRAGMA user_version").fetchone()[0])
finally:
    connection.close()
PY
}

ensure_backup_space() {
  local db_bytes db_kb avail_kb need_kb
  mkdir -p "$BACKUP_ROOT" 2>/dev/null || die "无法创建备份目录：$BACKUP_ROOT"
  chmod 0700 "$BACKUP_ROOT" 2>/dev/null || true
  db_bytes="$(wc -c <"$DB" | tr -d ' ')" || die "无法读取数据库大小：$DB"
  db_kb=$(((db_bytes + 1023) / 1024))
  avail_kb="$(df -Pk "$BACKUP_ROOT" | awk 'NR == 2 {print $4}')"
  [ -n "$avail_kb" ] || die "无法读取 $BACKUP_ROOT 的可用空间"
  need_kb=$((db_kb * 2 + 10240))
  [ "$avail_kb" -ge "$need_kb" ] \
    || die "备份空间不足：需要约 ${need_kb} KiB，$BACKUP_ROOT 可用 ${avail_kb} KiB"
}

backup_db() {
  local label=$1 stamp dir n
  local suffix db_bytes db_sha user_version integrity
  local py_state go_state py_version go_version

  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  dir="$BACKUP_ROOT/${stamp}-${label}"
  n=1
  while [ -e "$dir" ]; do
    dir="$BACKUP_ROOT/${stamp}-${label}-$n"
    n=$((n + 1))
  done

  install -d -m 0700 "$dir" || { warn "无法创建备份目录：$dir"; return 1; }
  cp -a "$DB" "$dir/state.db" || { warn "复制数据库失败：$DB"; return 1; }
  for suffix in -wal -shm; do
    if [ -e "$DB$suffix" ]; then
      cp -a "$DB$suffix" "$dir/state.db$suffix" || { warn "复制 $DB$suffix 失败"; return 1; }
    fi
  done

  db_bytes="$(wc -c <"$dir/state.db" | tr -d ' ')" || { warn "读取备份大小失败"; return 1; }
  db_sha="$(sha256_of "$dir/state.db")" || { warn "计算备份 sha256 失败"; return 1; }
  (cd "$dir" && printf '%s  state.db\n' "$db_sha" >SHA256SUMS) \
    || { warn "写入 SHA256SUMS 失败"; return 1; }

  backup_integrity "$dir/state.db" || return 1
  integrity="ok"
  user_version="$(sqlite_user_version "$dir/state.db")" \
    || { warn "读取备份库 user_version 失败"; return 1; }

  py_state="$(unit_state "$PY_UNIT")"
  go_state="$(unit_state "$GO_UNIT")"
  py_version="$("$PY_RUN" - "$PY_HOME/build.json" <<'PY'
import json
import sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get("version") or "?")
except Exception:
    print("?")
PY
)" || py_version="?"
  go_version="$("$PY_RUN" - "$GO_HOME/bin/build.json" <<'PY'
import json
import sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get("version") or "?")
except Exception:
    print("?")
PY
)" || go_version="?"

  {
    printf 'action=%s\n' "$label"
    printf 'created_utc=%s\n' "$(now_utc)"
    printf 'host=%s\n' "$HOSTNAME_VALUE"
    printf 'actor=%s\n' "$ACTOR"
    printf 'db=%s\n' "$DB"
    printf 'db_bytes=%s\n' "$db_bytes"
    printf 'db_sha256=%s\n' "$db_sha"
    printf 'db_integrity=%s\n' "$integrity"
    printf 'sqlite_user_version=%s\n' "$user_version"
    printf 'python_home=%s\n' "$PY_HOME"
    printf 'go_home=%s\n' "$GO_HOME"
    printf 'python_unit=%s state=%s version=%s\n' "$PY_UNIT" "$py_state" "$py_version"
    printf 'go_unit=%s state=%s version=%s\n' "$GO_UNIT" "$go_state" "$go_version"
    printf 'go_binary=%s sha256=%s\n' "$GO_BIN" "$(sha256_of "$GO_BIN" 2>/dev/null || echo '?')"
  } >"$dir/MANIFEST" || { warn "写入 MANIFEST 失败"; return 1; }

  # 旧 unit 文件一并留档，便于人工比对回滚（代码本身原地不动，不复制 venv）。
  for unit in "$PY_UNIT" "$GO_UNIT"; do
    if [ -f "/etc/systemd/system/$unit" ]; then
      cp -a "/etc/systemd/system/$unit" "$dir/$unit" 2>/dev/null || true
    fi
  done

  BACKUP_DIR="$dir"
  say "数据库已备份：${dir}（integrity_check=${integrity}，user_version=${user_version}）"
  return 0
}

restore_db() {
  local dir=$1 expected actual
  [ -f "$dir/state.db" ] || { warn "备份目录里没有 state.db：$dir"; return 1; }
  if [ -f "$dir/SHA256SUMS" ]; then
    expected="$(awk 'NR == 1 {print $1}' "$dir/SHA256SUMS")"
    actual="$(sha256_of "$dir/state.db")" || return 1
    [ "$expected" = "$actual" ] \
      || { warn "备份 sha256 不匹配：期望 ${expected}，实际 $actual"; return 1; }
  fi
  cp -a "$dir/state.db" "$DB.restore.$$" || { warn "复制备份到 $DB 失败"; return 1; }
  mv -f "$DB.restore.$$" "$DB" || { warn "替换 $DB 失败"; return 1; }
  rm -f "$DB-wal" "$DB-shm"
  chown "$SERVICE_USER:$SERVICE_USER" "$DB" 2>/dev/null || true
  chmod 0600 "$DB" 2>/dev/null || true
  say "已恢复备份：$dir/state.db"
  return 0
}

# ── 预先检查 ────────────────────────────────────────────────────────────────
preflight_common() {
  require_root
  need_cmd systemctl
  need_cmd ss
  need_cmd curl
  need_cmd flock
  need_cmd install
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 \
    || die "缺少 sha256sum / shasum，无法为备份做校验"
  [ -d "$DATA_DIR" ] || die "数据目录不存在：$DATA_DIR"
  [ -f "$DB" ] || die "数据库不存在：${DB}（首次部署请直接安装并启动 Go 版，不要走切换）"
  ensure_audit_log
  systemctl daemon-reload || die "systemctl daemon-reload 失败"
}

preflight_go() {
  preflight_common
  unit_exists "$GO_UNIT" || die "找不到 ${GO_UNIT}；先安装 unit 并 daemon-reload"
  [ -x "$GO_BIN" ] || die "Go 二进制不存在或不可执行：$GO_BIN"
  if [ ! -f "$GO_HOME/bin/build.json" ]; then
    warn "$GO_HOME/bin/build.json 不存在：/healthz 的 relayVersion 会是 0.0.0"
  fi
  if [ -n "${DSH_RELAY_GO_SHA256:-}" ]; then
    local actual
    actual="$(sha256_of "$GO_BIN")" || die "无法计算 $GO_BIN 的 sha256"
    [ "$actual" = "$DSH_RELAY_GO_SHA256" ] \
      || die "Go 二进制 sha256 不匹配：期望 ${DSH_RELAY_GO_SHA256}，实际 $actual"
  fi
}

# 只有真的要切换时才要求 Python 还在：已经跑在 Go 上的机器删掉 Python 之后，
# `--to-go` 仍应是一次成功的 no-op。
require_go_switch_prereqs() {
  if ! unit_exists "$PY_UNIT" && [ "${DSH_RELAY_ALLOW_NO_PYTHON:-0}" != "1" ]; then
    die "找不到 ${PY_UNIT}：切换后将没有回滚目标。确知不需要回滚时设 DSH_RELAY_ALLOW_NO_PYTHON=1"
  fi
  [ -n "$PY_RUN" ] || die "找不到可用的 Python 解释器（checkpoint 与备份校验需要 sqlite3）"
  "$PY_RUN" -c 'import sqlite3' >/dev/null 2>&1 \
    || die "$PY_RUN 缺少 sqlite3 模块，无法做 WAL checkpoint"
}

preflight_python() {
  preflight_common
  unit_exists "$PY_UNIT" || die "找不到 $PY_UNIT"
  [ -n "$PY_RUN" ] || die "找不到可用的 Python 解释器"
  [ -x "$PY_RUN" ] || die "Python 解释器不可执行：$PY_RUN"
  [ -f "$PY_HOME/relay.py" ] || die "找不到 Python relay：$PY_HOME/relay.py"
  "$PY_RUN" -c 'import sqlite3' >/dev/null 2>&1 \
    || die "$PY_RUN 缺少 sqlite3 模块，无法做 WAL checkpoint"
}

# 同理：已经跑在 Python 上时，即使 Go unit 已被移除，`--to-python` 也可以是 no-op。
require_python_switch_prereqs() {
  if ! unit_exists "$GO_UNIT" && [ "${DSH_RELAY_ALLOW_NO_GO:-0}" != "1" ]; then
    die "找不到 ${GO_UNIT}：回滚目标不存在。确知不需要回滚时设 DSH_RELAY_ALLOW_NO_GO=1"
  fi
}

current_impl() {
  if check_impl go "$GO_UNIT" >/dev/null 2>&1; then
    printf 'go'
  elif check_impl python "$PY_UNIT" >/dev/null 2>&1; then
    printf 'python'
  else
    printf 'none'
  fi
}

# ── 回滚 ────────────────────────────────────────────────────────────────────
rollback_to() {
  local impl=$1 unit=$2 reason=$3
  set +e
  warn "开始回滚到 ${impl}（原因：${reason}）"
  audit "phase=rollback target=$impl reason=$(sanitize "$reason")"

  unit_exists "$GO_UNIT" && systemctl stop "$GO_UNIT" >/dev/null 2>&1
  unit_exists "$PY_UNIT" && systemctl stop "$PY_UNIT" >/dev/null 2>&1
  wait_port_free >/dev/null 2>&1

  if [ "$RESTORE_ON_FAIL" = "1" ] && [ -n "$BACKUP_DIR" ]; then
    warn "DSH_RELAY_RESTORE_ON_FAIL=1：用本次备份覆盖数据库"
    restore_db "$BACKUP_DIR" || warn "恢复备份失败；继续尝试启动 $impl"
  fi

  if ! systemctl start "$unit" >/dev/null 2>&1; then
    warn "启动 $unit 失败"
    diagnose "$unit"
    audit "phase=rollback-failed target=$impl reason=start-failed"
    return 1
  fi
  if wait_health "$impl" "$unit"; then
    if enable_unit "$unit"; then
      case "$impl" in
        python) disable_unit "$GO_UNIT" ;;
        go) disable_unit "$PY_UNIT" ;;
      esac
    else
      warn "保留另一个 unit 的开机自启作为兜底；请手工修复 enable"
    fi
    audit "phase=rollback-ok target=$impl duration_s=$((SECONDS - START_SECONDS))"
    say "已回滚到 ${impl}，服务健康"
    return 0
  fi

  warn "回滚到 $impl 后仍未通过健康检查"
  diagnose "$unit"
  audit "phase=rollback-failed target=$impl reason=health"
  return 1
}

# fail_switch 是唯一的失败出口：写审计 → 按 MODE 决定回滚目标 → exit 1。
# 关闭自动回滚时只报告，不改动已经停下的服务。
fail_switch() {
  local reason=$1 rb_impl="" rb_unit=""
  ROLLBACK_ARMED=0
  set +e
  warn "切换失败：$reason"
  audit "phase=failed target=${MODE#to-} reason=$(sanitize "$reason")"

  if [ "$AUTO_ROLLBACK" != "1" ]; then
    warn "自动回滚已关闭（DSH_RELAY_AUTO_ROLLBACK=0）；服务可能处于停止状态，按 README 手工处理"
    cleanup_tmp
    exit 1
  fi

  case "$MODE" in
    to-go) rb_impl="python"; rb_unit="$PY_UNIT" ;;
    to-python) rb_impl="go"; rb_unit="$GO_UNIT" ;;
  esac
  if [ -n "$rb_impl" ]; then
    rollback_to "$rb_impl" "$rb_unit" "$reason" || warn "自动回滚未成功，见上面的诊断"
  fi
  cleanup_tmp
  exit 1
}

# ── 切换 ────────────────────────────────────────────────────────────────────
switch_to_go() {
  local previous
  preflight_go

  if check_impl go "$GO_UNIT"; then
    audit "phase=noop target=go reason=already-healthy"
    if enable_unit "$GO_UNIT"; then
      disable_unit "$PY_UNIT"
    else
      warn "保留 $PY_UNIT 的开机自启作为兜底"
    fi
    say "当前已经是 Go 实现且健康，未做改动"
    return 0
  fi

  require_go_switch_prereqs
  ensure_backup_space
  previous="$(current_impl)"
  START_SECONDS=$SECONDS
  audit "phase=begin target=go previous=$previous db=$DB"
  ROLLBACK_ARMED=1

  # 目标 unit 可能卡死但仍占着端口（上次启动失败、crash-loop 的残留），
  # 所以两个都停；随后 wait_port_free 才是"端口真的空出来"的证据。
  if unit_exists "$PY_UNIT"; then
    if ! systemctl stop "$PY_UNIT"; then
      fail_switch "停止 $PY_UNIT 失败"
    fi
  else
    warn "$PY_UNIT 不存在，跳过停止（DSH_RELAY_ALLOW_NO_PYTHON=1）"
  fi
  if unit_exists "$GO_UNIT"; then
    if ! systemctl stop "$GO_UNIT"; then
      fail_switch "停止 $GO_UNIT 失败"
    fi
  fi

  if ! wait_port_free; then
    fail_switch "停止旧实现后端口 $PORT 未释放"
  fi
  if ! checkpoint_db; then
    fail_switch "WAL checkpoint 未成功"
  fi
  if ! backup_db "to-go"; then
    fail_switch "数据库备份未成功"
  fi

  if ! systemctl start "$GO_UNIT"; then
    diagnose "$GO_UNIT"
    fail_switch "启动 $GO_UNIT 失败"
  fi
  if ! wait_health go "$GO_UNIT"; then
    diagnose "$GO_UNIT"
    fail_switch "Go 健康检查未通过"
  fi

  ROLLBACK_ARMED=0
  if enable_unit "$GO_UNIT"; then
    disable_unit "$PY_UNIT"
  else
    warn "保留 $PY_UNIT 的开机自启作为兜底；修复 enable 后再手工 disable 它"
    audit "phase=boot-warning target=go kept=$PY_UNIT"
  fi
  audit "phase=ok target=go previous=$previous duration_s=$((SECONDS - START_SECONDS)) backup=$BACKUP_DIR"
  print_summary go "$GO_UNIT"
  return 0
}

switch_to_python() {
  local previous
  preflight_python

  if check_impl python "$PY_UNIT"; then
    audit "phase=noop target=python reason=already-healthy"
    if enable_unit "$PY_UNIT"; then
      disable_unit "$GO_UNIT"
    else
      warn "保留 $GO_UNIT 的开机自启作为兜底"
    fi
    say "当前已经是 Python 实现且健康，未做改动"
    return 0
  fi

  require_python_switch_prereqs
  previous="$(current_impl)"
  START_SECONDS=$SECONDS
  audit "phase=begin target=python previous=$previous db=$DB"
  ROLLBACK_ARMED=1

  # 同 --to-go：两个都停，避免上一次失败的 Go/Python 进程继续占着 8787。
  if unit_exists "$GO_UNIT"; then
    if ! systemctl stop "$GO_UNIT"; then
      fail_switch "停止 $GO_UNIT 失败"
    fi
  else
    warn "$GO_UNIT 不存在，跳过停止（DSH_RELAY_ALLOW_NO_GO=1）"
  fi
  if unit_exists "$PY_UNIT"; then
    if ! systemctl stop "$PY_UNIT"; then
      fail_switch "停止 $PY_UNIT 失败"
    fi
  fi

  if ! wait_port_free; then
    fail_switch "停止 Go 后端口 $PORT 未释放"
  fi
  if ! checkpoint_db; then
    fail_switch "WAL checkpoint 未成功"
  fi

  if ! systemctl start "$PY_UNIT"; then
    diagnose "$PY_UNIT"
    fail_switch "启动 $PY_UNIT 失败"
  fi
  if ! wait_health python "$PY_UNIT"; then
    diagnose "$PY_UNIT"
    fail_switch "Python 健康检查未通过"
  fi

  ROLLBACK_ARMED=0
  if enable_unit "$PY_UNIT"; then
    disable_unit "$GO_UNIT"
  else
    warn "保留 $GO_UNIT 的开机自启作为兜底；修复 enable 后再手工 disable 它"
    audit "phase=boot-warning target=python kept=$GO_UNIT"
  fi
  audit "phase=ok target=python previous=$previous duration_s=$((SECONDS - START_SECONDS))"
  print_summary python "$PY_UNIT"
  return 0
}

print_summary() {
  local impl=$1 unit=$2 version
  version="$(json_relay_version "$TMP_DIR/health.json" 2>/dev/null || printf '?')"
  say "切换完成：$unit 正在服务（${impl}，relayVersion=${version}）"
  say "健康检查：$BASE_URL/healthz、$BASE_URL${PREFIX}/healthz、$BASE_URL/stats 均 200"
  if [ -n "$BACKUP_DIR" ]; then
    say "数据库备份：$BACKUP_DIR"
  fi
  say "审计日志：$AUDIT_LOG"
  say "观察指标与回滚阈值：relay-go/deploy/README.md"
}

# ── 只读状态 ────────────────────────────────────────────────────────────────
status() {
  local unit impl active enabled pid since active_count active_unit active_impl
  local sockets pids

  printf '%-24s %-10s %-10s %-8s %s\n' "UNIT" "ACTIVE" "ENABLED" "MAINPID" "SINCE"
  active_count=0
  active_unit=""
  active_impl=""

  for spec in "$PY_UNIT:python" "$GO_UNIT:go"; do
    unit="${spec%%:*}"
    impl="${spec##*:}"
    active="$(systemctl is-active "$unit" 2>/dev/null || true)"
    [ -n "$active" ] || active="unknown"
    enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
    [ -n "$enabled" ] || enabled="missing"
    pid="$(main_pid "$unit" 2>/dev/null || true)"
    [ -n "$pid" ] && [ "$pid" != "0" ] || pid="-"
    since="$(systemctl show -p ExecMainStartTimestamp --value "$unit" 2>/dev/null || true)"
    [ -n "$since" ] || since="-"
    printf '%-24s %-10s %-10s %-8s %s\n' "$unit" "$active" "$enabled" "$pid" "$since"
    if [ "$active" = "active" ]; then
      active_count=$((active_count + 1))
      active_unit="$unit"
      active_impl="$impl"
    fi
  done

  printf '\n监听 %s:%s：\n' "$PROBE_ADDR" "$PORT"
  if command -v ss >/dev/null 2>&1; then
    sockets="$(ss -lntH "sport = :$PORT" 2>/dev/null || true)"
    if [ -n "$sockets" ]; then
      printf '%s\n' "$sockets" | sed 's/^/  /'
    else
      printf '  （无监听）\n'
    fi
    pids="$(listener_pids 2>/dev/null || true)"
    if [ -n "$pids" ]; then
      printf '  监听 pid：%s\n' "$(printf '%s' "$pids" | sed 's/ $//')"
    fi
  else
    printf '  （没有 ss，无法查看）\n'
  fi

  printf '\n数据库：'
  if [ -f "$DB" ]; then
    printf '%s（%s 字节，WAL %s 字节）\n' "$DB" \
      "$(wc -c <"$DB" | tr -d ' ')" \
      "$(if [ -f "$DB-wal" ]; then wc -c <"$DB-wal" | tr -d ' '; else printf '0'; fi)"
  else
    printf '%s 不存在\n' "$DB"
  fi
  printf '备份目录：%s（%s 份）\n' "$BACKUP_ROOT" \
    "$(if [ -d "$BACKUP_ROOT" ]; then find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '; else printf '0'; fi)"
  printf '审计日志：%s\n\n' "$AUDIT_LOG"

  if ! command -v curl >/dev/null 2>&1; then
    warn "没有 curl，无法确认 HTTP 健康；按未验证处理"
    return 1
  fi

  if [ "$active_count" -eq 0 ]; then
    printf '健康：没有 active 的 unit\n'
    return 1
  fi
  if [ "$active_count" -gt 1 ]; then
    printf '健康：两个 unit 同时 active；端口只能被其中一个占用，先查明原因\n'
    return 1
  fi

  if check_impl "$active_impl" "$active_unit"; then
    printf '健康：%s（relayVersion=%s）\n' "$active_unit" \
      "$(json_relay_version "$TMP_DIR/health.json")"
    return 0
  fi
  printf '健康：%s 未通过检查\n' "$active_unit"
  return 1
}

# ── 入口 ────────────────────────────────────────────────────────────────────
case "${1:-}" in
  --to-go|--to-python|--status)
    MODE="${1#--}"
    shift
    [ "$#" -eq 0 ] || die "一次只接受一个动作，多余参数：$*"
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  "")
    usage >&2
    exit 2
    ;;
  *)
    usage >&2
    die "未知参数：$1"
    ;;
esac

case "$MODE" in
  status)
    status
    ;;
  to-go|to-python)
    require_root
    acquire_lock
    if [ "$MODE" = "to-go" ]; then
      switch_to_go
    else
      switch_to_python
    fi
    ;;
esac
