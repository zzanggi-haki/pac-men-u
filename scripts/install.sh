#!/bin/bash
# One-line installer for PAC-MEN-U.
#
# Downloads the latest release .dmg with curl (which does not set the
# com.apple.quarantine attribute, so Gatekeeper never blocks the app), copies
# Soundwich.app into /Applications, and launches it.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/zzanggi-haki/pac-men-u/main/scripts/install.sh | bash
#
# Overrides (mainly for testing):
#   PAC_MEN_U_DMG_URL      download URL or local path of the .dmg
#   PAC_MEN_U_INSTALL_DIR  install destination (default: /Applications)
#   PAC_MEN_U_NO_LAUNCH=1  don't launch after installing
set -euo pipefail

APP_NAME="PAC-MEN-U"
DMG_URL="${PAC_MEN_U_DMG_URL:-https://github.com/zzanggi-haki/pac-men-u/releases/latest/download/PAC-MEN-U.dmg}"
INSTALL_DIR="${PAC_MEN_U_INSTALL_DIR:-/Applications}"
MIN_MACOS="13.0"

fail() { echo "❌ $*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "PAC-MEN-U는 macOS 전용이에요."

OS_VERSION="$(sw_vers -productVersion)"
if [ "$(printf '%s\n%s\n' "$MIN_MACOS" "$OS_VERSION" | sort -V | head -n1)" != "$MIN_MACOS" ]; then
  fail "macOS $MIN_MACOS 이상이 필요해요. (현재: $OS_VERSION)"
fi

WORK="$(mktemp -d)"
MOUNT="$WORK/mount"
cleanup() {
  hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "==> PAC-MEN-U 내려받는 중"
if [ -f "$DMG_URL" ]; then
  cp "$DMG_URL" "$WORK/$APP_NAME.dmg"
else
  curl -fL --progress-bar -o "$WORK/$APP_NAME.dmg" "$DMG_URL" || fail "다운로드에 실패했어요. 인터넷 연결을 확인해 주세요."
fi

echo "==> 설치하는 중 ($INSTALL_DIR)"
mkdir -p "$MOUNT"
hdiutil attach "$WORK/$APP_NAME.dmg" -nobrowse -readonly -mountpoint "$MOUNT" -quiet \
  || fail "디스크 이미지를 열지 못했어요."
[ -d "$MOUNT/$APP_NAME.app" ] || fail "디스크 이미지에 $APP_NAME.app이 없어요."

# Quit a running copy so the bundle can be replaced cleanly.
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  sleep 1
  pkill -x "$APP_NAME" 2>/dev/null || true
fi

DEST="$INSTALL_DIR/$APP_NAME.app"
if [ -w "$INSTALL_DIR" ]; then
  rm -rf "$DEST"
  ditto "$MOUNT/$APP_NAME.app" "$DEST"
else
  echo "    $INSTALL_DIR 에 쓰려면 Mac 로그인 암호가 필요해요."
  sudo rm -rf "$DEST"
  sudo ditto "$MOUNT/$APP_NAME.app" "$DEST"
fi

# Belt and braces: curl doesn't quarantine, but a local .dmg passed in might be.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "✅ 설치 완료: $DEST"
if [ "${PAC_MEN_U_NO_LAUNCH:-}" != "1" ]; then
  open "$DEST"
  echo "   메뉴바에 🟡 팩맨이 나타나요. 뱃속 리스트를 보려면 '손쉬운 사용' 권한을 허용해 주세요."
fi
