#!/bin/bash
# ============================================================
# DSH Mobile —— 无线（OTA）发布
#
# 归档 → 导出 .ipa → 生成 manifest 与安装页 → 上传到已备案的站点。
# 之后在手机上打开安装链接点一下即可，不需要数据线，也不需要 Mac 与手机
# 在同一个 Wi-Fi：安装包和清单都放在公网服务器上。
#
# 用法: ./scripts/release/deploy-ota.sh [--no-build]
#   --no-build  复用已有的 .ipa，只重新上传（改安装页文案时用）
#
# 回滚：服务器上删除 /opt/dsh-relay/public/ios/ 即可，Caddy 路由仍在受管
#       块里，`relay/deploy/deploy.sh --uninstall` 会一并移除。
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT_DIR="$ROOT/ios/DSHMobile"
BUILD_DIR="$PROJECT_DIR/.build/ota"
ARCHIVE="$BUILD_DIR/DSHMobile.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
STAGE_DIR="$BUILD_DIR/stage"

# 本机部署配置：仓库里只有占位符（relay.example.com），真值放 .env.local（不入库）。
# shellcheck disable=SC1091
[ -f "$ROOT/.env.local" ] && . "$ROOT/.env.local"

# The developer team is the developer's, not the repository's: it is read from
# the environment or from a gitignored local file, never from a tracked one.
BUNDLE_ID="com.jayanttang.dsh"
LOCAL_SIGNING="$PROJECT_DIR/Signing.local.plist"
TEAM_ID="${DSH_TEAM_ID:-$(plutil -extract teamID raw -o - "$LOCAL_SIGNING" 2>/dev/null || true)}"
[ -n "$TEAM_ID" ] || die "没有开发者团队 ID：设 DSH_TEAM_ID=<TeamID>，或写 ${LOCAL_SIGNING}（形如 {teamID = XXXXXXXXXX;}，不入库）"
# 安装页与 manifest 上显示的名字，与 App 的 CFBundleDisplayName 保持一致。
APP_NAME="DSH Mobile"
HOST="${DSH_OTA_HOST:-relay.example.com}"
REMOTE_DIR="${DSH_OTA_DIR:-/opt/dsh-relay/public/ios}"
PUBLIC_BASE="https://${HOST}/ios"

SKIP_BUILD=0
[ "${1:-}" = "--no-build" ] && SKIP_BUILD=1

