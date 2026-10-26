# Projects, XAI Bases, memory, personalities and worlds

This upgrade adds a local workspace alongside Vortex's existing chat, agent,
party-chat, media, tool, plugin, server, connection, and secure-chat features.
The native Mac app and desktop/phone web interface both have workspace controls.
Existing model and gateway integrations remain in place.

## Start with a project

Open **Your workspace** in the Mac sidebar or **Workspace → Projects** in the web
interface. Create a project, add its instructions, assign conversations, and select
files, Bases, and a default personality. A conversation can override its personality
and Base choices in its context controls. The Mac project also offers a default
model; the web client continues using its existing model and composer controls.

Project files are snapshots of explicitly selected local files. They are not a live
repository mirror. Project scope groups related context without changing the model
server, credentials, existing agents, or their tool permissions.

## Use coding context deliberately

The web client's **Workspace → Coding** can read an explicitly selected repository
folder, selected relative file paths, branch, and the selected files' unstaged Git
diff. It excludes credential paths, dependency folders, binary/large files, and
symlinks escaping the selected repository. Review the draft, then save it to the
conversation. With no selected file paths, only diff statistics are requested.
Context is bounded to 32 files, 64 KiB per file, and 512 KiB total before the smaller
prompt budget is applied. These limits keep a large repository from consuming all
model context. This reads files and fixed Git inspection commands; it never executes
project code or applies a patch.

The Mac app offers explain, implement, review, and debug modes, coding notes/diffs,
and project file snapshots. Fenced code can be copied and diffs are displayed
clearly. Both clients build evidence-based coding prompts and retain the existing
agent/tool execution and approval flows. A proposed patch or test command is not
evidence that it was applied or run. These workflows improve the context and task
structure; model intelligence still depends on the selected model and runtime.

## Create or connect an XAI Base

A Base is a named knowledge collection with source metadata, extracted text where
available, keyword indexing, and per-connection use permissions. Local Bases accept
text, text files, document links, and image/audio/video/document attachments. Google
Docs and other document links can be saved with authorized exported text. A link
alone records a reference; it does not grant access to a private document.

For remote hosting, build the separate [XAI Base host](../bases/README.md) on the
other PC/home server/VPS. Import sources there, create a client-specific expiring
grant, then connect Vortex using a display name, endpoint, and token. Base clients
require HTTPS except for loopback HTTP, reject credential-bearing URLs and redirects,
and omit connection endpoints and tokens from model context. The endpoint is
available in connection settings; ordinary lists use the Base name.

Selected remote Bases are authenticated again before each model turn. An offline,
disconnected, denied, or revoked Base is excluded from new context. Health is a last
checked indicator, not a promise that a sleeping home PC will always be reachable.
The web client checks up to four remote Bases per turn concurrently. Keep selected
remote collections focused; host availability and network latency still matter.

Disconnect/forget removes this client's access. Delete removes this local connection
or local collection. To invalidate a token on every client, revoke its grant on the
host. To delete the hosted data, delete the source on that host. Previously downloaded
text already included in a chat cannot be retracted by the host.

Remote media stays hosted remotely; context uses metadata and supplied text excerpts.
Local media is retained locally. Neither client invents transcripts, OCR, or video
understanding. Native attachment extraction/vision features remain available where
already supported by the chosen model. Automatic Google Docs OAuth synchronization,
media transcription pipelines, semantic/vector retrieval, and fine-tuning are not
implemented by this workspace increment.

## Set memory scope and storage

Memory entries are saved intentionally: write text directly or attach files. Choose
global, project, or world scope. The memory quota is configurable and rejects additions
or quota reductions that would exceed it; existing entries are not evicted. Memory
does not silently summarize old conversations or automatically learn personal facts.

The per-chat shared-memory switch starts off, including for legacy chats. Turn it on
to read saved global memory across chats. Project and world memory remain scoped to
the selected project/world. Roleplay starts with shared memory off; explicitly turning
it on adds global reads without copying world facts into global memory. The native
client also has a master memory-use switch.

The quota covers saved memory text and its attached bytes/text extracts. Project/Base
files, chat history, indexes/JSON overhead, and model weights use additional storage.
Local files are not encrypted by this feature; use OS account protections and disk
encryption. Native Base credentials use the macOS Keychain. The existing Go desktop
credential adapter stores secrets separately in private local files (`0600` on Unix),
which is not an encrypted OS keychain. Neither workspace JSON nor personality exports
contain Base tokens.

## Personalities and roleplay worlds

Create a personality with a name and instructions, export it as JSON, and import a
saved personality into another workspace/client. Existing native personas remain
available. Personality text sets tone and working style; it does not grant tool
permissions, repository access, or computer-control authority.

Create a world with a premise, narrative guidance, lore, characters, and current
world state, then start a chat linked to it. Optional world memories only enter chats
for that world unless the user separately enables global shared memory. World state
is edited/saved explicitly by the user, preserving control over continuity. This is
a structured roleplay workspace, not a game simulation engine or an autonomous
world-state writer.

## Persistence and compatibility

The upgrade writes a new versioned `workspace.json` next to existing client data.
Native workspace fields on chats are optional. The Go client keeps chat workspace
settings in the separate workspace file. Existing chats, settings, agents, providers,
and connection formats stay readable without a destructive migration. The clients
preserve unreadable or newer workspace files instead of replacing them with defaults.
Errors should be resolved before editing that workspace. Back up client data before
changing application versions.

Native data lives in `~/Library/Application Support/Red-XAI Vortex`; the Go desktop
client uses `~/.config/red-xai-vortex`. These clients have distinct local stores and
workspace schemas. This change does not synchronize Mac, Windows/Linux, or phone-host
data with one another. Phone access uses the existing Go host store and PIN/session
controls; its sign-in and secure-chat behavior remains the existing implementation.

## Build and validation

Run `bash scripts/check-workspaces.sh` from the repository root. It checks Go tests
and vet for the desktop, gateway, and Base host, web JavaScript syntax, and native
Swift tests when running on macOS. Existing tests and workspace regression tests
cover legacy decoding, quota rejection without eviction, scope isolation, personality
roundtrips, remote-auth failures/revocation, bounded input, and selected repo context.

Build the Mac app using the existing `app/build.sh`; build the Go client from
`desktop/` and distribute its `frontend/` folder with the executable. Build the Base
host separately from `bases/`. Packaging the complete release still requires the
private helpers and runtimes described by the existing build script. Workspace work
does not install an app update, restart production services, configure public DNS,
or deploy a model or Base host automatically.
