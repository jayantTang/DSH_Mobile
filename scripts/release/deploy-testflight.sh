#!/usr/bin/env bash
#
# 归档 → 导出 App Store 包 → 上传 App Store Connect（TestFlight）。
#
#   scripts/release/deploy-testflight.sh                    # 三步全跑
#   scripts/release/deploy-testflight.sh --archive-only     # 只编译归档
#   scripts/release/deploy-testflight.sh --export-only      # 复用上次归档，只导出
#   scripts/release/deploy-testflight.sh --upload-only      # 复用导出的包，只上传
#
# 与 deploy-ota.sh 的区别就在「导出那一档」：OTA 用 method=debugging（Apple
# Development 证书 + 团队描述文件，只覆盖已登记 UDID 的设备），TestFlight 用
# method=app-store-connect（Apple Distribution 证书 + App Store 描述文件）。
# 所以别人能装的是这一条，而不是 OTA 那条。
#
# 前置（缺一样都会失败，报错都写在下面对应位置）：
#   1. Xcode 里登录过 Apple ID：Xcode → Settings → Accounts。没登录时
#      exportArchive 报 `No Accounts`，随后报 `No profiles for '<bundle id>' were found`
#      —— 分发证书是**联网生成**的，本地 keychain 里没有就是没有。
#   2. App Store Connect 里已建同名 App 记录（套装 ID 必须与 BUNDLE_ID 一致）。
#   3. 上传凭据：ASC API Key（ASC_KEY_ID / ASC_ISSUER_ID）或 Apple ID + App 专用密码。
#      **Xcode 的会话不够**——exportArchive 能用它，命令行 altool 不能；另外
#      exportArchive 的 destination=upload 只找得到已存在的 App 记录，所以第一次上传
#      必须先把 App Store Connect 里的 App 建好。
#      （~/.appstoreconnect/private_keys/AuthKey_*.p8 + ASC_KEY_ID/ASC_ISSUER_ID）。
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_DIR="$ROOT/ios/DSHMobile"
BUILD_DIR="$PROJECT_DIR/.build/testflight"
LOCAL_SIGNING="$PROJECT_DIR/Signing.local.plist"
# 本机配置：仓库里只有占位符与 <IssuerID>，真值放 .env.local（不入库）。
[ -f "$ROOT/.env.local" ] && . "$ROOT/.env.local"
BUNDLE_ID="com.jayanttang.dsh"

# 给 xcodebuild 一把 App Store Connect API Key：带 -allowProvisioningUpdates 时它会用这把
# 钥匙去**联网签发** Apple Distribution 证书，于是导出 App Store 包不再需要有人在 Xcode 里
# 登录 Apple ID（那一步是纯手工的，会卡住整条流水线）。钥匙读 .env.local 里的
# ASC_KEY_ID / ASC_ISSUER_ID 与 ~/.appstoreconnect/private_keys/AuthKey_<KeyID>.p8。
AUTH_ARGS=()
ASC_KEY_FILE="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID:-}.p8}"
if [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] && [ -f "$ASC_KEY_FILE" ]; then
  AUTH_ARGS=(-authenticationKeyPath "$ASC_KEY_FILE"
             -authenticationKeyID "$ASC_KEY_ID"
             -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

say() { printf '\n\033[1;36m>>>\033[0m %s\n' "$*"; }
die() { printf 'deploy-testflight: %s\n' "$*" >&2; exit 1; }

ARCHIVE_ONLY=0; EXPORT_ONLY=0; UPLOAD_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --archive-only) ARCHIVE_ONLY=1 ;;
    --export-only) EXPORT_ONLY=1 ;;
    --upload-only) UPLOAD_ONLY=1 ;;
    -h|--help) sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "不认识的参数 $arg" ;;
  esac
done

TEAM_ID="${DSH_TEAM_ID:-$(plutil -extract teamID raw -o - "$LOCAL_SIGNING" 2>/dev/null || true)}"
[ -n "$TEAM_ID" ] || die "没有开发者团队 ID：设 DSH_TEAM_ID=<TeamID>，或写 ${LOCAL_SIGNING}（形如 {teamID = XXXXXXXXXX;}，不入库）"

# TestFlight 拒绝重复的构建号，而本地 MARKETING/CURRENT_PROJECT_VERSION 是 1.0/1。
# 每次上传前把构建号改成日期时间，省掉「这个 build 已经存在」的往返。
BUILD_NUMBER="${DSH_BUILD_NUMBER:-$(date +%Y%m%d.%H%M)}"

# ── 1. 归档 ─────────────────────────────────────────────────────────────────

