import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct WorkspacePanel: View {
    @EnvironmentObject var chats: ChatStore
    @ObservedObject var workspace = WorkspaceStore.shared
    @Environment(\.dismiss) var dismiss
    @Local var tab = "projects"
    init(initialTab: String = "projects") { _tab = Local(wrappedValue: initialTab) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) { Text("Your workspace").font(.title2.bold()); Text("Organize your context. Choose what Vortex remembers.").foregroundStyle(.secondary) }
                Spacer(); Button("Done") { workspace.save(); dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(20)
            Divider()
            TabView(selection: $tab) {
                ProjectWorkspaceView().tabItem { Label("Projects", systemImage: "folder") }.tag("projects")
                BasesWorkspaceView().tabItem { Label("XAI Bases", systemImage: "externaldrive.connected.to.line.below") }.tag("bases")
                MemoryWorkspaceView().tabItem { Label("Memory", systemImage: "brain") }.tag("memory")
                PersonalityWorkspaceView().tabItem { Label("Personalities", systemImage: "person.crop.circle") }.tag("personalities")
                WorldsWorkspaceView().tabItem { Label("Worlds", systemImage: "globe.americas") }.tag("worlds")
                CodingWorkspaceView().tabItem { Label("Code", systemImage: "curlybraces") }.tag("coding")
            }.padding(12)
            if !workspace.errorMessage.isEmpty {
                HStack { Image(systemName: "exclamationmark.circle"); Text(workspace.errorMessage).font(.caption); Spacer(); Button("Dismiss") { workspace.errorMessage = "" } }.foregroundStyle(.red).padding(12)
            }
        }
        .frame(minWidth: 800, idealWidth: 900, minHeight: 620, idealHeight: 730)
        .onChange(of: workspace.state) { _, _ in workspace.save() }
        .onAppear { workspace.loadPersonalities() }
    }
}

struct WorkspaceEmpty: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View { VStack(spacing: 10) { Image(systemName: icon).font(.system(size: 36)).foregroundStyle(.tint); Text(title).font(.title3.bold()); Text(detail).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 360) }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30) }
}
struct WorkspaceAssetRow: View {
    let asset: WorkspaceAsset
    var remove: (() -> Void)? = nil
    @ObservedObject var workspace = WorkspaceStore.shared
    var body: some View {
        HStack {
            Image(systemName: asset.icon).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) { Text(asset.name).lineLimit(1); Text("\(asset.kind.capitalized) · \(ByteCountFormatter.string(fromByteCount: Int64(asset.bytes), countStyle: .file))\(asset.text == nil && asset.kind != "image" ? " · add a transcript or caption for model context" : "")").font(.caption2).foregroundStyle(.secondary) }
            Spacer()
            if let url = workspace.assetURL(asset) { Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }.help("Open the locally stored file") }
            if let remove { Button(role: .destructive, action: remove) { Image(systemName: "trash") }.help("Remove file") }
        }.padding(.vertical, 3)
    }
}
@MainActor func pickWorkspaceFiles(_ completion: @escaping ([URL]) -> Void) {
    let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = false
    p.message = "Import text, code, PDF, images, audio, or video. Media is stored locally; audio/video need transcripts for text-model context."
    p.begin { result in if result == .OK { completion(p.urls) } }
}

