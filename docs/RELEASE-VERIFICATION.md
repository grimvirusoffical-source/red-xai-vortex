# Release verification and the 2.10 signing-key transition

Vortex verifies the exact release-manifest bytes with Ed25519 and then compares the selected package's SHA-256 digest with its signed manifest entry. A release page's unsigned checksum list is useful for inspection but is not an authenticity check.

The public trust keys are:

- Existing release key: `6979c5dfd027191f385aa9abad43666af27166156726865c235a45c71d096a4d`.
- Owner-approved replacement key: `ea244ad764bc6556b93c5ca9a8e5075efc20dde9ac23ce26800be72bb2ece6e9`.

The existing key was recovered from the trusted universal `redx-verify` executable and confirmed against the published 2.8 manifest, signature, and Linux package. The replacement key was approved after the original private signing key could not be located. Private signing keys are not included in this repository, release packages, desktop applications, or build output.

**Existing 2.8 installations need a one-time manual update to 2.10.** Their pinned old key cannot authenticate a release signed by the replacement key. Do not bypass that check or substitute an unsigned manifest. Vortex 2.10 accepts both public keys, retaining verification of earlier authentic releases and supporting subsequent releases signed by the replacement key.

## Manifest and command contract

The manifest is UTF-8 JSON with a version and SHA-256 hashes indexed by exact asset filename:

```json
{"version":"2.10","assets":{"Red-XAI-Vortex-linux-amd64.tar.gz":"64 lowercase hexadecimal characters"}}
```

`release-manifest.sig` contains the 64-byte Ed25519 signature encoded as 128 hexadecimal characters, optionally followed by a newline. Sign the final manifest bytes as written; do not reformat the JSON after signing. Compute asset hashes after the final archive, application signing, and DMG signing steps.

The public verifier uses the native updater's existing command contract:

```sh
redx-verify release-manifest.json release-manifest.sig /path/to/package.zip
```

It prints the authenticated manifest version and exits successfully only when the signature and the package's signed filename/hash match. Verification failures exit unsuccessfully. The native app must bundle a newly built universal verifier with both public keys rather than an old verifier that trusts only the original key.

## Build the desktop and its hosting helper

The build script creates an adjacent hosting helper and embeds the same helper in the desktop executable:

```sh
VORTEX_VERSION=2.10 ./scripts/build-desktop-with-helper.sh linux amd64 /absolute/output/linux
VORTEX_VERSION=2.10 ./scripts/build-desktop-with-helper.sh windows amd64 /absolute/output/windows
VORTEX_VERSION=2.10 ./scripts/build-desktop-with-helper.sh darwin arm64 /absolute/output/mac-arm64
VORTEX_VERSION=2.10 ./scripts/build-desktop-with-helper.sh darwin amd64 /absolute/output/mac-amd64
```

Generated embedding files and binary payloads stay in a temporary build directory. The script removes that directory on exit. `VORTEX_BUILD_LDFLAGS` can provide additional trusted build settings; an existing trusted source overlay and SDK replacement can be supplied through `VORTEX_DESKTOP_OVERLAY` and `VORTEX_RSX_SDK` when needed. The standard public verifier requires no private signing material.

Embedding is needed for compatibility with older desktop updaters: those updaters did not install an additional `vortex-base` file from the release archive. The new executable can install its embedded helper into a private cache, verifies its SHA-256 before reuse, and repairs changed cache contents. It never downloads executable code for this bootstrap. Current updaters also replace the adjacent hosting helper during an update.

## Preserve the release package layout

Linux packages must contain `frontend/`, `rsx-runtime/`, `redx-link`, `vortex-base`, the desktop binary, and `install.sh`. Preserve the complete existing private secure-chat runtime and its platform libraries. The installed executable is normally named `vortex`, while previous archives used `vortex-linux-amd64`; include **both names as regular archive members** for compatibility with older updater executable lookups. Older extractors ignore tar hard-link members, so a hard-link alias is insufficient. Install `vortex-base` beside the installed executable.

Windows packages must retain `vortex.exe`, `vortex-base.exe`, `redx-link.exe`, `frontend/`, `rsx-runtime/`, and the existing runtime libraries and launch instructions. Keep those files and directories together.

macOS releases must preserve the complete application bundle, its existing signed private helpers, secure-chat runtimes and framework resources, platform-matching Base helpers, phone helpers, and the new universal public verifier. Sign the final bundle and DMG before hashing release assets.

Stage a release with its exact final assets, signed manifest, detached signature, and checksums. Validate each package using the new verifier before making the release public. Never publish a replacement manifest signed by a newly invented key without an explicitly approved trust transition.

## Verification checks

The test suite includes the public 2.8 manifest/signature as small compatibility fixtures and rejects modified manifests, signatures, packages, and unrelated keys. The large historical package is kept outside Git; it can be checked explicitly:

```sh
cd desktop
VORTEX_LEGACY_RELEASE_TEST_DIR=/absolute/path/to/rel2.8 go test ./internal/update
```

The ordinary tests do not require a signing private key or network access.

The legacy key is restricted to historical versions below 2.10. Only the rotated key can authorize releases starting at 2.10. Both clients also bind the authenticated manifest version to the requested tag and reject downgrades before changing installed files.
