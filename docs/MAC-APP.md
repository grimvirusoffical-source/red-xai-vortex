# Dolphino for macOS

Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`).

```bash
cd app
./build.sh                                   # ad-hoc signature
SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./build.sh   # or put that string in app/.sign-id
cp -R build/Dolphino.app /Applications/
```

## Connect
- **Settings → Connection**: SSH host `root@YOUR_SERVER`, key `~/.ssh/id_ed25519`, local port 18092, remote port 8092 (the gateway admin port). Dolphino keeps an SSH tunnel open, so no model port is ever exposed.
- Store the admin key from `/root/dolphino-admin.key` in the API key field. It's saved in the macOS Keychain.
- Optional: `defaults write com.redxai.dolphino publicBaseURL https://YOUR_DOMAIN/v1` so the docs tab shows your public URL.

## Windows
**Library, Merges & Keys** (⇧⌘L, or the books icon in the toolbar) has these tabs:
- **Library**: browse by category and Download / Uninstall / Set Default, with download progress and disk usage.
- **Merges**: build ensembles (mode, models, judge). They appear in the chat model picker.
- **Providers**: add outside OpenAI-compatible services, with a Test button.
- **API Keys**: create (shown once), list with usage, and revoke.
- **Use in Other Apps**: copy-paste setups for OmniRoute, Continue, Cline and Python.

Settings → Chat: "Show replies only when finished" (on by default). Merges show "Thinking with N models…" while they work.
