#!/usr/bin/env bash
# 采样 Go 中转的观察指标，追加到 /var/log/dsh-relay-go-observe.jsonl。
#
# 只读：不改服务、不写数据库；每 15 分钟由 dsh-relay-go-observe.timer 触发。
# 字段见下方注释与 relay-go/README.md 的「可观测性」一节。
set -euo pipefail

OUT="${DSH_RELAY_OBSERVE_OUT:-/var/log/dsh-relay-go-observe.jsonl}"
WINDOW="${DSH_RELAY_OBSERVE_WINDOW:-15 min ago}"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

STATS="$(curl -s --max-time 3 http://127.0.0.1:8787/stats || echo '{}')"
PID="$(systemctl show -p MainPID --value dsh-relay-go 2>/dev/null || echo 0)"
RSS="0"
if [ -n "$PID" ] && [ "$PID" != "0" ] && [ -r "/proc/$PID/status" ]; then
  RSS="$(awk '/^VmRSS:/{print $2}' "/proc/$PID/status" || echo 0)"
fi

# controlDrops 是 /stats 暴露的进程级累计值（pong/ping/hostStatus/accountState
# 被丢掉的次数）。15 分钟窗口用相邻两次采样的差算；进程重启后计数器归零，差值
# 为负时按"从 0 开始"处理，不把重启误读成巨额丢弃。
CTRL_TOTAL="$(printf '%s' "$STATS" | python3 -c '
import json
import sys
try:
    print(int(json.load(sys.stdin).get("controlDrops") or 0))
except Exception:
    print(0)
' 2>/dev/null || echo 0)"
PREV_TOTAL=0
if [ -s "$OUT" ]; then
  PREV_TOTAL="$(tail -n 1 "$OUT" | python3 -c '
import json
import sys
try:
    print(int(json.load(sys.stdin).get("controlDropsTotal") or 0))
except Exception:
    print(0)
' 2>/dev/null || echo 0)"
fi
if [ "$CTRL_TOTAL" -lt "$PREV_TOTAL" ]; then
  PREV_TOTAL=0
fi
CTRL_DELTA=$((CTRL_TOTAL - PREV_TOTAL))

# 必达控制帧等满 5 秒仍进不了队列时才会出现这条日志；它与上面的"静默丢弃"是
# 两个不同的事实，分开记。
CTRL_CLOSE="$(journalctl -u dsh-relay-go --since "$WINDOW" --no-pager -o cat 2>/dev/null \
  | grep -c 'control frame could not be queued' || true)"
CONN="$(journalctl -u dsh-relay-go --since "$WINDOW" --no-pager -o cat 2>/dev/null \
  | grep -c 'agent connected' || true)"
C5="$(journalctl -u caddy --since "$WINDOW" --no-pager -o cat 2>/dev/null \
  | grep -c '"status":5' || true)"

python3 - "$NOW" "$STATS" "$RSS" "$CTRL_DELTA" "$CTRL_TOTAL" "$CTRL_CLOSE" \
  "$CONN" "$C5" <<'PY' >>"$OUT"
import json
import sys

now, stats, rss, ctrl_delta, ctrl_total, ctrl_close, conn, c5 = sys.argv[1:9]
try:
    payload = json.loads(stats)
except Exception:
    payload = {}
record = {
    "ts": now,
    "load": payload.get("load"),
    "rssKb": int(rss or 0),
    "controlDrops15m": int(ctrl_delta or 0),
    "controlDropsTotal": int(ctrl_total or 0),
    "controlCloses15m": int(ctrl_close or 0),
    "agentConnects15m": int(conn or 0),
    "caddy5xx15m": int(c5 or 0),
}
print(json.dumps(record, ensure_ascii=False, separators=(",", ":")))
PY
