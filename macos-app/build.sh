#!/bin/bash
# Build the Kid Reminder macOS app into a .app bundle (no Xcode needed).
set -e
cd "$(dirname "$0")"

APP_NAME="KidReminder"
BUNDLE="build/$APP_NAME.app"

echo "=== building (universal, falls back to native arch) ==="
if swift build -c release --arch arm64 --arch x86_64; then
  BIN=".build/apple/Products/Release/$APP_NAME"
else
  echo "-- universal build failed, trying native arch --"
  rm -rf .build
  swift build -c release
  BIN=".build/release/$APP_NAME"
fi
[ -f "$BIN" ] || BIN=".build/release/$APP_NAME"

echo "=== assembling $BUNDLE ==="
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$BIN" "$BUNDLE/Contents/MacOS/$APP_NAME"

# app icon (from Resources/AppIcon.svg)
if [ -f "Resources/AppIcon.svg" ]; then
  echo "=== generating app icon ==="
  WORK=$(mktemp -d)
  qlmanage -t -s 1024 -o "$WORK" "Resources/AppIcon.svg" >/dev/null 2>&1
  SRC="$WORK/AppIcon.svg.png"
  ICONSET="$WORK/AppIcon.iconset"
  mkdir -p "$ICONSET"
  cp "$SRC" "$ICONSET/icon_512x512@2x.png"
  for spec in "16:icon_16x16.png" "32:icon_16x16@2x.png" "32:icon_32x32.png" \
              "64:icon_32x32@2x.png" "128:icon_128x128.png" "256:icon_128x128@2x.png" \
              "256:icon_256x256.png" "512:icon_256x256@2x.png" "512:icon_512x512.png"; do
    size="${spec%%:*}"; name="${spec##*:}"
    sips -z "$size" "$size" "$SRC" --out "$ICONSET/$name" >/dev/null 2>&1
  done
  mkdir -p "$BUNDLE/Contents/Resources"
  iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns"
  rm -rf "$WORK"
  echo "  -> Contents/Resources/AppIcon.icns"
fi

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>Kid Reminder</string>
    <key>CFBundleIdentifier</key><string>com.kidreminder.mac</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

echo "=== ad-hoc signing ==="
codesign --force --sign - "$BUNDLE"

echo "=== done: $BUNDLE ==="
echo "Copy the .app to the kid's MacBook, then right-click -> Open on first launch."
