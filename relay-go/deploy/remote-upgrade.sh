#!/usr/bin/env bash
# 在目标机上执行一次受控升级：先冒烟、留档、备份，再替换并观察；任何一步不健康
# 自动把上一份二进制与 build.json 放回去并重启。由 scripts/release/deploy-relay.sh
# 通过 ssh 调用，不手工执行。
#
# 环境变量：
#   STAGED_BIN    本次上传的 Linux 二进制
#   STAGED_BUILD  本次上传的 build.json
#   VERSION       期望的 relayVersion（例如 go-0.3.5）
#   OBSERVE       替换后继续观察的秒数（默认 60；每 5 秒一次，连续 3 次失败回滚）
set -euo pipefail

STAGED_BIN="${STAGED_BIN:?}"
STAGED_BUILD="${STAGED_BUILD:?}"
VERSION="${VERSION:?}"
OBSERVE="${OBSERVE:-60}"
SERVICE="${SERVICE:-dsh-relay-go}"
BIN="${BIN:-/opt/dsh-relay-go/bin/dsh-relay}"
BUILD="${BUILD:-/opt/dsh-relay-go/bin/build.json}"
HEALTH="${HEALTH:-http://127.0.0.1:8787/healthz}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/dsh-relay}"
SMOKE_PORT="${SMOKE_PORT:-18787}"

log() { printf '[remote] %s\n' "$*"; }
die() { printf '[remote] ERROR: %s\n' "$*" >&2; exit 2; }

health_version() {
  curl -fsS --max-time 3 --noproxy '*' "$HEALTH" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("relayVersion",""))' 2>/dev/null || true
}
wait_version() {
  local want="$1" seconds="$2" i
  for ((i = 0; i < seconds; i++)); do
    [[ "$(health_version)" == "$want" ]] && return 0
    sleep 1
  done
  return 1
}
is_active() { systemctl is-active --quiet "$SERVICE"; }

[[ "$(id -u)" == 0 ]] || die "run as root"
[[ -x "$STAGED_BIN" ]] || die "staged binary missing: $STAGED_BIN"
[[ -r "$STAGED_BUILD" ]] || die "staged build.json missing: $STAGED_BUILD"
is_active || die "service is not active before upgrade"
[[ -n "$(health_version)" ]] || die "health endpoint is unavailable before upgrade"
prev_version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$BUILD")"
[[ "$prev_version" != "$VERSION" ]] || die "service already reports $VERSION"

# 1. 新二进制先在一次性端口与一次性库上启动一次：坏二进制不碰生产。
smoke_dir="$(mktemp -d /tmp/dsh-relay-smoke-XXXXXX)"
smoke_pid=""
cleanup() {
  [[ -n "$smoke_pid" ]] && kill "$smoke_pid" 2>/dev/null || true
  rm -rf "$smoke_dir"
}
trap cleanup EXIT
"$STAGED_BIN" serve --host 127.0.0.1 --port "$SMOKE_PORT" \
  --db "$smoke_dir/state.db" --base-path /dsh-link >"$smoke_dir/out.log" 2>&1 &
smoke_pid=$!
smoke_ok=0
for ((i = 0; i < 20; i++)); do
  if curl -fsS --max-time 2 --noproxy '*' "http://127.0.0.1:$SMOKE_PORT/healthz" >/dev/null 2>&1; then
    smoke_ok=1
    break
  fi
  sleep 0.5
done
if [[ "$smoke_ok" != 1 ]]; then
  cat "$smoke_dir/out.log" >&2 || true
  die "staged binary failed its smoke start"
fi
kill "$smoke_pid" 2>/dev/null || true
wait "$smoke_pid" 2>/dev/null || true
smoke_pid=""
log "staged binary smoke start ok"

# 2. 留档当前二进制与指纹；同名留档已存在时加时间戳，不覆盖历史。
archive="/opt/dsh-relay-go/bin/history/$prev_version"
if [[ -e "$archive/dsh-relay" ]]; then
  archive="${archive}-$(date -u +%Y%m%dT%H%M%SZ)"
fi
install -d -m 0755 "$archive"
cp -a "$BIN" "$BUILD" "$archive/"
log "archived $prev_version -> $archive"

# 3. 数据库先 checkpoint 再备份；升级不换库，备份只用于回滚与取证。
install -d -m 0750 "$BACKUP_ROOT"
db_backup="$BACKUP_ROOT/state-$(date -u +%Y%m%dT%H%M%SZ).db"
python3 - "$db_backup" <<'PY'
import sqlite3
import sys

source = "/var/lib/dsh-relay/state.db"
target = sys.argv[1]
con = sqlite3.connect(source)
print("checkpoint", con.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone())
destination = sqlite3.connect(target)
con.backup(destination)
destination.close()
con.close()
print("backup", target)
PY
chown dsh-relay:dsh-relay "$db_backup" 2>/dev/null || true
log "db backup -> $db_backup"

rollback() {
  log "ROLLBACK to $prev_version"
  cp -a "$archive/dsh-relay" "$BIN"
  cp -a "$archive/build.json" "$BUILD"
  systemctl restart "$SERVICE" || true
  if wait_version "$prev_version" 30; then
    log "ROLLBACK-OK version=$prev_version"
    exit 1
  fi
  log "ROLLBACK-FAILED version=$prev_version; manual intervention required"
  exit 3
}

# 4. 原子替换二进制与指纹，重启并等待新版本健康。
install -m 0755 -o root -g root "$STAGED_BIN" "$BIN.new"
install -m 0644 -o root -g root "$STAGED_BUILD" "$BUILD.new"
mv "$BIN.new" "$BIN"
mv "$BUILD.new" "$BUILD"
start_epoch="$(date +%s)"
systemctl restart "$SERVICE" || rollback

if ! wait_version "$VERSION" 45; then
  journalctl -u "$SERVICE" --since "@$start_epoch" --no-pager -o cat 2>/dev/null | tail -40 >&2 || true
  rollback
fi
if ! is_active; then
  rollback
fi
if journalctl -u "$SERVICE" --since "@$start_epoch" --no-pager -o cat 2>/dev/null \
  | grep -Eq 'panic:|failed to start|FATAL'; then
  log "new version logged a fatal error"
  rollback
fi

# 5. 继续观察：连续 3 次（约 15 秒）健康检查失败即回滚，而不是只信第一次 200。
log "healthy at $VERSION; observing ${OBSERVE}s"
fails=0
checks=$((OBSERVE / 5))
for ((i = 0; i < checks; i++)); do
  sleep 5
  if [[ "$(health_version)" == "$VERSION" ]] && is_active; then
    fails=0
  else
    fails=$((fails + 1))
  fi
  if ((fails >= 3)); then
    rollback
  fi
done

log "UPGRADE-OK version=$VERSION previous=$prev_version archive=$archive db_backup=$db_backup"
