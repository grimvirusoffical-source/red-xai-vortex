import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var tunnel: TunnelManager
    @AppStorage("accent") var accent = "red"
    @AppStorage("useTunnel") var useTunnel = true
    @AppStorage("sshHost") var sshHost = Defaults.sshHost
    @AppStorage("sshKey") var sshKey = "~/.ssh/id_ed25519"
    @AppStorage("sshLocalPort") var sshLocalPort = Defaults.sshLocalPort
    @AppStorage("sshRemotePort") var sshRemotePort = Defaults.sshRemotePort
    @Local var search = ""
    @Local var renaming: UUID?
    @Local var renameText = ""

    var filtered: [Chat] {
        search.isEmpty ? store.sorted : store.sorted.filter { c in
            c.title.localizedCaseInsensitiveContains(search) || c.messages.contains { $0.content.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $store.selection) {
                ForEach(filtered) { c in
                    HStack {
                        if c.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(Color.accent(accent)) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).lineLimit(1)
                            Text(c.updated, style: .relative).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .tag(c.id)
                    .contextMenu {
                        Button("Rename") { renaming = c.id; renameText = c.title }
                        Button(c.pinned ? "Unpin" : "Pin") { store.togglePin(c.id) }
                        Divider()
                        Button("Delete", role: .destructive) { store.delete(c.id) }
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Circle().fill(tunnel.running ? .green : (useTunnel ? .orange : .gray)).frame(width: 8, height: 8)
                    Text(useTunnel ? (tunnel.running ? (tunnel.external ? "Tunnel up (shared)" : "Tunnel up") : "Tunnel down") : "Direct").font(.caption)
                    Spacer()
                    if useTunnel {
                        Button(tunnel.running ? (tunnel.external ? "Connected" : "Stop") : "Connect") {
                            (tunnel.running && !tunnel.external) ? tunnel.stop() : tunnel.start(host: sshHost, local: sshLocalPort, remote: sshRemotePort, keyPath: sshKey)
                        }.controlSize(.small)
                    }
                }.padding(8)
            }
            .toolbar { Button { store.newChat() } label: { Image(systemName: "square.and.pencil") }.help("New Chat") }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            ChatView()
        }
        .tint(Color.accent(accent))
        .onAppear {
            if useTunnel && !tunnel.running { tunnel.start(host: sshHost, local: sshLocalPort, remote: sshRemotePort, keyPath: sshKey) }
        }
        .alert("Rename Chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Save") { if let r = renaming { store.rename(r, renameText) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
}

struct ChatView: View {
    @EnvironmentObject var store: ChatStore
    @AppStorage("serverURL") var serverURL = Defaults.serverURL
    @AppStorage("model") var model = Defaults.model
    @AppStorage("temperature") var temperature = 0.7
    @AppStorage("topP") var topP = 0.9
    @AppStorage("topK") var topK = 40
    @AppStorage("maxTokens") var maxTokens = 1024
    @AppStorage("contextTokens") var contextTokens = 8192
    @AppStorage("repeatPenalty") var repeatPenalty = 1.1
    @AppStorage("seed") var seed = -1
    @AppStorage("systemPrompt") var systemPrompt = Defaults.systemPrompt
    @AppStorage("sendOnEnter") var sendOnEnter = true
    @AppStorage("fontSize") var fontSize = 14.0
    @AppStorage("accent") var accent = "red"
    @Local var input = ""
    @Local var pending: [Attachment] = []
    @Local var attachError = ""
    @Local var dropTarget = false
    @StateObject var skills = SkillStore.shared
    @Local var voiceCall = false

    var params: ChatParams {
        ChatParams(baseURL: serverURL, apiKey: Keychain.get() ?? "", model: model, temperature: temperature, topP: topP,
                   repeatPenalty: repeatPenalty, topK: topK, maxTokens: maxTokens, seed: seed)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let c = store.current {
                            if c.messages.isEmpty {
                                VStack(spacing: 8) {
                                    Text("🐬").font(.system(size: 56))
                                    Text("Red-XAI Vortex").font(.largeTitle.bold())
                                    Text("Model: \(model)").foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity).padding(.top, 80)
                            }
                            ForEach(c.messages) { m in BubbleView(message: m).id(m.id) }
                        }
                    }.padding()
                }
                .onChange(of: store.current?.messages.last?.content) { _, _ in
                    if let id = store.current?.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            Divider()
            if !pending.isEmpty || !attachError.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if !pending.isEmpty { AttachmentChips(items: pending) { a in pending.removeAll { $0.id == a.id } } }
                    if !attachError.isEmpty { Text(attachError).font(.caption).foregroundStyle(.red) }
                }.padding(.horizontal, 10).padding(.top, 8)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button { pickFiles() } label: { Image(systemName: "plus.circle.fill").font(.title) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Attach files: text, code, PDF, images")
                ComposeField(text: $input, sendOnEnter: sendOnEnter, fontSize: fontSize, onSend: send)
                    .frame(minHeight: 36, maxHeight: 140)
                if store.streaming {
                    Button { store.stop() } label: { Image(systemName: "stop.circle.fill").font(.title) }.buttonStyle(.plain)
                } else {
                    Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                        .buttonStyle(.plain).foregroundStyle(Color.accent(accent)).disabled(input.isEmpty && pending.isEmpty)
                }
            }.padding(10)
            HStack {
                Text(store.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text(sendOnEnter ? "Enter to send · Shift+Enter for newline" : "⌘Enter to send").font(.caption2).foregroundStyle(.tertiary)
            }.padding(.horizontal, 12).padding(.bottom, 6)
        }
        .sheet(isPresented: $voiceCall) { VoiceCallView { t in input = t; send() }.environmentObject(store) }
        .overlay { if dropTarget { RoundedRectangle(cornerRadius: 12).stroke(Color.accent(accent), lineWidth: 3).padding(4).allowsHitTesting(false) } }
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { Task { @MainActor in await add([u]) } } }
            }
            return true
        }
        .navigationTitle(store.current?.title ?? "Red-XAI Vortex")
        .toolbar {
            ToolbarItemGroup {
                Picker("Model", selection: $model) {
                    ForEach(Array(Set(store.availableModels + LocalRuntime.shared.models.map { "local:\($0)" } + [model])).sorted(), id: \.self) { Text($0).tag($0) }
                }.frame(width: 240)
                Picker("Skill", selection: Binding(get: { skills.activeID }, set: { skills.setActive($0) })) {
                    Text("No skill").tag("")
                    ForEach(skills.skills) { Text($0.name).tag($0.id) }
                }.frame(width: 170).help("Skill: reusable instructions + tools. Or type /skill-id")
                Toggle(isOn: Binding(get: { ToolRegistry.chatToolsOn }, set: { ToolRegistry.chatToolsOn = $0; store.objectWillChange.send() })) {
                    Image(systemName: "wrench.and.screwdriver")
                }.toggleStyle(.button).help("Let the model call tools (plugins, MCP, PC control)")
                Button { voiceCall = true } label: { Image(systemName: "phone.fill") }.help("Voice call (whisper.cpp + Piper on this Mac)")
                Button { store.regenerate(systemPrompt: systemPrompt, contextTokens: contextTokens, params: params) } label: {
                    Image(systemName: "arrow.clockwise") }.help("Regenerate last reply").disabled(store.streaming)
                OpenHubToolbar()
                SettingsLink { Image(systemName: "gearshape") }
            }
        }
        .task { ChatStoreRef.store = store; await refreshModels(); try? await HubStore.shared.loadMerges() }
    }

    func refreshModels() async {
        if let m = try? await API.models(base: serverURL, key: Keychain.get() ?? ""), !m.isEmpty { store.availableModels = m }
    }
    func send() {
        var t = input; let a = pending; input = ""; pending = []; attachError = ""
        skills.applySlash(&t)
        if t.isEmpty && a.isEmpty { store.status = skills.active.map { "Skill on: \($0.name)" } ?? "Skill off"; return }
        var p = params
        if let s = skills.active, !s.model.isEmpty { p.model = s.model }
        if a.contains(where: { $0.kind == "image" }) && !(model.contains("vision") || model.contains("vl") || model.hasPrefix("ext:")) {
            store.status = "Tip: images need a vision model (e.g. gemma3-12b-vision)."
        }
        store.send(t, attachments: a, systemPrompt: skills.systemPrompt(base: systemPrompt), contextTokens: contextTokens, params: p)
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
    @Binding var text: String
    var sendOnEnter: Bool
    var fontSize: Double
    var onSend: () -> Void
    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: fontSize))
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
            .onKeyPress(.return, phases: .down) { press in
                if sendOnEnter && !press.modifiers.contains(.shift) { onSend(); return .handled }
                if !sendOnEnter && press.modifiers.contains(.command) { onSend(); return .handled }
                return .ignored
            }
    }
}

