# Vortex 2.11 (build 46)

Vortex now has its own royal window frame, jewel controls, a clearer workspace sidebar, spacious conversation layout and unified composer. Gold and black is the default look; purple and black, light, and black and red are saved appearance options. Existing chats, projects, Bases, personalities, memories, tools and settings remain available.

## PC control

PC control asks before changes by default. On the Mac, use the header permission menu or PC Control settings to explicitly enable **Always allow on this Mac**. It enables every built-in PC tool and remembers that local permission. System Accessibility, Screen Recording and Automation permissions still apply. Plugin and MCP destructive actions keep their own approval flow.

**Stop control** cancels PC runs, pending PC approvals and running child commands, revokes the remembered unattended permission, and blocks queued work. Resetting Stop returns to per-action approval. Stop does not undo completed changes. A deliberately launched background command can continue normally after completion; tracked child process groups remain available to Stop while they are alive.

The desktop host has an equivalent local-operator setting. A phone or other remote bridge request cannot turn it on or inherit unattended permission. The phone can stop control. Coding patch application follows the same local policy, with manual review still the default.

## Owner audit history

The client includes audit controls for gateways that support the new retention, stable event IDs and snapshot-confirmation API. **These server features require an upgraded compatible gateway; installing this client does not change server retention or enable cleanup on an older gateway.**

This release will not replace the current production gateway. That deployment uses the private RSX crypto adapter and Go SDK, whose original compatible build sources are currently unavailable. Its existing gateway binary, crypto backend and configuration remain in place.

Until a compatible gateway is deployed, the Owner panel explains that a gateway update is required. **Refresh and existing audit logs remain available; Mark all as read and Export JSON and delete… are disabled.** The client does not silently substitute a different crypto backend.

On an upgraded compatible gateway:

- Only the latest ten audit events are retained. When an eleventh arrives, the oldest overflow is removed. The first retention migration makes a private copy of the old JSONL log before trimming it.
- **Mark all as read** removes only the displayed event IDs. New events arriving during the operation remain.
- **Export JSON and delete…** opens a native save dialog for a snapshot of the displayed entries. Choosing this action and completing the save requests deletion of that exact snapshot only after the local write succeeds. Cancelling or failing the save preserves the log; new events remain.
- Audit mutations and exports require the owner unlock and existing access checks. The exported file uses private permissions.

## Replies and media

Native chat can show text progressively while the provider streams, including replies from the tool loop. The explicitly saved finished-only preference remains available. Tool arguments stay hidden and must be complete and valid before execution. Compact tool instructions reduce unnecessary prompt overhead, and ordinary help questions or negated requests are not treated as shortcut commands.

The selected compatible model can use built-in PC tools. Text input is batched with cancellation checks, file reads stay bounded, and screen OCR includes logical coordinates for grounded follow-up actions.

Explicit requests such as “generate an image of a golden fox,” “create a video showing clouds,” or “make music for a quiet night” route to the existing media queue in native and web chat. Existing slash commands, exact-spec controls, progress, downloads, regeneration and redesign remain available. Generation speed and availability still depend on the configured model/server and media engines.

## Installation and verification

Install the complete platform package. Clients on 2.10 trust the existing release-signing key for this newer version; clients below 2.10 still need the documented one-time manual update. macOS packages are published only after Developer ID signing, Apple acceptance, stapling and Gatekeeper verification. Final signed manifests and release verification records identify the exact package hashes.