step() { printf '\n\033[1;36m>>>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

mkdir -p "$BUILD_DIR"

# Stamp every publish with its own build number.
#
# Without this the build number stayed at 1 forever, so "which version is on the
# phone?" could not be answered from the app, from the relay's device record, or
# from the install page — and a stale install was indistinguishable from a fresh
# one. A UTC timestamp fixes that permanently.
#
# The shape matters as much as the uniqueness. `CFBundleVersion` is defined as
# 1–3 period-separated integers, each at most 4294967295, and the previous
# 12-digit stamp (`202609161637`) blew past that ceiling. With it, iOS fetched
# the manifest and probed the package — then installed nothing, silently, while
# a *fresh* install of the very same build worked. An out-of-range build number
# is the one thing in the chain that differs between "nothing installed yet" and
# "something already installed", so the stamp is now `yyyyMMdd.HHmm`: in range,
# still monotonic, still readable.
BUILD_NUMBER="$(date -u +%Y%m%d).$(date -u +%H%M)"
step "构建号 $BUILD_NUMBER"

if [ "$SKIP_BUILD" -eq 0 ]; then
  # 归档这一步 xcodebuild 的输出经过 tail 折叠，所以「没有任何输出」是正常的，
  # 不是卡住：一次 Release 归档通常 1~3 分钟。中途 Ctrl-C 会留下半成品和
  # ibtoold 孤儿进程，看起来就像「停住了」，其实是被自己打断了。
  step "归档（Release / 真机）—— 本步无输出属正常，通常 1~3 分钟，请不要中断"
  rm -rf "$ARCHIVE" "$EXPORT_DIR"
  xcodebuild -project "$PROJECT_DIR/DSHMobile.xcodeproj" -scheme DSHMobile \
    -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" -allowProvisioningUpdates \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    DEVELOPMENT_TEAM="$TEAM_ID" archive \
    | tail -3

  step "导出 .ipa —— 同样需要一两分钟，无输出属正常"
  # 团队 ID 在这里落进导出选项的副本，仓库里那份留着占位符。
  sed "s/<TEAM_ID>/${TEAM_ID}/" "$PROJECT_DIR/ExportOptions-ota.plist" \
    > "$BUILD_DIR/ExportOptions-ota.local.plist"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions-ota.local.plist" \
    -exportPath "$EXPORT_DIR" -allowProvisioningUpdates \
    | tail -4
fi

IPA="$(/bin/ls -t "$EXPORT_DIR"/*.ipa 2>/dev/null | head -1 || true)"
[ -n "$IPA" ] || die "没有找到 .ipa（${EXPORT_DIR}）"

step "读取版本号"
APP_PLIST="$ARCHIVE/Products/Applications/DSHMobile.app/Info.plist"
SHORT_VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$APP_PLIST")
BUILD_VERSION=$(plutil -extract CFBundleVersion raw -o - "$APP_PLIST")
echo "版本 $SHORT_VERSION ($BUILD_VERSION)"

step "生成 manifest 与安装页"
rm -rf "$STAGE_DIR"; mkdir -p "$STAGE_DIR"

# Every publish gets its own file names.
#
# The install URL used to be the same for every build (`/ios/DSHMobile.ipa`,
# `/ios/manifest.plist`). iOS's installer keeps the manifest it fetched per URL,
# so a later tap could install the *same* version that is already on the phone:
# the system compares versions, sees nothing newer, and quietly does nothing —
# which reads as "the update only works if I delete the app first". Versioned
# names make that impossible; the unversioned ones stay as aliases so an old
# bookmark still resolves.
IPA_NAME="DSHMobile-${BUILD_VERSION}.ipa"
MANIFEST_NAME="manifest-${BUILD_VERSION}.plist"
ICON_SMALL="icon-${BUILD_VERSION}-57.png"
ICON_LARGE="icon-${BUILD_VERSION}-512.png"

cp "$IPA" "$STAGE_DIR/$IPA_NAME"
cp "$IPA" "$STAGE_DIR/DSHMobile.ipa"

# The install sheet shows these two bitmaps; Apple's manifest lists them and
# leaves them out at your peril (a missing display-image is a blank icon at best
# and a failed install at worst). They come from the same 1024 art as the icon.
ICON_SOURCE="$PROJECT_DIR/DSHMobile/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
if [ -f "$ICON_SOURCE" ]; then
  sips -z 57 57 "$ICON_SOURCE" --out "$STAGE_DIR/$ICON_SMALL" >/dev/null
  sips -z 512 512 "$ICON_SOURCE" --out "$STAGE_DIR/$ICON_LARGE" >/dev/null
else
  die "找不到图标源文件 ${ICON_SOURCE}（先跑 scripts/dev/make-app-icon.py）"
fi

cat > "$STAGE_DIR/manifest.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>items</key>
	<array>
		<dict>
			<key>assets</key>
			<array>
				<dict>
					<key>kind</key>
					<string>software-package</string>
					<key>url</key>
					<string>${PUBLIC_BASE}/${IPA_NAME}</string>
				</dict>
				<dict>
					<key>kind</key>
					<string>display-image</string>
					<key>needs-shine</key>
					<false/>
					<key>url</key>
					<string>${PUBLIC_BASE}/${ICON_SMALL}</string>
				</dict>
				<dict>
					<key>kind</key>
					<string>full-size-image</string>
					<key>needs-shine</key>
					<false/>
					<key>url</key>
					<string>${PUBLIC_BASE}/${ICON_LARGE}</string>
				</dict>
			</array>
			<key>metadata</key>
			<dict>
				<key>bundle-identifier</key>
				<string>${BUNDLE_ID}</string>
				<key>bundle-version</key>
				<string>${BUILD_VERSION}</string>
				<key>kind</key>
				<string>software</string>
				<key>title</key>
				<string>${APP_NAME}</string>
			</dict>
		</dict>
	</array>
</dict>
</plist>
PLIST
cp "$STAGE_DIR/manifest.plist" "$STAGE_DIR/$MANIFEST_NAME"

# 安装页刻意做得极简：它唯一的任务是把 itms-services 链接交给 iOS。
cat > "$STAGE_DIR/index.html" <<HTML
<!doctype html>
<html lang="zh-CN">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>安装 ${APP_NAME}</title>
<style>
  :root { color-scheme: light dark; }
  body {
    margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
    font: 16px/1.5 -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif;
    background: #151517; color: #f9fafb; padding: 24px;
  }
  .card { width: 100%; max-width: 420px; }
  h1 { font-size: 26px; font-weight: 600; margin: 0 0 6px; }
  .meta { color: #81858c; font-size: 13px; margin-bottom: 28px; }
  a.install {
    display: block; text-align: center; text-decoration: none;
    background: #4d6bfe; color: #fff; font-weight: 500;
    padding: 15px; border-radius: 12px;
  }
  ol { color: #cfd3d6; font-size: 14px; padding-left: 20px; margin: 26px 0 0; }
  li { margin-bottom: 8px; }
  code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 13px; color: #adb2b8; }
</style>
<div class="card">
  <h1>${APP_NAME}</h1>
  <div class="meta">版本 ${SHORT_VERSION} (${BUILD_VERSION})<br>构建于 $(date '+%Y-%m-%d %H:%M')</div>
  <a class="install" data-build="${BUILD_VERSION}" href="itms-services://?action=download-manifest&amp;url=${PUBLIC_BASE}/${MANIFEST_NAME}">安装 / 更新</a>
  <ol>
    <li>用 <strong>Safari</strong> 打开本页（微信、Chrome 内不支持直接安装）。</li>
    <li>点上面的按钮，系统会提示「安装」。</li>
    <li><strong>更新不用先卸载</strong>：直接点上面按钮即可覆盖安装，数据会保留；卸载再装会清掉 App 里的记录。</li>
    <li>首次安装后如提示「不受信任的开发者」，到 <code>设置 → 通用 → VPN 与设备管理</code> 信任本开发者。</li>
  </ol>
</div>
<script>
  // 这个页面可能来自 Safari 的缓存或「恢复上次的标签页」，而 iOS 的安装器又会按 URL
  // 记住 manifest：页面旧 + 那个 URL 被记过，点下去就是「什么都不发生」。所以打开时
  // 再对着 version.json（响应带 no-store，永远是当次发布）核一眼，把按钮改成指向
  // 当次那份 manifest——这样即使拿着旧页面点，装的也是最新一次发布。
  (function () {
    var link = document.querySelector('a.install');
    if (!link) return;
    fetch('version.json', { cache: 'no-store' })
      .then(function (response) { return response.json(); })
      .then(function (published) {
        if (!published || !published.build) return;
        var manifest = new URL('manifest-' + published.build + '.plist', location.href);
        link.href = 'itms-services://?action=download-manifest&url=' + encodeURIComponent(manifest.href);
        if (published.build !== link.dataset.build) {
          var meta = document.querySelector('.meta');
          if (meta) {
            meta.innerHTML = '最新版本 ' + published.shortVersion + ' (' + published.build +
              ')<br>这一页是缓存里的旧版，按钮已改指最新一次发布';
          }
        }
      })
      .catch(function () { /* 取不到就保持服务端渲染的那一份 */ });
  })();
</script>
</html>
HTML

# A tiny machine-readable version stamp. The app fetches this and tells the
# user when the published build is newer than the one installed — without it,
# "am I up to date?" can only be answered by walking to a computer, and an
# install that silently did nothing looks identical to one that never happened.
cat > "$STAGE_DIR/version.json" <<JSON
{
  "shortVersion": "${SHORT_VERSION}",
  "build": "${BUILD_VERSION}",
  "publishedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "installPage": "${PUBLIC_BASE}/"
}
JSON

step "上传到 $HOST:$REMOTE_DIR"
scp -q -o BatchMode=yes "$STAGE_DIR/$IPA_NAME" "$STAGE_DIR/DSHMobile.ipa" \
  "$STAGE_DIR/$MANIFEST_NAME" "$STAGE_DIR/manifest.plist" \
  "$STAGE_DIR/$ICON_SMALL" "$STAGE_DIR/$ICON_LARGE" \
  "$STAGE_DIR/index.html" "$STAGE_DIR/version.json" \
  "root@${HOST}:${REMOTE_DIR}/"

# 只留最近两份版本化产物：页面永远指向当前那份，旧的只是在占服务器空间。
ssh -q -o BatchMode=yes "root@${HOST}" "cd '$REMOTE_DIR' && \
  ls -t DSHMobile-*.ipa 2>/dev/null | tail -n +3 | xargs -r rm -f && \
  ls -t manifest-*.plist 2>/dev/null | tail -n +3 | xargs -r rm -f && \
  ls -t icon-*-57.png 2>/dev/null | tail -n +3 | xargs -r rm -f && \
  ls -t icon-*-512.png 2>/dev/null | tail -n +3 | xargs -r rm -f"

# scp creates the destination directory with a restrictive mode, and Caddy runs
# as an unprivileged user: without an explicit chmod it answers 403 because it
# cannot traverse into the folder.
ssh -q -o BatchMode=yes "root@${HOST}" \
  "chmod 755 $(dirname "$REMOTE_DIR") '$REMOTE_DIR' && chmod 644 '$REMOTE_DIR'/*"

step "校验公网可访问"
# A ranged probe keeps this cheap for the multi-megabyte .ipa; 206 is the
# expected answer for a range request, 200 for the small text files.
for path in index.html manifest.plist "$MANIFEST_NAME" DSHMobile.ipa "$IPA_NAME" "$ICON_SMALL" "$ICON_LARGE" version.json; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 60 -r 0-0 "${PUBLIC_BASE}/${path}")
  printf '  %-18s HTTP %s\n' "$path" "$code"
  case "$code" in
    200|206) ;;
    *) die "${path} 不可访问（HTTP ${code}）" ;;
  esac