struct BubbleView: View {
    let message: Message
    @AppStorage("bubbleStyle") var bubbleStyle = "rounded"
    @AppStorage("markdown") var markdown = true
    @AppStorage("fontSize") var fontSize = 14.0
    @AppStorage("accent") var accent = "red"
    @AppStorage("showTimestamps") var showTimestamps = false
    var isUser: Bool { message.role == "user" }

    var rendered: Text {
        if markdown, let a = try? AttributedString(markdown: message.content,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) { return Text(a) }
        return Text(message.content)
    }
    var body: some View {
        HStack(alignment: .top) {
            if isUser { Spacer(minLength: 60) } else { Text("🐬").font(.title2) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                if let a = message.attachments, !a.isEmpty { AttachmentChips(items: a) }
                if let l = message.toolLog, !l.isEmpty {
                    DisclosureGroup("\(l.count) tool call(s)") {
                        VStack(alignment: .leading, spacing: 2) { ForEach(Array(l.enumerated()), id: \.offset) { Text($0.element).font(.caption.monospaced()).textSelection(.enabled) } }
                    }.font(.caption).foregroundStyle(.secondary)
                }
                Group {
                    if message.content.isEmpty { TypingIndicator() } else { rendered }
                }
                .font(.system(size: fontSize))
                .textSelection(.enabled)
                .padding(bubbleStyle == "minimal" ? 4 : 10)
                .background(bg)
                .foregroundStyle(isUser && bubbleStyle != "minimal" ? .white : .primary)
                .contextMenu {
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.content, forType: .string) }
                }
                if showTimestamps { Text(message.date, style: .time).font(.caption2).foregroundStyle(.secondary) }
                FeedbackBar(message: message)
            }
            if !isUser { Spacer(minLength: 60) }
        }
    }
    @ViewBuilder var bg: some View {
        let fill: Color = isUser ? Color.accent(accent) : Color.gray.opacity(0.18)
        switch bubbleStyle {
        case "square": RoundedRectangle(cornerRadius: 3).fill(fill)
        case "minimal": Color.clear
        default: RoundedRectangle(cornerRadius: 16).fill(fill)
        }
    }
}

/// Three pulsing dots shown while Vortex writes a reply.
struct TypingIndicator: View {
    @Local var on = false
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle().frame(width: 7, height: 7).opacity(on ? 1 : 0.25)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2), value: on)
            }
        }
        .padding(.vertical, 4)
        .onAppear { on = true }
        .accessibilityLabel("Vortex is typing")
    }
}

struct OpenHubToolbar: View {
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Button { ModelBrowserServer.shared.open() } label: { Image(systemName: "safari") }.help("Browse Models (opens in your browser)")
        Button { openWindow(id: "hub") } label: { Image(systemName: "books.vertical") }.help("Model Library, Merges, Servers, Providers & API Keys")
    }
}
