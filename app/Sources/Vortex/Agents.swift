import SwiftUI
import Foundation

/// A user-created agent: its own model (Vortex or external via API key) plus the same tool surface as chat
/// (PC control with Allow/Deny, web, files, skills/plugins).
struct AgentProfile: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var description: String = ""
    /// "vortex" | "openai" | "anthropic" | "google" | "xai" | "openrouter" | "ollama" | "openai_compat"
    var provider: String = "vortex"
    /// Model id for the chosen provider (e.g. vortex, gpt-4o, claude-sonnet-4, …)
    var model: String = Defaults.model
    /// OpenAI-compatible base URL when provider == openai_compat or ollama
    var baseURL: String = ""
    var systemPrompt: String = Defaults.systemPrompt
    var toolsOn: Bool = true
    var pcControlOn: Bool = true
    var skillIDs: [String] = []
    var pluginIDs: [String] = []
    // Optional for backward compatibility with every existing agents.json.
    var goal: String? = nil
    var modelMode: String? = nil       // single, auto, mix
    var modelPool: [String]? = nil
    var permissions: [String]? = nil  // nil = legacy defaults
    var scheduleSeconds: Int? = nil   // 0 = manual, 15 = nonstop, otherwise interval
    var nonstop: Bool? = nil
    var running: Bool? = nil
    var runOn: String? = nil          // local, server, cloudpc
    var alwaysAllow: Bool? = nil
    var lastRun: Date? = nil
    var created = Date()
    var updated = Date()

    /// Keychain account for this agent's external API key (never printed).
    var keyAccount: String { "agent-key-\(id)" }

    static let providers: [(String, String, String)] = [
        ("vortex", "Vortex (Red-XAI)", ""),
        ("openai", "OpenAI", "https://api.openai.com/v1"),
        ("anthropic", "Anthropic", "https://api.anthropic.com"),
        ("google", "Google AI", "https://generativelanguage.googleapis.com/v1beta"),
        ("xai", "xAI", "https://api.x.ai/v1"),
        ("openrouter", "OpenRouter", "https://openrouter.ai/api/v1"),
        ("ollama", "Ollama (local)", "http://127.0.0.1:11434/v1"),
        ("openai_compat", "OpenAI-compatible", ""),
    ]
}

@MainActor final class AgentStore: ObservableObject {
    static let shared = AgentStore()
    @Published var agents: [AgentProfile] = []
    @Published var activeID: String = AccountProfile.preferences.string(forKey: "activeAgent") ?? ""
    @Published var message = ""
    var file: URL { ChatStore.dir.appendingPathComponent("agents.json") }

    init() { load() }

    func load() {
        if let d = try? Data(contentsOf: file), let a = try? JSONDecoder().decode([AgentProfile].self, from: d) {
            agents = a
        }
        if agents.isEmpty {
            let a = AgentProfile(id: "vortex-default", name: "Vortex", description: "Default Red-XAI Vortex agent",
                                 provider: "vortex", model: Defaults.model, systemPrompt: Defaults.systemPrompt)
            agents = [a]; activeID = a.id; save()
        }
        if activeID.isEmpty || !agents.contains(where: { $0.id == activeID }) {
            activeID = agents.first?.id ?? ""
        }
    }
    func save() {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(agents).write(to: file, options: .atomic)
        AccountProfile.preferences.set(activeID, forKey: "activeAgent")
    }
    var active: AgentProfile? { agents.first { $0.id == activeID } }
    func setActive(_ id: String) { activeID = id; AccountProfile.preferences.set(id, forKey: "activeAgent") }

    func upsert(_ a: AgentProfile, apiKey: String? = nil) {
        var a = a; a.updated = Date()
        if let i = agents.firstIndex(where: { $0.id == a.id }) { agents[i] = a } else { agents.append(a) }
        if let k = apiKey {
            // Store in OS keychain; never log or echo the value.
            Keychain.set(k.trimmingCharacters(in: .whitespacesAndNewlines), account: a.keyAccount)
        }
        save(); message = "Saved \(a.name)."
    }
    func delete(_ id: String) {
        guard id != "vortex-default" else { message = "The default Vortex agent can't be removed."; return }
        if let a = agents.first(where: { $0.id == id }) { Keychain.set("", account: a.keyAccount) }
        agents.removeAll { $0.id == id }
        if activeID == id { activeID = agents.first?.id ?? "" }
        save()
    }
    func keyPresent(for a: AgentProfile) -> Bool {
        if a.provider == "vortex" { return true }
        return !(Keychain.get(account: a.keyAccount) ?? "").isEmpty
    }