struct ProjectWorkspaceView: View {
    @EnvironmentObject var chats: ChatStore
    @ObservedObject var workspace = WorkspaceStore.shared
    @Local var selected: UUID?
    @Local var name = ""
    var body: some View {
        HSplitView {
            VStack(alignment: .leading) {
                HStack { TextField("New project", text: $name); Button { selected = workspace.newProject(name); name = "" } label: { Image(systemName: "plus") }.help("Create project") }
                List(selection: $selected) { ForEach(workspace.state.projects) { p in Label(p.name, systemImage: "folder").tag(p.id) } }
            }.frame(minWidth: 180, idealWidth: 220).padding(8)
            if let id = selected ?? chats.current?.projectID, let index = workspace.state.projects.firstIndex(where: { $0.id == id }) {
                ProjectDetailView(project: $workspace.state.projects[index])
            } else { WorkspaceEmpty(icon: "folder.badge.plus", title: "A home for each project", detail: "Group chats, reference files, Bases, a personality, and model settings. Existing chats can be moved into a project at any time.") }
        }
    }
}
struct ProjectDetailView: View {
    @EnvironmentObject var chats: ChatStore
    @ObservedObject var workspace = WorkspaceStore.shared
    @Binding var project: VortexProject
    var body: some View {
        Form {
            Section("Project") {
                TextField("Name", text: $project.name)
                Text("Instructions apply only to chats in this project.").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $project.instructions).frame(minHeight: 90)
                TextField("Model override (optional)", text: $project.model).help("Leave blank to keep the chat's existing model selection.")
                Picker("Default personality", selection: $project.personaID) { Text("Use chat default").tag(Optional<UUID>.none); ForEach(workspace.personalities) { p in Text(p.name).tag(Optional(p.id)) } }
                HStack { Button("New project chat") { chats.newChat(projectID: project.id) }; if chats.current != nil { Button("Move current chat here") { chats.updateCurrent { $0.projectID = project.id } } } }
            }
            Section("Reference files") {
                Text("Text, code and PDF contents are indexed locally. Images use a compatible vision model; audio/video remain stored files until you add a transcript.").font(.caption).foregroundStyle(.secondary)
                ForEach(project.files) { asset in WorkspaceAssetRow(asset: asset) { workspace.removeProjectFile(project.id, asset: asset.id) } }
                Button("Import files…") { let id = project.id; pickWorkspaceFiles { urls in Task { await workspace.attachToProject(id, urls: urls) } } }
            }
            Section("Connected Bases") {
                if workspace.state.bases.isEmpty { Text("Create or connect a Base in the XAI Bases tab.").foregroundStyle(.secondary) }
                ForEach(workspace.state.bases) { base in
                    Toggle(base.name, isOn: Binding(get: { project.baseIDs.contains(base.id) }, set: { on in if on { project.baseIDs.append(base.id) } else { project.baseIDs.removeAll { $0 == base.id } } }))
                }
            }
            Section("Chats") {
                ForEach(chats.sorted.filter { $0.projectID == project.id }) { c in Button(c.title) { chats.selection = c.id }.buttonStyle(.link) }
            }
            Button("Delete project", role: .destructive) {
                let id = project.id
                for i in chats.chats.indices where chats.chats[i].projectID == id { chats.chats[i].projectID = nil }
                chats.save(); workspace.deleteProject(id)
            }.help("Chats are kept and returned to the main sidebar. Project reference copies are removed.")
        }.formStyle(.grouped).frame(minWidth: 450)
    }
}

