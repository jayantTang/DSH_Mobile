#!/usr/bin/env bash
#
# 归档 → 导出 App Store 包 → 上传 App Store Connect（TestFlight）。
#
#   scripts/release/deploy-testflight.sh                    # 三步全跑
#   scripts/release/deploy-testflight.sh --archive-only     # 只编译归档
#   scripts/release/deploy-testflight.sh --export-only      # 复用上次归档，只导出
#   scripts/release/deploy-testflight.sh --upload-only      # 复用导出的包，只上传
#   scripts/release/deploy-testflight.sh --beta-only        # 只做"挂组 + 提交外部测试审核"
#   scripts/release/deploy-testflight.sh --no-submit        # 传上去但不提交审核（例外情况才用）
#   scripts/release/deploy-testflight.sh --beta-only --build <版本>   # 指定某一版挂组+提审核
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
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
die() { printf 'deploy-testflight: %s\n' "$*" >&2; exit 1; }

ARCHIVE_ONLY=0; EXPORT_ONLY=0; UPLOAD_ONLY=0; BETA_ONLY=0; SUBMIT=1
# `while` 而不是 `for`：`--build <version>` 要吃掉下一个参数，
# `for arg in "$@"` 里的 shift 不会影响循环本身，版本号会被当成未知参数。
while [ $# -gt 0 ]; do
  case "$1" in
    --archive-only) ARCHIVE_ONLY=1 ;;
    --export-only) EXPORT_ONLY=1 ;;
    --upload-only) UPLOAD_ONLY=1 ;;
    --beta-only) BETA_ONLY=1 ;;
    --build) DSH_BETA_BUILD="${2:-}"; export DSH_BETA_BUILD; shift ;;
    --no-submit) SUBMIT=0 ;;
    -h|--help) sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "不认识的参数 $1" ;;
  esac
  shift
done

[ "$BETA_ONLY" = 1 ] && { EXPORT_ONLY=1; UPLOAD_ONLY=1; }

TEAM_ID="${DSH_TEAM_ID:-$(plutil -extract teamID raw -o - "$LOCAL_SIGNING" 2>/dev/null || true)}"
[ -n "$TEAM_ID" ] || die "没有开发者团队 ID：设 DSH_TEAM_ID=<TeamID>，或写 ${LOCAL_SIGNING}（形如 {teamID = XXXXXXXXXX;}，不入库）"

# TestFlight 拒绝重复的构建号，而本地 MARKETING/CURRENT_PROJECT_VERSION 是 1.0/1。
# 每次上传前把构建号改成日期时间，省掉「这个 build 已经存在」的往返。
BUILD_NUMBER="${DSH_BUILD_NUMBER:-$(date +%Y%m%d.%H%M)}"

# ── 1. 归档 ─────────────────────────────────────────────────────────────────

if [ "$EXPORT_ONLY" = 0 ] && [ "$UPLOAD_ONLY" = 0 ]; then
  say "归档（Release，构建号 ${BUILD_NUMBER}）"
  mkdir -p "$BUILD_DIR"
  # 独立 DerivedData：默认那份是 ~/Library/Developer/Xcode/DerivedData 下的共享目录，
  # 别的会话同时在构建同一个工程时会让 build.db 打架（2026-09-24 实测报
  # "build.db: disk I/O error" + "failed to deserialize Info.plist task context"）。
  xcodebuild -project "$PROJECT_DIR/DSHMobile.xcodeproj" -scheme DSHMobile \
    -configuration Release -destination 'generic/platform=iOS' \
    -derivedDataPath "$BUILD_DIR/derived" \
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

  # 两条导出路：
  #   * **手工签名**（首选，本团队唯一走得通的）：本机 dshbuild 钥匙串里那张
  #     Apple Distribution + `ExportOptions-manual.plist` 指的 App Store 描述文件。
  #     它们是 `scripts/release/asc-dist-signing.mjs cert|profile` 装出来的；
  #   * 云签名（历史方案）：`ExportOptions-appstore.plist` + API Key，实测被 Apple
  #     拒（Cloud signing permission error），只在手工那条路不可用时兜底。
  MANUAL_KEYCHAIN="${DSH_BUILD_KEYCHAIN:-$HOME/Library/Keychains/dshbuild.keychain-db}"
  MANUAL_PASSWORD="${DSH_BUILD_KEYCHAIN_PASSWORD:-dsh}"
  exported=0
  if [ -f "$MANUAL_KEYCHAIN" ] && [ -f "$PROJECT_DIR/ExportOptions-manual.plist" ]; then
    say "用本机分发证书手工签名导出（${MANUAL_KEYCHAIN}）"
    # 私钥不在 login 钥匙串里（那边的 ACL 会让 codesign 卡住等授权），所以把
    # dshbuild 临时加进搜索列表，导出完再还原。
    original_chains="$(security list-keychains -d user | tr -d ' "' | tr '\n' ' ')"
    security unlock-keychain -p "$MANUAL_PASSWORD" "$MANUAL_KEYCHAIN" >/dev/null 2>&1 || true
    security list-keychains -d user -s "$MANUAL_KEYCHAIN" "$HOME/Library/Keychains/login.keychain-db"
    restore_chains() { security list-keychains -d user -s ${original_chains}; }
    trap restore_chains EXIT

    sed "s/<TEAM_ID>/${TEAM_ID}/" "$PROJECT_DIR/ExportOptions-manual.plist" \
      > "$BUILD_DIR/ExportOptions-manual.local.plist"
    if xcodebuild -exportArchive \
        -archivePath "$BUILD_DIR/DSHMobile.xcarchive" \
        -exportOptionsPlist "$BUILD_DIR/ExportOptions-manual.local.plist" \
        -exportPath "$BUILD_DIR/export" 2>&1 | tee "$BUILD_DIR/export.log" | tail -5
    then
      exported=1
    else
      warn "手工签名导出失败（日志见 $BUILD_DIR/export.log），退回云签名再试一次"
      rm -rf "$BUILD_DIR/export"
    fi
  fi

  if [ "$exported" = 0 ]; then
    if ! xcodebuild -exportArchive \
        -archivePath "$BUILD_DIR/DSHMobile.xcarchive" \
        -exportOptionsPlist "$BUILD_DIR/ExportOptions-appstore.plist" \
        -exportPath "$BUILD_DIR/export" \
        -allowProvisioningUpdates \
        ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} 2>&1 | tee "$BUILD_DIR/export.log" | tail -5
    then
      if grep -q "No Accounts" "$BUILD_DIR/export.log"; then
        die "导出失败：手工签名那条路也没成（要求 $MANUAL_KEYCHAIN 里有一张 Apple Distribution），
     而云签名需要 Xcode 里登录 Apple ID。二选一：
       node scripts/release/asc-dist-signing.mjs cert && node scripts/release/asc-dist-signing.mjs profile <证书 id>
       或在 Xcode → Settings → Accounts 里登录后重跑：$0 --export-only"
      fi
      die "导出失败，完整日志：$BUILD_DIR/export.log"
    fi
  fi