    /// Resolve chat params for the active agent (or a named one). Keys stay in Keychain.
    func chatParams(for id: String? = nil, fallback: ChatParams) -> ChatParams {
        guard let a = agents.first(where: { $0.id == (id ?? activeID) }) else { return fallback }
        var p = fallback
        p.model = a.model.isEmpty ? Defaults.model : a.model
        switch a.provider {
        case "vortex":
            break // use app's Vortex gateway + key
        case "openai", "xai", "openrouter", "ollama", "openai_compat":
            let base = a.baseURL.isEmpty ? (AgentProfile.providers.first { $0.0 == a.provider }?.2 ?? "") : a.baseURL
            if !base.isEmpty { p.baseURL = base.hasSuffix("/v1") || base.contains("/v1") ? base : base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1" }
            if let k = Keychain.get(account: a.keyAccount), !k.isEmpty { p.apiKey = k }
        case "anthropic", "google":
            // Routed through gateway shims when available; otherwise OpenAI-compat base if set.
            if !a.baseURL.isEmpty { p.baseURL = a.baseURL }
            if let k = Keychain.get(account: a.keyAccount), !k.isEmpty { p.apiKey = k }
        default: break
        }
        return p
    }
}

struct AgentsView: View {
    @StateObject var store = AgentStore.shared
    @Local var draft = AgentProfile(id: "", name: "", model: Defaults.model)
    @Local var apiKey = ""
    @Local var editing = false
    @Local var agentKeySaved = false
    @AppStorage("model", store: AccountProfile.preferences) var chatModel = Defaults.model
    private let grants: [(String, String)] = [
        ("files-read", "Read files"), ("files-write", "Write files"), ("shell", "Run commands"),
        ("apps", "Open apps"), ("input", "Keyboard and mouse"), ("screen", "Read screen"),
        ("browser", "Browser"), ("clipboard", "Clipboard"), ("plugins", "Skills and plugins")
    ]

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Agents").font(.headline)
                    Spacer()
                    Button { newDraft() } label: { Label("New agent", systemImage: "plus") }
                }.padding([.top, .horizontal])
                Text("Each agent can use any Vortex model or an external AI (OpenAI, Anthropic, Google, xAI, OpenRouter, Ollama, or any OpenAI-compatible URL). API keys stay in the OS keychain and are never printed.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                List(store.agents) { a in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(a.name).font(.body.bold())
                                if a.id == store.activeID { Text("ACTIVE").font(.caption2.bold()).padding(3).background(Capsule().fill(.green.opacity(0.25))) }
                            }
                            Text("\(label(a.provider)) · \(Defaults.displayName(a.model))").font(.caption).foregroundStyle(.secondary)
                            if !a.description.isEmpty { Text(a.description).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                        }
                        Spacer()
                        Button("Use") { store.setActive(a.id); if a.provider == "vortex" { chatModel = a.model }; store.message = "Using \(a.name)." }
                        Button("Edit") { draft = a; apiKey = ""; editing = true }
                        Button("Run") { LocalAgentScheduler.shared.launch(a) }.disabled(a.runOn == "server" || a.runOn == "cloudpc")
                        if a.id != "vortex-default" {
                            Button(role: .destructive) { store.delete(a.id) } label: { Image(systemName: "trash") }
                        }
                    }
                }
                if !store.message.isEmpty { Text(store.message).font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
            }.frame(minWidth: 360)
            if editing { editor.frame(minWidth: 380) }
            else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select or create an agent.").foregroundStyle(.secondary)
                    Text("Tools: PC control (Allow/Deny), web, files, skills & plugins — same rules as chat.").font(.caption)
                    Button("Test with Vortex model") { Task { await testVortex() } }.buttonStyle(.borderedProminent)
                    Divider()
                    ScrollView { BackgroundAgentsView() }
                }.padding().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onAppear { store.load(); _ = LocalAgentScheduler.shared; Task { await BGAgentStore.shared.refresh() } }
    }

    var editor: some View {
        ScrollView {
        Form {
            Text(draft.id.isEmpty || !store.agents.contains(where: { $0.id == draft.id }) ? "New agent" : "Edit \(draft.name)").font(.headline)
            TextField("Name", text: $draft.name)
            TextField("Description", text: $draft.description)
            Picker("Provider", selection: $draft.provider) {
                ForEach(AgentProfile.providers, id: \.0) { Text($0.1).tag($0.0) }
            }
            Picker("Model intelligence", selection: Binding(get: { draft.modelMode ?? "single" }, set: { draft.modelMode = $0 })) {
                Text("Smart specialist selection").tag("auto")
                Text("Multiple models: planner + executor").tag("mix")
                Text("One model").tag("single")
            }.disabled(draft.provider != "vortex")
            TextField("Model id (single or external provider)", text: $draft.model)
            if draft.provider == "openai_compat" || draft.provider == "ollama" || draft.provider == "anthropic" || draft.provider == "google" {
                TextField("Base URL", text: $draft.baseURL)
                    .help(draft.provider == "openai_compat" ? "Any OpenAI-compatible /v1 base URL" : "Override default endpoint")
            }
            if draft.provider != "vortex" {
                SecureField(store.keyPresent(for: draft) ? "API key (leave blank to keep saved)" : "API key", text: $apiKey)
                Text("Stored in the OS keychain. Never shown again.").font(.caption2).foregroundStyle(.secondary)
            }
            Text("Instructions and tools").font(.headline)
            TextEditor(text: $draft.systemPrompt).frame(minHeight: 80)
            TextField("Standing task or goal", text: Binding(get: { draft.goal ?? "" }, set: { draft.goal = $0 }), axis: .vertical).lineLimit(2...5)
            Toggle("Skills, MCP and plugins", isOn: $draft.toolsOn)
            Toggle("PC control (requires this Mac's approval)", isOn: $draft.pcControlOn)
            VStack(alignment: .leading, spacing: 7) {
                Text("Allowed actions (an agent cannot grant itself more)").font(.caption.bold())
                ForEach(grants.indices, id: \.self) { index in
                    let item = grants[index]
                    Toggle(item.1, isOn: Binding(
                        get: { (draft.permissions ?? []).contains(item.0) },
                        set: { enabled in
                            var set = Set(draft.permissions ?? [])
                            if enabled { set.insert(item.0) } else { set.remove(item.0) }
                            draft.permissions = set.sorted()
                        }))
                }
            }
            Toggle("Allow this agent to skip individual PC approvals (only when machine Always allow is also enabled)", isOn:
                Binding(get: { draft.alwaysAllow ?? false }, set: { draft.alwaysAllow = $0 }))
            Text("Stop control can immediately cancel active PC actions and revoke unattended permission.").font(.caption).foregroundStyle(.secondary)
            Section("Background execution") {
                Picker("Run on", selection: Binding(get: { draft.runOn ?? "local" }, set: { draft.runOn = $0 })) {
                    Text("On this Mac, while Vortex is running").tag("local")
                    Text("Vortex server — persistent model-only tasks").tag("server")
                    Text("Cloud PC — worker connection required").tag("cloudpc")
                }
                Picker("Run every", selection: Binding(get: { draft.scheduleSeconds ?? 0 }, set: { draft.scheduleSeconds = $0 })) {
                    Text("Manually").tag(0)
                    Text("Every 30 seconds").tag(30)
                    Text("Every minute").tag(60)
                    Text("Every five minutes").tag(300)
                    Text("Every fifteen minutes").tag(900)
                    Text("Every hour").tag(3600)
                    Text("Daily").tag(86400)
                }
                Toggle("Nonstop: restart after each run", isOn: Binding(get: { draft.nonstop ?? false }, set: { draft.nonstop = $0; if $0 { draft.scheduleSeconds = 15 } }))
                Toggle("Enabled", isOn: Binding(get: { draft.running ?? false }, set: { draft.running = $0 }))
                Text("Cloud PC tool execution requires a separately connected worker. Server runs only model reasoning; they cannot control your Mac or Cloud PC.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("STOP ALL AGENTS", role: .destructive) { LocalAgentScheduler.shared.stopAll() }
                    Button("Reset stop") { LocalAgentScheduler.shared.resetStop() }
                }
            }
            HStack {
                Button("Cancel") { editing = false; apiKey = "" }
                Spacer()
                Button("Save") { saveDraft() }.buttonStyle(.borderedProminent)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty || draft.model.isEmpty)
            }
        }.formStyle(.columns).padding()
        }.scrollIndicators(.visible).frame(maxHeight: .infinity)
    }

    func label(_ p: String) -> String { AgentProfile.providers.first { $0.0 == p }?.1 ?? p }
    func newDraft() {
        let id = "agent-" + String((0..<8).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        draft = AgentProfile(id: id, name: "New agent", provider: "vortex", model: "vortex", modelMode: "auto", permissions: ["files-read", "browser", "plugins"], runOn: "local")
        apiKey = ""; editing = true
    }
    func saveDraft() {
        var a = draft
        if a.id.isEmpty {
            a.id = "agent-" + String((0..<8).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        }
        guard a.running != true || ((a.nonstop == true || (a.scheduleSeconds ?? 0) >= 15) && !(a.goal ?? "").trimmingCharacters(in: .whitespaces).isEmpty) else {
            store.message = "A scheduled agent needs a task and frequency."
            return
        }
        guard !(a.alwaysAllow == true && !a.pcControlOn) else {
            store.message = "Enable PC control before selecting unattended permissions."
            return
        }
        let key: String? = (a.provider != "vortex" && !apiKey.isEmpty) ? apiKey : nil
        if a.provider != "vortex", key == nil, !store.keyPresent(for: a), !store.agents.contains(where: { $0.id == a.id }) {
            store.message = "Paste an API key for this provider."; return
        }
        store.upsert(a, apiKey: key)
        if a.runOn == "server" || a.runOn == "cloudpc" { Task { await saveRemoteAgent(a) } }
        apiKey = ""; editing = false
        if a.provider == "openai_compat" && a.baseURL.isEmpty {
            store.message = "Saved \(a.name). Set a Base URL before chatting."
        }
    }
    func saveRemoteAgent(_ a: AgentProfile) async {
        guard a.provider == "vortex" else {
            store.message = "Remote agents currently use Vortex gateway models. External providers remain local."
            return
        }
        let location = a.runOn ?? "server"
        let running = a.running ?? false
        if location == "cloudpc", running, !(await BGAgentStore.shared.cloudWorkerOnline()) {
            remoteSyncFailed(a, detail: "No authenticated Cloud PC worker is online. Install and sign in to the worker before enabling its schedule.")
            return
        }
        let base = AccountProfile.preferences.string(forKey: "serverURL") ?? Defaults.serverURL
        let models = (try? await API.models(base: base, key: Keychain.get() ?? "")) ?? []
        let chosen = AgentModelRouter.select(task: a.goal ?? "", profile: a, available: models)
        let selectedModel = a.modelMode == "single" ? a.model : chosen.executor
        var b = BGAgent(id: a.id, name: a.name,
                        model: location == "server" && a.modelMode == "auto" ? "vortex" : selectedModel,
                        system: a.systemPrompt, goal: a.goal ?? "",
                        interval_s: a.nonstop == true ? 30 : max(30, a.scheduleSeconds ?? 300),
                        on: running, run_on: location)
        if location == "cloudpc" {
            b.planner = chosen.planner
            let supported: Set<String> = ["web", "files-read", "files-write", "shell", "browser"]
            b.permissions = (a.permissions ?? []).filter { supported.contains($0) }
            b.allow_actions = a.alwaysAllow ?? false
        }
        await BGAgentStore.shared.save(b)
        if !BGAgentStore.shared.msg.hasPrefix("Saved") {
            remoteSyncFailed(a, detail: BGAgentStore.shared.msg)
        }
    }

    func remoteSyncFailed(_ a: AgentProfile, detail: String) {
        if let i = store.agents.firstIndex(where: { $0.id == a.id }) {
            store.agents[i].running = false
            store.save()
        }
        store.message = "Agent saved locally, but its remote schedule was not activated: " + detail
    }
    func testVortex() async {
        let a = store.agents.first { $0.provider == "vortex" } ?? store.agents.first
        guard let a else { store.message = "No agent."; return }
        store.setActive(a.id)
        let base = AccountProfile.preferences.string(forKey: "serverURL") ?? Defaults.serverURL
        let key = Keychain.get() ?? ""
        do {
            let models = try await API.models(base: base, key: key)
            guard models.contains(where: { $0 == a.model || $0 == "vortex" }) else {
                store.message = "Vortex model not listed on gateway."; return
            }
            // Minimal chat probe — never include keys in the message.
            var req = URLRequest(url: API.url(base, "/chat/completions")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let body: [String: Any] = ["model": a.model == "" ? "vortex" : a.model,
                                       "messages": [["role": "user", "content": "Reply with exactly: VORTEX_AGENT_OK"]],
                                       "max_tokens": 32, "temperature": 0]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data, encoding: .utf8) ?? ""
            if code == 200 && text.contains("VORTEX_AGENT_OK") {
                store.message = "E2E OK: agent \(a.name) → model \(a.model) replied VORTEX_AGENT_OK."
            } else if code == 200 {
                store.message = "E2E partial: HTTP 200 from \(a.model); reply did not contain marker (model may paraphrase)."
            } else {
                store.message = "E2E failed: HTTP \(code)."
            }
        } catch {
            store.message = "E2E failed: \(error.localizedDescription)"
        }
    }
}