struct BasesWorkspaceView: View {
    @EnvironmentObject var chats: ChatStore
    @ObservedObject var workspace = WorkspaceStore.shared
    @Local var name = ""
    @Local var address = ""
    @Local var token = ""
    @Local var sourceName = ""
    @Local var sourceText = ""
    @Local var documentURL = ""
    @Local var selected: UUID?
    @Local var connecting = false
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                List(selection: $selected) { ForEach(workspace.state.bases) { base in VStack(alignment: .leading) { Label(base.name, systemImage: base.isRemote ? "network" : "externaldrive"); Text(base.connected ? base.status : "Disconnected").font(.caption2).foregroundStyle(base.status == "Available" || !base.isRemote ? Color.green : Color.secondary) }.tag(base.id) } }
                TextField("Base name", text: $name)
                Button("Create local Base") { workspace.newLocalBase(name); selected = workspace.state.bases.last?.id; name = "" }
            }.frame(minWidth: 190, idealWidth: 220).padding(8)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("Connect a hosted Base") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Another PC, a private home server, or a VPS can host the source files. Use the host's HTTPS address and a read token; the token stays in macOS Keychain.").font(.caption).foregroundStyle(.secondary)
                            TextField("Friendly name", text: $name)
                            TextField("https://base.example.com", text: $address)
                            SecureField("Read token", text: $token)
                            Button(connecting ? "Connecting…" : "Connect and check access") {
                                connecting = true; let n = name, a = address, t = token; token = ""
                                Task { await workspace.connectBase(name: n, address: a, token: t); selected = workspace.state.bases.last?.id; connecting = false }
                            }.disabled(connecting || address.isEmpty || token.isEmpty)
                            Text("Private HTTP is supported only through localhost/tunnels. Remote addresses are shown here only while entering them; chat context uses the friendly name. Each model turn rechecks access. Deleting a local connection does not delete the remote host's files or revoke a token for other clients; revoke it on the host.").font(.caption2).foregroundStyle(.secondary)
                        }.padding(6)
                    }
                    if let id = selected, let i = workspace.state.bases.firstIndex(where: { $0.id == id }) { baseDetail(i) }
                    else { Text("Select a Base to manage sources, permissions, or chat access.").foregroundStyle(.secondary) }
                }.padding(12)
            }.frame(minWidth: 450)
        }
    }
    @ViewBuilder func baseDetail(_ i: Int) -> some View {
        let base = workspace.state.bases[i]
        GroupBox(base.name) {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Label(base.status, systemImage: base.status == "Available" || !base.isRemote ? "checkmark.circle" : "exclamationmark.circle"); Spacer(); if let date = base.lastChecked { Text(date, style: .relative).font(.caption).foregroundStyle(.secondary) } }
                if !base.detail.isEmpty { Text(base.detail).font(.caption).foregroundStyle(.secondary) }
                Toggle("Allow this Base to provide model context", isOn: $workspace.state.bases[i].canUse)
                if chats.current != nil {
                    Toggle("Use in current chat", isOn: Binding(get: { chats.current?.baseIDs?.contains(base.id) == true }, set: { on in chats.updateCurrent { c in var ids = c.baseIDs ?? []; if on && !ids.contains(base.id) { ids.append(base.id) }; if !on { ids.removeAll { $0 == base.id } }; c.baseIDs = ids } }))
                }
                if base.isRemote {
                    HStack { Button("Check availability") { Task { await workspace.refreshBase(base.id) } }.disabled(!base.connected || workspace.refreshing.contains(base.id)); Button("Disconnect and forget token") { workspace.disconnectBase(base.id) }.disabled(!base.connected) }
                } else {
                    Button("Import source files…") { pickWorkspaceFiles { urls in Task { await workspace.importBaseFiles(base.id, urls: urls) } } }
                    DisclosureGroup("Add text or document-source snapshot") {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Source title", text: $sourceName)
                            TextField("Google Docs or document URL (optional citation)", text: $documentURL)
                            TextEditor(text: $sourceText).frame(height: 100)
                            Text("Paste an exported document, transcript, or caption. Private document links are citations; this app does not sign in to Google or fetch them automatically.").font(.caption2).foregroundStyle(.secondary)
                            Button("Add source") { if workspace.addBaseText(base.id, name: sourceName, text: sourceText, documentURL: documentURL) { sourceName = ""; sourceText = ""; documentURL = "" } }.disabled(sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                Text("\(base.sources.count) indexed sources").font(.headline)
                ForEach(base.sources) { asset in
                    if base.isRemote { WorkspaceAssetRow(asset: asset) }
                    else { WorkspaceAssetRow(asset: asset) { workspace.removeBaseSource(base.id, source: asset.id) } }
                }
                Button("Delete this Base connection", role: .destructive) { workspace.deleteBase(base.id); selected = nil }
            }.padding(8)
        }
    }
}