if [ "$EXPORT_ONLY" = 0 ] && [ "$UPLOAD_ONLY" = 0 ]; then
  say "归档（Release，构建号 ${BUILD_NUMBER}）"
  mkdir -p "$BUILD_DIR"
  xcodebuild -project "$PROJECT_DIR/DSHMobile.xcodeproj" -scheme DSHMobile \
    -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$BUILD_DIR/DSHMobile.xcarchive" \
    -allowProvisioningUpdates \
    ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    archive | tail -3
fi
[ "$ARCHIVE_ONLY" = 1 ] && { say "只归档，结束"; exit 0; }

# ── 2. 导出 ─────────────────────────────────────────────────────────────────

if [ "$UPLOAD_ONLY" = 0 ]; then
  say "导出 App Store 包（method=app-store-connect）"
  [ -d "$BUILD_DIR/DSHMobile.xcarchive" ] || die "没有归档：先跑 scripts/release/deploy-testflight.sh"
  # teamID 属于人、不属于仓库：占位符在导出前替换到 .build/ 里的一份副本。
  sed "s/<TEAM_ID>/${TEAM_ID}/" "$PROJECT_DIR/ExportOptions-appstore.plist" \
    > "$BUILD_DIR/ExportOptions-appstore.plist"
  rm -rf "$BUILD_DIR/export"
  if ! xcodebuild -exportArchive \
      -archivePath "$BUILD_DIR/DSHMobile.xcarchive" \
      -exportOptionsPlist "$BUILD_DIR/ExportOptions-appstore.plist" \
      -exportPath "$BUILD_DIR/export" \
      -allowProvisioningUpdates \
      ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} 2>&1 | tee "$BUILD_DIR/export.log" | tail -5
  then
    if grep -q "No Accounts" "$BUILD_DIR/export.log"; then
      die "Xcode 里没有登录 Apple ID —— 导出这一步需要联网生成 Apple Distribution 证书。
     打开 Xcode → Settings → Accounts → + → Apple ID，登录后重跑：
       scripts/release/deploy-testflight.sh --export-only"
    fi
    die "导出失败，完整日志：$BUILD_DIR/export.log"
  fi
fi

IPA="$BUILD_DIR/export/DSHMobile.ipa"
[ -f "$IPA" ] || die "导出目录里没有 .ipa：$BUILD_DIR/export"
say "导出完成：${IPA}（$(du -h "$IPA" | cut -f1)）"

# ── 3. 上传 ─────────────────────────────────────────────────────────────────

say "上传到 App Store Connect"
if [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ]; then
  # API Key 路径（推荐）：Key ID 就是 .p8 文件名里的那串，Issuer ID 在
  # App Store Connect → 用户和访问 → 集成 → App Store Connect API 页面顶部。
  # 两个都给了就显式传；只给 Key ID 时，altool 会自己去
  # ~/.appstoreconnect/private_keys/ 找 AuthKey_<KEY_ID>.p8（缺 Issuer 会报
  # "Either JWT (--api-issuer and --api-key) ... is required"）。
  if [ -n "${ASC_ISSUER_ID:-}" ]; then
    xcrun altool --upload-app -f "$IPA" -t ios \
      --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
  else
    xcrun altool --upload-app -f "$IPA" -t ios --apiKey "$ASC_KEY_ID"
  fi
else
  # 本机路径：用 Xcode 已有的会话（就是上面登录的那个账号）。
  if ! xcrun altool --upload-app -f "$IPA" -t ios 2>&1 | tee "$BUILD_DIR/upload.log" | tail -8; then
    die "上传失败。若提示没有凭据，二选一：
     * 在 Xcode → Settings → Accounts 里保持登录，然后重跑 --upload-only；
     * 或者建一个 App Store Connect API Key（App Store Connect → 用户和访问 → 集成），
       下载 AuthKey_*.p8 放到 ~/.appstoreconnect/private_keys/，再设 ASC_KEY_ID / ASC_ISSUER_ID。"
  fi
fi

cat <<NOTE

上传成功。接下来在 App Store Connect 里：
  1. 我的 App → 选中 $BUNDLE_ID → TestFlight → 等构建处理完（几分钟，会收到邮件）
  2. 构建 → 「管理」→ 测试信息（Beta App Description + 反馈邮箱）→ 提交审核
     （外部测试的第一个构建要过一遍审核，通常 1–2 天；内部测试不用）
  3. 审核通过后「外部测试」里会出现公开链接，那个链接才是可以贴到 README / issue 的
     下载入口——任何人不登记 UDID 也能装，有效期 90 天。
NOTE
