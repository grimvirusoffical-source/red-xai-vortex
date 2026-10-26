import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ConnectionSettings().tabItem { Label("Connection", systemImage: "network") }
            ModelSettings().tabItem { Label("Model", systemImage: "slider.horizontal.3") }
            PersonaSettings().tabItem { Label("Personas", systemImage: "person.text.rectangle") }
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintpalette") }
            DataSettings().tabItem { Label("Chats & Data", systemImage: "tray.full") }
            VortexTrainingSettings().tabItem { Label("Vortex Training", systemImage: "graduationcap") }
            NodeSettings().tabItem { Label("Compute", systemImage: "cpu") }
        }
        .frame(width: 720, height: 560)
    }
}

struct ConnectionSettings: View {
    @EnvironmentObject var tunnel: TunnelManager
    @EnvironmentObject var store: ChatStore
    @AppStorage("serverURL") var serverURL = Defaults.serverURL
    @AppStorage("useTunnel") var useTunnel = true
    @AppStorage("sshHost") var sshHost = Defaults.sshHost
    @AppStorage("sshKey") var sshKey = "~/.ssh/id_ed25519"
    @AppStorage("sshLocalPort") var sshLocalPort = Defaults.sshLocalPort
    @AppStorage("sshRemotePort") var sshRemotePort = Defaults.sshRemotePort
    @Local var key = ""
    @Local var keySaved = false
    // keySaved filled in .onAppear — never Keychain in property initializers used by View body
    @Local var test = ""
    var body: some View {
        Form {
            Section("Updates") {
                Toggle("Auto-update from GitHub Releases (SHA256 + Developer ID verified)", isOn: Binding(get: { !UserDefaults.standard.bool(forKey: "noAutoUpdate") }, set: { UserDefaults.standard.set(!$0, forKey: "noAutoUpdate") }))
                Button("Check for updates now") { Task { await Updater.shared.check() } }
            }
            Section("Server") {
                TextField("Server URL (OpenAI-compatible, ends in /v1)", text: $serverURL)
                HStack {
                    SecureField(keySaved ? "API key saved in Keychain (enter to replace)" : "API key", text: $key)
                    Button("Save Key") { Keychain.set(key); key = ""; keySaved = Keychain.get() != nil }.disabled(key.isEmpty)
                    Button("Remove") { Keychain.set(""); keySaved = false }.disabled(!keySaved)
                }
                HStack {
                    Button("Test Connection") { Task { await runTest() } }
                    Text(test).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .onAppear { keySaved = Keychain.get() != nil }
            Section("Secure SSH tunnel") {
                Toggle("Open SSH tunnel automatically on launch", isOn: $useTunnel)
                TextField("SSH host", text: $sshHost)
                TextField("SSH private key path", text: $sshKey)
                HStack {
                    TextField("Local port", value: $sshLocalPort, format: .number.grouping(.never))
                    TextField("Remote port", value: $sshRemotePort, format: .number.grouping(.never))
                }
                HStack {
                    Circle().fill(tunnel.running ? .green : .orange).frame(width: 8, height: 8)
                    Text(tunnel.running ? (tunnel.external ? "Connected (reusing existing tunnel)" : "Connected") : "Not connected")
                    Spacer()
                    Button(tunnel.running ? (tunnel.external ? "Recheck" : "Disconnect") : "Connect") {
                        (tunnel.running && !tunnel.external) ? tunnel.stop() : tunnel.start(host: sshHost, local: sshLocalPort, remote: sshRemotePort, keyPath: sshKey)
                    }
                }
                if !tunnel.lastError.isEmpty { Text(tunnel.lastError).font(.caption).foregroundStyle(.red) }
                Text("The model API on the VPS only listens on 127.0.0.1:\(sshRemotePort). Red-XAI Vortex forwards it to 127.0.0.1:\(sshLocalPort) on this Mac over SSH, and every request also carries the bearer key.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
    func runTest() async {
        test = "Testing…"
        do { let m = try await API.models(base: serverURL, key: Keychain.get() ?? ""); store.availableModels = m; test = "OK — \(m.count) models: \(m.joined(separator: ", "))" }
        catch { test = "Failed: \(error.localizedDescription)" }
    }
}

struct ModelSettings: View {
    @EnvironmentObject var store: ChatStore
    @AppStorage("model") var model = Defaults.model
    @AppStorage("temperature") var temperature = 0.7
    @AppStorage("topP") var topP = 0.9
    @AppStorage("topK") var topK = 40
    @AppStorage("maxTokens") var maxTokens = 1024
    @AppStorage("contextTokens") var contextTokens = 8192
    @AppStorage("repeatPenalty") var repeatPenalty = 1.1
    @AppStorage("seed") var seed = -1
    var body: some View {
        Form {
            Section("Model") {
                Picker("Model", selection: $model) {
                    ForEach(Array(Set(store.availableModels + Defaults.knownModels + [model])).sorted(), id: \.self) { Text(Defaults.displayName($0)).tag($0) }
                }
                TextField("Custom model id", text: $model)
                Text("vortex = default Red-XAI learning model. red-xai = production router. qwen2.5-coder-14b = coding. Other installed models appear in the Hub. Switching loads the model on the server; the first reply takes a few extra seconds.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sampling") {
                slider("Temperature", $temperature, 0...2, "%.2f")
                slider("Top P", $topP, 0...1, "%.2f")
                Stepper("Top K: \(topK)", value: $topK, in: 0...200, step: 5)
                slider("Repeat penalty", $repeatPenalty, 1...2, "%.2f")
                HStack { Text("Seed (-1 = random)"); TextField("", value: $seed, format: .number.grouping(.never)).frame(width: 120) }
            }
            Section("Length") {
                Stepper("Max reply tokens: \(maxTokens)", value: $maxTokens, in: 64...8192, step: 64)
                Stepper("Context length: \(contextTokens)", value: $contextTokens, in: 1024...8192, step: 512)
                Text("The server is started with an 8192-token context; older messages are trimmed to fit.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Reset to defaults") { temperature = 0.7; topP = 0.9; topK = 40; maxTokens = 1024; contextTokens = 8192; repeatPenalty = 1.1; seed = -1 }
        }.formStyle(.grouped)
    }
    func slider(_ t: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, _ f: String) -> some View {
        HStack { Text(t).frame(width: 120, alignment: .leading); Slider(value: v, in: r); Text(String(format: f, v.wrappedValue)).monospacedDigit().frame(width: 44) }
    }
}

struct PersonaSettings: View {
    @AppStorage("systemPrompt") var systemPrompt = Defaults.systemPrompt
    @AppStorage("personasJSON") var personasJSON = ""
    @Local var personas: [Persona] = []
    @Local var newName = ""
    var body: some View {
        Form {
            Section("System prompt (active)") {
                TextEditor(text: $systemPrompt).frame(height: 110).font(.body)
            }
            Section("Saved personas") {
                ForEach(personas) { p in
                    HStack {
                        VStack(alignment: .leading) { Text(p.name).bold(); Text(p.prompt).font(.caption).lineLimit(2).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Use") { systemPrompt = p.prompt }
                        Button(role: .destructive) { personas.removeAll { $0.id == p.id }; persist() } label: { Image(systemName: "trash") }
                    }
                }
                HStack {
                    TextField("Save current prompt as…", text: $newName)
                    Button("Save Persona") { personas.append(Persona(name: newName, prompt: systemPrompt)); newName = ""; persist() }.disabled(newName.isEmpty)
                }
                Button("Restore built-in personas") { personas = Defaults.personas; persist() }
            }
        }.formStyle(.grouped)
        .onAppear {
            personas = (try? JSONDecoder().decode([Persona].self, from: Data(personasJSON.utf8))) ?? Defaults.personas
            if let i = personas.firstIndex(where: { $0.name == "Lumi Trainer" }), let v = Defaults.personas.first(where: { $0.name == "Vortex Trainer" }) {
                personas[i] = v; persist() // renamed preset: training now targets Vortex
            }
        }
    }
    func persist() { if let d = try? JSONEncoder().encode(personas) { personasJSON = String(data: d, encoding: .utf8) ?? "" } }
}

struct AppearanceSettings: View {
    @AppStorage("theme") var theme = "system"
    @AppStorage("accent") var accent = "red"
    @AppStorage("fontSize") var fontSize = 14.0
    @AppStorage("bubbleStyle") var bubbleStyle = "rounded"
    @AppStorage("markdown") var markdown = true
    @AppStorage("sendOnEnter") var sendOnEnter = true
    @AppStorage("showTimestamps") var showTimestamps = false
    @AppStorage("replyWhenFinished") var replyWhenFinished = false
    @AppStorage("royalPalette") var royalPalette = "gold"
    var body: some View {
        Form {
            Picker("Vortex look", selection: $royalPalette) {
                Text("Royal gold & black").tag("gold"); Text("Purple & black").tag("purple")
                Text("Light").tag("light"); Text("Black & red").tag("red")
            }
            Toggle("Show replies only when finished", isOn: $replyWhenFinished)
                .help("Shows a typing indicator, then the whole reply at once instead of word by word.")
            Picker("Theme", selection: $theme) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
            Picker("Accent", selection: $accent) {
                ForEach(["gold", "red", "blue", "teal", "purple", "orange", "green", "pink"], id: \.self) { Text($0.capitalized).tag($0) }
            }
            HStack { Text("Font size"); Slider(value: $fontSize, in: 10...24, step: 1); Text("\(Int(fontSize)) pt").frame(width: 44) }
            Picker("Bubble style", selection: $bubbleStyle) { Text("Rounded").tag("rounded"); Text("Square").tag("square"); Text("Minimal").tag("minimal") }
            Toggle("Render Markdown", isOn: $markdown)
            Toggle("Send on Enter (Shift+Enter for newline)", isOn: $sendOnEnter)
            Toggle("Show message timestamps", isOn: $showTimestamps)
        }.formStyle(.grouped)
    }
}

struct DataSettings: View {
    @EnvironmentObject var store: ChatStore
    @AppStorage("systemPrompt") var systemPrompt = Defaults.systemPrompt
    @Local var confirm = false
    var body: some View {
        Form {
            Section("Chats") {
                Text("\(store.chats.count) chats, \(store.chats.reduce(0) { $0 + $1.messages.count }) messages, stored in ~/Library/Application Support/Red-XAI Vortex/")
                HStack { Button("Export Chats (JSON)…") { store.exportJSON() }; Button("Import Chats…") { store.importJSON() } }
                Button("Export for Training (JSONL)…") { store.exportTraining(systemPrompt: systemPrompt, onlyCurrent: false) }
                Button("Reveal data folder") { NSWorkspace.shared.open(ChatStore.dir) }
            }
            Section("Danger zone") {
                Button("Clear All History", role: .destructive) { confirm = true }
            }
            if !store.status.isEmpty { Text(store.status).font(.caption).foregroundStyle(.secondary) }
        }.formStyle(.grouped)
        .confirmationDialog("Delete every chat?", isPresented: $confirm) { Button("Delete All", role: .destructive) { store.clearAll() } }
    }
}

struct VortexTrainingSettings: View {
    @EnvironmentObject var store: ChatStore
    @AppStorage("vortexSystemPrompt") var vortexPrompt = "You are Vortex, the Red-XAI Vortex assistant: direct, warm and precise."
    @AppStorage("omniRouteURL") var omniRouteURL = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Training Vortex").font(.title2.bold())
                Text("Everything you collect here trains Red-XAI Vortex itself. Each trained version is installed as vortex-v1, vortex-v2, … and you choose which one \"vortex\" uses in the Vortex tab.").foregroundStyle(.secondary)
                Group {
                    h("1. Where Vortex's training data comes from")
                    Text("• Training mode (Vortex tab, off by default, plus consent): 👍 👎 and corrections on any reply.\n• Learn from the active model: replies from whatever model or merge you chat with, judge-scored; only the best are used.\n• Merges that include Vortex: the judge's or refiner's final answer is the preferred sample, and the other members' answers are kept as alternatives.\n• Your own chats exported below (optional).\nPersonal details are scrubbed and everything is stored encrypted on your server.")
                    h("2. Add your chats (optional)")
                    Text("Use the \"Vortex Trainer\" persona to write example answers in Vortex's voice, keep the good conversations, then export. Each line is one conversation in OpenAI chat format.")
                    TextField("System prompt written into the training file", text: $vortexPrompt)
                    HStack {
                        Button("Export for Training (all chats)…") { store.exportTraining(systemPrompt: vortexPrompt, onlyCurrent: false) }.buttonStyle(.borderedProminent)
                        Button("Export current chat only…") { store.exportTraining(systemPrompt: vortexPrompt, onlyCurrent: true) }
                    }
                    if !store.status.isEmpty { Text(store.status).font(.caption).foregroundStyle(.secondary) }
                    code("scp vortex-train.jsonl root@YOUR_SERVER:/opt/dolphin/redxai/export/")
                }
                Group {
                    h("3. Export Vortex's dataset on the server")
                    code("redxai-train export     # -> /opt/dolphin/redxai/export/train-*.jsonl (best samples; merge rows include a \"rejected\" alternative)")
                    h("4. Train a Vortex version (needs a GPU)")
                    Text("The reference server has no GPU, so training there is impractical. Rent a 24–48 GB GPU for an hour or two, or use an Apple Silicon Mac with MLX. Train a LoRA on the SAME base model Vortex uses (see the Vortex tab → config \"base\").").font(.callout)
                    code("""
                    pip install unsloth          # or axolotl; for "rejected" pairs use a DPO/ORPO trainer
                    # LoRA r=16, alpha=32, 2-3 epochs on train-*.jsonl (+ vortex-train.jsonl)
                    python llama.cpp/convert_lora_to_gguf.py --base <hf-base-dir> <lora-dir> --outfile vortex-lora.gguf
                    scp vortex-lora.gguf root@YOUR_SERVER:/root/
                    """)
                    h("5. Install, compare, activate")
                    code("""
                    redxai-train install /root/vortex-lora.gguf   # becomes vortex-vN
                    redxai-eval                                    # benchmark every version
                    redxai-train activate vN                       # what model "vortex" uses
                    """)
                }
                Group {
                    h("Optional: OmniRoute")
                    Text("If you use OmniRoute, add the gateway as an OpenAI-compatible provider (base URL http://127.0.0.1:18091/v1 with the app's tunnel up, and a redx_ai_ key). Export its request logs as JSONL in the same {\"messages\":[…]} format to add them to Vortex's training data.")
                    TextField("OmniRoute URL (optional; use it as Server URL in Connection to chat through it)", text: $omniRouteURL)
                }
            }.padding(20).textSelection(.enabled)
        }
    }
    func h(_ s: String) -> some View { Text(s).font(.headline).padding(.top, 4) }
    func code(_ s: String) -> some View {
        Text(s).font(.system(.caption, design: .monospaced)).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
    }
}