struct MemoryWorkspaceView: View {
    @ObservedObject var workspace = WorkspaceStore.shared
    @Local var title = ""
    @Local var text = ""
    @Local var scope = "shared"
    @Local var search = ""
    @Local var quotaMB = 256
    var worldID: UUID? { scope.hasPrefix("world:") ? UUID(uuidString: String(scope.dropFirst(6))) : nil }
    var projectID: UUID? { scope.hasPrefix("project:") ? UUID(uuidString: String(scope.dropFirst(8))) : nil }
    var filtered: [VortexMemory] { workspace.state.memories.filter { $0.worldID == worldID && $0.projectID == projectID && (search.isEmpty || ($0.title + " " + $0.text).localizedCaseInsensitiveContains(search)) }.sorted { $0.updated > $1.updated } }
    var body: some View {
        Form {
            Section("Local memory") {
                Toggle("Use saved memory as chat context", isOn: $workspace.state.memoryEnabled)
                Text("Memories stay in this Mac's Application Support folder. Selected memories are sent to the model provider when used in a chat. Vortex remembers only the entries you save here; it does not silently extract or delete memories.").font(.caption).foregroundStyle(.secondary)
                HStack { Text("Storage quota"); TextField("MB", value: $quotaMB, format: .number).frame(width: 90); Text("MB"); Button("Apply quota") { do { guard quotaMB >= 1 && quotaMB <= 16384 else { throw WorkspaceStore.error("Choose a quota from 1 MB to 16 GB.") }; try workspace.setQuota(quotaMB * 1024 * 1024) } catch { workspace.errorMessage = error.localizedDescription } } }
                ProgressView(value: Double(workspace.usedMemoryBytes), total: Double(max(1, workspace.state.memoryQuotaBytes)))
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(workspace.usedMemoryBytes), countStyle: .file)) used of \(ByteCountFormatter.string(fromByteCount: Int64(workspace.state.memoryQuotaBytes), countStyle: .file)). Full memory blocks new entries; existing memories are kept.").font(.caption)
            }
            Section("Memory scope") {
                Picker("Library", selection: $scope) {
                    Text("Shared across chats").tag("shared")
                    ForEach(workspace.state.projects) { p in Text("Project: " + p.name).tag("project:" + p.id.uuidString) }
                    ForEach(workspace.state.worlds) { w in Text("World: " + w.name).tag("world:" + w.id.uuidString) }
                }
                Text(worldID != nil ? "These entries are visible only in this world when its memory is enabled. They never enter shared memory." : projectID != nil ? "These entries are used only in regular chats in this project with shared memory enabled. World chats exclude project memories." : "Each chat can turn shared memory on or off. Roleplay worlds exclude shared memory by default; you may explicitly enable it for a chat.").font(.caption).foregroundStyle(.secondary)
                TextField("Search this library", text: $search)
            }
            Section("Write a memory") {
                TextField("Title", text: $title)
                TextEditor(text: $text).frame(minHeight: 80)
                Button("Save memory") { do { try workspace.upsertMemory(VortexMemory(title: title.isEmpty ? "Memory" : title, text: text, worldID: worldID, projectID: projectID)); title = ""; text = "" } catch { workspace.errorMessage = error.localizedDescription } }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section("Saved entries (\(filtered.count))") {
                if filtered.isEmpty { Text("No entries in this library yet.").foregroundStyle(.secondary) }
                ForEach(filtered) { memory in MemoryEntryView(memoryID: memory.id) }
            }
        }.formStyle(.grouped).onAppear { quotaMB = workspace.state.memoryQuotaBytes / (1024 * 1024) }
    }
}
struct MemoryEntryView: View {
    @ObservedObject var workspace = WorkspaceStore.shared
    let memoryID: UUID
    @Local var editing = false
    @Local var title = ""
    @Local var text = ""
    var body: some View {
        if let memory = workspace.state.memories.first(where: { $0.id == memoryID }) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    if editing {
                        TextField("Title", text: $title); TextEditor(text: $text).frame(height: 100)
                        HStack { Button("Save") { var value = memory; value.title = title; value.text = text; value.updated = Date(); do { try workspace.upsertMemory(value); editing = false } catch { workspace.errorMessage = error.localizedDescription } }; Button("Cancel") { editing = false } }
                    } else { Text(memory.text).textSelection(.enabled) }
                    ForEach(memory.attachments) { asset in WorkspaceAssetRow(asset: asset) }
                    HStack {
                        Button("Edit") { title = memory.title; text = memory.text; editing = true }
                        Button("Attach files…") { pickWorkspaceFiles { urls in Task { await workspace.attachToMemory(memoryID, urls: urls) } } }
                        Spacer(); Button("Delete entry", role: .destructive) { workspace.removeMemory(memoryID) }
                    }
                }.padding(.vertical, 8)
            } label: { HStack { Text(memory.title).font(.headline); Spacer(); Text("\(memory.attachments.count) files").font(.caption).foregroundStyle(.secondary) } }
        }
    }
}

