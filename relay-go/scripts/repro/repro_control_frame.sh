#!/usr/bin/env bash
# M6 验收：真实连接器 + 临时 Go relay，验证控制帧不再被 pong 等待挤掉。
#
# 覆盖四项验收判据：
#   1. 连接至少保持 --seconds 秒（默认 180），relay 日志只有 1 条 agent connected；
#   2. relay 日志 0 条 control frame could not be queued；
#   3. 连接器日志 0 条 relay stopped answering pings；
#   4. /stats 的 controlDrops 为 0，且 goroutine 转储里写循环不处在 Ping 调用里。
#
# 用法：
#   relay-go/scripts/repro/repro_control_frame.sh                # 180 秒
#   relay-go/scripts/repro/repro_control_frame.sh --seconds 30   # 冒烟
#
# 依赖本机正在运行的 DSH（连接器从 ~/.dsh/mobile-link/endpoint.json 取 dshUrl）；
# 只写 /tmp 下的临时库与临时 agent，不碰 ~/.dsh/mobile-link/agent.json。
set -euo pipefail

SECONDS_TO_RUN=180
while [ $# -gt 0 ]; do
  case "$1" in
    --seconds) SECONDS_TO_RUN="${2:?--seconds 需要数字}"; shift 2 ;;
    --seconds=*) SECONDS_TO_RUN="${1#*=}"; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done
if ! [[ "$SECONDS_TO_RUN" =~ ^[0-9]+$ ]] || [ "$SECONDS_TO_RUN" -lt 10 ]; then
  echo "--seconds 必须是 >=10 的整数" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BIN="${REPRO_BIN:-$ROOT/relay-go/bin/dsh-relay}"
WORK="$(mktemp -d /tmp/repro-m6.XXXXXX)"
PORT="${REPRO_PORT:-18888}"
PPROF_PORT="${REPRO_PPROF_PORT:-18889}"
ENDPOINT="$HOME/.dsh/mobile-link/endpoint.json"

log() { printf '[m6-repro] %s\n' "$*"; }
fail() { FAILURES+=("$*"); log "FAIL: $*"; }
FAILURES=()

cleanup() {
  if [ -n "${CONN_PID:-}" ]; then kill "$CONN_PID" 2>/dev/null || true; fi
  if [ -n "${RELAY_PID:-}" ]; then kill "$RELAY_PID" 2>/dev/null || true; fi
  wait 2>/dev/null || true
}
trap cleanup EXIT

if [ ! -r "$ENDPOINT" ]; then
  echo "找不到 ${ENDPOINT}：需要本机 DSH 在运行" >&2
  exit 2
fi
DSH_URL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["url"])' "$ENDPOINT")"
if [ -z "${REPRO_SKIP_BUILD:-}" ] && [ -z "${REPRO_BIN:-}" ]; then
  make -C "$ROOT/relay-go" build >/dev/null
fi

log "work=$WORK seconds=$SECONDS_TO_RUN dsh=$DSH_URL"
"$BIN" serve --host 127.0.0.1 --port "$PORT" --db "$WORK/state.db" \
  --pprof-addr "127.0.0.1:$PPROF_PORT" >"$WORK/relay.log" 2>&1 &
RELAY_PID=$!
sleep 1
if ! kill -0 "$RELAY_PID" 2>/dev/null; then
  echo "relay 没能启动（端口 $PORT 被占用？）" >&2
  cat "$WORK/relay.log" >&2
  exit 2
fi

ACC="$("$BIN" admin --db "$WORK/state.db" account-create --name repro \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["accountId"])')"
AG="$("$BIN" admin --db "$WORK/state.db" agent-register --account "$ACC" --name repro-mac \
  | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["agentId"],d["agentSecret"])')"
AGENT_ID="${AG%% *}"
AGENT_SECRET="${AG##* }"

node "$ROOT/plugins/mobile-link/lib/cli.js" \
  --relay "ws://127.0.0.1:$PORT" --agent-id "$AGENT_ID" --agent-secret "$AGENT_SECRET" \
  --dsh-url "$DSH_URL" --status-file "$WORK/status.json" --log-level info \
  >"$WORK/connector.log" 2>&1 &
CONN_PID=$!

# 先等连接建立：最多 15 秒。
for _ in $(seq 1 30); do
  if grep -q 'relay: agent connected' "$WORK/relay.log"; then break; fi
  sleep 0.5
