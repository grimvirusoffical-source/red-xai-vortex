# Cloud PC permission persistence candidate

This change extends the authorization-boundary candidate in PR15. It is not a
production deployment or an account/session integration.

The Cloud PC gateway serializes every ACL read/modify/write operation in one
process. It writes a same-directory temporary file, flushes and closes it,
renames it over the ACL, and on Linux flushes the directory before acknowledging
success. Request, approval and revocation handlers return 503 on persistence
failure and do not send a success notification. A directory flush failure can
mean the replacement is visible but has not been acknowledged as durable;
operators must inspect and reconcile it before retrying.

Malformed, oversized, nonregular, null, trailing or unknown-field ACL data fails
closed. A mutation does not replace the corrupt original. Reads also share the
writer lock, so they do not observe partially constructed permissions. The ACL
parent directory must be pre-provisioned on durable private storage, owned by
the service, and writable by no unrelated process. Run exactly one gateway
writer: the mutex does not coordinate separate processes or hosts. Existing
ACL names and fields are preserved; no user assignments are guessed.

Local Windows fixtures check mutation outcomes, concurrent changes and final
replacement state but do not establish Unix atomicity or directory durability. Linux
race-test CI covers the directory-sync implementation. Tests never start a
desktop, call OS control helpers, sign in to a real account or send alerts.
An injected directory-flush failure verifies the uncertain-commit case:
replacement state is visible, all three mutation handlers return 503, and no
success notification is sent.

Before rollout, preserve an application-consistent ACL/configuration backup
and a code rollback. Verify the single writer and actual filesystem durability,
exercise success and failure paths, and prove that revoking an approved account
closes its active desktop connection. Do not restore an old ACL over newer
permission changes during a code rollback.

The independent identity blockers remain: legacy owner/approval checks are
username based, canonical website-session exchange is absent, deployment of
the explicit proxy boundary below is unverified, and the storage/control helper
implementations and sudo policy have not been verified. Immutable account
ownership, owner-role plus MFA proof, an audited grant migration and OS-level
tenant isolation must be established before promoting this service as the
website's tenant-isolated Cloud PC integration. This persistence fix alone
does not satisfy those requirements.

## Explicit HTTPS proxy boundary

The candidate defaults to trusting no proxy headers. Native TLS continues to
work without any proxy configuration. For a verified cloudflared deployment,
set `CPC_TRUSTED_PROXY_CIDRS` to the explicit, narrow CIDRs of the immediate
proxy connections. For example, use `127.0.0.1/32,::1/128` only after confirming
that the tunnel connects from those local addresses and that unrelated
processes cannot inject requests through that trusted transport. There are no
implicit loopback or Cloudflare-range exceptions. Invalid CIDRs fail startup;
hostnames, bare IPs and empty list entries are invalid. Do not trust broad
public ranges merely to make a request pass.

Only an allowlisted `RemoteAddr` can supply `CF-Visitor` or `CF-Connecting-IP`.
Proxy HTTPS requires one valid JSON object containing exactly
`{"scheme":"https"}`. Duplicate headers/keys, other fields or schemes, malformed
JSON and trailing values fail closed. Client IP requires a single valid IP
literal; invalid or untrusted forwarded IPs fall back to the immediate peer.
Caller `Forwarded` and `X-Forwarded-*` do not establish identity, TLS or an IP.

Cloud PC, sign-in and sign-out reject unverified cleartext writes with 426
before reading form bodies or calling Accounts. Safe methods redirect to
HTTPS. The shared website wrapper applies the same boundary to the remaining
website/plugin routes. The standalone `/v1/` API retains its stricter native
TLS-only requirement and still returns 426 for an HTTP connection even from a
trusted HTTPS proxy; this change does not enable API keys over proxy HTTP.

Tests use disposable HTTP authority fixtures and synthetic request data. They
check both native TLS and explicitly trusted HTTPS proxy session paths,
untrusted/duplicate/malformed headers, cleartext rejection before credential
consumption, scheme-aware origin checks and the unchanged native API policy.
They do not establish a real tunnel's peer addresses, certificate validity,
production account exchange or tenant/resource isolation.
