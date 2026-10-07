#!/bin/bash
# Unregisters the plugin from the web profile and (optionally) removes DSH.app.
# Usage: bash macos/uninstall.sh [--keep-app] [--purge] [--restore-permission]
set -euo pipefail

MACOS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$MACOS_DIR/.." && pwd)"
PKG_NAME="$(python3 -c "import json; print(json.load(open('$ROOT/package.json'))['name'])")"
DSH_HOME_DIR="${DSH_HOME:-$HOME/.dsh}"
PROFILE_NAME="web"
PROFILE_DIR="$DSH_HOME_DIR/profiles/$PROFILE_NAME"
SHELL_DIR="$DSH_HOME_DIR/desktop-shell"
KEEP_APP=0
PURGE=0
RESTORE_PERMISSION=0
for arg in "$@"; do
  case "$arg" in
    --keep-app) KEEP_APP=1 ;;
    --purge) PURGE=1 ;;
    --restore-permission) RESTORE_PERMISSION=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if command -v pnpm >/dev/null 2>&1; then
  echo "==> 反注册插件：dsh plugin --profile $PROFILE_NAME remove $PKG_NAME"
  ( cd "$PROFILE_DIR" && DSH_HOME="$DSH_HOME_DIR" dsh plugin --profile "$PROFILE_NAME" remove "$PKG_NAME" )
else
  echo "!! 未找到 pnpm，无法走官方反注册；请先 npm install -g pnpm 再重跑。" >&2
  exit 1
fi

if [ "$KEEP_APP" = 0 ]; then
  for target in "/Applications/DSH.app" "$HOME/Applications/DSH.app"; do
    if [ -d "$target" ]; then
      rm -rf "$target"
      echo "==> 已删除 $target"
    fi
  done
fi

if [ "$PURGE" = 1 ]; then
  rm -rf "$SHELL_DIR"
  echo "==> 已删除 ${SHELL_DIR}（配置与日志）"
else
  echo "==> 保留 ${SHELL_DIR}（配置与日志）；加 --purge 可一并删除"
fi

if [ "$RESTORE_PERMISSION" = 1 ]; then
  echo "==> 移除默认权限预设覆盖（新建会话回到 DSH 组合默认值）"
  python3 "$MACOS_DIR/set-permission-default.py" --clear
else
  echo "==> 默认权限预设未改动；如需还原：bash $MACOS_DIR/uninstall.sh --restore-permission"
fi

echo "==> 插件源码仍在 $ROOT（这个目录就是它的长期位置）；不需要时手动删掉该目录即可"
