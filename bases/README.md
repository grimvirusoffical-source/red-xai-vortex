# XAI Base host

`vortex-base` lets an owner host a knowledge Base on another PC, a home server,
or a VPS. The client receives authenticated reference context from that machine.
This is retrieval, not model training or a change to model weights. Large media
stays on its host; the manifest carries metadata and any supplied transcript or
description. Vortex keeps a bounded text cache to build chat context.

The server is deliberately read-only over HTTP. The owner imports/deletes sources
and grants/revokes access locally with the command line. Each Base has an isolated
private directory, a stable identity, and expiring credentials. Tokens are random,
stored as hashes by the host, and never accepted in query strings. Every route,
including health, requires a Bearer token. The source directory is never served.

## Build and create a Base

From `bases/`, using Go 1.22 or newer:

```sh
go test ./...
go build -o vortex-base .
./vortex-base init -dir /absolute/private/my-base -name "Engineering reference" -quota-mib 2048
./vortex-base import -dir /absolute/private/my-base -file /absolute/notes.txt -name "Design notes"
./vortex-base import -dir /absolute/private/my-base -file /absolute/demo.mp4 -name "Product demo" -text-file /absolute/demo-transcript.txt
./vortex-base import -dir /absolute/private/my-base -url https://docs.google.com/document/d/DOCUMENT_ID/edit -name "Google design doc" -text-file /absolute/exported-document.txt
./vortex-base grant -dir /absolute/private/my-base -name "My Vortex laptop" -out /absolute/private/laptop-token -days 30 -scopes read,search
./vortex-base status -dir /absolute/private/my-base
./vortex-base serve -dir /absolute/private/my-base
```

Choose a new private directory. `init` refuses to overwrite an existing Base.
Imported files are copied into the Base, so deleting the original does not remove
the hosted copy. Default quota is 2 GiB, up to 1,000 sources; each imported file is
limited to 128 MiB. Text/transcript input is bounded to 1 MiB. Text files are indexed
as UTF-8; other formats retain MIME type, size, checksum, and an optional description
or transcript. Text search ranks matching words; it is not a semantic/vector index.
The serialized metadata/text index is limited to 32 MiB; an import that exceeds it
is rejected while preserving the existing Base. Split larger indexes into multiple
Bases. Raw media storage is governed separately by the configured storage quota.

Google Docs and other HTTPS document URLs can be registered with exported text.
The host does not fetch arbitrary remote URLs or bypass document access controls.
Export the document using an account with access, then import its `.txt` export.
There is no Google OAuth connector, automatic document synchronization, OCR, speech
transcription, video understanding, or PDF text extraction in the Base host itself.
Native chat's existing attachment capabilities remain available separately.

The token file is private (`0600`) and is never overwritten or printed by the
command. Transfer its contents to the intended client's connection form through a
trusted channel. Give each client its own grant; do not commit credentials or Base
data into Git. `status` lists grant IDs and expiry without exposing their hashes or
tokens. Owner filesystem access is trusted; use disk encryption for data at rest.

## Managed desktop/native publishing

The Vortex applications can maintain a Base through the same local owner CLI.
Initialize its private directory once, then publish a complete JSON snapshot:

```sh
./vortex-base sync -dir /absolute/private/my-base -snapshot /absolute/private/snapshot.json
./vortex-base grant -dir /absolute/private/my-base -name "Reader" -out /absolute/private/reader-token -json
./vortex-base serve -dir /absolute/private/my-base -listen 127.0.0.1:0 -ready-file /absolute/private/ready.json
```

`publish` is an alias for `sync`; `-file` can replace `-snapshot`. These commands
require an initialized `catalog.json` and never replace the Base identity, quota,
or access grants. A snapshot contains the entire intended source collection:

```json
{
  "name": "My project reference",
  "sources": [
    {
      "id": "native-or-desktop-source-id",
      "name": "Architecture notes",
      "kind": "text",
      "mimeType": "text/plain",
      "text": "Optional supplied reference text or media transcript",
      "attachmentPath": "/absolute/local/notes.txt",
      "bytes": 100,
      "updatedAt": "2026-10-26T12:00:00Z"
    }
  ]
}
```

`url` is an optional HTTPS document reference subject to the same restrictions as
`import`. Sources may contain text, a URL, an attachment, or a combination. Every
source requires a unique, nonempty ID and name. The helper deterministically maps
any client ID to the first 16 bytes of its SHA-256 digest as hexadecimal. Reusing
the same client ID preserves the hosted source ID on future publishes. An empty
source array removes the published sources while retaining the Base and grants.

