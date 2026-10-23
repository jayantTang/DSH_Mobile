#!/usr/bin/env bash
# 磁盘写满（ENOSPC）的进程级故障注入。
#
# 构造方式：在**工作区内**的挂载点上放一个 8 MiB 的 APFS 镜像（diskutil 建、
# hdiutil 挂载），把中转的库与 WAL 放进这个卷，然后把卷填满。这样写请求会遇到
# 真实的文件系统 ENOSPC（SQLite 报 "database or disk is full"），不是模拟错误。
#
# 断言：
#   1. 写请求返回 5xx JSON 信封（不是纯文本 500 页），顶层 requestId 与响应头一致；
#   2. 不是 busy：不带 Retry-After（写满是运维事实，重试不会立刻恢复）；
#   3. 进程没崩：同一进程的 /healthz 仍 200；
#   4. 释放空间后同一写请求恢复 200（失败没有把连接弄坏）。
#
# 只写工作区内的镜像与临时库，不碰 ~/.dsh、生产库与真实数据；退出时强制卸载镜像。
#
# 用法：
#   relay-go/scripts/repro/repro_disk_full.sh
#   REPRO_BIN=relay-go/bin/dsh-relay relay-go/scripts/repro/repro_disk_full.sh
#
# 环境：macOS（需要 diskutil/hdiutil）；Linux 上没有这条路径时脚本报 blocked（exit 3）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RELAY_GO="$ROOT/relay-go"
BIN="${REPRO_BIN:-$RELAY_GO/bin/dsh-relay}"
IMAGE_MB="${REPRO_IMAGE_MB:-8}"

log() { printf '[disk-full] %s\n' "$*"; }
fail() { FAILURES+=("$*"); log "FAIL: $*"; }
FAILURES=()
RELAY_PID=""
MOUNT=""
WORK=""

cleanup() {
  if [ -n "$RELAY_PID" ]; then kill "$RELAY_PID" 2>/dev/null || true; wait "$RELAY_PID" 2>/dev/null || true; fi
  if [ -n "$MOUNT" ] && [ -d "$MOUNT" ]; then
    # 先删填充文件再卸载：APFS 在空间耗尽时卸载偶尔会拒绝。
    rm -f "$MOUNT"/fill-* 2>/dev/null || true
    hdiutil detach "$MOUNT" -quiet 2>/dev/null || diskutil unmount force "$MOUNT" >/dev/null 2>&1 || true
  fi
  if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT

if [ "$(uname -s)" != "Darwin" ]; then
  log "blocked：非 macOS，没有 diskutil/hdiutil 的安全构造方式"
  exit 3
fi
if ! command -v diskutil >/dev/null || ! command -v hdiutil >/dev/null; then
  log "blocked：缺 diskutil/hdiutil"
  exit 3
fi
if [ -z "${REPRO_BIN:-}" ]; then
  make -C "$RELAY_GO" build >/dev/null
fi
if [ ! -x "$BIN" ]; then
  log "FAIL：二进制不存在或不可执行：$BIN"
  exit 2
fi

# 挂载点必须在中转仓库工作区内：沙箱对 /Volumes、/tmp 之外的写路径可能拒绝，
# 而在工作区内挂载点上的写入是允许的（脚本自身验证过）。
WORK="$(mktemp -d "$RELAY_GO/.tmp-diskfull.XXXXXX")"
MOUNT="$WORK/mnt"
mkdir -p "$MOUNT"
IMAGE="$WORK/state.img"

diskutil image create blank -size "${IMAGE_MB}m" --volumeName DSHFault "$IMAGE" >/dev/null
hdiutil attach "$IMAGE" -nobrowse -noautoopen -mountpoint "$MOUNT" >/dev/null
log "挂载：${MOUNT}（${IMAGE_MB} MiB）"

PORT="$(python3 - <<'PY'
import socket
with socket.socket() as probe:
    probe.bind(("127.0.0.1", 0))
    print(probe.getsockname()[1])
PY
)"
DB="$MOUNT/state.db"
"$BIN" serve --host 127.0.0.1 --port "$PORT" --db "$DB" >"$WORK/relay.log" 2>&1 &
RELAY_PID=$!
BASE="http://127.0.0.1:$PORT"
for _ in $(seq 1 100); do
  if curl -fsS --max-time 1 "$BASE/healthz" >/dev/null 2>&1; then break; fi
  if ! kill -0 "$RELAY_PID" 2>/dev/null; then
    log "FAIL：relay 没能在镜像卷上启动"
    cat "$WORK/relay.log" >&2
    exit 1
  fi
  sleep 0.1
done
curl -fsS --max-time 2 "$BASE/healthz" >/dev/null || { log "FAIL：/healthz 不通"; exit 1; }

