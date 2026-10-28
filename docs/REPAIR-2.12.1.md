# Vortex 2.12.1 account, MCP and editor repair

## Security changes

A saved owner/admin credential no longer bypasses Red-XAI account authentication. The owner shortcut was removed from the signed-out UI. Native Mac preferences, stored files and Keychain names are scoped to a SHA-256 identifier derived from the verified account issuer and immutable subject. An account change retires active tasks and restarts the native process before rendering the new profile. Temporary Quick Login grants use a bounded anonymous-pipe handoff across that restart, not disk, command arguments or environment variables.

The Go desktop now enforces authentication at the HTTP entrypoint, rather than relying on the login overlay. Each account has an immutable Server/Store pair, private credentials and an independent activity log. Browser request epochs reject stale tabs. Run listing/cancellation, media-result caches, settings, agents, hosts and MCP connections are account-scoped. Logout retires local runs, MCP sessions, managed hosts and phone sessions. Late completions retain their original account store and cannot write into the newly signed-in account.

New account credentials on Windows/Linux use the operating system secret store through go-keyring. There is no plaintext or environment fallback for profile-scoped credentials. Existing legacy login-coordinator storage remains for compatibility and is never inherited as a model/admin key by another account.

**Legacy data:** old unscoped data remains untouched. It is not automatically assigned to the first person who signs in after upgrading, because its owner cannot be established safely. A newly isolated account may therefore begin with default settings until its own configuration is entered or deliberately imported. No old chats, agents or keys were deleted by this repair.

## MCP settings

Both native and cross-platform desktop editors support local stdio and remote Streamable HTTP. Name, transport, and the applicable URL or command remain required. API keys and advanced settings are optional. Options include Bearer access tokens, custom key headers, local environment keys, custom headers/environment, argument arrays, working directories, connection/tool timeouts, protocol version, enabled state, and automatic connection. Inheriting the entire process environment is an explicit opt-in.

Firecrawl presets use `https://mcp.firecrawl.dev/v2/mcp` with Bearer authentication, or `npx -y firecrawl-mcp` with `FIRECRAWL_API_KEY`. The editor does not embed credentials in URLs. Bearer token entry is not a browser OAuth enrollment implementation. Legacy standalone HTTP+SSE endpoints are not advertised as supported; Streamable HTTP JSON/SSE responses are supported.

Credentials are stored separately from configuration JSON. Blank credential inputs retain the existing value; explicit removal clears them. Standard MCP JSON imports retain existing servers and start imported connections disabled. Tests initialize and discover tools without executing a provider tool. Runtime calls preserve existing agent approval controls; tools without an explicit safe read-only annotation require approval. Redirects never forward credentials.

## Scroll/accessibility changes

The native agent editor and MCP form have explicit scroll containers. The shared desktop has visible scrollbar styling and constrained scrollable editors/dialogs. The Save actions in both agent and MCP panels were measured as reachable in an isolated Chrome fixture at 1280×720, 900×540, and 640×480.

## Verification

- 66 native Swift tests passed, including actual local stdio and HTTP/SSE MCP fixtures, bearer auth, pagination, session reuse, cancellation, redirect rejection, account switching and unsafe-header validation.
- All Go desktop package tests passed, including two-account data/credential/run isolation, stale request rejection, MCP transport fixtures and media-cache isolation.
- 32 shared frontend tests passed.
- Six browser layout checks passed across the three window sizes.

These fixture tests are not a claim that a real Firecrawl API key was entered or that two real customer accounts were used. Native Windows/Linux UI and OS-secret-store behavior require those platform environments. Release signing, notarization, installation and publication are separate checks and must be reported from the actual build results.

Shared Accounts, RedX, Quick Login and Red-SecretsXAI repositories were not modified.
