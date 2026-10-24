#!/usr/bin/env bash
# M7 验收：重复连接风暴下的生命周期抑制。
#
# 场景（对应 2026-10-23 两次回滚的形态）：
#   * storm 桩连接器每秒开一条新的 /link/agent 连接，不关旧连接，也从不上报版本；
#   * healthy 桩连接器正常连一次、上报版本、每秒 ping 并等 pong；
#   * 30 秒后核对：superseded 有界（新实现应为 0）、reconnectStorm 有界、
#     未上报版本的连接进入退避、healthy 不被影响。
#
# 用法：
#   relay-go/scripts/repro/repro_reconnect_storm.sh                  # 30 秒
#   relay-go/scripts/repro/repro_reconnect_storm.sh --seconds 60
#   REPRO_BIN=relay-go/bin/dsh-relay-baseline \
#     relay-go/scripts/repro/repro_reconnect_storm.sh                # 旧实现对照
#
# 只写 /tmp 下的临时库与临时 agent，不碰 ~/.dsh 与生产库。
set -euo pipefail

SECONDS_TO_RUN=30
BIN_OVERRIDE="${REPRO_BIN:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --seconds) SECONDS_TO_RUN="${2:?--seconds 需要数字}"; shift 2 ;;
    --seconds=*) SECONDS_TO_RUN="${1#*=}"; shift ;;
    --bin) BIN_OVERRIDE="${2:?--bin 需要路径}"; shift 2 ;;
    --bin=*) BIN_OVERRIDE="${1#*=}"; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done
if ! [[ "$SECONDS_TO_RUN" =~ ^[0-9]+$ ]] || [ "$SECONDS_TO_RUN" -lt 10 ]; then
  echo "--seconds 必须是 >=10 的整数" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RELAY_GO="$ROOT/relay-go"
PYTHON="${REPRO_PYTHON:-$ROOT/.venv/bin/python}"
BIN="${BIN_OVERRIDE:-$RELAY_GO/bin/dsh-relay}"
WORK="$(mktemp -d /tmp/repro-m7-storm.XXXXXX)"
PORT="${REPRO_PORT:-18887}"

log() { printf '[m7-storm] %s\n' "$*"; }
fail() { FAILURES+=("$*"); log "FAIL: $*"; }
FAILURES=()
RELAY_PID=""
STUB_PID=""

cleanup() {
  if [ -n "$STUB_PID" ]; then kill "$STUB_PID" 2>/dev/null || true; fi
  if [ -n "$RELAY_PID" ]; then kill "$RELAY_PID" 2>/dev/null || true; fi
  wait 2>/dev/null || true
}
trap cleanup EXIT

if [ ! -x "$PYTHON" ]; then
  echo "找不到 Python 虚拟环境：${PYTHON}（需要仓库根的 .venv）" >&2
  exit 2
fi
if [ -z "$BIN_OVERRIDE" ]; then
  make -C "$RELAY_GO" build >/dev/null
fi
if [ ! -x "$BIN" ]; then
  echo "二进制不存在或不可执行：$BIN" >&2
  exit 2
fi
if lsof -ti "tcp:$PORT" >/dev/null 2>&1; then
  echo "端口 $PORT 已被占用；用 REPRO_PORT 换一个" >&2
  exit 2
fi

log "bin=$BIN work=$WORK port=$PORT seconds=$SECONDS_TO_RUN"
"$BIN" serve --host 127.0.0.1 --port "$PORT" --db "$WORK/state.db" \
  >"$WORK/relay.log" 2>&1 &
RELAY_PID=$!
sleep 1
if ! kill -0 "$RELAY_PID" 2>/dev/null; then
  echo "relay 没能启动" >&2
  cat "$WORK/relay.log" >&2
  exit 2
fi

# 建一个账户与两个 agent：storm（异常）与 healthy（对照）。
ACC="$("$BIN" admin --db "$WORK/state.db" account-create --name repro-storm \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["accountId"])')"
STORM="$("$BIN" admin --db "$WORK/state.db" agent-register --account "$ACC" --name storm-mac)"
HEALTHY="$("$BIN" admin --db "$WORK/state.db" agent-register --account "$ACC" --name healthy-mac)"
STORM_ID="$(printf '%s' "$STORM" | python3 -c 'import json,sys;print(json.load(sys.stdin)["agentId"])')"
STORM_SECRET="$(printf '%s' "$STORM" | python3 -c 'import json,sys;print(json.load(sys.stdin)["agentSecret"])')"
HEALTHY_ID="$(printf '%s' "$HEALTHY" | python3 -c 'import json,sys;print(json.load(sys.stdin)["agentId"])')"
HEALTHY_SECRET="$(printf '%s' "$HEALTHY" | python3 -c 'import json,sys;print(json.load(sys.stdin)["agentSecret"])')"

