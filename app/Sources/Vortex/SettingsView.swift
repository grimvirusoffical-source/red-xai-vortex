import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ConnectionSettings().tabItem { Label("Connection", systemImage: "network") }
            ModelSettings().tabItem { Label("Model", systemImage: "slider.horizontal.3") }
            PersonaSettings().tabItem { Label("Personas", systemImage: "person.text.rectangle") }
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintpalette") }
            DataSettings().tabItem { Label("Chats & Data", systemImage: "tray.full") }
            LumiSettings().tabItem { Label("Lumi Training", systemImage: "graduationcap") }
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
    @Local var keySaved = Keychain.get() != nil
    @Local var test = ""
    var body: some View {
        Form {
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
                    Text(tunnel.running ? "Connected" : "Not connected")
                    Spacer()
                    Button(tunnel.running ? "Disconnect" : "Connect") {
                        tunnel.running ? tunnel.stop() : tunnel.start(host: sshHost, local: sshLocalPort, remote: sshRemotePort, keyPath: sshKey)
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
                    ForEach(Array(Set(store.availableModels + Defaults.knownModels + [model])).sorted(), id: \.self) { Text($0).tag($0) }
                }
                TextField("Custom model id", text: $model)
                Text("dolphin2.7-mixtral-8x7b-iq4xs = biggest, default (47B MoE, ~22 tokens/s). dolphin3-mistral-24b-q6k = Dolphin 3.0 24B (~11 tokens/s). dolphin3-llama3.1-8b-q8 = 8B (~22 tokens/s). dolphin3-llama3.2-3b-q4km = fastest (~79 tokens/s). Switching loads the model on the server; the first reply takes a few extra seconds.")
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
    @AppStorage("replyWhenFinished") var replyWhenFinished = true
    var body: some View {
        Form {
            Toggle("Show replies only when finished", isOn: $replyWhenFinished)
                .help("Shows a typing indicator, then the whole reply at once instead of word by word.")
            Picker("Theme", selection: $theme) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
            Picker("Accent", selection: $accent) {
                ForEach(["red", "blue", "teal", "purple", "orange", "green", "pink"], id: \.self) { Text($0.capitalized).tag($0) }
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

struct LumiSettings: View {
    @EnvironmentObject var store: ChatStore
    @AppStorage("systemPrompt") var systemPrompt = Defaults.systemPrompt
    @AppStorage("lumiSystemPrompt") var lumiPrompt = "You are Lumi. She is warm, clever and concise."
    @AppStorage("omniRouteURL") var omniRouteURL = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Training Lumi from the VPS").font(.title2.bold())
                Group {
                    h("1. Where everything lives on the VPS (YOUR_SERVER)")
                    code("""
                    Server binary : /opt/dolphin/bin/llama-server  (llama.cpp, CPU build)
                    Models        : /opt/dolphin/models/*.gguf
                                    dolphin3-llama3.1-8b-q8.gguf   (main, 8.5 GB)
                                    dolphin3-llama3.2-3b-q4km.gguf (fallback, 2.0 GB)
                    Service       : systemctl status dolphin-llm   (6 threads, CPUQuota 500%, MemoryMax 12G)
                    API key file  : /etc/dolphin/api-keys  (root/dolphin only)
                    Endpoint (VPS): http://127.0.0.1:8090/v1   (localhost only)
                    Endpoint (Mac): http://127.0.0.1:18090/v1  (through Red-XAI Vortex's SSH tunnel)
                    Logs          : journalctl -u dolphin-llm -f
                    """)
                    h("2. Build a dataset")
                    Text("Chat with Red-XAI Vortex (the \"Lumi Trainer\" persona helps), keep the good conversations, then export. Each line is one conversation in OpenAI chat format: {\"messages\":[{\"role\":\"system\",…},{\"role\":\"user\",…},{\"role\":\"assistant\",…}]}. Lumi is she/her, so keep her voice consistent in every example.")
                    TextField("System prompt written into the training file", text: $lumiPrompt)
                    HStack {
                        Button("Export for Training (all chats)…") { store.exportTraining(systemPrompt: lumiPrompt, onlyCurrent: false) }.buttonStyle(.borderedProminent)
                        Button("Export current chat only…") { store.exportTraining(systemPrompt: lumiPrompt, onlyCurrent: true) }
                    }
                    if !store.status.isEmpty { Text(store.status).font(.caption).foregroundStyle(.secondary) }
                    code("scp -i ~/.ssh/id_ed25519 lumi-train.jsonl root@YOUR_SERVER:/opt/dolphin/datasets/")
                }
                Group {
                    h("3. LoRA fine-tuning: honest expectations")
                    Text("The VPS (YOUR_SERVER) in the reference setup has 16 vCPUs, 32 GB RAM and no GPU. Inference works well; training does not scale there. CPU LoRA on a 3B model is possible for small adapters (a few hundred examples, short sequences) and takes hours; an 8B model on CPU is days and can run out of RAM next to production. Stop dolphin-llm while training. For real runs, train on a GPU machine (a rented 24 GB GPU, or an Apple Silicon Mac with MLX), then copy the adapter back.")
                    h("Option A: GPU box with Unsloth (recommended)")
                    code("""
                    pip install unsloth
                    # base: cognitivecomputations/Dolphin3.0-Llama3.1-8B (or Llama3.2-3B)
                    # load_in_4bit=True, LoRA r=16, alpha=16, lr=2e-4, 1-3 epochs on lumi-train.jsonl
                    # then: model.save_pretrained_gguf("lumi", tokenizer, quantization_method="q8_0")
                    scp lumi-*.gguf root@YOUR_SERVER:/opt/dolphin/models/
                    ssh root@YOUR_SERVER 'chown dolphin: /opt/dolphin/models/*; systemctl restart dolphin-llm'
                    """)
                    h("Option B: Apple Silicon Mac with MLX")
                    code("""
                    pip install mlx-lm
                    mlx_lm.lora --model cognitivecomputations/Dolphin3.0-Llama3.2-3B --train \\
                      --data ./lumi-data --iters 600 --batch-size 2 --num-layers 8
                    mlx_lm.fuse --model cognitivecomputations/Dolphin3.0-Llama3.2-3B --adapter-path adapters --save-path lumi-3b
                    # convert to GGUF with llama.cpp convert_hf_to_gguf.py, then copy to /opt/dolphin/models/
                    """)
                    h("Option C: CPU-only on the VPS (small adapters only)")
                    code("""
                    systemctl stop dolphin-llm
                    # use llama.cpp's finetune tool (build from source if it isn't in the release), e.g.
                    # llama-finetune -m models/dolphin3-llama3.2-3b-q4km.gguf -f datasets/lumi.txt -t 6 -c 512
                    # Expect hours for a few hundred samples. Load the adapter with --lora at serve time.
                    systemctl start dolphin-llm
                    """)
                    Text("A new .gguf dropped into /opt/dolphin/models shows up automatically in Red-XAI Vortex's model picker after a service restart.").font(.caption)
                }
                Group {
                    h("4. OmniRoute")
                    Text("Add the VPS as an OpenAI-compatible provider in OmniRoute, so you can route between Dolphin, Lumi and other providers and log conversations for training data.")
                    code("""
                    Provider type : OpenAI-compatible
                    Base URL      : http://127.0.0.1:8090/v1   (if OmniRoute runs on the VPS)
                                    http://127.0.0.1:18090/v1  (if it runs on this Mac, tunnel up)
                    API key       : contents of /etc/dolphin/api-keys
                    Models        : dolphin3-llama3.1-8b-q8, dolphin3-llama3.2-3b-q4km (+ lumi-* when trained)
                    """)
                    Text("Keep OmniRoute bound to localhost or behind the tunnel; do not expose port 8090 publicly. Export OmniRoute's request logs as JSONL in the same {\"messages\":[…]} format to merge them with Red-XAI Vortex exports.")
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
