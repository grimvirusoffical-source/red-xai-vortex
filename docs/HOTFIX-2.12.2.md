# Vortex 2.12.2 — native startup crash hotfix

## Cause

On macOS, a newly isolated account can legitimately have the default model-server placeholder `root@YOUR_SERVER`. In 2.12.1, ServerStore.init called activate synchronously when that placeholder failed validation, even when the selected fallback was the same placeholder. When the account was signed in and RedX Link was enabled, activate started RedXLink, whose serverList read ServerStore.shared while its one-time initialization was still running. libdispatch deliberately trapped with “trying to lock recursively”. Opening the MCP/Settings interface could initialize the Servers view and expose this independent model-server startup bug.

## Fix

ServerStore initialization now loads and repairs configuration only. It never activates a server, starts a monitor, accesses the account gate, or starts RedX Link. Model connections start explicitly after verified sign-in or when the Servers view becomes active, once the singleton exists. Startup is idempotent; stopping resets it and cancels its monitor. Placeholder and signed-out connections cannot start SSH tunnels. Fallback selects only a usable primary server and preserves link-only servers that do not use SSH.

No account data, MCP entry, credentials or shared-library repositories are reset or removed by this code fix. Firecrawl HTTP authentication errors remain connection errors rather than application startup errors. For an API-key connection, Firecrawl documents https://mcp.firecrawl.dev/v2/mcp with a Bearer header; its /v2/mcp-oauth endpoint is for browser sign-in.

## Regression verification

71 native Swift tests passed in an isolated account directory, including five new checks for saved enabled Firecrawl configuration plus the model-server placeholder, usable-primary fallback, link-only setup, signed-out startup, and stopping/idempotence. Existing MCP stdio, HTTP/SSE, account-isolation and credential-validation tests passed.

Mac signing, notarization, installed-app relaunch, real-provider connection and published release status must be verified separately from test results. A connection-test credential lookup was blocked by the host; no key was printed or changed. The user's non-secret Firecrawl URL correction is a backed-up local configuration repair, not a credential migration.
