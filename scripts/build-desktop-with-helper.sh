#!/usr/bin/env bash
# Build one desktop target with its matching Base helper embedded and adjacent.
# Example: VORTEX_VERSION=2.11 ./scripts/build-desktop-with-helper.sh linux amd64 /tmp/vortex-linux
# Official private release-verifier registration can be supplied as a trusted
# source overlay; this script never creates a signing key or disables verification.
set -euo pipefail
if [ "$#" -ne 3 ]; then echo 'Usage: build-desktop-with-helper.sh linux|windows|darwin amd64|arm64 OUTPUT_DIRECTORY' >&2; exit 2; fi
TARGET_OS="$1"; TARGET_ARCH="$2"; OUTPUT_DIR="$3"
case "$TARGET_OS" in linux|windows|darwin) ;; *) echo 'Unsupported target OS' >&2; exit 2;; esac
case "$TARGET_ARCH" in amd64|arm64) ;; *) echo 'Unsupported architecture' >&2; exit 2;; esac
RELEASE_VERSION="${VORTEX_VERSION:-2.11}"
case "$RELEASE_VERSION" in ''|*[!0-9.]*) echo 'VORTEX_VERSION must be numeric dotted version' >&2; exit 2;; esac
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
BUILD_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/vortex-platform-build.XXXXXX")"
trap 'rm -rf "$BUILD_STAGE"' EXIT
cp -R "$REPO_DIR/desktop" "$BUILD_STAGE/desktop"
if [ -n "${VORTEX_DESKTOP_OVERLAY:-}" ]; then
  if [ ! -d "$VORTEX_DESKTOP_OVERLAY" ]; then echo 'VORTEX_DESKTOP_OVERLAY must be an existing trusted directory' >&2; exit 2; fi
  cp -R "$VORTEX_DESKTOP_OVERLAY/." "$BUILD_STAGE/desktop/"
fi
HELPER_NAME='vortex-base'
APP_NAME="vortex-$TARGET_OS-$TARGET_ARCH"
if [ "$TARGET_OS" = windows ]; then HELPER_NAME='vortex-base.exe'; APP_NAME='vortex.exe'; fi
(
 cd "$REPO_DIR/bases"
 GOWORK=off CGO_ENABLED=0 GOOS="$TARGET_OS" GOARCH="$TARGET_ARCH" go build -trimpath -buildvcs=false -o "$OUTPUT_DIR/$HELPER_NAME" .
)
cp "$OUTPUT_DIR/$HELPER_NAME" "$BUILD_STAGE/desktop/internal/bridge/base-helper.asset"
cat > "$BUILD_STAGE/desktop/internal/bridge/base_helper_official.go" <<'GO'
package bridge
import _ "embed"
//go:embed base-helper.asset
var officialEmbeddedBaseHelper []byte
func init() { BundledBaseHelper = officialEmbeddedBaseHelper }
GO
(
 cd "$BUILD_STAGE/desktop"
 if [ -n "${VORTEX_RSX_SDK:-}" ]; then go mod edit "-replace=redsecretsxai=$VORTEX_RSX_SDK"; fi
 GOWORK=off CGO_ENABLED=0 GOOS="$TARGET_OS" GOARCH="$TARGET_ARCH" go build -trimpath -buildvcs=false -ldflags "${VORTEX_BUILD_LDFLAGS:-} -X github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/update.Version=$RELEASE_VERSION" -o "$OUTPUT_DIR/$APP_NAME" ./cmd/vortex
)
printf 'Built %s and %s for %s/%s\n' "$APP_NAME" "$HELPER_NAME" "$TARGET_OS" "$TARGET_ARCH"
printf 'Release verification registration is preserved from source/overlay; sign the final release manifest separately.\n'