done
if ! grep -q 'relay: agent connected' "$WORK/relay.log"; then
  fail "连接器未能建立连接"
  tail -20 "$WORK/connector.log" >&2
fi

capture_goroutines() {
  local label="$1"
  curl -s --max-time 5 "http://127.0.0.1:$PPROF_PORT/debug/pprof/goroutine?debug=2" \
    >"$WORK/goroutine-$label.txt" || true
}
stats_field() {
  curl -s --max-time 3 "http://127.0.0.1:$PORT/stats" \
    | python3 -c 'import json,sys
try:
    payload = json.load(sys.stdin)
except Exception:
    print("?"); raise SystemExit
print(payload.get("controlDrops"), payload.get("load", {}).get("agents"))' 2>/dev/null || echo "? ?"
}

# 每 10 秒采一次；60 秒时抓一次 goroutine（与验收要求对应）。
elapsed=0
while [ "$elapsed" -lt "$SECONDS_TO_RUN" ]; do
  sleep 10
  elapsed=$((elapsed + 10))
  read -r drops agents <<<"$(stats_field)"
  connects="$(grep -c 'relay: agent connected' "$WORK/relay.log" || true)"
  log "t=${elapsed}s controlDrops=$drops agents=$agents connects=$connects"
  if [ "$elapsed" -ge 60 ] && [ ! -s "$WORK/goroutine-60s.txt" ]; then
    capture_goroutines 60s
  fi
done
capture_goroutines final

# 判据 1：连接没有断开、也没有重连。
CONNECTS="$(grep -c 'relay: agent connected' "$WORK/relay.log" || true)"
DISCONNECTS="$(grep -c 'relay: agent disconnected' "$WORK/relay.log" || true)"
[ "$CONNECTS" -eq 1 ] || fail "agent connected = ${CONNECTS}，期望 1（发生了重连）"
[ "$DISCONNECTS" -eq 0 ] || fail "agent disconnected = ${DISCONNECTS}，期望 0"

# 判据 2：必达控制帧没有排不进去。
CTRL_CLOSE="$(grep -c 'control frame could not be queued' "$WORK/relay.log" || true)"
[ "$CTRL_CLOSE" -eq 0 ] || fail "control frame could not be queued = ${CTRL_CLOSE}，期望 0"

# 判据 3：连接器没有判定 relay 不回 pong。
PING_LOST="$(grep -c 'relay stopped answering pings' "$WORK/connector.log" || true)"
[ "$PING_LOST" -eq 0 ] || fail "连接器日志出现 relay stopped answering pings ($PING_LOST)"

# 判据 4：controlDrops 为 0；写循环不在 Ping 里。
read -r FINAL_DROPS FINAL_AGENTS <<<"$(stats_field)"
[ "$FINAL_DROPS" = "0" ] || fail "/stats controlDrops = ${FINAL_DROPS}，期望 0"
[ "$FINAL_AGENTS" = "1" ] || fail "/stats load.agents = ${FINAL_AGENTS}，期望 1"
PONG_WAIT="$(grep -h -F -A 30 'hub.(*Link).writeLoop' "$WORK"/goroutine-*.txt \
  | grep -c -F 'websocket.(*Conn).Ping' || true)"
[ "$PONG_WAIT" -eq 0 ] || fail "写循环停在 WS Ping 等待上（$PONG_WAIT 处）"
WRITE_LOOPS="$(grep -c -F 'hub.(*Link).writeLoop' "$WORK/goroutine-final.txt" || true)"
[ "$WRITE_LOOPS" -ge 1 ] || fail "goroutine 转储里没有 writeLoop（连接可能已退出）"

log "goroutine: writeLoop=$WRITE_LOOPS 处，Ping 等待=$PONG_WAIT 处"
log "relay 日志：$(grep -c 'relay: control\|dropped a lossy' "$WORK/relay.log" || true) 条控制帧丢弃相关日志"
if [ "${#FAILURES[@]}" -gt 0 ]; then
  log "结论：FAIL（${#FAILURES[@]} 项）"
  for item in "${FAILURES[@]}"; do log "  - $item"; done
  log "现场：$WORK"
  exit 1
fi
log "结论：PASS（${SECONDS_TO_RUN}s 无重连、无控制帧关闭、无 pong 失联、controlDrops=0）"
log "现场：$WORK"
