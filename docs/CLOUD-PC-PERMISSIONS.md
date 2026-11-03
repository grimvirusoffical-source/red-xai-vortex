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
username ACLs require the explicit reviewed migration below; no user
assignments are guessed or changed automatically.

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

The remaining deployment/integration blockers include a verified canonical
website-session exchange, an independently reviewed ID-grant migration,
the original account contract and expiry/MFA evidence, deployment of
the explicit proxy boundary below, and verification of storage/control helpers
and sudo policy. Immutable account
ownership, owner-role plus MFA proof, an audited grant migration and OS-level
tenant isolation must be established before promoting this service as the
website's tenant-isolated Cloud PC integration. This persistence fix alone
does not satisfy those requirements.

## Immutable grant and owner boundaries

The source candidate no longer grants access from `CPC_OWNERS`, default owner
usernames, mutable usernames, email addresses or a caller-supplied account ID.
Permissions schema 2 stores exact, case-sensitive canonical account IDs in
`approved` and `pending`. Usernames are display data. A normal completed
password session can request access and use only its own approved canonical
subject. The desktop storage identifier continues to be the first eight bytes
of SHA-256 of `cloudpc-redx:` plus the original canonical ID, preserving its
existing OS/helper namespace.

`CPC_OWNER_ACCOUNT_IDS` is an explicit private allowlist of independently
verified canonical IDs, with no defaults. Owner access additionally requires
the authority's `owner` role, a completed MFA method in session `amr`, and a
future `expiresMs`. Every request rechecks the existing account authority;
subject/username changes, loss of owner proof, expired/incomplete sessions,
revocation and unknown account responses invalidate the local session. A
password-only normal session is accepted without being elevated. MFA evidence
does not establish recent step-up authentication.

The currently reviewed response shape is `{account:{id,username,roles},
expiresMs,amr}` with active/verified flags enforced when present and no pending
steps. The separate modern Accounts source (`internal/server/server.go` and
`internal/accounts/models.go`) returns a flat `Me` without session expiry/AMR;
its `owner`/`twoFactorState` fields are not substitutes for that proof. That
contract fails closed here. No new website session exchange, authority swap,
identity lookup or authentication bypass is introduced by this candidate.

Request/approval/revocation audit entries include the acting and target account
IDs and timestamp. Repeating an already-pending request performs no write,
appends no audit event and sends no further alert. At 256 entries, the audit
tail rolls into an immutable, digest-addressed private `audit-segments` file
linked to the previous segment hash. The segment and directory are flushed
before the atomically replaced ACL references the new head. History is never
pruned; the short tail and constant-size head prevent request history from
exhausting the ACL file and blocking an owner's revocation. New requests reserve
128 KiB for administrative changes; a capacity denial returns 503 without a
write or alert. Audit rolls earlier if necessary to keep an administrative
envelope within its size limit. Permission changes
and the new audit reference share the same acknowledgement. Existing audit
chains are verified before extension; an uncertain failure can leave a
preserved, unreferenced segment. Backups/restores must include every referenced
segment with the ACL, and disk capacity still requires monitoring. Corruption
fails closed and must be reconciled before new writes.

Per-user decision notifications are paused: the existing gateway
routes `user:<username>` by mutable key name and lacks a verified canonical-ID
recipient contract. The stored decision remains visible in Cloud PC. No
private grant decision is sent to a guessed username recipient.

## Reviewed username migration preparation

A missing ACL starts empty schema 2. An existing schema-less username ACL
fails closed and remains byte-for-byte intact. Even a username that resembles
an account ID is never reinterpreted as one. Before promotion, take a consistent
protected backup and independently verify every old name against the real
canonical account authority. Prepare a private 0600 mapping file such as:

```json
{"operator_account_id":"VERIFIED-OPERATOR-ID","mappings":{"old-name":"VERIFIED-ACCOUNT-ID"}}
```

Mapping keys are explicit lowercase legacy names; values preserve exact ID
case. Every approved and pending name must be covered, with no extra entries.
Distinct names cannot silently merge into one canonical ID. The mapping is an
operator assertion; the tool verifies coverage/collisions, not its provenance.

Run the candidate daemon in the separate offline preparation mode:

```sh
cloudpc-web prepare-acl-migration --source /private/acl-consistent-backup.json \
  --mapping /private/reviewed-account-ids.json --output /private/acl-id-review.json
```

It creates only a new exclusive 0600 review artifact, flushes it and its parent
directory, and refuses the input, mapping or configured live ACL as output.
It never starts listeners, calls Accounts, changes desktop files, rewrites
the source ACL or promotes the result. New migration audit entries carry the
operator/target IDs and source/mapping SHA-256 digests. A failed artifact must
not be promoted. Review the mapping and artifact, test two real identities and
the owner against an isolated copy, preserve changes since the snapshot, and
promote only within a coordinated migration/rollback procedure. Never restore
a stale grant snapshot over newer permission or audit changes.

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
