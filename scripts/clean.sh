#!/usr/bin/env bash
# ============================================================
# 清理可以重新生成的产物 —— 不碰源码、文档与任何凭据。
#
# 仓库里最重的东西都是产物：iOS 的 .build（编译 + 归档 + OTA 暂存）、
# SwiftPM 的 .build、relay 的 .venv。它们合起来近 1 GB，而全部都能由
# 构建/安装命令重新生成，所以需要腾空间或排查"干净的构建"时跑这个。
#
# 用法:
#   ./scripts/clean.sh               # 构建产物与缓存
#   ./scripts/clean.sh --all         # 连依赖目录（relay/.venv）一起删
#   ./scripts/clean.sh --dry-run     # 只打印要删什么
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY=0
ALL=0

for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY=1 ;;
    --all) ALL=1 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'clean.sh: 未知参数 %s\n' "$arg" >&2; exit 2 ;;
  esac
done

TARGETS=(
  "$ROOT/ios/DSHMobile/.build"
  "$ROOT/ios/DSHMobile/DSHKit/.build"
  "$ROOT/.pytest_cache"
  "$ROOT/relay/.pytest_cache"
)
if [ "$ALL" -eq 1 ]; then
  TARGETS+=("$ROOT/relay/.venv")
fi

for target in "${TARGETS[@]}"; do
  # 只在仓库内部动手：万一变量被改坏，也不会删到仓库外面去。
  case "$target" in
    "$ROOT"/*) ;;
    *) printf 'clean.sh: 拒绝操作 %s（不在 %s 内）\n' "$target" "$ROOT" >&2; exit 1 ;;
  esac
  [ -e "$target" ] || continue
  if [ "$DRY" -eq 1 ]; then
    printf 'would remove  %s\n' "${target#"$ROOT"/}"
  else
    printf 'removing      %s\n' "${target#"$ROOT"/}"
    rm -rf -- "$target"
  fi
done

# 只扫仓库自己的 __pycache__：依赖目录里的那些属于 .venv / node_modules，
# 删了既没意义又让输出淹没在几千行里（--all 会整体删掉它们）。
while IFS= read -r -d '' cache; do
  if [ "$DRY" -eq 1 ]; then
    printf 'would remove  %s\n' "${cache#"$ROOT"/}"
  else
    printf 'removing      %s\n' "${cache#"$ROOT"/}"
    rm -rf -- "$cache"
  fi
done < <(find "$ROOT/relay" "$ROOT/plugins" \
           \( -name .venv -o -name node_modules \) -prune -o \
           -name __pycache__ -type d -prune -print0 2>/dev/null)

printf '\n重新生成：ios/DSHMobile/.build → 跑 scripts/release/deploy-ota.sh 或 scripts/dev/verify-simulator.sh；'
printf '\n          DSHKit 的 .build → 跑 swift test；relay/.venv → 跑 relay 的安装步骤。\n'