# /stats 的字段快照（旧实现没有这些字段时输出 -1，便于对照）。
stats_fields() {
  curl -s --max-time 3 "http://127.0.0.1:$PORT/stats" | python3 -c '
import json, sys
try:
    payload = json.load(sys.stdin)
except Exception:
    print("-1 -1 -1 -1 -1 -1 -1"); raise SystemExit
load = payload.get("load") or {}
def value(key):
    return payload.get(key, -1)
print(value("superseded"), value("reconnectStorm"), value("refusedDuplicate"),
      value("refusedUnverified"), value("unverifiedAgents"),
      load.get("agents", -1), load.get("devices", -1))'
}

"$PYTHON" "$RELAY_GO/scripts/repro/storm_stub.py" \
  --base "http://127.0.0.1:$PORT" \
  --storm-id "$STORM_ID" --storm-secret "$STORM_SECRET" \
  --healthy-id "$HEALTHY_ID" --healthy-secret "$HEALTHY_SECRET" \
  --seconds "$SECONDS_TO_RUN" --out "$WORK/stub-summary.json" \
  >"$WORK/stub.log" 2>&1 &
STUB_PID=$!

# 运行中采样一次 /stats：此时 healthy 必须仍在线，风暴计数已经开始增长。
sleep $((SECONDS_TO_RUN * 2 / 3))
read -r MID_SUP MID_STORM MID_DUP MID_UNV MID_UNVERIFIED MID_AGENTS MID_DEVICES \
  <<<"$(stats_fields)"
MID_SNAPSHOT="$(curl -s --max-time 3 "http://127.0.0.1:$PORT/stats")"
MID_HEALTHY_DISCONNECTS="$(grep 'agent disconnected' "$WORK/relay.log" | grep -c "$HEALTHY_ID" || true)"
MID_HEALTHY="$(printf '%s' "$MID_SNAPSHOT" | python3 -c "
import json, sys
try:
    payload = json.load(sys.stdin)
except Exception:
    print('missing'); raise SystemExit
ids = [agent.get('agentId') for agent in (payload.get('snapshot') or {}).get('agents') or []]
print('present' if '$HEALTHY_ID' in ids else 'missing')" 2>/dev/null || echo missing)"

wait "$STUB_PID" || true
STUB_PID=""
read -r END_SUP END_STORM END_DUP END_UNV END_UNVERIFIED END_AGENTS END_DEVICES \
  <<<"$(stats_fields)"

STORM_ATTEMPTS="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["storm"]["attempts"])' "$WORK/stub-summary.json")"
STORM_REFUSED="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["storm"]["refused"])' "$WORK/stub-summary.json")"
HEALTHY_PONGS="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["healthy"]["pongs"])' "$WORK/stub-summary.json")"
HEALTHY_CLOSES="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["healthy"]["closes"])' "$WORK/stub-summary.json")"
HEALTHY_SECONDS="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["healthy"]["connectedSeconds"])' "$WORK/stub-summary.json")"

SUPERSEDED_LOGS="$(grep -c 'agent superseded by a new connection' "$WORK/relay.log" || true)"
STORM_CONNECTS="$(grep 'agent connected' "$WORK/relay.log" | grep -c "$STORM_ID" || true)"
HEALTHY_DISCONNECTS="$(grep 'agent disconnected' "$WORK/relay.log" | grep -c "$HEALTHY_ID" || true)"
REFUSED_LOGS="$(grep -cE 'refused a (duplicate agent connection|reconnect from an agent)' "$WORK/relay.log" || true)"