Attachment paths must explicitly name absolute regular local files; directories
and symlinks are rejected. The helper copies the files into private immutable
storage and never includes their local paths in HTTP responses. Files can be up
to 128 MiB each. Supplied text is limited to 1 MiB per source; UTF-8 text files up
to that size are indexed automatically if no text was supplied. The `bytes`
field is advisory: quota checks use measured attachment bytes plus stored text.
The existing 1,000-source and 32 MiB serialized-index limits also apply.

Publishing stages and validates all sources, then atomically switches the
catalog. Failed validation, copying, or quota/index checks preserve the previous
catalog and files. Removed or replaced attachment objects are pruned only after
the new catalog is committed. Perform owner mutations sequentially, including
publishes, imports, grants, and revocations. A serving process reloads this catalog
for every request, so successful local publishes are immediately available.

`sync` prints JSON containing `id`, `name`, `revision`, and the source count in
`sources`. `grant -json` prints `id`, `tokenFile`, `scopes`, and `expiresAt`; the
credential itself remains only in its new private token file. An application can
move it into an OS credential store and remove that file after a successful move.

The ready file is private (`0600`) JSON containing `endpoint`, `baseID`, and `pid`.
Its endpoint contains the actual chosen port, including when `-listen` requests
port zero. It appears only after the listener and any TLS configuration are ready.
SIGINT and SIGTERM stop the server gracefully and remove its own ready file.
After an abrupt kill a stale file can remain, so process managers should confirm
the recorded process and authenticated health before treating it as live. These
local management commands do not add remote HTTP write endpoints.

## Connect and expose securely

The default listener is `127.0.0.1:7941`. For a local client, connect using that
address and the generated token. For another machine, use either:

- An owner-managed SSH or private VPN tunnel to the loopback listener; connect
  Vortex to the tunnel's loopback address.
- An HTTPS reverse proxy/tunnel with a hostname, forwarding only to the loopback
  listener. Preserve the Authorization header and disable public caching.
- A direct TLS listener, supplying `-listen`, `-tls-cert`, and `-tls-key`. The host
  refuses a non-loopback listener without both TLS files.

Vortex's Base clients accept HTTPS and loopback HTTP, reject URL credentials and
redirects, and keep the connection endpoint out of ordinary labels and model
prompts. A hostname avoids showing a raw home IP in the client. Configuring DNS,
certificates, a VPN, router forwarding, or a public service is a separate owner
operation; none happens just by adding a Base in Vortex. Do not expose a plaintext
port on a home router. Use one process per Base directory. Concurrent owner CLI
mutations should be performed sequentially.

To revoke or delete:

```sh
./vortex-base revoke -dir /absolute/private/my-base -id GRANT_ID
./vortex-base delete -dir /absolute/private/my-base -id SOURCE_ID
```

Revocation is checked on every host request. Vortex revalidates selected remote
Bases before building new chat context and excludes unavailable or rejected Bases.
Disconnecting a client disables its context. Deleting a client-side connection
does not delete the owner's hosted files. A host cannot retract text that a client
already downloaded or placed into an earlier conversation. Revoke at the host to
stop future access, and remove existing local copies/chats separately if desired.

## Protocol v1

All routes are GET, with `Authorization: Bearer <token>`. Errors use JSON with a
short `error` code. No CORS headers or anonymous health endpoint are provided.

| Route | Required scope | Response |
| --- | --- | --- |
| `/v1/health` | Any valid grant | `ok`, Base `id`, `name`, `revision`, and granted `scopes` |
| `/v1/manifest` | `read` | `id`, `name`, `revision`, `sources` |
| `/v1/search?q=words` | `search` | Up to ten ranked source records and `revision` |
| `/v1/sources/{id}` | `read` | Original imported bytes as an attachment; references without a file return 404 |

Source records contain `id`, `name`, `kind`, `mimeType`, `bytes`, `updatedAt`, and
optional `text`, `url`, `sha256`. Manifest text is limited to 16 KiB per source and
1 MiB total. Search uses the locally indexed text and returns up to 16 KiB of text
per hit. A Base reference URL is metadata, not an access grant to that document.

Do not send token values in logs, model context, screenshots, or bug reports. Health
failures report unavailable/unauthorized status without returning credential values.

## Verification

`go test -race ./...` covers authentication, expiry, scoped access, immediate
revocation, deletion, quotas, document references, bounded manifests, token-file
permissions, traversal/symlink refusal, and the refusal of public plaintext serving.
Managed publishing tests also cover deterministic source IDs, identity/grant
preservation, changes/removals, shared attachment cleanup, quota rollback, private
machine output, safe attachment paths, and real listener readiness and shutdown.
These tests use temporary private data and never access an existing user Base.