fi

if [ "$BETA_ONLY" = 0 ] && [ "$EXPORT_ONLY" = 0 ]; then
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
      --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" 2>&1 | tee "$BUILD_DIR/upload.log" | tail -6
  else
    xcrun altool --upload-app -f "$IPA" -t ios --apiKey "$ASC_KEY_ID" 2>&1 | tee "$BUILD_DIR/upload.log" | tail -6
  fi
  # 管道会把退出码吃掉，所以看日志：altool 失败时会打印 "Failed to upload"。
  if grep -qE "Failed to upload|ERROR:.*altool" "$BUILD_DIR/upload.log"; then
    if grep -q "must be higher than the previously uploaded version" "$BUILD_DIR/upload.log"; then
      die "这个构建号 App Store Connect 已经收过一版了（同一个号不能传两次）。重跑不加参数即可：
       $0            # 会按时间取一个新的构建号，重新归档、导出、上传"
    fi
    die "上传失败，完整日志：$BUILD_DIR/upload.log"
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

fi  # BETA_ONLY / EXPORT_ONLY

# ── 4. 挂到测试组 + 提交外部测试审核 ────────────────────────────────────────
#
# 这一步不是可选的收尾：**只上传不提交，外部测试者根本拿不到**——构建会一直躺在
# "READY_FOR_BETA_SUBMISSION"，公开链接上还是上一版。2026-09-19 传的三个构建就是这么
# 被漏掉的，测试者停在 9-18 那版两天。所以"发布 TestFlight"在这里的定义是：
# 上传 → 挂到 Public beta 组 → 提交外部测试审核 → （通过后）测试者能下载。
if [ "$SUBMIT" = 1 ]; then
  # 等的是**我们这一次的构建号**，不是"最近一版"：上传到能查询有一两分钟延迟，
  # 按"最近一版"找会把上一版挂给测试者（2026-09-21 踩过）。
  TARGET_BUILD="${DSH_BETA_BUILD:-${BUILD_NUMBER}}"
  if [ "$BETA_ONLY" = 1 ] && [ -z "${DSH_BETA_BUILD:-}" ]; then
    TARGET_BUILD=""      # 只跑 beta 那一步时，没指定就用最近上传的一版
  fi
  say "等 App Store Connect 处理完构建 ${TARGET_BUILD:-（最近一版）}"
  deadline=$(( $(date +%s) + 900 ))
  ok=0
  while :; do
    if [ -n "$TARGET_BUILD" ]; then
      status="$(node "$ROOT/scripts/dev/asc-beta.mjs" status --build "$TARGET_BUILD" 2>&1 || true)"
      if ! grep -q "还没出现在 App Store Connect" <<<"$status" && grep -q "VALID" <<<"$status"; then
        ok=1
      fi
    else
      status="$(node "$ROOT/scripts/dev/asc-beta.mjs" status 2>&1 || true)"
      grep -q "VALID" <<<"$status" && ok=1
    fi
    [ "$ok" = 1 ] && break
    if [ "$(date +%s)" -gt "$deadline" ]; then
      die "15 分钟内${TARGET_BUILD:+ 构建 $TARGET_BUILD}还没处理完。处理完之后单独跑：
       $0 --beta-only${TARGET_BUILD:+ --build $TARGET_BUILD}"
    fi
    sleep 20
  done

  if grep -q "外部测试审核：APPROVED" <<<"$status"; then
    say "这一版已经在外部测试中（APPROVED），不需要再提交"
  else
    say "挂到测试组并提交外部测试审核"
    node "$ROOT/scripts/dev/asc-beta.mjs" prepare ${TARGET_BUILD:+--build "$TARGET_BUILD"}
    node "$ROOT/scripts/dev/asc-beta.mjs" submit ${TARGET_BUILD:+--build "$TARGET_BUILD"}
  fi
  node "$ROOT/scripts/dev/asc-beta.mjs" status ${TARGET_BUILD:+--build "$TARGET_BUILD"} || true
fi

cat <<NOTE

完成。手机上用 TestFlight 打开 DSH_Mobile（或点公开链接
https://testflight.apple.com/join/tHKQsbCk ）就能装到这一版；
装完在 App 里核对构建号。

若这次带了 --no-submit：构建只对**内部**测试者可见，外部测试者要等有人跑
  $0 --beta-only
把它挂到 Public beta 组并提交外部测试审核之后才能下载。
NOTE
