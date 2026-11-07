#!/bin/bash
# Builds LiveWallpaper.app from the Swift package and reveals it in Finder.
# Requires Xcode Command Line Tools:  xcode-select --install
set -eo pipefail
cd "$(dirname "$0")"

if ! command -v swift >/dev/null 2>&1; then
  echo "❌ Swift not found. Run:  xcode-select --install   then run this script again."
  exit 1
fi

echo "▶ Building (this takes ~1 minute the first time)…"
if ! swift build -c release; then
  echo ""
  echo "❌ Build failed. Copy everything above this line and send it to Claude."
  exit 1
fi

BIN="$(swift build -c release --show-bin-path)/LiveWallpaper"
APP="$(pwd)/LiveWallpaper.app"

echo "▶ Packaging…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LiveWallpaper"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>             <string>LiveWallpaper</string>
    <key>CFBundleDisplayName</key>      <string>Live Wallpaper</string>
    <key>CFBundleIdentifier</key>       <string>com.tenzero.livewallpaper</string>
    <key>CFBundleExecutable</key>       <string>LiveWallpaper</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleVersion</key>          <string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key>   <string>13.0</string>
    <key>LSUIElement</key>              <true/>
    <key>NSHighResolutionCapable</key>  <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo ""
echo "✅ Done: $APP"
echo "   (Finder may show it just as \"LiveWallpaper\" with an app icon.)"
open -R "$APP"
