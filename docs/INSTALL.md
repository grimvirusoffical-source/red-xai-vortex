# Installing Red-XAI Vortex 2.2

All downloads: the GitHub release **v2.2** or https://45.77.105.187/vortex/ . Verify with `SHA256SUMS`:
`shasum -a 256 -c SHA256SUMS` (macOS/Linux) or `Get-FileHash <file> -Algorithm SHA256` (Windows PowerShell).

## macOS (14 Sonoma or newer, Apple silicon and Intel)
1. Download `Vortex-2.2-mac.dmg` (or the `.zip`).
2. Open the dmg and drag **Red-XAI Vortex** into **Applications**.
3. Launch it. The app is signed with a Developer ID. If macOS says it cannot check the app for malware,
   right-click the app → **Open** → **Open** once (the 2.2 build is signed but not yet notarized).
4. Accept the Terms of Service, then sign in with your red-xai.com account ([SIGN-IN.md](SIGN-IN.md)).

## Windows 10/11 (x64)
1. Download `Red-XAI-Vortex-windows-amd64.zip` and extract it anywhere (e.g. `C:\Program Files\Red-XAI Vortex`).
2. Run `vortex.exe`. It opens the Vortex window in your default browser engine; keep the `frontend` folder next to the exe.
3. SmartScreen may warn about an unrecognised app: **More info → Run anyway**.
4. Accept the Terms and sign in.

## Linux (x86_64)
```bash
tar xzf Red-XAI-Vortex-linux-amd64.tar.gz -C vortex && cd vortex
./install.sh            # installs to ~/.local (PREFIX=/usr/local sudo ./install.sh for system-wide)
red-xai-vortex          # or launch "Red-XAI Vortex" from your app menu
```
Needs a desktop browser (xdg-open) or `vortex-webview` if installed. `-headless` serves the UI only.

## Server (optional, for self-hosting models)
See [SERVER-LINUX.md](SERVER-LINUX.md), [SERVER-MAC.md](SERVER-MAC.md), [SERVER-WINDOWS.md](SERVER-WINDOWS.md).
