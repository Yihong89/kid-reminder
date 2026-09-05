#!/bin/bash
# Build the Kid Reminder macOS app into a .app bundle (no Xcode needed).
set -e
cd "$(dirname "$0")"

APP_NAME="KidReminder"
BUNDLE="build/$APP_NAME.app"

echo "=== building (universal: arm64 + x86_64, combined with lipo) ==="
# NOTE: `swift build --arch arm64 --arch x86_64` in one invocation asks
# SwiftPM to hand off to xcbuild to produce the fat binary directly, which
# isn't installed on every machine (plain Xcode Command Line Tools don't
# ship it). That combo silently fell back to a *single native-arch* build
# in that case — on an Intel dev machine this produced an x86_64-only
# binary that then had to run under Rosetta on an Apple Silicon Mac, which
# crashed inside CoreAudio's audio format converter the first time the app
# played a sound (a known Rosetta translation issue with that code path,
# not a bug in KidReminder). Building each arch as its own SwiftPM
# invocation and combining with `lipo` sidesteps xcbuild entirely and
# always yields a true universal binary regardless of the host machine.
swift build -c release --arch arm64
swift build -c release --arch x86_64
BIN=".build/apple/Products/Release/$APP_NAME"
mkdir -p "$(dirname "$BIN")"
lipo -create \
  ".build/arm64-apple-macosx/release/$APP_NAME" \
  ".build/x86_64-apple-macosx/release/$APP_NAME" \
  -output "$BIN"
echo "  -> $(lipo -info "$BIN")"

echo "=== assembling $BUNDLE ==="
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$BIN" "$BUNDLE/Contents/MacOS/$APP_NAME"

# app icon (from Resources/AppIcon.svg)
if [ -f "Resources/AppIcon.svg" ]; then
  echo "=== generating app icon ==="
  WORK=$(mktemp -d)
  CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  if [ -x "$CHROME" ]; then
    # Render the SVG directly. (An HTML <img> wrapper makes Chrome's screenshot
    # paint a gray border on the bottom/right edges — a rendering artifact.)
    # guard against headless Chrome hanging: run under a 20s alarm (perl's alarm)
    perl -e 'alarm shift; exec @ARGV' 20 \
      "$CHROME" --headless --disable-gpu --screenshot="$WORK/AppIcon.svg.png" \
      --window-size=1024,1024 --default-background-color=00000000 "file://$(pwd)/Resources/AppIcon.svg" >/dev/null 2>&1 || true
    SRC="$WORK/AppIcon.svg.png"
  else
    qlmanage -t -s 1024 -o "$WORK" "Resources/AppIcon.svg" >/dev/null 2>&1
    SRC="$WORK/AppIcon.svg.png"
  fi
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
    <key>CFBundleShortVersionString</key><string>1.11.2</string>
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