log "storm: attempts=$STORM_ATTEMPTS refused=$STORM_REFUSED"
log "healthy: pongs=$HEALTHY_PONGS closes=$HEALTHY_CLOSES connected=${HEALTHY_SECONDS}s mid-run=$MID_HEALTHY disconnects(mid)=$MID_HEALTHY_DISCONNECTS"
log "relay: connects(storm)=${STORM_CONNECTS} superseded(log)=${SUPERSEDED_LOGS} refused(log)=${REFUSED_LOGS} 429(stub)=${STORM_REFUSED}"
log "/stats mid: superseded=$MID_SUP reconnectStorm=$MID_STORM dup=$MID_DUP unverifiedRefused=$MID_UNV unverifiedAgents=$MID_UNVERIFIED agents=$MID_AGENTS"
log "/stats end: superseded=$END_SUP reconnectStorm=$END_STORM dup=$END_DUP unverifiedRefused=$END_UNV unverifiedAgents=$END_UNVERIFIED agents=$END_AGENTS"

# ── 判据 ────────────────────────────────────────────────────────────────────
[ "$STORM_ATTEMPTS" -ge $((SECONDS_TO_RUN * 7 / 10)) ] \
  || fail "storm 尝试次数 $STORM_ATTEMPTS 太少（桩没跑起来？）"
# 1) 顶替必须有界：新实现里旧连接从未被新连接顶掉（关它的是心跳或它自己）。
[ "$SUPERSEDED_LOGS" -le 2 ] \
  || fail "superseded 日志 $SUPERSEDED_LOGS 条，期望 <=2（秒级顶替循环复现）"
if [ "$END_SUP" != "-1" ]; then
  [ "$END_SUP" -le 2 ] || fail "/stats superseded=${END_SUP}，期望 <=2"
fi
# 2) 风暴被抑制且有计数；抑制次数不超过尝试次数。
[ "$END_STORM" -ge 1 ] 2>/dev/null || [ "$REFUSED_LOGS" -ge 1 ] \
  || fail "reconnectStorm=$END_STORM / 拒绝日志 ${REFUSED_LOGS}：没有任何抑制记录"
if [ "$END_STORM" != "-1" ]; then
  [ "$END_STORM" -le "$STORM_ATTEMPTS" ] \
    || fail "reconnectStorm=$END_STORM 超过尝试次数 $STORM_ATTEMPTS"
fi
# 3) storm 的连接次数必须有界：旧实现每条尝试都会 connected 一次（≈30）。
[ "$STORM_CONNECTS" -le 6 ] \
  || fail "storm agent connected=$STORM_CONNECTS 次，期望 <=6（仍在每次顶替）"
# 4) 未上报版本的连接器进入服务端退避（>=helloTimeout 之后才可能出现）。
if [ "$END_UNV" != "-1" ] && [ "$SECONDS_TO_RUN" -ge 15 ]; then
  [ "$END_UNV" -ge 1 ] || fail "refusedUnverified=${END_UNV}，期望 >=1（未验证退避没生效）"
fi
# 5) healthy 不受影响：运行中在线、pong 持续、0 次关闭、relay 没记它断开。
[ "$MID_HEALTHY" = "present" ] || fail "storm 进行中 healthy agent 不在 /stats.snapshot 里"
[ "$HEALTHY_PONGS" -ge $((SECONDS_TO_RUN / 4)) ] \
  || fail "healthy pong=$HEALTHY_PONGS 太少（链路被风暴影响）"
[ "$HEALTHY_CLOSES" -eq 0 ] || fail "healthy 被关闭 $HEALTHY_CLOSES 次"
# 运行结束时桩自己会关 socket（relay 必然记一次断开），所以断开判据取运行中的采样。
[ "$MID_HEALTHY_DISCONNECTS" -eq 0 ] \
  || fail "运行中 relay 记录 healthy 断开 $MID_HEALTHY_DISCONNECTS 次"
[ "$HEALTHY_DISCONNECTS" -le 1 ] \
  || fail "relay 记录 healthy 断开 $HEALTHY_DISCONNECTS 次（运行结束时最多 1 次）"
[ "$MID_AGENTS" -ge 2 ] || fail "运行中 agents=${MID_AGENTS}，期望 >=2（storm + healthy）"

if [ "${#FAILURES[@]}" -gt 0 ]; then
  log "结论：FAIL（${#FAILURES[@]} 项）"
  for item in "${FAILURES[@]}"; do log "  - $item"; done
  log "现场：$WORK"
  exit 1
fi
log "结论：PASS（${SECONDS_TO_RUN}s：superseded=${END_SUP:-?}(log ${SUPERSEDED_LOGS}) storm 连接 ${STORM_CONNECTS} 次、"
log "        抑制 $END_STORM 次、未验证退避 $END_UNV 次；healthy pong=${HEALTHY_PONGS}、0 关闭）"
log "现场：$WORK"
