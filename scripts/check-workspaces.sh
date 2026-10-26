#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
for component in bases desktop gateway; do
  (cd "$component" && go test -buildvcs=false ./... && go vet -buildvcs=false ./...)
done
node --check desktop/frontend/app.js
node --check desktop/frontend/workspace.js
node --test desktop/frontend/workspace.test.cjs
if [[ "$(uname -s)" == Darwin ]]; then
  # Copy source bytes without Finder/file-provider metadata. This also avoids
  # SwiftPM's Git scan and generated XCTest bundle signing issues in synced folders.
  python3 - <<'PY'
import pathlib, shutil, subprocess, tempfile
source = pathlib.Path('app').resolve()
def copy_bytes(source, destination):
    # shutil.copyfile uses macOS fcopyfile, which can time out on file-provider
    # managed sources. Plain reads/writes also avoid copying extended attributes.
    with open(source, 'rb') as incoming, open(destination, 'wb') as outgoing:
        while block := incoming.read(1024 * 1024):
            outgoing.write(block)
    return destination
with tempfile.TemporaryDirectory(prefix='vortex-native-check-') as directory:
    target = pathlib.Path(directory)
    copy_bytes(source / 'Package.swift', target / 'Package.swift')
    for name in ('Sources', 'Tests'):
        shutil.copytree(source / name, target / name, copy_function=copy_bytes)
    subprocess.run(['swift', 'test', '--package-path', str(target), '-j', '2'], check=True)
PY
else
  printf '%s\n' 'Native SwiftUI validation requires macOS; Go and web checks passed.'
fi
