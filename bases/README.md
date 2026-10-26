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
These tests use temporary private data and never access an existing user Base.
