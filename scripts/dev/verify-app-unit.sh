#!/bin/bash
# ============================================================
# 不含 UI 的 iOS 单元测试（spec 023 的 T008 / 车道对象 `ios-unit`）
#
# 与 `verify-simulator.sh` 的分工：
#   verify-simulator.sh  —— 起 App、连本机 DSH、截图，判定靠人看图（慢闸）
#   本脚本               —— 只跑 `DSHMobileTests`：不启动主界面、不截图、不做手势（快闸）
#
# 注意口径：这不等于"不碰模拟器"。`xcodebuild test` 仍会拉起一个模拟器进程并把测试包注入
# App 宿主，只是不建主界面（App 侧读到 XCTestConfigurationFilePath 就跳过 RootView）。
# 界面回归仍必须走 verify-simulator.sh 与 test/run.sh 的逐屏核对。
#
# 用法: ./scripts/dev/verify-app-unit.sh [额外 xcodebuild 参数…]
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT_DIR="$ROOT/ios/DSHMobile"
DERIVED="$PROJECT_DIR/.build/app-unit"

# 仿真器：默认挑一台可用的（优先叫 DSH-Test 的），不把某一台机器的 UDID 写进仓库。
SIM_ID="${SIM_ID:-$(xcrun simctl list devices available --json | python3 -c "
import json,sys
devices=[d for group in json.load(sys.stdin)['devices'].values() for d in group if d.get('isAvailable') and ('iPhone' in d['name'] or 'iPad' in d['name'])]
picked=next((d for d in devices if 'DSH-Test' in d['name']), None) or next((d for d in devices if d['state']=='Booted'), None) or (devices[0] if devices else None)
print(picked['udid'] if picked else '')
")}"
[ -n "$SIM_ID" ] || { echo "找不到可用的 iOS 仿真器；请用 SIM_ID=<udid> 指定"; exit 1; }

if ! grep -q 'DSHMobileTests' "$PROJECT_DIR/DSHMobile.xcodeproj/project.pbxproj"; then
  echo "工程里还没有 DSHMobileTests target —— 先按 specs/023-app-dshkit-boundary/tasks.md 的 T007 建它"
  exit 2
fi

printf '\n\033[1;36m>>>\033[0m 跑 DSHMobileTests（不含 UI，不截图）\n'
cd "$PROJECT_DIR"
# 用单测专用 scheme：它只构建 App + DSHMobileTests，不带 UI 测试包（省掉整包构建时间）。
xcodebuild test \
  -project DSHMobile.xcodeproj \
  -scheme DSHMobileUnitTests \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIM_ID" \
  -derivedDataPath "$DERIVED" \
  -only-testing:DSHMobileTests \
  "$@"
