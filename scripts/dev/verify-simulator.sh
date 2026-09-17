#!/bin/bash
# ============================================================
# DSH Mobile 端到端验证
#
# 编译 → 安装 → 连接本机正在运行的 DSH → 截图会话列表与聊天页。
#
# 为什么用启动参数而不是深链：iOS 对 `simctl openurl` 打开自定义 scheme
# 会弹出确认框，而该弹框无法从命令行关闭。`-DSHConnectURL` /
# `-DSHOpenSession` 是 App 内 DEBUG-only 的自动化钩子（见 RootView），
# Release 构建不包含该代码路径。
#
# 全部钩子（都可叠加，用来逐屏截图）：
#   -DSHConnectURL <dsh://…>   指定连接目标，不走记忆里的 profile
#   -DSHOpenSession <id>       直接打开某个会话
#   -DSHOpenScreen <name>      打开某个界面：settings / connections / web /
#                              diagnostics / files
#   -DSHFilesDir <相对目录>     文件浏览器的起始目录（配合 files 用）
#   -DSHOpenFile <路径>         直接打开一个文件（HTML 走渲染查看）
#   -DSHOnboarding             停在配对页，不自动重连
#   -DSHForgetDirect           先删掉遗留的直连 profile，只留中转
#   -DSHUploadFile <路径>       走一次文件上传
#   -DSHDraftImage <路径>       往输入框塞一张待发图片
#
# 用法: ./scripts/dev/verify-simulator.sh [截图输出目录]
# ============================================================
set -euo pipefail

# 仿真器：默认挑一台可用的（优先叫 DSH-Test 的），不把某一台机器的 UDID 写进仓库。
SIM_ID="${SIM_ID:-$(xcrun simctl list devices available --json | python3 -c "
import json,sys
devices=[d for group in json.load(sys.stdin)['devices'].values() for d in group if d.get('isAvailable') and ('iPhone' in d['name'] or 'iPad' in d['name'])]
picked=next((d for d in devices if 'DSH-Test' in d['name']), None) or next((d for d in devices if d['state']=='Booted'), None) or (devices[0] if devices else None)
print(picked['udid'] if picked else '')
")}"
[ -n "$SIM_ID" ] || { echo "找不到可用的 iOS 仿真器；请用 SIM_ID=<udid> 指定"; exit 1; }
BUNDLE_ID="com.jayanttang.dsh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT_DIR="$ROOT/ios/DSHMobile"
OUT_DIR="${1:-/tmp/dsh-mobile-verify}"
DERIVED="$PROJECT_DIR/.build/sim"

mkdir -p "$OUT_DIR"
step() { printf '\n\033[1;36m>>>\033[0m %s\n' "$*"; }

step "读取本机 DSH 端点"
ENDPOINT="$HOME/.dsh/desktop-shell/endpoint.json"
[ -f "$ENDPOINT" ] || { echo "找不到 $ENDPOINT —— 本机没有运行中的 DSH"; exit 1; }
PORT=$(python3 -c "import json;print(json.load(open('$ENDPOINT')).get('port') or 54499)")
TOKEN=$(python3 -c "
import json,re
url=json.load(open('$ENDPOINT'))['url']
m=re.search(r'token=([^&]+)', url); print(m.group(1) if m else '')
")
[ -n "$TOKEN" ] || { echo "端点文件里没有 token"; exit 1; }
echo "port=$PORT token=${TOKEN:0:12}…"

# 选一个内容最丰富的会话来验证聊天渲染。
step "挑选一个真实会话"
SESSION=$(curl -s -m 20 -c /tmp/dsh-verify-cookies.txt -o /dev/null \
    "http://127.0.0.1:$PORT/?token=$TOKEN" -D - \
  | awk -F': ' 'tolower($1)=="set-cookie"{print $2}' | head -1 | cut -d';' -f1 | \
  { read -r COOKIE; curl -s -m 20 -b "$COOKIE" -X POST "http://127.0.0.1:$PORT/api/session/list" \
      -H 'content-type: application/json' \
      -d '{"type":"client-request","rpcId":"v","method":"session/list","payload":{"args":{"_request":{}}}}' \
    | python3 -c "
import json,sys
items=json.load(sys.stdin)['result']['value']['items']
top=[i for i in items if i.get('origin')!='subagent' and not i.get('blank')]
top.sort(key=lambda i: (i.get('projections') or {}).get('asOfSeq',0), reverse=True)
print(top[0]['sessionId'] if top else '')
"; })
echo "session=${SESSION:-（无，跳过聊天页验证）}"

step "编译"
cd "$PROJECT_DIR"
xcodebuild -project DSHMobile.xcodeproj -scheme DSHMobile -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIM_ID" -derivedDataPath "$DERIVED" build \
  | tail -2

APP="$DERIVED/Build/Products/Debug-iphonesimulator/DSHMobile.app"
[ -d "$APP" ] || { echo "找不到构建产物 $APP"; exit 1; }

step "启动模拟器"
xcrun simctl bootstatus "$SIM_ID" -b >/dev/null 2>&1 || xcrun simctl boot "$SIM_ID" >/dev/null 2>&1 || true

step "安装并运行"
xcrun simctl install "$SIM_ID" "$APP"
xcrun simctl terminate "$SIM_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl launch "$SIM_ID" "$BUNDLE_ID" \
  -DSHConnectURL "dsh://direct?host=127.0.0.1&port=$PORT&token=$TOKEN" \
  ${SESSION:+-DSHOpenSession "$SESSION"} >/dev/null
sleep 14
xcrun simctl io "$SIM_ID" screenshot "$OUT_DIR/01-transcript-or-list.png" >/dev/null 2>&1
echo "已截图: $OUT_DIR/01-transcript-or-list.png"

step "回到会话列表"
xcrun simctl terminate "$SIM_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl launch "$SIM_ID" "$BUNDLE_ID" \
  -DSHConnectURL "dsh://direct?host=127.0.0.1&port=$PORT&token=$TOKEN" >/dev/null
sleep 12
xcrun simctl io "$SIM_ID" screenshot "$OUT_DIR/02-session-list.png" >/dev/null 2>&1
echo "已截图: $OUT_DIR/02-session-list.png"

rm -f /tmp/dsh-verify-cookies.txt
echo
echo "完成。截图目录: $OUT_DIR"
ls -la "$OUT_DIR"
