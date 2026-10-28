# Red-XAI Vortex 2.12.0 — Intelligent Agents and Team Workspaces

This release introduces a unified agent creator and real background execution alongside the cross-platform account/logout and authenticated-chat fixes prepared for 2.11.4. Official update packages are published **only after** Developer ID signing, Apple notarization/stapling, current source CI, full private runtime packaging, and manifest signature verification against the existing pinned Ed25519 release key.

## Unified agent creator on macOS, Windows and Linux

Agents now have one entry point for **name, instructions, task, model selection, tool permissions, recurring schedule, execution location, optional external provider API key and a prominent emergency stop**. Existing chat agents and server background agents retain their profiles and can be managed without creating competing types of agent.

**Automatic intelligence** chooses from authenticated/available coding, reasoning, writing, vision and general models. **Mix mode** adds a second permitted planning specialist, with the executor alone allowed to use approved tools. The gateway still decides whether a key may use each model; no plan can override model authorization.

## Background and Cloud PC tasks

Local jobs can run while the desktop app is open. They use the host OS's per-action approvals, never silently type into the user's currently focused app, and stop when the agent is paused.

Server jobs continue when the app is closed, but are **model-only** (they cannot magically control another computer). The new opt-in Linux Cloud PC worker authenticates with the user's **chat + cloudpc** API key, receives revocable, expiring task leases, and executes only owner-permitted tasks inside its own workspace and isolated Playwright Chromium profile. Tool observations and cancellation responses are verified; unsupported/unauthorized actions report blockers rather than fictional completion.

**Important:** Cloud PC execution requires the worker to be installed and running in an approved Cloud PC. A Cloud PC that stops when idle also stops its worker. External API provider adapters and browser sign-in sessions are not installed or automatically authenticated by upgrading Vortex. See [Cloud PC agent worker](CLOUD-PC-AGENT-WORKER.md).

## Teams with one leader

Separate agent group chats can have dedicated project workspaces, one leader, and multiple agents/models. The leader delegates subtasks; each worker uses only its saved permissions; and the leader provides a final report that distinguishes tool-confirmed completion from pending approvals, failures and unexecuted suggestions. Existing party chats remain readable.

## PC control and global Stop

Mac keyboard injection now verifies the target process and focused element; browser typing requires the intended tab URL and refuses unverified search/address input. The model does not receive a user's browser/account password.

**Stop All Agents** persists locally, cancels the current local work before network calls, disables unattended PC control and sends a single authenticated request to revoke the account's remote schedules and outstanding worker leases. If the remote gateway is unreachable, the app explicitly warns that remote cancellation was **not verified**. Stop cannot reverse already completed external actions.

## Cross-platform account and chat repair

This source also includes the pending 2.11.4 fixes for Mac/Windows/Linux logout/account switching, secure helper API-key refresh, and clearer 401/403 access-denied errors. These fixes never bypass valid IP restrictions, model restrictions, expired credentials or chat scopes.

## Release and authenticity

All three platform builds must pass current-source automated tests; the complete Windows/Linux/Mac packages must include their private RSX runtimes, frontends and helper executables. The final Mac app must be Apple Developer ID signed, notarized and stapled. All four final packages must be listed in a SHA256SUMS file and signed manifest with the **existing** owner-approved Ed25519 private key, which remains outside the repository. Do not install a manual test package as if it were an updater-signed stable release.

Review the [agent guide](AGENTS.md) and [Cloud PC worker setup](CLOUD-PC-AGENT-WORKER.md) for the required scopes and explicit host permissions.
