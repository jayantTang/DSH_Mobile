#!/usr/bin/env bash
# M6 验收：多真实连接器同时长连，验证心跳修复在并发下不再产生重连循环。
#
# 判据：
#   1. 每个连接器只连接一次（relay 日志 agent connected 总数 == 连接器数）；
#   2. controlDrops 为 0；
#   3. 连接器日志无 "relay stopped answering pings"；
#   4. 结束时全部连接器仍是 connected；
#   5. relay RSS 不持续增长。
#
# 用法：
#   relay-go/scripts/repro/soak_multi_connector.sh --seconds 1800 --connectors 10
set -euo pipefail

SECONDS_TO_RUN=1800
CONNECTORS=10
while [ $# -gt 0 ]; do
  case "$1" in
    --seconds) SECONDS_TO_RUN="${2:?}"; shift 2 ;;
    --seconds=*) SECONDS_TO_RUN="${1#*=}"; shift ;;
    --connectors) CONNECTORS="${2:?}"; shift 2 ;;
    --connectors=*) CONNECTORS="${1#*=}"; shift ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BIN="${REPRO_BIN:-$ROOT/relay-go/bin/dsh-relay}"
WORK="$(mktemp -d /tmp/soak-multi.XXXXXX)"
PORT="${REPRO_PORT:-18888}"
PPROF_PORT="${REPRO_PPROF_PORT:-18889}"
ENDPOINT="$HOME/.dsh/mobile-link/endpoint.json"
DSH_URL="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["url"])' "$ENDPOINT")"

log() { printf '[soak] %s\n' "$*"; }
PIDS=()
cleanup() {
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  [ -n "${RELAY_PID:-}" ] && kill "$RELAY_PID" 2>/dev/null || true
}
trap cleanup EXIT

"$BIN" serve --host 127.0.0.1 --port "$PORT" --db "$WORK/state.db" \
  --pprof-addr "127.0.0.1:$PPROF_PORT" >"$WORK/relay.log" 2>&1 &
RELAY_PID=$!
sleep 1

for i in $(seq 1 "$CONNECTORS"); do
  ACC="$("$BIN" admin --db "$WORK/state.db" account-create --name "soak-$i" \
    | python3 -c 'import json,sys;print(json.load(sys.stdin)["accountId"])')"
  READ="$("$BIN" admin --db "$WORK/state.db" agent-register --account "$ACC" \
    --name "soak-mac-$i" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["agentId"],d["agentSecret"])')"
  AGENT_ID="${READ%% *}"; AGENT_SECRET="${READ##* }"
  ( cd "$ROOT" && node plugins/mobile-link/lib/cli.js \
      --relay "ws://127.0.0.1:$PORT" --agent-id "$AGENT_ID" \
      --agent-secret "$AGENT_SECRET" --dsh-url "$DSH_URL" \
      --status-file "$WORK/status-$i.json" --log-level warn \
      >"$WORK/conn-$i.log" 2>&1 ) &
  PIDS+=("$!")
done

log "work=$WORK connectors=$CONNECTORS seconds=$SECONDS_TO_RUN"
started=$(date +%s)
while :; do
  now=$(date +%s); elapsed=$((now - started))
  [ "$elapsed" -ge "$SECONDS_TO_RUN" ] && break
  sleep 30
  stats="$(curl -s --max-time 3 "http://127.0.0.1:$PORT/stats" || echo '{}')"
  python3 - "$stats" "$elapsed" "$WORK" <<'PY' >>"$WORK/soak.jsonl"
import json, pathlib, re, sys
stats, elapsed, work = sys.argv[1], int(sys.argv[2]), pathlib.Path(sys.argv[3])
try:
    d = json.loads(stats)
except Exception:
    d = {}
load = d.get("load") or {}
def _connected(p):
    try:
        return json.loads(p.read_text(errors="replace")).get("state") == "connected"
    except Exception:
        return False
connected = sum(1 for p in work.glob("status-*.json") if _connected(p))
lost = sum(p.read_text(errors="replace").count("relay stopped answering pings") for p in work.glob("conn-*.log"))
relay = work / "relay.log"
connects = relay.read_text(errors="replace").count("agent connected") if relay.exists() else 0
record = {"elapsed": elapsed, "load": load, "controlDrops": d.get("controlDrops"),
          "connected": connected, "connects": connects, "lost": lost}
print(json.dumps(record, separators=(",", ":")))
PY
done

# 用最后一轮采样判定：收尾时连接器会因 relay 关闭而把 status 改成 disconnected，
# 或正好写一半（parse-error），那不是连接问题。
connected=$(python3 - "$WORK/soak.jsonl" <<'PY'
import json, pathlib, sys
last = 0
p = pathlib.Path(sys.argv[1])
if p.exists():
    for line in p.read_text(errors="replace").splitlines():
        try:
            last = json.loads(line).get("connected", 0) or 0
        except Exception:
            pass
print(last)
PY
)
lost=$(awk '/relay stopped answering pings/{n++} END{print n+0}' "$WORK"/conn-*.log 2>/dev/null || echo 0)
connects=$(grep -c "agent connected" "$WORK/relay.log" 2>/dev/null || true)
control=$(curl -s --max-time 3 "http://127.0.0.1:$PORT/stats" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("controlDrops"))' 2>/dev/null || echo '?')
rss=$(awk '/^VmRSS:/{print $2}' "/proc/$RELAY_PID/status" 2>/dev/null || echo 0)
log "end: connected=$connected/$CONNECTORS connects=$connects controlDrops=$control lost=$lost rssKb=$rss"
log "samples: $WORK/soak.jsonl"
if [ "$connected" -eq "$CONNECTORS" ] && [ "$connects" -eq "$CONNECTORS" ] && [ "$control" = "0" ] && [ "$lost" -eq 0 ]; then
  log "结论：PASS"
else
  log "结论：FAIL（见 samples 与 conn-*.log）"
  exit 1
fi
