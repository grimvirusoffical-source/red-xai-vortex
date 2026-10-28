import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(\.royalPalette) private var palette
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var tunnel: TunnelManager
    @ObservedObject private var account = AccountGate.shared
    @AppStorage("accent", store: AccountProfile.preferences) var accent = "red"
    @AppStorage("useTunnel", store: AccountProfile.preferences) var useTunnel = true
    @AppStorage("sshHost", store: AccountProfile.preferences) var sshHost = Defaults.sshHost
    @AppStorage("sshKey", store: AccountProfile.preferences) var sshKey = "~/.ssh/id_ed25519"
    @AppStorage("sshLocalPort", store: AccountProfile.preferences) var sshLocalPort = Defaults.sshLocalPort
    @AppStorage("sshRemotePort", store: AccountProfile.preferences) var sshRemotePort = Defaults.sshRemotePort
    @Local var search = ""
    @Local var renaming: UUID?
    @Local var renameText = ""
    @Local var partyHint = false
    @Local var showActivity = false
    @StateObject var agents = AgentStore.shared
    @ObservedObject var workspace = WorkspaceStore.shared
    @Local var showWorkspace = false
    @Local var workspaceTab = "projects"
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    @ViewBuilder func chatRow(_ c: Chat) -> some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 2).fill(store.selection == c.id ? RoyalTheme.accent : .clear).frame(width: 3, height: 27)
            Image(systemName: c.worldID != nil ? "globe.americas" : (c.participants?.count ?? 0) >= 2 ? "person.3" : "bubble.left")
                .font(.system(size: 12)).foregroundStyle(RoyalTheme.accent.opacity(0.8)).frame(width: 17)
            VStack(alignment: .leading, spacing: 4) {
                Text(c.title).font(.system(size: 13, weight: store.selection == c.id ? .semibold : .regular)).lineLimit(1).foregroundStyle(RoyalTheme.text)
                Text(c.updated, style: .relative).font(.system(size: 10)).foregroundStyle(RoyalTheme.secondary)
            }
            Spacer(minLength: 0)
            if c.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Color.accent(accent)) }
        }.padding(.vertical, 5)
        .tag(c.id)
        .listRowBackground(store.selection == c.id ? RoyalTheme.selection : Color.clear)
        .contextMenu {
            Button("Rename") { renaming = c.id; renameText = c.title }
            Button(c.pinned ? "Unpin" : "Pin") { store.togglePin(c.id) }
            Divider()
            Button("Delete", role: .destructive) { store.delete(c.id) }
        }
    }

    var filtered: [Chat] {
        search.isEmpty ? store.sorted : store.sorted.filter { c in
            c.title.localizedCaseInsensitiveContains(search) || c.messages.contains { $0.content.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        let _ = palette
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 15) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Your space").font(.system(size: 23, weight: .semibold, design: .rounded)).foregroundStyle(RoyalTheme.text)
                        Text("Chats, knowledge & worlds").font(.system(size: 12)).foregroundStyle(RoyalTheme.secondary)
                    }
                    Button { store.newChat() } label: { HStack { Image(systemName: "plus"); Text("New conversation"); Spacer(); Image(systemName: "square.and.pencil") }.frame(maxWidth: .infinity) }
                        .buttonStyle(RoyalButtonStyle(prominent: true)).help("New Chat · ⌘N")
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(RoyalTheme.secondary)
                        TextField("Search chats", text: $search).textFieldStyle(.plain).font(.system(size: 12)).accessibilityLabel("Search chats")
                        if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search") }
                    }.padding(10).background(RoundedRectangle(cornerRadius: 10).fill(RoyalTheme.background)).overlay(RoundedRectangle(cornerRadius: 10).stroke(RoyalTheme.line))
                }.padding(.horizontal, 19).padding(.top, 24).padding(.bottom, 12)
                List(selection: $store.selection) {
                    Section {
                        workspaceLink("Workspace", icon: "square.grid.2x2", tab: "projects")
                        workspaceLink("XAI Bases", icon: "externaldrive.connected.to.line.below", tab: "bases")
                        workspaceLink("Roleplay worlds", icon: "globe.americas", tab: "worlds")
                    }
                    Section("Projects") {
                        ForEach(workspace.state.projects) { project in
                            DisclosureGroup {
                                ForEach(filtered.filter { $0.projectID == project.id }) { c in chatRow(c) }
                                Button { store.newChat(projectID: project.id) } label: { Label("New project chat", systemImage: "plus") }.buttonStyle(.borderless)
                            } label: { Label(project.name, systemImage: "folder").font(.system(size: 12, weight: .medium)) }
                        }
                        Button { workspaceTab = "projects"; showWorkspace = true } label: { Label("Manage projects", systemImage: "folder.badge.plus") }.buttonStyle(.borderless).font(.system(size: 12))
                    }
                    Section("Chats") { ForEach(filtered.filter { ($0.participants ?? []).isEmpty && $0.projectID == nil && $0.worldID == nil }) { c in chatRow(c) } }
                    if !filtered.filter({ $0.worldID != nil && $0.projectID == nil }).isEmpty {
                        Section("World chats") { ForEach(filtered.filter { $0.worldID != nil && $0.projectID == nil }) { c in chatRow(c) } }
                    }
                    Section("Agents") {
                        ForEach(agents.agents) { a in
                            let c = store.chats.first { $0.participants == ["agent:" + a.id] }
                            HStack(spacing: 9) { Image(systemName: "cpu").foregroundStyle(RoyalTheme.accent); Text(a.name).lineLimit(1); Spacer(); Text(a.model).font(.system(size: 10)).foregroundStyle(RoyalTheme.secondary) }
                                .font(.system(size: 12)).padding(.vertical, 5)
                                .tag(c?.id ?? UUID()).contentShape(Rectangle()).onTapGesture { store.openAgentChat(a) }
                        }
                    }
                    Section("Party chats") {
                        ForEach(filtered.filter { ($0.participants?.count ?? 0) >= 2 || ($0.participants == nil && $0.title == "Party chat") }) { c in chatRow(c) }
                        Button { store.newParty(); partyHint = true } label: { Label("New party chat", systemImage: "person.3") }.buttonStyle(.borderless).font(.system(size: 12))
                    }
                    Section("Activity") {
                        Button { showActivity = true } label: { Label("Activity and dashboard", systemImage: "list.bullet.rectangle") }.buttonStyle(.borderless).font(.system(size: 12))
                    }
                }.listStyle(.sidebar).scrollContentBackground(.hidden).background(RoyalTheme.sidebar)
                VStack(spacing: 0) {
                    Rectangle().fill(RoyalTheme.line).frame(height: 1)
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle").foregroundStyle(RoyalTheme.secondary)
                        Text(account.signedIn ? "Signed in: \(account.username)" : "Owner mode")
                            .font(.system(size: 11)).foregroundStyle(RoyalTheme.secondary).lineLimit(1)
                        Spacer(minLength: 2)
                        Button {
                            Task { await account.signOut() }
                        } label: {
                            Label("Log out", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        .buttonStyle(RoyalButtonStyle(compact: true))
                        .accessibilityIdentifier("vortex-sign-out")
                    }.padding(.horizontal, 15).padding(.vertical, 12)
                    HStack(spacing: 8) {
                        Circle().fill(tunnel.running ? .green : (useTunnel ? .orange : RoyalTheme.secondary)).frame(width: 6, height: 6)
                        Text(useTunnel ? (tunnel.running ? (tunnel.external ? "Tunnel up (shared)" : "Tunnel up") : "Tunnel down") : "Direct connection").font(.system(size: 11)).foregroundStyle(RoyalTheme.secondary)
                        Spacer(minLength: 4)
                        if useTunnel {
                            Button(tunnel.running ? (tunnel.external ? "Connected" : "Stop") : "Connect") {
                                (tunnel.running && !tunnel.external) ? tunnel.stop() : tunnel.start(host: sshHost, local: sshLocalPort, remote: sshRemotePort, keyPath: sshKey)
                            }.buttonStyle(RoyalButtonStyle(compact: true))
                        }
                    }.padding(15)
                }
            }.background(RoyalTheme.sidebar)
                .navigationSplitViewColumnWidth(min: 225, ideal: 270, max: 350)
        } detail: {
            ChatView(toggleSidebar: { columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly })
        }
        .toolbar(.hidden, for: .windowToolbar)
        .background(RoyalTheme.background).foregroundStyle(RoyalTheme.text).tint(Color.accent(accent))
        .onAppear {
            if useTunnel && !tunnel.running { tunnel.start(host: sshHost, local: sshLocalPort, remote: sshRemotePort, keyPath: sshKey) }
        }
        .sheet(isPresented: $showWorkspace) { WorkspacePanel(initialTab: workspaceTab).environmentObject(store) }
        .sheet(isPresented: $partyHint) { GroupSetupView().environmentObject(store) }
        .sheet(isPresented: $showActivity) { ActivityView() }
        .alert("Rename Chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Save") { if let r = renaming { store.rename(r, renameText) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    func workspaceLink(_ title: String, icon: String, tab: String) -> some View {
        Button { workspaceTab = tab; showWorkspace = true } label: {
            HStack(spacing: 10) { Image(systemName: icon).foregroundStyle(RoyalTheme.accent).frame(width: 17); Text(title).font(.system(size: 12, weight: .medium)); Spacer(); Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(RoyalTheme.secondary) }.padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct ChatView: View {
    @Environment(\.royalPalette) private var palette
    var toggleSidebar: () -> Void = {}
    @EnvironmentObject var store: ChatStore
    @AppStorage("serverURL", store: AccountProfile.preferences) var serverURL = Defaults.serverURL
    @AppStorage("model", store: AccountProfile.preferences) var model = Defaults.model
    @AppStorage("temperature", store: AccountProfile.preferences) var temperature = 0.7
    @AppStorage("topP", store: AccountProfile.preferences) var topP = 0.9
    @AppStorage("topK", store: AccountProfile.preferences) var topK = 40
    @AppStorage("maxTokens", store: AccountProfile.preferences) var maxTokens = 1024
    @AppStorage("contextTokens", store: AccountProfile.preferences) var contextTokens = 8192
    @AppStorage("repeatPenalty", store: AccountProfile.preferences) var repeatPenalty = 1.1
    @AppStorage("seed", store: AccountProfile.preferences) var seed = -1
    @AppStorage("systemPrompt", store: AccountProfile.preferences) var systemPrompt = Defaults.systemPrompt
    @AppStorage("sendOnEnter", store: AccountProfile.preferences) var sendOnEnter = true
    @AppStorage("fontSize", store: AccountProfile.preferences) var fontSize = 14.0
    @AppStorage("accent", store: AccountProfile.preferences) var accent = "red"
    @Local var input = ""
    @Local var pending: [Attachment] = []
    @Local var attachError = ""
    @Local var dropTarget = false
    @StateObject var skills = SkillStore.shared
    @Local var voiceCall = false
    @Local var groupSetup = false
    @Local var showWorkspace = false
    @Local var workspaceTab = "projects"

    var params: ChatParams {
        let projectModel = WorkspaceStore.shared.state.projects.first(where: { $0.id == store.current?.projectID })?.model.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = ChatParams(baseURL: serverURL, apiKey: Keychain.get() ?? "", model: projectModel.isEmpty ? model : projectModel, temperature: temperature, topP: topP,
                   repeatPenalty: repeatPenalty, topK: topK, maxTokens: maxTokens, seed: seed)
        return AgentStore.shared.chatParams(fallback: base)
    }

    var body: some View {
        let _ = palette
        VStack(spacing: 0) {
            conversationHeader
            WorkspaceContextBar { tab in workspaceTab = tab; showWorkspace = true }
                .font(.system(size: 11)).background(RoyalTheme.surface.opacity(0.65))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        if let c = store.current {
                            if c.messages.isEmpty { welcome }
                            ForEach(c.messages) { m in BubbleView(message: m).id(m.id) }
                        }
                    }.padding(.horizontal, 30).padding(.vertical, 30).frame(maxWidth: RoyalTheme.contentWidth).frame(maxWidth: .infinity)
                }
                .onChange(of: store.current?.messages.last?.content) { _, _ in
                    if let id = store.current?.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            VStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 8) {
                    ActiveItemsBar()
                    if !pending.isEmpty { AttachmentChips(items: pending) { a in pending.removeAll { $0.id == a.id } }.padding(.horizontal, 12) }
                    if !attachError.isEmpty { Label(attachError, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red).padding(.horizontal, 12) }
                    HStack(alignment: .bottom, spacing: 10) {
                        ChatPlusMenu(upload: pickFiles) { tab in HubNav.open(tab) }.padding(.bottom, 8)
                        ComposeField(text: $input, sendOnEnter: sendOnEnter, fontSize: fontSize, onSend: send).frame(minHeight: 58, maxHeight: 140)
                        if store.streaming {
                            Button { store.stop() } label: { Image(systemName: "stop.fill").frame(width: 17, height: 20) }.buttonStyle(RoyalButtonStyle(prominent: true)).help("Stop generating").accessibilityLabel("Stop generating")
                        } else {
                            Button { send() } label: { Image(systemName: "arrow.up").font(.system(size: 17, weight: .semibold)).frame(width: 17, height: 20) }
                                .buttonStyle(RoyalButtonStyle(prominent: true)).help("Send message").accessibilityLabel("Send message").disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pending.isEmpty)
                        }
                    }.padding(.horizontal, 14).padding(.bottom, 4)
                    Rectangle().fill(RoyalTheme.line).frame(height: 1).padding(.horizontal, 14)
                    ComposerBar().padding(.horizontal, 14).padding(.bottom, 11)
                }.padding(.top, 7).background(RoundedRectangle(cornerRadius: 20).fill(RoyalTheme.surface)).overlay(RoundedRectangle(cornerRadius: 20).stroke(RoyalTheme.accent.opacity(0.28))).shadow(color: .black.opacity(0.13), radius: 16, y: 5)
                HStack(spacing: 8) {
                    Text(store.status.isEmpty ? "Make space for your next idea." : store.status).font(.system(size: 10)).foregroundStyle(RoyalTheme.secondary).lineLimit(1)
                    Spacer(minLength: 5)
                    Text(sendOnEnter ? "Enter to send · Shift+Enter for a new line" : "⌘Enter to send").font(.system(size: 10)).foregroundStyle(RoyalTheme.secondary)
                }.padding(.horizontal, 7)
            }.frame(maxWidth: RoyalTheme.contentWidth).padding(.horizontal, 25).padding(.top, 8).padding(.bottom, 16).frame(maxWidth: .infinity).background(RoyalTheme.background)
        }.background(RoyalTheme.background)
        .sheet(isPresented: $showWorkspace) { WorkspacePanel(initialTab: workspaceTab).environmentObject(store) }
        .sheet(isPresented: $groupSetup) { GroupSetupView().environmentObject(store) }
        .sheet(isPresented: $voiceCall) { VoiceCallView { t in input = t; send() }.environmentObject(store) }
        .overlay { if dropTarget { RoundedRectangle(cornerRadius: 12).stroke(Color.accent(accent), lineWidth: 3).padding(4).allowsHitTesting(false) } }
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { Task { @MainActor in await add([u]) } } }
            }
            return true
        }
        .task { ChatStoreRef.store = store; await refreshModels(); try? await HubStore.shared.loadMerges() }
    }

    var conversationHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button(action: toggleSidebar) { Image(systemName: "sidebar.left").frame(width: 15, height: 16) }.buttonStyle(RoyalButtonStyle(compact: true)).help("Show or hide sidebar").accessibilityLabel("Show or hide sidebar")
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.current?.title ?? "New conversation").font(.system(size: 18, weight: .semibold)).lineLimit(1)
                    Text(store.streaming ? "Vortex is responding…" : "A little context. Endless possibilities.").font(.system(size: 11)).foregroundStyle(RoyalTheme.secondary)
                }
                Spacer(minLength: 4)
                PCControlStatusView()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    Picker("Model", selection: $model) {
                        ForEach(Array(Set(store.availableModels + LocalRuntime.shared.models.map { "local:\($0)" } + [model])).sorted(), id: \.self) { Text(Defaults.displayName($0)).tag($0) }
                    }.frame(width: 210).controlSize(.small).help("Choose a model")
                    Toggle(isOn: Binding(get: { ToolRegistry.chatToolsOn }, set: { ToolRegistry.chatToolsOn = $0; store.objectWillChange.send() })) { Label("Tools", systemImage: "wrench.and.screwdriver") }.toggleStyle(.button).help("Let the model call tools (plugins, MCP, PC control)")
                    Button { groupSetup = true } label: { Image(systemName: (store.current?.participants?.isEmpty == false) ? "person.3.fill" : "person.3") }.help("Group chat: several models reply in turn; @mention one to ask only it").accessibilityLabel("Group chat")
                    Button { voiceCall = true } label: { Image(systemName: "phone") }.help("Voice call (whisper.cpp + Piper on this Mac)").accessibilityLabel("Start voice call")
                    Button { if let u = URL(string: AccountProfile.preferences.string(forKey: "cloudpc.url") ?? "https://45.77.105.187/vortex/cloudpc/") { NSWorkspace.shared.open(u) } } label: { Image(systemName: "cloud") }.help("Cloud PC: open your private Linux desktop in the browser").accessibilityLabel("Open Cloud PC")
                    Button { store.regenerate(systemPrompt: systemPrompt, contextTokens: contextTokens, params: params) } label: { Image(systemName: "arrow.clockwise") }.help("Regenerate last reply").accessibilityLabel("Regenerate last reply").disabled(store.streaming)
                    OpenHubToolbar()
                    SettingsLink { Image(systemName: "gearshape") }.help("Settings").accessibilityLabel("Settings")
                }.buttonStyle(RoyalButtonStyle(compact: true)).padding(.vertical, 1)
            }
        }.padding(.horizontal, 25).padding(.vertical, 18).background(RoyalTheme.background).overlay(alignment: .bottom) { Rectangle().fill(RoyalTheme.line).frame(height: 1) }
    }
    var welcome: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 9) { Rectangle().fill(RoyalTheme.accent).frame(width: 24, height: 1); Text("ROOM FOR YOUR NEXT IDEA").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(RoyalTheme.accent) }
            Text("What shall we\ncreate today?").font(.system(size: 43, weight: .medium, design: .serif)).tracking(-1).foregroundStyle(RoyalTheme.text).fixedSize(horizontal: false, vertical: true)
            Text("Build something useful, follow your curiosity, or step into a world of your own.").font(.system(size: 14)).foregroundStyle(RoyalTheme.secondary).lineSpacing(4).frame(maxWidth: 440, alignment: .leading)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 11) {
                starter("Build something", detail: "Turn a goal into working code", icon: "curlybraces", prompt: "Help me plan a code change. First, ask for the files and goal you need.")
                starter("Review a change", detail: "A second look at your diff", icon: "text.magnifyingglass", prompt: "Review the diff I will provide for bugs, regressions, and security issues.")
                starter("Your knowledge", detail: "Connect files and XAI Bases", icon: "externaldrive", tab: "bases")
                starter("Enter a world", detail: "Give your next story a home", icon: "globe.americas", tab: "worlds")
            }.frame(maxWidth: 610).padding(.top, 12)
            HStack(spacing: 6) { Circle().fill(RoyalTheme.accent).frame(width: 4, height: 4); Text(Defaults.displayName(params.model)).font(.system(size: 10)).foregroundStyle(RoyalTheme.secondary) }
        }.frame(maxWidth: 650, alignment: .leading).padding(.top, 32).padding(.bottom, 26).frame(maxWidth: .infinity)
    }
    @ViewBuilder func starter(_ title: String, detail: String, icon: String, prompt: String? = nil, tab: String? = nil) -> some View {
        Button {
            if let tab { workspaceTab = tab; showWorkspace = true }
            if let prompt { input = prompt }
        } label: {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: icon).font(.system(size: 17, weight: .light)).foregroundStyle(RoyalTheme.accent).frame(width: 23, height: 25)
                VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(RoyalTheme.text); Text(detail).font(.system(size: 11)).foregroundStyle(RoyalTheme.secondary).fixedSize(horizontal: false, vertical: true) }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(RoyalTheme.accent.opacity(0.7))
            }.padding(17).frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
        }.buttonStyle(.plain).background(RoundedRectangle(cornerRadius: 15).fill(RoyalTheme.surface)).overlay(RoundedRectangle(cornerRadius: 15).stroke(RoyalTheme.line))
    }
    func refreshModels() async {
        if let m = try? await API.models(base: serverURL, key: Keychain.get() ?? ""), !m.isEmpty { store.availableModels = m }
    }
    func send() {
        var t = input; let a = pending; input = ""; pending = []; attachError = ""
        if a.isEmpty, let ms = MediaSpec.parse(t) {
            if store.selection == nil { store.newChat() }
            let cid = store.selection; Task { await MediaLibrary.shared.submit(ms, chat: store, chatID: cid) }; return
        }
        skills.applySlash(&t)
        if t.isEmpty && a.isEmpty { store.status = skills.always.isEmpty ? "No always-on skills" : "Always on: " + skills.always.map(\.name).joined(separator: ", "); return }
        var p = params
        if let m = skills.preferredModel { p.model = m }
        if a.contains(where: { $0.kind == "image" }) && !(model.contains("vision") || model.contains("vl") || model.hasPrefix("ext:")) {
            store.status = "Tip: images need a vision model (e.g. gemma3-12b-vision)."
        }
        var sp = skills.systemPrompt(base: AgentStore.shared.active?.systemPrompt ?? systemPrompt)
        let comp = store.current?.composer ?? Composer.globalDefault
        Composer.apply(comp, params: &p, systemPrompt: &sp)
        if store.current?.composer == nil, let i = store.chats.firstIndex(where: { $0.id == store.selection }) { store.chats[i].composer = comp }
        store.send(t, attachments: a, systemPrompt: sp, contextTokens: contextTokens, params: p)
    }
    func pickFiles() {
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = false
        p.message = "Attach text, code, PDF or image files as context"
        p.begin { r in if r == .OK { let urls = p.urls; Task { @MainActor in await add(urls) } } }
    }
    @MainActor func add(_ urls: [URL]) async {
        attachError = ""
        for u in urls {
            do { let a = try await AttachmentLoader.load(u); if !pending.contains(where: { $0.name == a.name && $0.bytes == a.bytes }) { pending.append(a) } }
            catch { attachError = error.localizedDescription }
        }
    }
}

