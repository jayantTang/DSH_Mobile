#!/bin/bash
# Builds DSH.app (a self-contained WKWebView shell) into ./macos/build/DSH.app
# Requires only the Xcode command line tools (swiftc, iconutil).
set -euo pipefail

MACOS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$MACOS_DIR/.." && pwd)"
APP_NAME="DSH"
BUILD="$MACOS_DIR/build"
APP="$BUILD/$APP_NAME.app"
VERSION="${DSH_SHELL_VERSION:-1.0.0}"

echo "==> cleaning $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> compiling swift"
swiftc -O -swift-version 5 \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  "$MACOS_DIR/main.swift" \
  -framework AppKit -framework WebKit

echo "==> generating icon"
if swift "$MACOS_DIR/make-icon.swift" "$BUILD/AppIcon.iconset" >/dev/null 2>&1; then
  iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns" || true
else
  echo "   (icon generation skipped)"
fi

echo "==> writing Info.plist"
sed "s/__VERSION__/$VERSION/g" "$MACOS_DIR/Info.plist" > "$APP/Contents/Info.plist"

echo "==> signing"
# A stable identity is what makes the Screen Recording grant survive a rebuild.
# macOS keys an ad-hoc signature's TCC grant to the cdhash, so every rebuild
# looks like a brand-new app and the user has to grant (and restart) again —
# the reason `screencapture` kept failing after the permission was configured.
# With a signing certificate the requirement becomes
# identifier + certificate, which does not change when the binary does.
IDENTITY="${DSH_CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"/{print $2; exit}')"
fi
if [ -n "$IDENTITY" ]; then
  if codesign --force --deep --sign "$IDENTITY" "$APP" >/dev/null 2>&1; then
    echo "   signed as: $IDENTITY"
  else
    echo "   !! signing as '$IDENTITY' failed; falling back to ad-hoc" >&2
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "   (codesign skipped)"
  fi
else
  echo "   !! no code-signing identity found — using ad-hoc signing."
  echo "      macOS will forget the Screen Recording grant on every rebuild,"
  echo "      so screenshots will need to be re-authorized each time."
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "   (codesign skipped)"
fi

echo "==> built $APP"