struct PersonalityWorkspaceView: View {
    @EnvironmentObject var chats: ChatStore
    @ObservedObject var workspace = WorkspaceStore.shared
    @Local var selected: UUID?
    @Local var name = ""
    @Local var prompt = ""
    var body: some View {
        HSplitView {
            VStack {
                List(selection: $selected) { ForEach(workspace.personalities) { p in Text(p.name).tag(p.id) } }.onChange(of: selected) { _, id in if let p = workspace.personalities.first(where: { $0.id == id }) { name = p.name; prompt = p.prompt } }
                HStack { Button("New") { selected = nil; name = ""; prompt = "" }; Button("Import…") { let p = NSOpenPanel(); p.allowedContentTypes = [.json]; if p.runModal() == .OK, let u = p.url { do { try workspace.importPersonalities(u) } catch { workspace.errorMessage = error.localizedDescription } } } }
            }.frame(minWidth: 180, idealWidth: 220)
            Form {
                Section("Personality") {
                    TextField("Name", text: $name)
                    Text("A saved style and instruction profile. Importing a personality does not enable tools or grant permissions.").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $prompt).frame(minHeight: 200)
                    HStack {
                        Button("Save personality") { let p = Persona(id: selected ?? UUID(), name: name, prompt: prompt); workspace.savePersonality(p); selected = p.id }.disabled(name.isEmpty || prompt.isEmpty)
                        if let p = workspace.personalities.first(where: { $0.id == selected }) { Button("Export…") { workspace.exportPersonality(p) }; Button("Use in current chat") { chats.updateCurrent { $0.personaID = p.id } }.disabled(chats.current == nil) }
                    }
                }
                Text("These are the same saved personas available in Settings. A project default can be overridden by each chat.").font(.caption).foregroundStyle(.secondary)
                Button("Use project or app personality in current chat") { chats.updateCurrent { $0.personaID = nil } }.disabled(chats.current == nil)
            }.formStyle(.grouped).frame(minWidth: 450)
        }
    }
}