struct ComposeField: View {
    @Environment(\.royalPalette) private var palette
    @Binding var text: String
    var sendOnEnter: Bool
    var fontSize: Double
    var onSend: () -> Void
    var body: some View {
        let _ = palette
        TextEditor(text: $text)
            .font(.system(size: fontSize))
            .scrollContentBackground(.hidden)
            .foregroundStyle(RoyalTheme.text)
            .padding(.vertical, 8)
            .overlay(alignment: .topLeading) { if text.isEmpty { Text("Message Vortex…").font(.system(size: fontSize)).foregroundStyle(RoyalTheme.secondary).padding(.top, 14).padding(.leading, 5).allowsHitTesting(false) } }
            .accessibilityLabel("Message Vortex")
            .onKeyPress(.return, phases: .down) { press in
                if sendOnEnter && !press.modifiers.contains(.shift) { onSend(); return .handled }
                if !sendOnEnter && press.modifiers.contains(.command) { onSend(); return .handled }
                return .ignored
            }
    }
}

struct BubbleView: View {
    @Environment(\.royalPalette) private var palette
    let message: Message
    @AppStorage("bubbleStyle", store: AccountProfile.preferences) var bubbleStyle = "rounded"
    @AppStorage("markdown", store: AccountProfile.preferences) var markdown = true
    @AppStorage("fontSize", store: AccountProfile.preferences) var fontSize = 14.0
    @AppStorage("accent", store: AccountProfile.preferences) var accent = "red"
    @AppStorage("showTimestamps", store: AccountProfile.preferences) var showTimestamps = false
    var isUser: Bool { message.role == "user" }

