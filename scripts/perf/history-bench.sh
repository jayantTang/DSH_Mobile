#!/usr/bin/env bash
# 会话历史加载：一条命令给出改前/改后的可比数字（离线、只读）。
#
#   scripts/perf/history-bench.sh [--session <substring>] [--iterations N]
#
# 两项指标：
#   1) 线上字节 —— 按连接器现在的分页规则重放真实会话，量整段字节/单页中位/压缩比
#      （`history-page-bench.mjs`）
#   2) 手机侧解码 —— 用同一页的两种形态（全字段 / 剔除 data.stream）在 DSHKit 真类型上
#      量本机耗时（`history-page-bench-swift`，release 构建）
#
# 数字随机器与负载浮动，脚本固定 iterations 并打印口径；对账用同一台机器重跑。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURES="${TMPDIR:-/tmp}/dsh-history-bench"

iterations=20
session_arg=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session) session_arg=(--session "$2"); shift 2 ;;
    --iterations) iterations="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

echo "== 线上字节（连接器分页规则，真实会话重放）=="
node "$ROOT/scripts/perf/history-page-bench.mjs" "${session_arg[@]}" --emit-fixtures "$FIXTURES"

echo
echo "== 手机侧解码（DSHKit 真类型，release，${iterations} 次平均）=="
swift build --package-path "$ROOT/scripts/perf/history-page-bench-swift" -c release >/dev/null
BIN="$ROOT/scripts/perf/history-page-bench-swift/.build/release/history-page-bench"
"$BIN" "$FIXTURES/page-full.json" "$iterations" "全字段"
"$BIN" "$FIXTURES/page-no-stream.json" "$iterations" "剔除 data.stream"

echo
echo "fixtures: $FIXTURES"