struct WorldsWorkspaceView: View {
    @EnvironmentObject var chats: ChatStore
    @ObservedObject var workspace = WorkspaceStore.shared
    @Local var selected: UUID?
    @Local var name = ""
    var body: some View {
        HSplitView {
            VStack {
                HStack { TextField("New world", text: $name); Button { selected = workspace.newWorld(name); name = "" } label: { Image(systemName: "plus") }.help("Create roleplay world") }
                List(selection: $selected) { ForEach(workspace.state.worlds) { world in Label(world.name, systemImage: "globe.americas").tag(world.id) } }
            }.frame(minWidth: 180, idealWidth: 220).padding(8)
            if let id = selected ?? chats.current?.worldID, let i = workspace.state.worlds.firstIndex(where: { $0.id == id }) { WorldDetailView(world: $workspace.state.worlds[i]) }
            else { WorkspaceEmpty(icon: "globe.americas", title: "Build a world with continuity", detail: "Set the premise, lore, cast, narration style and current state. Save private memories for each world, isolated from everyday chats by default.") }
        }
    }
}
struct WorldDetailView: View {
    @EnvironmentObject var chats: ChatStore
    @ObservedObject var workspace = WorkspaceStore.shared
    @Binding var world: VortexWorld
    var body: some View {
        Form {
            Section("World setup") {
                TextField("World name", text: $world.name)
                Text("Premise and opening situation").font(.headline); TextEditor(text: $world.premise).frame(height: 80)
                Text("Narration style and player boundaries").font(.headline); TextEditor(text: $world.style).frame(height: 70)
                HStack { Button("Start world chat") { chats.newChat(worldID: world.id) }; Button("Use world in current chat") { chats.updateCurrent { $0.worldID = world.id; $0.sharedMemoryEnabled = false } }.disabled(chats.current == nil) }
                if chats.current?.worldID == world.id { Button("Return current chat to general mode") { chats.updateCurrent { $0.worldID = nil } } }
            }
            Section("Continuity") {
                Text("Lore and rules").font(.headline); TextEditor(text: $world.lore).frame(height: 90)
                Text("Characters and relationships").font(.headline); TextEditor(text: $world.characters).frame(height: 90)
                Text("Current state and story log").font(.headline); TextEditor(text: $world.state).frame(height: 90)
                Text("Update the story state explicitly as it evolves. Vortex receives this snapshot on every turn; it does not overwrite the world automatically.").font(.caption).foregroundStyle(.secondary)
                Toggle("Use this world's isolated personal memory", isOn: $world.useMemory)
                Text("Add entries and attachments in Memory → this world's library. Global shared memory is off by default; enable it in a chat only when you want to include personal memory.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Delete world setup and its memories", role: .destructive) {
                let id = world.id; for i in chats.chats.indices where chats.chats[i].worldID == id { chats.chats[i].worldID = nil }; chats.save(); workspace.deleteWorld(id)
            }.help("Chat history is kept; world setup and its local memory copies are removed.")
        }.formStyle(.grouped).frame(minWidth: 450)
    }
}

struct CodingWorkspaceView: View {
    @EnvironmentObject var chats: ChatStore
    @ObservedObject var workspace = WorkspaceStore.shared
    var body: some View {
        Form {
            Section("Coding workflow for this chat") {
                Picker("Mode", selection: Binding(get: { chats.current?.codingMode ?? "off" }, set: { value in chats.updateCurrent { $0.codingMode = value } })) {
                    Text("General chat").tag("off"); Text("Explain code").tag("explain"); Text("Implement a change").tag("implement"); Text("Review a diff").tag("review"); Text("Debug a problem").tag("debug")
                }
                Text("Add the relevant files to a project or attach them to your message. File names and language hints stay with the context. Enabled agents, plugins, MCP and PC tools keep their existing permissions.").font(.callout).foregroundStyle(.secondary)
                Text("Repository overview, reproduction, error output or unified diff").font(.headline)
                TextEditor(text: Binding(get: { chats.current?.codingNotes ?? "" }, set: { value in chats.updateCurrent { $0.codingNotes = value } })).font(.system(.body, design: .monospaced)).frame(minHeight: 250)
                Text("This is explicit task context, not a live repository connection. Vortex can propose diffs and review supplied changes. Applying changes or running builds still requires an enabled tool and its normal permission checks. No command is run by changing this setting.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Project context") {
                Picker("Current project", selection: Binding(get: { chats.current?.projectID }, set: { value in chats.updateCurrent { $0.projectID = value } })) { Text("No project").tag(Optional<UUID>.none); ForEach(workspace.state.projects) { p in Text(p.name).tag(Optional(p.id)) } }
                if let id = chats.current?.projectID, let project = workspace.state.projects.first(where: { $0.id == id }) {
                    ForEach(project.files) { file in WorkspaceAssetRow(asset: file) }
                    Button("Add code or reference files…") { pickWorkspaceFiles { urls in Task { await workspace.attachToProject(id, urls: urls) } } }
                }
            }
        }.formStyle(.grouped).disabled(chats.current == nil)
    }
}

struct WorkspaceContextBar: View {
    @EnvironmentObject var chats: ChatStore
    @ObservedObject var workspace = WorkspaceStore.shared
    let open: (String) -> Void
    var body: some View {
        HStack(spacing: 12) {
            Button { open("projects") } label: { Label(workspace.state.projects.first(where: { $0.id == chats.current?.projectID })?.name ?? "Add to a project", systemImage: "folder") }.buttonStyle(.borderless)
            if let id = chats.current?.worldID, let world = workspace.state.worlds.first(where: { $0.id == id }) {
                Button { open("worlds") } label: { Label(world.name, systemImage: "globe.americas") }.buttonStyle(.borderless)
            }
            Toggle("Shared memory", isOn: Binding(get: { chats.current?.sharedMemoryEnabled ?? false }, set: { value in chats.updateCurrent { $0.sharedMemoryEnabled = value } })).toggleStyle(.switch).controlSize(.mini).help("When enabled, this chat may use the manual shared-memory library. World memory remains isolated; shared memory is off by default in world chats. Memories are sent to the selected model provider.")
            Spacer()
            Button { open("coding") } label: { Image(systemName: "curlybraces"); Text(chats.current?.codingMode == "off" || chats.current?.codingMode == nil ? "Code" : (chats.current?.codingMode?.capitalized ?? "Code")) }.buttonStyle(.borderless)
            Button { open("bases") } label: { Label("Bases", systemImage: "externaldrive.connected.to.line.below") }.buttonStyle(.borderless)
            Button { open("memory") } label: { Image(systemName: "brain") }.buttonStyle(.borderless).help("Manage local memory")
        }.font(.caption).padding(.horizontal, 18).padding(.vertical, 9).background(.bar)
    }
}

/// Fenced code keeps its language hint and has an explicit copy action; diff lines retain readable colors.
struct WorkspaceMessageBody: View {
    let content: String
    let markdown: Bool
    struct Segment: Identifiable { var id: Int; var text: String; var language: String? }
    var segments: [Segment] {
        let pieces = content.components(separatedBy: "```")
        return pieces.enumerated().map { index, text in
            if index % 2 == 0 { return Segment(id: index, text: text, language: nil) }
            let lines = text.components(separatedBy: "\n")
            return Segment(id: index, text: lines.dropFirst().joined(separator: "\n"), language: lines.first ?? "")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(segments) { segment in
                if let language = segment.language {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack { Text(language.isEmpty ? "Code" : language).font(.caption.monospaced()); Spacer(); Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(segment.text, forType: .string) }.buttonStyle(.borderless).font(.caption) }.padding(8).background(Color.primary.opacity(0.04))
                        ScrollView(.horizontal) {
                            if language == "diff" || language == "patch" {
                                VStack(alignment: .leading, spacing: 0) { ForEach(Array(segment.text.components(separatedBy: "\n").enumerated()), id: \.offset) { line in Text(line.element.isEmpty ? " " : line.element).foregroundStyle(line.element.hasPrefix("+") ? Color.green : line.element.hasPrefix("-") ? Color.red : Color.primary) } }.font(.system(.body, design: .monospaced)).padding(12)
                            } else { Text(segment.text).font(.system(.body, design: .monospaced)).padding(12) }
                        }
                    }.background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05))).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
                } else if !segment.text.isEmpty {
                    if markdown, let attributed = try? AttributedString(markdown: segment.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) { Text(attributed) } else { Text(segment.text) }
                }
            }
        }
    }
}