    var rendered: Text {
        if markdown, let a = try? AttributedString(markdown: message.content,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) { return Text(a) }
        return Text(message.content)
    }
    var body: some View {
        let _ = palette
        HStack(alignment: .top, spacing: 12) {
            if isUser { Spacer(minLength: 48) }
            if !isUser { avatar }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Text(isUser ? "You" : message.model.map(GroupTurns.label) ?? "Vortex").font(.system(size: 11, weight: .semibold)).foregroundStyle(isUser ? RoyalTheme.secondary : RoyalTheme.accent)
                    if let who = message.model, !isUser { Circle().fill(GroupColors.color(who)).frame(width: 4, height: 4) }
                    if showTimestamps { Text(message.date, style: .time).font(.system(size: 10)).foregroundStyle(RoyalTheme.secondary) }
                }
                if let a = message.attachments, !a.isEmpty { AttachmentChips(items: a) }
                if let l = message.toolLog {
                    let off = Array(Set(l.compactMap { $0.hasPrefix(PCControl.offMarker) ? PCKind(rawValue: String($0.dropFirst(PCControl.offMarker.count))) : nil }))
                    ForEach(off) { PCTurnOnButton(kind: $0) }
                }
                if let l = message.toolLog, !l.isEmpty {
                    DisclosureGroup("\(l.count) tool call(s)") {
                        VStack(alignment: .leading, spacing: 4) { ForEach(Array(l.enumerated()), id: \.offset) { Text($0.element).font(.caption.monospaced()).textSelection(.enabled) } }
                    }.font(.system(size: 11)).foregroundStyle(RoyalTheme.secondary).padding(11).background(RoundedRectangle(cornerRadius: 11).fill(RoyalTheme.surface))
                }
                Group {
                    if message.content.isEmpty { TypingIndicator() }
                    else if let mid = MediaCard.mediaID(message.content) { MediaCard(id: mid, chat: ChatStoreRef.store) }
                    else { WorkspaceMessageBody(content: message.content, markdown: markdown) }
                }
                .font(.system(size: fontSize)).lineSpacing(5)
                .textSelection(.enabled)
                .padding(bubbleStyle == "minimal" ? 4 : 17)
                .background(bg)
                .foregroundStyle(RoyalTheme.text)
                .contextMenu {
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.content, forType: .string) }
                }
                FeedbackBar(message: message)
            }
            if isUser { avatar }
            if !isUser { Spacer(minLength: 20) }
        }
    }
    var avatar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(isUser ? Color.accent(accent).opacity(0.12) : RoyalTheme.surface)
            RoundedRectangle(cornerRadius: 10).stroke(isUser ? Color.accent(accent).opacity(0.3) : RoyalTheme.line)
            Image(systemName: isUser ? "person.fill" : "sparkle").font(.system(size: 14)).foregroundStyle(isUser ? Color.accent(accent) : RoyalTheme.accent)
        }.frame(width: 33, height: 33).accessibilityHidden(true)
    }
    @ViewBuilder var bg: some View {
        let fill = isUser ? Color.accent(accent).opacity(0.12) : RoyalTheme.surface
        let stroke = isUser ? Color.accent(accent).opacity(0.22) : RoyalTheme.line
        switch bubbleStyle {
        case "square": RoundedRectangle(cornerRadius: 3).fill(fill).overlay(RoundedRectangle(cornerRadius: 3).stroke(stroke))
        case "minimal": Color.clear
        default: RoundedRectangle(cornerRadius: 17).fill(fill).overlay(RoundedRectangle(cornerRadius: 17).stroke(stroke))
        }
    }
}

