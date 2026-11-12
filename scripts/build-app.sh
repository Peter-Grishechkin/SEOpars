#!/bin/zsh
# Собирает build/SEOpars.app из SwiftPM-пакета (Xcode не нужен).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/sdk.sh
swift build -c release --product SEOpars
swift build -c release --product seopars-cli
BIN="$(swift build -c release --show-bin-path)"
APP="build/SEOpars.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SEOpars" "$APP/Contents/MacOS/SEOpars"
cp "$BIN/seopars-cli" build/seopars-cli
# Ресурсы зависимостей (если появятся)
for b in "$BIN"/*.bundle(N); do cp -R "$b" "$APP/Contents/Resources/"; done
VERSION="0.3.0"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.petergrish.seopars</string>
  <key>CFBundleName</key><string>SEOpars</string>
  <key>CFBundleDisplayName</key><string>SEOpars</string>
  <key>CFBundleExecutable</key><string>SEOpars</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST
codesign --force --deep -s - "$APP"
echo "Готово: $PWD/$APP"
