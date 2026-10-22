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

- **Red-XAI**: training mode (off by default), teach it, the crawler, versions and the benchmark.
- **Servers**: add a VPS (user@host + SSH key) and click **Install / Update** to run `server/install.sh` over SSH. The admin key is saved to the Keychain automatically. **Use** switches servers. With failover on, a chat that can't reach its server retries on the next one that answers, then on a local model.

## Local mode
Models downloaded to **This Mac** (from the model browser) appear as `local:<id>` in the chat model picker. Dolphino starts the
bundled `llama-server` (Metal) only when you chat with one, stops it after 5 idle minutes, and kills it (and every SSH tunnel) on quit.

Settings → Chat: "Show replies only when finished" (on by default). Merges show "Thinking with N models…" while they work.
