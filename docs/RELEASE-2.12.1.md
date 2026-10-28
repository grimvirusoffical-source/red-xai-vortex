# Red-XAI Vortex 2.12.1 — account boundaries and MCP authentication

## Account isolation

Vortex now selects a workspace only after the account service verifies a stable account subject. The workspace, agents, chats, projects, settings, cached media and credentials are bound to that identity. A saved machine-wide administrator key no longer opens the sign-in gate. The owner shortcut is hidden at sign-in and its old backend action refuses access.

On macOS, switching accounts intentionally restarts the app after stopping account-owned agents, MCP clients and helpers. The selected profile is immutable for that process lifetime, preventing an old singleton or asynchronous callback from writing into a new account. Windows/Linux use a per-login workspace lease, stop old account-owned resources, and reject late results from a previous session. Presentation preferences and agent/MCP editor state are cleared or account-scoped.

New account-scoped credentials use the operating system credential store. On Windows this is Credential Manager; on Linux a functioning Secret Service must be available. A credential-store failure is shown instead of silently writing a plaintext fallback. Tests use a mock credential store only inside test binaries.

### Existing data

Old unscoped data and credentials are deliberately left untouched. They are not automatically attributed to the first account that signs in after this update. A new profile can therefore start empty and need its own API keys entered. This prevents a different account from inheriting the previous owner's settings. This change isolates Vortex accounts inside the application; it does not protect against a person who already has full access to the same operating-system user account.

## MCP connection settings

The essentials remain required: name/ID and the selected transport's URL or executable. Authentication is optional: None, Bearer API key/token, custom API-key header, HTTP Basic, or a named environment variable for local stdio servers. Additional headers, environment variables, executable arguments, working directory, protocol version, initialization/call timeouts and automatic connection controls are available with defaults.

Firecrawl presets:

- Remote: `https://mcp.firecrawl.dev/v2/mcp`, Bearer authentication, key entered in the protected API-key field.
- Local: the official `firecrawl-mcp` command with `FIRECRAWL_API_KEY` supplied as an environment variable. Windows command-launch requirements still apply.

Credentials are excluded from exported connection JSON and ordinary status results. Key-bearing HTTP redirects are not followed. Session IDs and negotiated protocol versions are retained; tool discovery handles pagination and JSON/SSE responses. Test connection performs initialization and discovery only, not tool actions. Account sign-out or an explicit stop cancels the connection. Agent access to connected MCP tools is an explicit permission, not an automatic grant to older agents.

Browser OAuth enrollment and the old two-endpoint HTTP+SSE transport are not newly implemented here. OAuth access tokens can be configured as Bearer credentials. Do not describe this release as supporting every possible MCP extension.

## Scrolling

Native agent/MCP editors have scrollable content and reachable action buttons. Windows/Linux panels and dialogs allow overflow with visible scrollbar styling. A Chromium fixture test verifies agent creation and Firecrawl connection saving at 1280×720 and 800×600; these are UI tests using fake accounts/keys, not authentication to a live Firecrawl account.

## API access

Red-XAI sign-in and an inference API key remain distinct credentials. Vortex's OpenAI-compatible base URL remains configurable, and saved keys are scoped to the signed-in profile. The Bridge's saved key has previously authenticated against the local forwarded inference gateway. This release does not itself provision DNS or a publicly reachable inference service: `ai.red-xai.com` must resolve and route to the authenticated inference gateway for external clients to use that hostname. Never expose the model's unkeyed port or administrative port as a substitute.

## Release verification

The source changes must pass the native Swift tests, Go regression tests on Windows/Linux, frontend tests and the MCP transport tests before promotion. A passing source build is not evidence of notarization, a published installer or a live provider login. Existing signing, notarization and signed-manifest verification requirements remain in place; they are not bypassed by this update.
