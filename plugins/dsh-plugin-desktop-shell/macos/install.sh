#!/bin/bash
# Installs both halves of the DSH macOS shell, the official way:
#   1. plugin  — register this package inside the web profile with
#      `dsh plugin --profile web add` (a profile is DSH's home for out-of-tree
#      plugins; this directory is the plugin's permanent source of truth)
#   2. DSH.app — build from macos/ and copy to /Applications (or ~/Applications)
#   3. default permission preset — ~/.dsh/settings.yaml
#
# Usage: bash macos/install.sh [--no-verify] [--no-app] [--no-plugin]
#                              [--no-permission] [--permission <preset>]
set -euo pipefail

MACOS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$MACOS_DIR/.." && pwd)"
PKG_NAME="$(python3 -c "import json; print(json.load(open('$ROOT/package.json'))['name'])")"
PKG_DIR_NAME="$(basename "$ROOT")"
DSH_HOME_DIR="${DSH_HOME:-$HOME/.dsh}"
PROFILE_NAME="web"
PROFILE_DIR="$DSH_HOME_DIR/profiles/$PROFILE_NAME"
PATCH="$PROFILE_DIR/cordis.patch.yml"
PLUGIN_SPEC="link:plugins/$PKG_DIR_NAME"
SHELL_DIR="$DSH_HOME_DIR/desktop-shell"

VERIFY=1
DO_APP=1
DO_PLUGIN=1
DO_PERMISSION=1
PERMISSION_PRESET="danger-full-access"
while [ $# -gt 0 ]; do
  case "$1" in
    --no-verify) VERIFY=0 ;;
    --no-app) DO_APP=0 ;;
    --no-plugin) DO_PLUGIN=0 ;;
    --no-permission) DO_PERMISSION=0 ;;
    --permission)
      shift
      if [ $# -eq 0 ]; then echo "--permission needs a preset" >&2; exit 2; fi
      PERMISSION_PRESET="$1"
      ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

case "$PERMISSION_PRESET" in
  read-only|workspace-write|danger-full-access) ;;
  *) echo "--permission must be one of: read-only, workspace-write, danger-full-access" >&2; exit 2 ;;
esac

mkdir -p "$SHELL_DIR"

# ── npm registry (follow the machine's npm config, fall back to npmjs) ───────
NPM_REGISTRY="$(npm config get registry 2>/dev/null | tail -1 || true)"
case "$NPM_REGISTRY" in
  http*) NPM_REGISTRY="${NPM_REGISTRY%/}/@deepseek-ai/dsh" ;;
  *) NPM_REGISTRY="https://registry.npmjs.org/@deepseek-ai/dsh" ;;
esac

# ── 1. app ───────────────────────────────────────────────────────────────────
if [ "$DO_APP" = 1 ]; then
  echo "==> 构建 DSH.app"
  bash "$MACOS_DIR/build-app.sh"

  if [ -w /Applications ]; then DEST="/Applications"; else DEST="$HOME/Applications"; fi
  mkdir -p "$DEST"
  rm -rf "$DEST/DSH.app"
  cp -R "$MACOS_DIR/build/DSH.app" "$DEST/DSH.app"
  xattr -dr com.apple.quarantine "$DEST/DSH.app" 2>/dev/null || true
  echo "==> 已安装 $DEST/DSH.app"

  if [ ! -f "$SHELL_DIR/app.json" ]; then
    cat > "$SHELL_DIR/app.json" <<JSON
{
  "appTitle": "DSH",
  "dshBin": "dsh",
  "extraArgs": ["--port", "0"],
  "attachToRunning": true,
  "checkUpdates": true,
  "tag": "latest",
  "showPrereleases": false,
  "permissionMode": "${PERMISSION_PRESET}",
  "lingerMinutes": 30,
  "npmBin": "npm",
  "registry": "$NPM_REGISTRY",
  "startupTimeoutSeconds": 60
}
JSON
    echo "==> 写入默认配置 $SHELL_DIR/app.json"
  else
    echo "==> 保留已有配置 $SHELL_DIR/app.json"
    # Migrate older configs to the latest-only reminder policy + permission keys.
    python3 - "$SHELL_DIR/app.json" "$DO_PERMISSION" "$PERMISSION_PRESET" <<'PY'
