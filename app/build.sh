#!/bin/bash
set -e
SIGN_ID="${SIGN_ID:--}"   # export SIGN_ID="Developer ID Application: Your Name (TEAMID)" to sign for distribution
[ -f .sign-id ] && SIGN_ID="$(cat .sign-id)"   # local, git-ignored
cd "$(dirname "$0")"
swift build -c release 2>&1 | tail -20
APP="build/Red-XAI Vortex.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Vortex "$APP/Contents/MacOS/Vortex"
# icon
IS=build/Vortex.iconset; rm -rf $IS; mkdir -p $IS
sips -s format png icon.jpg --out build/icon1024.png >/dev/null
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon1024.png --out $IS/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon1024.png --out $IS/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $IS -o "$APP/Contents/Resources/AppIcon.icns"
# compute-node worker (llama.cpp RPC, Metal), built in ~/Projects/redx-node
W=~/Projects/redx-node/llama.cpp/build/bin/ggml-rpc-server
if [ -x "$W" ]; then cp "$W" "$APP/Contents/Resources/ggml-rpc-server"
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP/Contents/Resources/ggml-rpc-server" 2>&1 | tail -1; fi
# server installer for one-click Servers > Install
[ -f server/install.sh ] && cp server/install.sh "$APP/Contents/Resources/install.sh"
# local mode runtime (Metal); signed without hardened runtime so it can load Homebrew's OpenSSL
L=~/Projects/redx-node/llama.cpp/build/bin/llama-server
if [ -x "$L" ]; then cp "$L" "$APP/Contents/Resources/llama-server"; codesign --force --timestamp --sign "$SIGN_ID" "$APP/Contents/Resources/llama-server" 2>&1 | tail -1; fi
cat > "$APP/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Red-XAI Vortex</string>
<key>CFBundleDisplayName</key><string>Red-XAI Vortex</string>
<key>CFBundleIdentifier</key><string>com.redxai.vortex</string>
<key>CFBundleExecutable</key><string>Vortex</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.0</string>
<key>CFBundleVersion</key><string>6</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
P
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP" 2>&1 || codesign --force --sign - "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Authority|Signature" | head -3
