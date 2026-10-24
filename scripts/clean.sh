#!/usr/bin/env bash
# ============================================================
# 清理可以重新生成的产物 —— 不碰源码、文档与任何凭据。
#
# 仓库里最重的都是产物。2026-10-12 清理前实测：
#   test/runs              11.4G  仿真器运行记录（RULES.md 写明「随时可用同样用例重跑」）
#   ios/DSHMobile/.build    4.1G  编译 + 归档 + OTA / TestFlight 暂存（含 .xcarchive 与 .ipa）
#   ios/DSHMobile/DSHKit/.build 1.5G  swift test 产物
#   .venv                   190M  中转/信件测试共用的 Python 依赖
# 四者合计约 17G，全部可由构建 / 安装命令重新生成。
#
# 用法:
#   ./scripts/clean.sh                 # 构建产物与缓存（默认；不碰运行证据与依赖）
#   ./scripts/clean.sh --evidence      # 连 test/runs 与 .lanes/runs 一起删（历史运行证据）
#   ./scripts/clean.sh --all           # 连依赖目录与生成文档一起删
#                                      # （.venv、test/.venv、sidecars/*/node_modules、
#                                      #   docs/arch 的生成件）
#   ./scripts/clean.sh --dry-run       # 只打印要删什么
#
# 注意：--evidence 删掉的运行记录被 maintainers/ 与 test/cases/ 里的文档按路径引用，
# 删完全仓库搜索不到那些引用目标。默认不动它。
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY=0
ALL=0
EVIDENCE=0

usage() {
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY=1 ;;
    --evidence) EVIDENCE=1 ;;
    --all) ALL=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'clean.sh: 未知参数 %s\n' "$arg" >&2; exit 2 ;;
  esac
done

TARGETS=(
  "$ROOT/ios/DSHMobile/.build"
  "$ROOT/ios/DSHMobile/DSHKit/.build"
  "$ROOT/test/.build"
  "$ROOT/.pytest_cache"
)

if [ "$EVIDENCE" -eq 1 ]; then
  # 三级验证渠道与仿真器用例台的历史运行记录。两者都是本机数据，见
  # test/RULES.md 与 scripts/verify/README.md。
  TARGETS+=("$ROOT/test/runs" "$ROOT/.lanes/runs")
fi

if [ "$ALL" -eq 1 ]; then
  # 依赖目录：删了要按各自 README 重装。生成文档：`npm run arch` 重新生成。
  TARGETS+=(
    "$ROOT/.venv"
    "$ROOT/test/.venv"
    "$ROOT/docs/arch/index.html"
    "$ROOT/docs/arch/latest.json"
    "$ROOT/docs/arch/deep.json"
  )
  while IFS= read -r -d '' dir; do
    TARGETS+=("$dir")
  done < <(find "$ROOT/sidecars" -maxdepth 3 -type d -name node_modules -print0 2>/dev/null)
  while IFS= read -r -d '' dir; do
    TARGETS+=("$dir")
  done < <(find "$ROOT/docs/arch" -maxdepth 1 -type d -name 'v[0-9]*' -print0 2>/dev/null)
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
done < <(find "$ROOT/mail" "$ROOT/relay-go" "$ROOT/plugins" "$ROOT/scripts" "$ROOT/test/tools" "$ROOT/maintainers" \
           \( -name .venv -o -name node_modules \) -prune -o \
           -name __pycache__ -type d -prune -print0 2>/dev/null)

printf '\n重新生成：ios/DSHMobile/.build → 跑 scripts/release/deploy-ota.sh 或 scripts/dev/verify-simulator.sh；'
printf '\n          DSHKit 的 .build → 跑 swift test；.venv → python3 -m venv .venv && .venv/bin/pip install -r mail/requirements-dev.txt -r relay-go/requirements-dev.txt；'
printf '\n          test/.venv → python3 -m venv test/.venv && test/.venv/bin/pip install pillow；'
printf '\n          .lanes/runs → 跑 npm run lane:l1；test/runs → 跑 test/run.sh；docs/arch → npm run arch。\n'
