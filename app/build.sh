#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [ -z "${SIGN_ID:-}" ]; then
  if [ -f .sign-id ]; then SIGN_ID="$(cat .sign-id)"; else SIGN_ID="-"; fi
fi
if [ "$SIGN_ID" = "-" ]; then TIMESTAMP=(--timestamp=none); else TIMESTAMP=(--timestamp); fi
ARCHS="${VORTEX_ARCHS:-arm64 x86_64}"
PACKAGE="${VORTEX_SWIFT_PACKAGE_PATH:-$PWD}"
SWIFT_ARGS=(--package-path "$PACKAGE" -c release -j "${VORTEX_BUILD_JOBS:-2}")
for arch in $ARCHS; do SWIFT_ARGS+=(--arch "$arch"); done
if [ -n "${VORTEX_SWIFT_BINARY:-}" ]; then
  SWIFT_BINARY="$VORTEX_SWIFT_BINARY"
else
  swift build "${SWIFT_ARGS[@]}"
  SWIFT_BINARY="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)/Vortex"
fi
for arch in $ARCHS; do lipo -verify_arch "$arch" "$SWIFT_BINARY"; done
APP="${VORTEX_BUILD_OUTPUT:-$PWD/build/Red-XAI Vortex.app}"
case "$APP" in *.app) ;; *) echo "VORTEX_BUILD_OUTPUT must name a generated .app bundle." >&2; exit 1;; esac
case "$APP" in /Applications/*|"$HOME/Applications/"*) echo "Build to a staging folder. This script never replaces an installed app." >&2; exit 1;; esac
RESOURCE_SEED="${VORTEX_RESOURCE_SEED:-/Applications/Red-XAI Vortex.app/Contents/Resources}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build
APP_ABS="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
cp "$SWIFT_BINARY" "$APP/Contents/MacOS/Vortex"
# Private executables and both existing RSX runtime packages remain part of a complete release.
if [ -d "$RESOURCE_SEED" ]; then
  for helper in redx-link redx-verify ggml-rpc-server llama-server; do
    if [ -x "$RESOURCE_SEED/$helper" ]; then cp "$RESOURCE_SEED/$helper" "$APP/Contents/Resources/$helper"; fi
  done
  for runtime in rsx-runtime-arm64 rsx-runtime-amd64; do
    if [ -d "$RESOURCE_SEED/$runtime" ]; then ditto --noextattr --norsrc "$RESOURCE_SEED/$runtime" "$APP/Contents/Resources/$runtime"; fi
  done
fi
# Separate private source trees may supply newer helpers than the resource seed.
for pair in "redx-link:$HOME/Projects/redx-link/redx-link" "redx-verify:$HOME/Projects/redx-verify" "ggml-rpc-server:$HOME/Projects/redx-node/llama.cpp/build/bin/ggml-rpc-server" "llama-server:$HOME/Projects/redx-node/llama.cpp/build/bin/llama-server"; do
  helper="${pair%%:*}"; source="${pair#*:}"
  if [ -f "$source" ] && [ -x "$source" ]; then cp "$source" "$APP/Contents/Resources/$helper"; fi
 done
if [ "$SIGN_ID" != "-" ]; then
  for helper in redx-link redx-verify ggml-rpc-server llama-server; do
    [ -x "$APP/Contents/Resources/$helper" ] || { echo "Missing required private helper: $helper (set VORTEX_RESOURCE_SEED)." >&2; exit 1; }
  done
  for runtime in rsx-runtime-arm64 rsx-runtime-amd64; do
    [ -d "$APP/Contents/Resources/$runtime" ] || { echo "Missing required runtime: $runtime (set VORTEX_RESOURCE_SEED)." >&2; exit 1; }
  done
fi
# A build host may supply helpers cross-compiled from this exact source checkout.
# Verify architecture before using them; otherwise build them locally as before.
BASE_PARTS=(); PHONE_PARTS=(); VERIFY_PARTS=()
if [ -n "${VORTEX_GO_HELPER_DIR:-}" ]; then
  for arch in $ARCHS; do
    case "$arch" in arm64) goarch=arm64;; x86_64) goarch=amd64;; *) echo "Unsupported Mac architecture: $arch" >&2; exit 1;; esac
    helper_dir="$VORTEX_GO_HELPER_DIR/darwin-$goarch"
    for helper in vortex-base vortex-phone redx-verify; do
      [ -f "$helper_dir/$helper" ] || { echo "Missing prebuilt helper: $helper_dir/$helper" >&2; exit 1; }
      lipo -verify_arch "$arch" "$helper_dir/$helper"
    done
    BASE_PARTS+=("$helper_dir/vortex-base"); PHONE_PARTS+=("$helper_dir/vortex-phone"); VERIFY_PARTS+=("$helper_dir/redx-verify")
  done
else
  command -v go >/dev/null 2>&1 || { echo "Go is required to package the Base and phone helpers." >&2; exit 1; }
  GO_WORK="$(mktemp -d "${TMPDIR:-/tmp}/vortex-go-helpers.XXXXXX")"
  trap 'rm -rf "$GO_WORK"' EXIT
  for arch in $ARCHS; do
    case "$arch" in arm64) goarch=arm64;; x86_64) goarch=amd64;; *) echo "Unsupported Mac architecture: $arch" >&2; exit 1;; esac
    (cd ../bases && CGO_ENABLED=0 GOOS=darwin GOARCH="$goarch" go build -buildvcs=false -trimpath -ldflags="-s -w" -o "$GO_WORK/base-$arch" .)
    bash ../scripts/build-desktop-with-helper.sh darwin "$goarch" "$GO_WORK/phone-$arch"
    (cd ../desktop && CGO_ENABLED=0 GOOS=darwin GOARCH="$goarch" go build -buildvcs=false -trimpath -ldflags="-s -w" -o "$GO_WORK/verify-$arch" ./cmd/redx-verify)
    BASE_PARTS+=("$GO_WORK/base-$arch"); PHONE_PARTS+=("$GO_WORK/phone-$arch/vortex-darwin-$goarch"); VERIFY_PARTS+=("$GO_WORK/verify-$arch")
  done
fi
lipo -create "${BASE_PARTS[@]}" -output "$APP/Contents/Resources/vortex-base"
lipo -create "${PHONE_PARTS[@]}" -output "$APP/Contents/Resources/vortex-phone"
lipo -create "${VERIFY_PARTS[@]}" -output "$APP/Contents/Resources/redx-verify"
# The phone bridge serves the current frontend, not a previous release's copy.
ditto --noextattr --norsrc ../desktop/frontend "$APP/Contents/Resources/frontend"
IS=build/Vortex.iconset; rm -rf "$IS"; mkdir -p "$IS"
sips -s format png icon.jpg --out build/icon1024.png >/dev/null
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" build/icon1024.png --out "$IS/icon_${s}x${s}.png" >/dev/null
  sips -z "$((s*2))" "$((s*2))" build/icon1024.png --out "$IS/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$IS" -o "$APP/Contents/Resources/AppIcon.icns"
cp redx-256.png "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/Help"; cp help/*.md "$APP/Contents/Resources/Help/"
for guide in RELEASE-2.10 RELEASE-2.11 RELEASE-VERIFICATION MACOS-NOTARIZATION; do
  if [ -f "../docs/$guide.md" ]; then cp "../docs/$guide.md" "$APP/Contents/Resources/Help/$guide.md"; fi
done
if [ -f server/install.sh ]; then cp server/install.sh "$APP/Contents/Resources/install.sh"; elif [ -f "$RESOURCE_SEED/install.sh" ]; then cp "$RESOURCE_SEED/install.sh" "$APP/Contents/Resources/install.sh"; fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Red-XAI Vortex</string>
<key>CFBundleDisplayName</key><string>Red-XAI Vortex</string>
<key>CFBundleIdentifier</key><string>com.redxai.vortex</string>
<key>CFBundleExecutable</key><string>Vortex</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.11.1</string>
<key>CFBundleVersion</key><string>47</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>NSSpeechRecognitionUsageDescription</key><string>With your permission, transcribe selected audio locally when on-device speech recognition is available.</string>
<key>NSMicrophoneUsageDescription</key><string>Voice calls: your speech is transcribed on this Mac by whisper.cpp.</string>
<key>NSAppleEventsUsageDescription</key><string>PC control: open and control apps when you allow it.</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST
cat > build/vortex.entitlements <<'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.device.audio-input</key><true/>
<key>com.apple.security.automation.apple-events</key><true/>
</dict></plist>
ENTITLEMENTS
# The local model helper loads its existing Homebrew OpenSSL libraries. Keep that
# compatibility exception while enabling the hardened runtime required by notarization.
cat > build/llama.entitlements <<'LLAMA_ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.cs.disable-library-validation</key><true/>
</dict></plist>
LLAMA_ENTITLEMENTS
# File-provider metadata must not enter signatures. This touches only the staged output bundle.
xattr -cr "$APP"
while IFS= read -r -d '' binary; do
  case "$(file -b "$binary")" in
    *Mach-O*)
      if [ "$(basename "$binary")" = "llama-server" ]; then
        codesign --force --options runtime "${TIMESTAMP[@]}" --entitlements build/llama.entitlements --sign "$SIGN_ID" "$binary"
      else
        codesign --force --options runtime "${TIMESTAMP[@]}" --preserve-metadata=entitlements --sign "$SIGN_ID" "$binary"
      fi;;
  esac
done < <(find "$APP/Contents/Resources" -type f -print0)
codesign --force --options runtime "${TIMESTAMP[@]}" --entitlements build/vortex.entitlements --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP"
for binary in "$APP/Contents/MacOS/Vortex" "$APP/Contents/Resources/vortex-base" "$APP/Contents/Resources/vortex-phone" "$APP/Contents/Resources/redx-verify"; do
  for arch in $ARCHS; do lipo -verify_arch "$arch" "$binary"; done
done
codesign -dv "$APP" 2>&1 | sed -n '/Authority=/p; /Signature=/p; /TeamIdentifier=/p'
echo "Built staged app: $APP_ABS"