import json
import sys

path, set_permission, preset = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as handle:
    cfg = json.load(handle)
changed = False
if "tag" not in cfg:
    cfg["tag"] = cfg.get("channel", "latest")
    changed = True
if "showPrereleases" not in cfg:
    cfg["showPrereleases"] = False
    changed = True
if set_permission == "1":
    # Keep the app's deployment override in step with the settings default.
    if cfg.get("permissionMode") != preset:
        cfg["permissionMode"] = preset
        changed = True
elif "permissionMode" not in cfg:
    cfg["permissionMode"] = preset
    changed = True
if "lingerMinutes" not in cfg:
    cfg["lingerMinutes"] = 30
    changed = True
if changed:
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(cfg, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    print("    migrated: tag / showPrereleases / permissionMode / lingerMinutes")
PY
  fi
fi

# ── 2. plugin: official profile install (pnpm under `dsh plugin`) ────────────
if [ "$DO_PLUGIN" = 1 ]; then
  if [ ! -d "$PROFILE_DIR" ]; then
    echo "!! 找不到 web profile 目录：$PROFILE_DIR" >&2
    echo "   先运行一次 'dsh web'（或 'dsh --profile web'）让它初始化，然后重跑本脚本。" >&2
    exit 1
  fi
  if ! command -v pnpm >/dev/null 2>&1; then
    echo "!! 未找到 pnpm —— DSH 的插件管理就是转发给 pnpm 的。" >&2
    echo "   先执行：npm install -g pnpm" >&2
    exit 1
  fi

  echo "==> 注册插件：dsh plugin --profile $PROFILE_NAME add $PLUGIN_SPEC"
  ( cd "$PROFILE_DIR" && DSH_HOME="$DSH_HOME_DIR" dsh plugin --profile "$PROFILE_NAME" add "$PLUGIN_SPEC" )

  python3 - "$PROFILE_DIR/package.json" "$PROFILE_DIR/node_modules/$PKG_NAME" "$PKG_NAME" <<'PY'
import json
import os
import sys

manifest, installed, name = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(manifest, encoding="utf-8"))
bundles = data.get("dsh", {}).get("profile", {}).get("bundles", [])
if name not in bundles:
    raise SystemExit(f"!! {name} 没有进入 dsh.profile.bundles（{manifest}）")
if not os.path.exists(installed):
    raise SystemExit(f"!! {name} 没有被 pnpm 装进 {installed}")
print(f"    ✓ {name} 已是 profile bundle，源码留在 {os.path.realpath(installed)}")
PY

  # Migration: drop the legacy hand-managed block from the profile patch; the
  # bundle layer above replaces it and must not load the plugin twice.
  if [ -f "$PATCH" ]; then
    python3 - "$PATCH" <<'PY'
import re
import sys

path = sys.argv[1]
BEGIN = "# >>> dsh-macos-shell (managed block — edit outside this fence)"
END = "# <<< dsh-macos-shell (managed block)"
with open(path, "r", encoding="utf-8") as handle:
    text = handle.read()
cleaned = re.sub(re.escape(BEGIN) + r".*?" + re.escape(END) + r"\n?", "", text, flags=re.S).rstrip("\n")
if cleaned == text.rstrip("\n"):
    print("    （profile patch 里没有旧 managed block，跳过）")
else:
    # Comments alone are not a YAML array; keep them and leave an empty list
    # behind so the profile patch still parses as a top-level array.
    effective = [line for line in cleaned.splitlines()
                 if line.strip() and not line.lstrip().startswith("#")]
    if cleaned and effective:
        body = cleaned + "\n"
    elif cleaned:
        body = cleaned + "\n\n[]\n"
    else:
        body = "[]\n"
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(body)
    print(f"    ✓ 已移除旧 managed block（{path}）")