done
size=$(curl -s -o /dev/null -w '%{size_download}' -m 120 "${PUBLIC_BASE}/$IPA_NAME")
printf '  %-18s %s 字节\n' "ipa 完整下载" "$size"

# The one mismatch that silently breaks an update: the manifest advertises a
# version the .ipa does not have. iOS compares them and installs nothing, with
# no error anywhere. Read both back from the server and compare.
step "校验 manifest 与 ipa 的版本一致"
curl -s -m 60 -o "$BUILD_DIR/check-manifest.plist" "${PUBLIC_BASE}/$MANIFEST_NAME"
curl -s -m 180 -o "$BUILD_DIR/check.ipa" "${PUBLIC_BASE}/$IPA_NAME"
MANIFEST_VERSION=$(plutil -extract items.0.metadata.bundle-version raw -o - "$BUILD_DIR/check-manifest.plist")
PACKAGE_VERSION=$(unzip -p "$BUILD_DIR/check.ipa" Payload/DSHMobile.app/Info.plist \
  | plutil -extract CFBundleVersion raw -o - -)
MANIFEST_ID=$(plutil -extract items.0.metadata.bundle-identifier raw -o - "$BUILD_DIR/check-manifest.plist")
printf '  manifest %s / %s\n' "$MANIFEST_ID" "$MANIFEST_VERSION"
printf '  ipa      %s / %s\n' "$BUNDLE_ID" "$PACKAGE_VERSION"
[ "$MANIFEST_VERSION" = "$PACKAGE_VERSION" ] || die "manifest 写的是 ${MANIFEST_VERSION}，包里是 ${PACKAGE_VERSION}——这种不一致会让 iOS 什么都不装"
[ "$MANIFEST_ID" = "$BUNDLE_ID" ] || die "manifest 的 bundle-identifier 是 ${MANIFEST_ID}，应为 $BUNDLE_ID"
rm -f "$BUILD_DIR/check.ipa" "$BUILD_DIR/check-manifest.plist"

cat <<EOF

$(printf '\033[1;32m完成\033[0m')  构建号 ${BUILD_VERSION}

  手机上核对是否已更新：设置 → 关于 → App 版本，应显示 ${SHORT_VERSION} (${BUILD_VERSION})

  手机上用 Safari 打开：  ${PUBLIC_BASE}/
  直接安装命令（同一 Wi-Fi 时可用）：
    xcrun devicectl device install app --device <UDID> "$EXPORT_DIR/$(basename "$IPA")"

EOF
