#!/usr/bin/env bash
# OpenHands 本机进程模式启动器：不依赖 Docker，不调用远程运行时。
# 用法：scripts/openhands-local.sh [openhands 参数...]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SETTINGS="$ROOT/.openhands/settings.json"
if [ ! -f "$SETTINGS" ]; then
  echo "缺少 $SETTINGS" >&2
  exit 2
fi

# 显式容器配置一律拒绝：本机没有 Docker 运行时，也不允许回退。
case "${RUNTIME:-}" in
  docker|remote|e2b|modal|runloop)
    echo "已拒绝：RUNTIME=$RUNTIME，本机只允许 process 运行时。" >&2
    exit 2
    ;;
esac

export RUNTIME=process
export OPENHANDS_AGENT_MODE="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["agent_mode"])' "$SETTINGS")"
export OPENHANDS_MAX_ITERATIONS="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["max_iterations"])' "$SETTINGS")"
export OPENHANDS_CONFIG_ROOT="$ROOT"

CLI=""
for candidate in openhands openhands-cli; do
  if command -v "$candidate" >/dev/null 2>&1; then
    CLI="$(command -v "$candidate")"
    break
  fi
done

if [ -z "$CLI" ]; then
  cat >&2 <<'EOF'
未找到 openhands 可执行文件。已核实：PyPI 包 openhands-ai 1.11.0 不提供命令行入口，
自动拉起它没有意义，因此本脚本不代为下载。

本仓库的提交防线不依赖 OpenHands CLI，可直接使用：
  python3 scripts/targeted_tests.py --staged   靶向测试（≤30s）
  python3 scripts/local_ai_review.py --staged  Diff 审查（规则即时 + 模型 ≤5s）

需要完整 Agent 时，安装提供 CLI 的发行版后本脚本会自动以 RUNTIME=process 启动。
EOF
  exit 2
fi

exec "$CLI" "$@"
