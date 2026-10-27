# Vortex 2.11.4 — all-platform logout and chat access repair

Release candidate source for macOS, Windows and Linux. This file **does not announce a published release**; publication requires final signed packages, tests and a release asset manifest.

## Account switching (every desktop platform)

- **macOS**: the visible sidebar **Log out** button and the native app's **Sign Out of RedX** menu command clear the current Red-XAI login. An existing owner key is retained, but cannot silently reopen Vortex after a deliberate logout. Sign in with Quick Login or password/MFA, or explicitly choose owner mode.
- **Windows and Linux**: the shared browser desktop now exposes **Log out** in the always-visible top toolbar; the older footer entry remains functional. Logout is local/same-origin only, clears browser-approved and legacy sessions, and persists the account switch across restarts. Owner mode is still available via an explicit choice.
- A logged-out Mac phone companion no longer silently reuses the previous login from its original process environment.
- Local chats/projects and separate model API keys are not deleted during logout. Red-XAI website sign-in and Vortex's gateway API key are distinct: signing in with a website account does not by itself grant or change API key permissions.

## HTTP 403 and model access

- Windows/Linux chat and agent/group messages now show the actual gateway refusal instead of a fabricated assistant reply or just an HTTP status.
- macOS chat and model-list requests now explain 401 versus 403, including allowed models, chat scope and IP/device policy.
- Replacing a gateway API key restarts the secure RedX Link helper on Windows, Linux and macOS so it cannot keep an outdated key. The Mac helper passes the active Keychain credential through its process environment, not command-line arguments or logs.
- Mini, Standard and Pro tier routing uses the model scopes already granted by the gateway. **Existing bans, IP restrictions and key restrictions are not bypassed.**
- Authentic 403s imposed by server policy still need the owner to inspect the server's access controls and resolve the underlying condition.

## Verification and release gate

Automated tests run Go desktop + frontend suites on Windows/Linux, Swift native tests on macOS, gateway tier-policy tests and real Microsoft Edge startup/login smoke tests on Windows x64 and Windows 11 ARM. These are source/build checks; they are not a substitute for testing the affected customer's actual gateway policy.

A valid official GitHub release requires complete final artifacts:

- `Red-XAI-Vortex-windows-amd64.zip`, with current exe, embedded Base helper, frontend, RedX Link and the complete private runtime.
- `Red-XAI-Vortex-linux-amd64.tar.gz`, with both executable-name variants, frontend, installer, RedX Link, Base helper and private runtime.
- `Vortex-2.11.4-mac.zip` and `Vortex-2.11.4-mac.dmg`, with universal native app and helper binaries, Developer ID signature, hardened runtime, Apple notarization and stapled tickets.
- `release-manifest.json`, `release-manifest.sig` signed by the **existing approved Ed25519 release key**, and `SHA256SUMS` matching the exact uploaded archive bytes.

Do not generate a new signing key or claim an unsigned preview ZIP is an official auto-update. The complete publisher, `scripts/publish-vortex-release.sh`, verifies the signed assets and macOS Gatekeeper acceptance before creating a GitHub release. It runs only on the authorized macOS signing machine, and requires the existing owner-controlled credentials.
