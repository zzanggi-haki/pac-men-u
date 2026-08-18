#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP="PAC-MEN-U.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$APP/Contents/MacOS/PAC-MEN-U" main.swift

# app icon (regenerate only when missing or the generator changed)
if [[ ! -f AppIcon.icns || gen-icon.swift -nt AppIcon.icns ]]; then
    swift gen-icon.swift AppIcon.iconset
    iconutil -c icns AppIcon.iconset -o AppIcon.icns
    rm -rf AppIcon.iconset
fi
cp AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>PAC-MEN-U</string>
    <key>CFBundleDisplayName</key><string>PAC-MEN-U</string>
    <key>CFBundleIdentifier</key><string>com.zzanggi.pacmenu</string>
    <key>CFBundleExecutable</key><string>PAC-MEN-U</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.6</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
EOF
codesign --force --deep -s "Apple Development: zzanggi1206@naver.com (6GWWF97289)" "$APP"
echo "Built $APP"

# install to /Applications
pkill -f "PAC-MEN-U.app" 2>/dev/null || true
sleep 1
rm -rf "/Applications/$APP"
cp -R "$APP" /Applications/
echo "Installed to /Applications/$APP"
