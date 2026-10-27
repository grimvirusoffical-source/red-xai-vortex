# Windows Vortex: full-package testing and troubleshooting

The latest public Vortex package is on the [2.11.3 GitHub release](https://github.com/grimvirusoffical-source/red-xai-vortex/releases/tag/v2.11.3). **Download the whole Windows ZIP and extract it to a folder.** Launch `vortex.exe` beside `vortex-base.exe`, `redx-link.exe`, `frontend/` and `rsx-runtime/`; Windows cannot run the entire application directly from inside the compressed ZIP.

## What a successful launch does

The Windows Go desktop opens the account/login interface in the system's default browser, with a private, loopback-only desktop bridge. It is not the native Swift macOS UI; it still requires the user's browser to display Vortex. It must not send any browser to a public HTTP IP for local app controls.

Accept the Terms, then choose **Quick sign in with Red-XAI**. The desktop starts a PKCE request for the distinct `vortex` application. In the browser, approve the request with an already signed-in Red-XAI account or use the website login. Users can still use existing password and MFA authentication. Browser/OS security rules may prevent closing tabs created outside a user click.

## Useful failure details from a tester

Ask the tester to note whether (1) Windows blocks the executable, (2) the app starts but no browser opens, (3) the sign-in form doesn't appear, (4) Quick Login produces an error, or (5) sign-in completes but the workspace stays blocked. Screenshots of error text are useful; screenshots of actual authorization links, QR codes, access tokens, passwords and browser cookies are **not**.

On a trusted Windows machine, from **Windows Terminal** opened in the extracted folder:

```powershell
.\vortex.exe -no-update
```

Vortex should report its version and the local bridge address. After the Windows ShellExecuteW launcher change, if opening the default browser fails, it prints a clear message and the address the tester can open locally; no browser or local server needs to be made public. Do not change firewall settings or disable Microsoft Defender/SmartScreen simply to make an untrusted executable run. Record any SmartScreen notice, including the displayed publisher/signature information.

## Repeatable Windows CI

`.github/workflows/vortex-native.yml` includes source tests and **published-package** end-to-end tests using both Windows x64 and Windows 11 Arm runners. They download the exact public ZIP, cryptographically verify it against the release's signed manifest, extract the entire archive, start Vortex in normal (non-headless) mode and launch real Microsoft Edge to click through Terms, Quick Login, approval-link creation and cancellation. Production account authorization is never completed with fake credentials. This catches broken startup/browser integration that a headless-only test would miss.

On an Apple Silicon Mac, **Parallels Desktop + Windows 11 on Arm** can run many x64 apps through emulation and is generally easier for this kind of interactive test than VirtualBox. However, a real x64 Windows computer is still needed to validate hardware-specific behavior and security products. Keep adequate disk space for the VM.
