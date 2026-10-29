# Vortex 2.12.2 — Windows connection repair

This repair was driven from a native Windows Shadow PC after the published 2.12.1 archive launched successfully but model access returned HTTP 401.

## Fixes

- Windows/Linux now default to the public DNS gateway at `https://ai.red-xai.com/v1`.
- Existing raw-IP gateway settings for `45.77.105.187` are migrated to the DNS endpoint and persisted.
- A signed-in account with no profile-scoped Vortex model key is reported as **API key required**, not merely **offline**.
- Status no longer sends an unauthenticated `/models` request when no model key exists.
- Test Connection, Vortex E2E testing and Vortex chat stop locally with a precise message when the profile has no `redx_ai_…` or `redx_xai_…` key.
- Saving non-key connection settings no longer claims that a key was stored when none exists.
- Settings explains that Red-XAI account authentication and Vortex model-gateway authorization are intentionally separate.
- Account isolation remains intact: no legacy global key is silently assigned to a newly signed-in account.

## Regression coverage

New Go tests cover DNS endpoint defaults/migration, preservation of custom gateways, missing-key status/probe behavior and draft preservation when chat is blocked locally for a missing model key. Windows CI builds 2.12.2 and exercises the native startup and browser-based authentication flow.
