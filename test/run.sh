#!/bin/bash
# ============================================================
# 测试入口。五个动作分开调，测什么、怎么判由测试者（AI）决定。
#
#   ./test/run.sh prepare                准备环境（端点、仿真器、必要时编译）
#   ./test/run.sh run [用例.md]          执行用例（不给用例则跑 01）
#   ./test/run.sh shot <名字> [--note x] 立刻截一张当前画面
#   ./test/run.sh scaffold               生成本次运行的 review.md 骨架
#   ./test/run.sh report --verdict 通过 --note "结论" --basis "依据"
#   ./test/run.sh ls                     列出运行记录
#
# 报告产物：test/runs/<运行>/report.html
# 规则见 test/RULES.md，报告契约见 test/REPORT-CONTRACT.md，
# 用例写法与目录布局见 test/README.md。
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec node "$ROOT/test/tools/dsh.mjs" "$@"