/// Three pulsing dots shown while Vortex writes a reply.
struct TypingIndicator: View {
    @Environment(\.royalPalette) private var palette
    @Local var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let _ = palette
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle().frame(width: 7, height: 7).opacity(on ? 1 : 0.25)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2), value: on)
            }
        }
        .padding(.vertical, 4)
        .foregroundStyle(RoyalTheme.accent)
        .onAppear { on = !reduceMotion }
        .onChange(of: reduceMotion) { _, value in on = !value }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Vortex is typing")
    }
}

struct OpenHubToolbar: View {
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Button { ModelBrowserServer.shared.open() } label: { Image(systemName: "safari") }.help("Browse Models (opens in your browser)")
        NotifBell()
        Button { openWindow(id: "hub") } label: { Image(systemName: "books.vertical") }.help("Model Library, Merges, Servers, Providers & API Keys")
            .onAppear { HubNav.opener = { openWindow(id: "hub") } }
    }
}

struct NotifBell: View {
    @ObservedObject var n = NotificationStore.shared
    var body: some View {
        Button { HubNav.open("notifications") } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: n.unread > 0 ? "bell.badge" : "bell")
                if n.unread > 0 {
                    Text("\(min(n.unread, 99))").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 3).background(Capsule().fill(.red)).offset(x: 8, y: -6)
                }
            }
        }.help("Notifications")
    }
}
