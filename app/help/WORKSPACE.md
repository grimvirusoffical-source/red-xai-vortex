# Projects, XAI Bases, memory and worlds

Open **Your workspace** in the sidebar. The Projects, XAI Bases, Memory, Personalities, Worlds and Code tabs add context to the existing chat system. Agents, party chats, tools, models, providers, attachments, voice and existing settings remain available.

## Projects

Create a project, enter its instructions, optionally choose a model and personality, and import reference files. Move an existing chat into the project or start a project chat. The Code tab's project picker can move a chat back out of a project. Project reference files are copies; changing the original file does not refresh its imported copy.

Projects select their own Bases. A chat can also select Bases directly. Project memory belongs to its project's library and is excluded from other projects and roleplay worlds. Removing a project keeps its chats and removes its reference copies and project memory.

## XAI Bases

A local Base indexes imported text, code and PDFs. Images and scanned PDF pages use on-device Vision English OCR when available. Video sources receive a timeline from at most 12 sampled OCR frames; this extracts visible text, not the meaning of unseen scenes. Audio transcribes on-device only when Speech Recognition is authorized and the current language/model is available. Use the explicit Transcribe action to request permission; unavailable adapters leave the original media intact with a visible explanation. Add captions or transcripts when a model needs more context. These collections are reference context, not fine-tuning of model weights.

A remote Base keeps its original files on another PC, private home server or VPS. For another machine, run the repository's `bases/` host there, create a read grant, then enter the friendly name, HTTPS address and token in **Connect a hosted Base**. For this Mac, use **Start private host** inside a local Base. Vortex launches its bundled host, reports readiness, syncs source changes automatically, and stops the owned process on Stop, app exit or parent-process loss. Create expiring read/search invites and revoke them from the same panel. Invite credentials remain in Keychain and enter the clipboard only when you explicitly copy an invite. The default listener is loopback-only. Sharing with another PC requires your own existing private HTTPS tunnel/reverse-proxy alias; Vortex does not open a router, create a tunnel, or expose a public port. HTTP is accepted only for localhost, such as an SSH tunnel. The app stores tokens in macOS Keychain, refuses redirects, bounds responses and displays the Base's friendly name instead of its IP.

Enable **Allow this Base to provide model context**, then select it for a project or the current chat. Each user turn checks the selected remote host's health and authenticated manifest. Unavailable, disconnected or denied Bases contribute no new context. Text snippets are ranked using the current message and bounded to the context budget. Remote media bytes are not downloaded automatically.

**Disconnect and forget token** removes the local credential and cached source list. **Delete this Base connection** also removes local project references. Neither deletes the remote host's files nor revokes access for another client; revoke grants or delete sources on the host. Previously generated replies remain in chat history.

Use **Fetch live public document** for an HTTPS text/CSV/Markdown export or a public Google Doc. Standard Docs links are converted to text exports. Live sources can sync before selected chat turns; failed live sources are excluded until a successful sync. Credential-bearing citations, embedded userinfo and private-network hosts are rejected. Public Google exports may redirect only within approved Google download domains, without cookies or Authorization headers. Native Google OAuth/private-document credentials are not configured; use an authorized exported snapshot for private content. OCR and sampled video extraction run locally; audio never falls back to a cloud service automatically.

## Local persistent memory

Choose a quota from 1 MB to 16 GB. Memory usage includes entry text, copied attachments and extracted text. A full quota blocks new entries; no existing memory is silently evicted. The quota applies to memory, not project files, Bases, chat history or model downloads. Each imported file has a 100 MB limit; text/PDF extraction uses the existing 25 MB reader limit.

Write and edit memories explicitly. Give an empty entry a title if you want to attach only files. Search the selected shared, project or world library and delete entries when needed. Deletion removes Vortex's imported file copies, preserving original files.

Shared memory starts off until you opt in. The **Shared memory** switch in each chat controls shared/project memory reads. World chats start with shared memory off. Explicitly turning it on allows global shared-memory reads in that chat, while world entries remain isolated. The main memory switch disables all memory reads. By default, the app does not extract facts from chats. In Memory, choose **Propose for review** or **Save automatically** for the current chat to opt in. Each completed text turn then triggers a separate tool-free structured model request. World captures stay in that world, project captures stay in that project, and global captures require shared memory on. Generated entries remain editable/deletable and obey the same quota. Review/discard proposals in Memory; invalid output is not applied, completed-turn IDs prevent duplicate captures, and a bounded queue processes overlapping completed turns.

Memory is stored locally under Application Support/Red-XAI Vortex/Workspace. Selected memory and reference contents are sent to the model provider when used. Local storage is not an offline guarantee when the chat uses a remote model.

## Personalities

Save a named personality, select it for a chat or project, and export/import its JSON profile. Native raw profiles, native profile arrays and version 1 Vortex personality wrappers from the web client are accepted; unsupported future versions are rejected. Existing Settings personas use the same preference store. Importing a conflicting profile preserves the original and adds a new profile. A personality cannot enable tools or grant computer-control permission.

## Roleplay worlds

Set a premise, narration style and player boundaries, lore, characters, and a current world-state/story log. Start a world chat or attach the setup to the current chat. Update the state explicitly as the story changes, or opt the current world chat into state proposals/automatic evolution. Proposed changes require review. Automatic changes retain a restore proposal; stale proposals cannot overwrite a world you have edited since extraction. Each world may use its own isolated memory library; world memories are never copied into global memory.

Use **Return current chat to general mode** to stop using the setup. Deleting a world keeps its chat transcripts and removes the setup plus its isolated memories.

## Coding workflows

Choose Explain, Implement, Review or Debug in the Code tab. Supply code files, a repository overview, a unified diff, a reproduction or error output. Vortex gets file names and language hints, task-specific instructions, selected project context and enabled tools with their existing permissions. Code fences have Copy controls; unified diff fences distinguish added and removed lines.

Choose a local repository in Code to inspect its actual branch, working-tree status, eligible files and staged/unstaged diffs. Select up to 20 files for context; imported copies retain repository-relative names. Known credential paths and generated folders are excluded, including from diffs. Use the actual diff as current-chat review context. Paste a unified patch or take a fenced diff from the latest reply, check it with Git, then apply it only after review. Applying requires the existing PC Control file-write permission and Allow once confirmation; the working tree is checked again, symlink/binary/blocked-path patches are refused, and no commit/push is performed. Debugger execution and tests still use compatible enabled tools, with their normal permissions. Vortex must distinguish proposed changes from commands actually run. Changing a coding mode alone executes no command.

## Compatibility and backup

Existing chat JSON gains only optional workspace references. Existing chats and settings keep their storage locations. Workspace state is stored separately as versioned `workspace.json` plus imported files under `Workspace/assets/`. An unreadable or future-version workspace is preserved instead of overwritten. Back up the full Workspace folder along with chats; the existing chat-only JSON export does not include workspace files or Keychain credentials.
