#!/bin/zsh
# Builds PAC-MEN-U as a universal (arm64 + x86_64) app, ad-hoc signs it, and
# packages it into a distributable .dmg under dist/.
#
# Unlike ./build.sh (dev build: Apple Development signature + install to
# /Applications), this never touches /Applications. Users install via
# scripts/install.sh (curl → no quarantine) or bypass Gatekeeper once.
#
# Usage: ./scripts/build_dmg.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_NAME="PAC-MEN-U"
DMG_NAME="PAC-MEN-U.dmg"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
VERSION="$(sed -n 's/.*CFBundleShortVersionString<\/key><string>\([^<]*\)<.*/\1/p' build.sh)"
[ -n "$VERSION" ] || { echo "Could not read version from build.sh"; exit 1; }

echo "==> Building universal ($VERSION)"
rm -rf "$BUILD_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -target arm64-apple-macos13.0  -o "$BUILD_DIR/$APP_NAME-arm64"  main.swift
swiftc -O -target x86_64-apple-macos13.0 -o "$BUILD_DIR/$APP_NAME-x86_64" main.swift
lipo -create "$BUILD_DIR/$APP_NAME-arm64" "$BUILD_DIR/$APP_NAME-x86_64" -output "$APP/Contents/MacOS/$APP_NAME"

if [[ ! -f AppIcon.icns || gen-icon.swift -nt AppIcon.icns ]]; then
    swift gen-icon.swift AppIcon.iconset
    iconutil -c icns AppIcon.iconset -o AppIcon.icns
    rm -rf AppIcon.iconset
fi
cp AppIcon.icns "$APP/Contents/Resources/"

# Same Info.plist as build.sh (single source of truth is build.sh's heredoc).
sed -n '/<?xml/,/<\/plist>/p' build.sh > "$APP/Contents/Info.plist"

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP" || true

echo "==> Staging DMG contents"
STAGE="$BUILD_DIR/dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating $DMG_NAME"
mkdir -p "$ROOT/dist"
rm -f "$ROOT/dist/$DMG_NAME"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$ROOT/dist/$DMG_NAME" >/dev/null

echo "==> Done: $ROOT/dist/$DMG_NAME"
ls -lh "$ROOT/dist/$DMG_NAME"
lipo -info "$APP/Contents/MacOS/$APP_NAME"