# 准备一个账户 + 电脑 + 设备（全部走真实管理面与配对流程）。
ACC="$("$BIN" admin --db "$DB" account-create --name disk-full \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["accountId"])')"
AGENT="$("$BIN" admin --db "$DB" agent-register --account "$ACC" --name disk-full-mac)"
AGENT_ID="$(printf '%s' "$AGENT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["agentId"])')"
AGENT_SECRET="$(printf '%s' "$AGENT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["agentSecret"])')"
CODE="$(curl -fsS --max-time 3 -X POST "$BASE/pair/code" \
  -H "Authorization: Bearer $AGENT_SECRET" -H 'Content-Type: application/json' -d '{}' \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["code"])')"
CLAIM="$(curl -fsS --max-time 3 -X POST "$BASE/pair/claim" \
  -H 'Content-Type: application/json' \
  -d "{\"pairCode\":\"$CODE\",\"deviceName\":\"disk-full-iPhone\"}")"
TOKEN="$(printf '%s' "$CLAIM" | python3 -c 'import json,sys;print(json.load(sys.stdin)["deviceToken"])')"
log "准备完成：agent=${AGENT_ID} device=$(printf '%s' "$CLAIM" | python3 -c 'import json,sys;print(json.load(sys.stdin)["deviceId"])')"

# 填满卷：先 1 MiB 块，再用 4 KiB 小块逼近 0 可用块。
dd if=/dev/zero of="$MOUNT/fill-1m.bin" bs=1m 2>/dev/null || true
for index in $(seq 1 4096); do
  if ! dd if=/dev/zero of="$MOUNT/fill-4k-$index.bin" bs=4096 count=1 2>/dev/null; then
    break
  fi
  # 每次小块写入都可能成功；卷满时 dd 会失败退出。
  if ! df -k "$MOUNT" | awk 'NR==2{exit !($4>0)}'; then break; fi
done
sync
log "卷状态：$(df -h "$MOUNT" | awk 'NR==2{print $4" 可用"}')"

put_state() {
  local outfile="$1"
  curl -sS --max-time 20 -o "$outfile" -w '%{http_code}' -X PUT "$BASE/account/state" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -H 'X-Request-Id: trace-disk-full' \
    -d '{"entries":[{"key":"theme","value":"dark","updatedAt":1}]}'
}

STATUS="$(put_state "$WORK/full-body.json" || echo 000)"
log "满盘时 PUT /account/state = $STATUS"
if [ "$STATUS" != "500" ]; then
  fail "满盘写请求状态码 = ${STATUS}，期望 500（JSON 信封）"
fi
python3 - "$WORK/full-body.json" <<'PY' || fail "满盘响应不是带 requestId 的 JSON 错误信封"
import json, sys
payload = json.load(open(sys.argv[1]))
assert payload.get("ok") is False, payload
body = payload.get("error") or {}
assert body.get("code") == "internal/error", payload
assert payload.get("requestId") == "trace-disk-full", payload
print("[disk-full] 信封：", json.dumps(payload, ensure_ascii=False)[:240])
PY
RETRY="$(curl -sS -o /dev/null -D - --max-time 20 -X PUT "$BASE/account/state" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"entries":[{"key":"theme","value":"light","updatedAt":2}]}' | tr -d '\r' \
  | awk -F': ' 'tolower($1)=="retry-after"{print $2}')"
if [ -n "$RETRY" ]; then
  fail "满盘写请求带了 Retry-After=${RETRY}（只读/满盘不是 busy）"
fi

# 进程没崩：同一进程的 /healthz 仍 200。
if ! curl -fsS --max-time 2 "$BASE/healthz" >/dev/null; then
  fail "满盘之后 /healthz 不通（进程或库坏了）"
fi

# 释放空间：同一请求必须恢复 200。
rm -f "$MOUNT"/fill-*.bin
sync
STATUS="$(put_state "$WORK/recovered-body.json" || echo 000)"
log "释放空间后 PUT /account/state = $STATUS"
if [ "$STATUS" != "200" ]; then
  fail "释放空间后写请求 = ${STATUS}，期望 200（失败没有恢复）"
fi

if ! grep -q 'database transaction failed' "$WORK/relay.log"; then
  fail "relay 日志没有 database transaction failed"
fi
if ! grep -qi 'disk is full' "$WORK/relay.log"; then
  fail "relay 日志没有 disk is full 的错误原因"
fi
log "relay 日志证据："
grep -i 'disk is full' "$WORK/relay.log" | head -3 | sed 's/^/[disk-full]   /'
grep 'request failed' "$WORK/relay.log" | head -2 | sed 's/^/[disk-full]   /' 

if [ "${#FAILURES[@]}" -gt 0 ]; then
  log "结论：FAIL（${#FAILURES[@]} 项）"
  for item in "${FAILURES[@]}"; do log "  - $item"; done
  exit 1
fi
log "结论：PASS（真实 ENOSPC：500 JSON 信封 + requestId、无 Retry-After、进程存活、释放后恢复 200）"
log "现场：${WORK}（退出时删除）"
