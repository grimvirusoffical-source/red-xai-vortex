# Vortex 2.10 (build 45)

This release adds projects, XAI Bases, configurable scoped memory, portable
personalities, coding context/review tools and roleplay worlds alongside the
existing chat, agents, tools, media, plugins, secure chat and connection features.
See [WORKSPACES.md](WORKSPACES.md) for setup, storage and capability limits.

## Install this release once manually

The previous release-signing private key was held by the earlier build agent and
is unavailable. With the owner's approval, 2.10 introduces a new Ed25519 release
signing key. New clients trust the new key and retain the previously verified
public key. The private key is kept outside the repository and public website.

Older clients cannot authenticate a manifest signed by the new key. Their update
verification should reject it. Download and install 2.10 manually from
[red-xai.com/vortex/](https://red-xai.com/vortex/) or the matching GitHub release.
Keep the complete Windows/Linux package together, including its frontend, Base
helper, secure-chat helper and runtime. The Linux installer installs these helpers
next to the executable. Existing local chats/settings are retained; back up client
data before changing versions.

Once 2.10 is installed, subsequent releases can use the new signing key. No client
disables signature checks or trusts a checksum file as a replacement for a signed
release manifest. The Mac app and bundled executables also use Developer ID signing
when packaged with the owner's signing identity. Notarization is a separate step.

## Added workflows

- A clearer chat/sidebar/composer and workspace navigation in the native Mac app
  and desktop/phone web client, retaining existing controls.
- Projects grouping chats, files, Base selections, personalities and scoped settings.
- Savable/exportable/importable personalities, manual scoped memory, attachments,
  user-selected memory quota and per-chat shared global memory (off by default).
- Optional completed-turn memory capture and world evolution: Off, Review, or Save
  automatically, with editable proposals and quota/scope checks.
- Roleplay worlds with premise, lore, characters, state and isolated world memory.
- Explicit repository/file context, selected Git diffs, coding modes and patch
  review. Applying a patch uses the existing Allow/Deny flow and rechecks the patch.
- Managed authenticated Base hosting with start/stop, source synchronization,
  expiring scoped invites, grant revocation and connection/availability indicators.
- Public HTTPS text/HTML imports, authorized Google Docs export, optional refresh
  on use, and credential removal while retaining an explicit local snapshot.
- Local extraction adapters for PDF, image OCR, audio transcription and sampled
  video OCR. Availability depends on the OS or installed tools/model; unsupported
  files remain available as attachments with honest extraction status.

## Configuration and limits

Base hosting defaults to loopback. To serve another computer, configure authenticated
HTTPS with your own TLS listener or reverse proxy; this release does not open router
ports or create a public tunnel. Host endpoints and tokens are omitted from model
context. Revocation blocks new reads; previously copied text cannot be retracted.

Private Google Docs require an authorized Drive token; Google OAuth onboarding is
not configured automatically. The Go host uses optional pdftotext, Tesseract,
FFmpeg and whisper-cli with a chosen local Whisper model. Mac extraction uses
PDFKit, Vision and on-device Speech when available. Audio/video extraction is
bounded and sampled; it is not unrestricted multimodal understanding.

Bases supply retrieved context, not model-weight training. Coding quality depends
on the selected model and runtime. Semantic/vector retrieval, automatic cross-device
store synchronization, hosted model deployment and native iOS/Android installers
are outside this release. Phones use the existing full web client served by the
desktop host.

The native Mac and Go clients retain separate local stores. Existing workspace
files are migrated additively; unreadable/newer data is preserved instead of
silently replaced. Memory quota covers saved memory text and attached bytes/text
extracts, not every file/model/cache on the machine.
