#!/usr/bin/env bash
set -euo pipefail
PREFIX="${PREFIX:-$HOME/.local}"
mkdir -p "$PREFIX/bin" "$PREFIX/share/red-xai-vortex"
cp -a frontend "$PREFIX/share/red-xai-vortex/"
install -m 755 vortex-linux-amd64 "$PREFIX/bin/vortex"
if [ -f redx-link ]; then install -m 755 redx-link "$PREFIX/bin/redx-link"; fi
if [ -f vortex-base ]; then install -m 755 vortex-base "$PREFIX/bin/vortex-base"; fi
if [ -d rsx-runtime ]; then rm -rf "$PREFIX/bin/rsx-runtime"; cp -a rsx-runtime "$PREFIX/bin/rsx-runtime"; fi
cat > "$PREFIX/bin/vortex-app" << E
#!/usr/bin/env bash
export VORTEX_FRONTEND="$PREFIX/share/red-xai-vortex/frontend"
exec "$PREFIX/bin/vortex" "\$@"
E
chmod +x "$PREFIX/bin/vortex-app"
# desktop entry
DESKTOP_ENTRY_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$DESKTOP_ENTRY_DIR"
cat > "$DESKTOP_ENTRY_DIR/red-xai-vortex.desktop" << E
[Desktop Entry]
Name=Red-XAI Vortex
Comment=Red-XAI Vortex desktop
Exec=$PREFIX/bin/vortex-app
Icon=applications-internet
Terminal=false
Type=Application
Categories=Network;Utility;
E
echo "Installed. Run: vortex-app"
