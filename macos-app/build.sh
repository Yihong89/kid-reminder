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
# --disable-sandbox：SwiftPM 编译 manifest 时会调 sandbox-exec，在被外层沙箱
# 包住的环境（CI、受限 shell）里会直接失败。本包没有任何 build plugin，
# 关掉这层嵌套沙箱不影响产物。
swift build -c release --disable-sandbox --arch arm64
swift build -c release --disable-sandbox --arch x86_64
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
# 图标生成依赖 Chrome/qlmanage，缺一个就失败。**图标失败不该让整个构建挂掉** ——
# 二进制和 .app 在这之前就组装好了，而 `set -e` 会让 cp 的失败直接中止脚本，
# 结果是一个明明可用、却因为没图标而"构建失败"的包。
set +e
if [ -f "Resources/AppIcon.svg" ]; then
  echo "=== generating app icon ==="
  WORK=$(mktemp -d)
  CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  if [ -x "$CHROME" ]; then
    # Render the SVG directly. (An HTML <img> wrapper makes Chrome's screenshot
    # paint a gray border on the bottom/right edges — a rendering artifact.)
    # guard against headless Chrome hanging: run under a 25s alarm (perl's alarm)
    #
    # --user-data-dir 必须显式给：受限环境（CI、被外层沙箱包住的 shell）里 Chrome
    # 建不了默认 profile，会直接退出，表现就是"图标静默缺失"。
    # --no-sandbox 同理：外层已有沙箱时 Chrome 自己的沙箱会崩（Trace/BPT trap: 5）。
    perl -e 'alarm shift; exec @ARGV' 25 \
      "$CHROME" --headless=new --no-sandbox --disable-gpu \
      --user-data-dir="$WORK/chrome" \
      --screenshot="$WORK/AppIcon.svg.png" \
      --window-size=1024,1024 --default-background-color=00000000 "file://$(pwd)/Resources/AppIcon.svg" >/dev/null 2>&1 || true
  fi
  # 不要假设上一步一定产出了 PNG：Chrome 可能在没报错的情况下什么都没写。
  # 少了这个回退，后面 cp 会失败，iconutil 也会失败，最后得到一个没图标的包
  # 却仍然打印"构建成功"——比直接报错更糟。
  [ -s "$WORK/AppIcon.svg.png" ] || qlmanage -t -s 1024 -o "$WORK" "Resources/AppIcon.svg" >/dev/null 2>&1
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
  if iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns" 2>/dev/null \
     && [ -s "$BUNDLE/Contents/Resources/AppIcon.icns" ]; then
    echo "  -> Contents/Resources/AppIcon.icns ($(du -h "$BUNDLE/Contents/Resources/AppIcon.icns" | cut -f1))"
  else
    echo "  !! 图标生成失败，这个包没有图标（功能不受影响）"
  fi
  rm -rf "$WORK"
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
    <key>CFBundleShortVersionString</key><string>2.0.0</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <!--
      ATS exemption: the user types an arbitrary server IP/hostname in Settings,
      so the set of hosts cannot be enumerated in advance. Without this, ATS
      treats non-RFC1918 literals (e.g. Tailscale's 100.64.0.0/10 CGNAT range)
      as public and forces HTTPS, while APIClient.swift hardcodes the http
      scheme — the connection then fails with "requires the use of a secure
      connection". APIClient speaks plain HTTP to the LAN/Tailscale server only.
    -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key><true/>
    </dict>
</dict>
</plist>
PLIST
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

echo "=== ad-hoc signing ==="
codesign --force --sign - "$BUNDLE"

echo "=== done: $BUNDLE ==="
echo "Copy the .app to the kid's MacBook, then right-click -> Open on first launch."