PY
  fi
fi

# ── 3. default permission preset (~/.dsh/settings.yaml) ─────────────────────
if [ "$DO_PERMISSION" = 1 ]; then
  echo "==> 设置默认权限预设 ${PERMISSION_PRESET}（sessions created later）"
  python3 "$MACOS_DIR/set-permission-default.py" --preset "$PERMISSION_PRESET"
fi

# ── 4. verify: boot a throwaway instance and probe the plugin route ──────────
if [ "$VERIFY" = 1 ] && [ "$DO_PLUGIN" = 1 ]; then
  echo "==> 验证插件（临时实例，端口 0）"
  LOG="$(mktemp -t dsh-shell-verify)"
  DSH_NO_DESKTOP_ENDPOINT=1 dsh web --no-open --port 0 >"$LOG" 2>&1 &
  PID=$!
  PORT=""
  for _ in $(seq 1 60); do
    PORT="$(sed -n 's/.*dsh web: http:\/\/127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$LOG" | head -1)"
    [ -n "$PORT" ] && break
    kill -0 "$PID" 2>/dev/null || break
    sleep 1
  done
  if [ -z "$PORT" ]; then
    echo "!! 验证失败：临时实例没有打印 dsh web URL" >&2
    tail -25 "$LOG" >&2 || true
    kill "$PID" 2>/dev/null || true
    exit 1
  fi
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$PORT/desktop-shell/status" || true)"
  kill "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
  rm -f "$LOG"
  if [ "$CODE" = "401" ]; then
    echo "    ✓ 插件已加载（/desktop-shell/status → 401，符合“未认证即拒绝”的预期）"
  else
    echo "!! 插件路由返回 ${CODE}（预期 401，404 表示插件未加载）" >&2
    exit 1
  fi
fi

cat <<EOF

完成。

使用方式
  • 打开方式：在“启动台 / 聚焦搜索 / 应用程序”里打开 DSH（或把它拖到程序坞），双击即可，
    不需要在终端里敲任何命令。DSH.app 会自己拉起 dsh web，并解析它打印的带 token 的地址。
  • 网页里版本号显示在侧边栏「设置」按钮上、“设置”两个字旁边，点它可以看版本 / 检查更新。
  • 升级：应用菜单“DSH → 检查更新…”（原生弹窗），或网页里版本号面板上的“立即升级”按钮。

默认权限
  • 新建会话的默认权限预设已设为 ${PERMISSION_PRESET}（写在 $DSH_HOME_DIR/settings.yaml 的
    permission.defaultPreset，等同于 GUI「设置 → 通用 → 权限」那一行）。
  • DSH.app 启动子进程时还会带 DSH_PERMISSION_MODE=${PERMISSION_PRESET}（见 app.json 的 permissionMode），
    这是 DSH 官方的部署级覆盖，同时决定 sandbox 与 approval；把 permissionMode 设为 "" 即可关掉，
    只保留 settings.yaml 里的默认。
  • 改回来：bash "$MACOS_DIR/install.sh" --permission workspace-write
            或 python3 "$MACOS_DIR/set-permission-default.py" --clear

长期位置（以后直接改这里）
  • 插件包根目录：$ROOT
  • 主机插件：    $ROOT/lib/index.js
  • macOS App：   $ROOT/macos/main.swift
  • 应用配置：    $SHELL_DIR/app.json
  • 日志：        $SHELL_DIR/dsh-shell.log
  • 注册方式：    profile bundle（$PROFILE_DIR/package.json 的 dsh.profile.bundles），
                  由 'dsh plugin --profile $PROFILE_NAME add $PLUGIN_SPEC' 维护，改动 patchReload: live 热加载
EOF
