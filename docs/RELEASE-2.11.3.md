# Vortex 2.11.3 — Red-XAI Quick Login repair

This release repairs the distributed Windows browser-based sign-in controls and ships the shared Red-XAI Quick Login integration on Mac and Windows, using a dedicated `vortex` client ID and `vortex.app` scope. It does not reuse GenDragoon storage tokens.

## Account flow

Use **Quick sign in with Red-XAI** to open an approval request on `https://red-xai.com`. If already signed in on the website, review the application and scope; otherwise use the existing sign-in/register flow. The page presents per-app device trust, expiration and revocation. With the **default browser** on the Go desktop, Vortex opens a script-created tab; after approval the website can close it and focus its opener. When choosing a different installed browser, the OS opens that browser and automatic tab closure may be blocked by that browser's security policy. On the native Mac app, Vortex activates itself and can hide the browser it opened once approval succeeds, where the OS permits.

The existing password + MFA sign-in remains a fallback. Vortex does not store Red-XAI website cookies or ask users for their website password in Quick Login mode.

## Windows release validation

- Native Windows job must run the Go tests and the frontend regression suite, compile the matching embedded Base helper, **launch the real `vortex.exe` on Windows**, and verify the served login controls.
- Preserve the complete release archive layout: `vortex.exe`, `vortex-base.exe`, `redx-link.exe`, `frontend/`, `rsx-runtime/` and related original DLLs.
- Verify the exact final archive checksum and the separately signed Ed25519 release manifest before publishing.
- Mac app version `2.11.3`, build `49`, must be built for both architectures, Developer ID signed, notarized, stapled and verified. Signed release manifests must name the exact shipped assets. Never bypass Gatekeeper or updater signature verification.

## Compatibility and limitations

The public shared-account approval service currently supports built-in app IDs `gendragoon` and `vortex` plus the developer-key registration API. Other Red-XAI desktop applications need their own client adapters before Quick Login is universal at the app-installation level. Existing app secrets and owner-only controls remain isolated. A browser may refuse to close a tab it did not allow a script to open. This release does not confer website owner privileges or bypass database/hosting subscription requirements.
