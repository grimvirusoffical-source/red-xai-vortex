# Native Vortex MCP authentication and settings

The macOS MCP editor keeps Name, Id, transport, and a matching URL or command required. Authentication defaults to None. Advanced settings retain usable defaults and do not require a key for unauthenticated servers.

## Firecrawl

For hosted API-key access choose **Firecrawl · API key**, use `https://mcp.firecrawl.dev/v2/mcp`, select API key / bearer token and paste only the Firecrawl key in the masked field. Vortex sends `Authorization: Bearer <key>`; do not place the key in a URL.

For local access choose **Firecrawl · local**. This uses `npx -y firecrawl-mcp` and the optional credential is placed in `FIRECRAWL_API_KEY`. Connecting a local server executes its command; only run trusted packages.

Source: https://github.com/firecrawl/firecrawl-mcp-server (hosted and local setup documentation).

## Optional settings

- Authentication: none, bearer/API key, custom header with optional prefix, Basic username/password, or a local environment-variable key.
- Command arguments, working directory, environment inheritance, additional environment variables and HTTP headers.
- Connection/discovery and tool-call timeouts; maximum response size.
- Exact-name allow/block tool lists and reconnect-on-start preference. Existing destructive tool confirmations are unchanged.

Headers, environment values and the selected credential are stored in macOS Keychain. Metadata contains only a credential reference. Old raw header/environment profiles remain readable and migrate to Keychain when settings are successfully saved. Keychain failures do not fall back to plaintext. Import skips duplicates and leaves imported servers disabled.

## Protocol compatibility

The client negotiates supported MCP protocol versions, retains server session IDs, handles JSON and multiline SSE responses, and follows paginated tool lists. Redirects are refused, including credential-bearing redirects. TLS validation remains enabled. Tools are not automatically retried, avoiding duplicate writes after timeouts.

This patch implements API-key and manually supplied bearer-token authentication, not an interactive OAuth browser flow or legacy HTTP+SSE transport. Use a server's Streamable HTTP API-key endpoint where available. The native macOS MCP editor is the implementation changed here; the separate Go desktop application did not previously have this MCP registry and is not represented as receiving these controls in this patch.

## Vortex inference versus MCP credentials

A Vortex model key belongs on the Vortex inference API (`/v1/models`, `/v1/chat/completions`). A Firecrawl key belongs on Firecrawl's MCP connection. A bridge credential belongs on the bridge connection. Credentials are per-server and are never reused across providers automatically.

The bridge's current API client supports HTTPS endpoints and explicit loopback addresses such as `http://127.0.0.1:18091/v1`. A missing DNS record is not an invalid-key result. API-key scopes, expiry and model permissions are always decided by the service; admin status alone does not prove incompatibility.

## Verification

Configuration tests cover optional defaults, required fields, legacy decoding, secret-free metadata, bearer/custom/basic/environment authentication, duplicate headers, injection boundaries, tool filters, and diagnostic redaction. Loopback fixtures test authenticated JSON/SSE sessions, protocol negotiation, pagination, errors, redirects and response bounds. These fixtures never use real service credentials and are not a claim that a real Firecrawl account has been authenticated.
