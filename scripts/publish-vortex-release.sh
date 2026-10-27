#!/usr/bin/env bash
# Publish a COMPLETE official Vortex release. Run only on the authenticated
# macOS signing host, after signing, Apple notarization and stapling.
# No keys or unsigned binaries are published by this script.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: bash scripts/publish-vortex-release.sh VERSION /absolute/final-assets-directory" >&2
  exit 2
fi
VERSION="$1"
ASSETS="$2"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version must be x.y.z" >&2; exit 2; }
[ "$(uname -s)" = "Darwin" ] || { echo "Official publishing requires a macOS signing/notarization host" >&2; exit 2; }
command -v gh >/dev/null || { echo "GitHub CLI (gh) is required" >&2; exit 2; }
command -v go >/dev/null || { echo "Go is required to verify all signed assets" >&2; exit 2; }
[ -d "$ASSETS" ] || { echo "Release assets directory missing" >&2; exit 2; }
ASSETS="$(cd "$ASSETS" && pwd -P)"
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$REPO"
EXPECTED="grimvirusoffical-source/red-xai-vortex"
test "$(gh repo view --json nameWithOwner -q .nameWithOwner)" = "$EXPECTED" || { echo "Wrong GitHub repository" >&2; exit 2; }

COMMIT="$(git rev-parse HEAD)"
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || exit 2
[ -z "$(git status --porcelain)" ] || { echo "Release checkout must be clean" >&2; exit 2; }
[ "$(git branch --show-current)" = "main" ] || { echo "Publish from main only" >&2; exit 2; }
git fetch origin main --quiet
[ "$COMMIT" = "$(git rev-parse origin/main)" ] || { echo "Checkout is not current main" >&2; exit 2; }
# A signed release must be based on a source commit where the complete
# Windows/Linux/Mac CI suite actually finished successfully.
RUNS="$(gh run list --repo "$EXPECTED" --workflow vortex-native.yml --commit "$COMMIT" --json status,conclusion --limit 20)"
python3 - "$RUNS" <<'PY'
import json,sys
runs=json.loads(sys.argv[1])
assert any(x["status"]=="completed" and x["conclusion"]=="success" for x in runs), "Cross-platform CI has not passed for this source commit"
PY
if gh release view "v$VERSION" >/dev/null 2>&1; then
  echo "Release v$VERSION already exists; refusing overwrite" >&2
  exit 2
fi

WIN="$ASSETS/Red-XAI-Vortex-windows-amd64.zip"
LINUX="$ASSETS/Red-XAI-Vortex-linux-amd64.tar.gz"
MACZIP="$ASSETS/Vortex-$VERSION-mac.zip"
MACDMG="$ASSETS/Vortex-$VERSION-mac.dmg"
MANIFEST="$ASSETS/release-manifest.json"
SIG="$ASSETS/release-manifest.sig"
SUMS="$ASSETS/SHA256SUMS"
for file in "$WIN" "$LINUX" "$MACZIP" "$MACDMG" "$MANIFEST" "$SIG" "$SUMS"; do
  [ -f "$file" ] && [ -s "$file" ] && [ ! -L "$file" ] || { echo "Missing regular release asset: $file" >&2; exit 2; }
done

# Do not accidentally publish an older package with a newly named archive.
python3 - "$WIN" "$LINUX" "$MACZIP" "$VERSION" "$MANIFEST" "$COMMIT" <<'PY'
import json, pathlib, plistlib, sys, tarfile, zipfile
win, linux, mac, version, manifest, commit = sys.argv[1:]
m = json.loads(pathlib.Path(manifest).read_text())
assert m.get("version") == version and m.get("sourceCommit") == commit, "Signed manifest doesn't match release source"
for name in ("Red-XAI-Vortex-windows-amd64.zip", "Red-XAI-Vortex-linux-amd64.tar.gz", f"Vortex-{version}-mac.zip", f"Vortex-{version}-mac.dmg"):
    assert name in m["assets"], "Signed manifest missing " + name
checksums = pathlib.Path(manifest).with_name("SHA256SUMS").read_text().splitlines()
expected_checksums = {f"{digest}  {name}" for name, digest in m["assets"].items()}
assert set(checksums) == expected_checksums, "SHA256SUMS does not match the authenticated manifest"
with zipfile.ZipFile(win) as z:
    names = set(z.namelist())
    for entry in ("vortex.exe", "vortex-base.exe", "redx-link.exe", "frontend/index.html", "frontend/app.js"):
        assert entry in names, "Missing Windows asset: " + entry
    assert any(x.startswith("rsx-runtime/") for x in names), "Windows private runtime missing"
    assert "accountLogOut" in z.read("frontend/index.html").decode(), "Windows logout control missing"
with tarfile.open(linux, "r:gz") as t:
    names = set(t.getnames())
    for entry in ("vortex", "vortex-linux-amd64", "vortex-base", "redx-link", "install.sh", "frontend/index.html", "frontend/app.js"):
        assert entry in names, "Missing Linux asset: " + entry
    assert any(x.startswith("rsx-runtime/") for x in names), "Linux private runtime missing"
    assert "accountLogOut" in t.extractfile("frontend/index.html").read().decode(), "Linux logout control missing"
with zipfile.ZipFile(mac) as z:
    name = next((x for x in z.namelist() if x.endswith(".app/Contents/Info.plist")), None)
    assert name, "Mac application bundle not found"
    info = plistlib.loads(z.read(name))
    assert info["CFBundleShortVersionString"] == version, "Mac bundle version mismatch"
    assert any(x.endswith(".app/Contents/Resources/redx-link") for x in z.namelist()), "Mac secure helper missing"
PY

TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
ditto -x -k "$MACZIP" "$TEMP"
APP="$(find "$TEMP" -type d -name "*.app" -print -quit)"
[ -n "$APP" ] || { echo "No Mac app bundle in archive" >&2; exit 2; }
codesign --verify --deep --strict "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
codesign --verify "$MACDMG"
xcrun stapler validate "$MACDMG"
hdiutil verify "$MACDMG"

# These checks validate the owner's existing Ed25519 signature and exact bytes.
for file in "$WIN" "$LINUX" "$MACZIP" "$MACDMG"; do
  (cd desktop && go run ./cmd/redx-verify "$MANIFEST" "$SIG" "$file")
done

# No GitHub Release is created until every package and trust check passes.
gh release create "v$VERSION" "$WIN" "$LINUX" "$MACZIP" "$MACDMG" "$MANIFEST" "$SIG" "$SUMS" \
  --repo "$EXPECTED" --target "$COMMIT" --latest \
  --title "Red-XAI Vortex $VERSION — macOS, Windows and Linux" \
  --notes "Cross-platform account switching and authenticated chat fixes. macOS Developer ID signed, notarized and stapled. All four packages verified against the existing Ed25519-signed manifest."
echo "Published official signed release v$VERSION from $COMMIT"
