import SwiftUI
import AppKit

/// Integrations: connect coding/AI tools to the Vortex gateway using each tool's OFFICIAL custom-endpoint setting.
/// Automatic tools get their config written (after a backup); guided tools get a dedicated key copied to the
/// clipboard plus exact steps; tools without a custom-endpoint option are marked unsupported.
struct Integration: Identifiable {
    enum Mode { case auto, guided, unsupported }
    let id: String, name: String, category: String, wire: String, mode: Mode
    let how: String            // the official mechanism
    var steps: String = ""      // guided steps ({BASE}, {MODEL} are filled in)
    var publicOnly = false      // the tool calls from its own cloud, so the tunnel URL can't work
}

enum IntegrationCatalog {
    static let all: [Integration] = [
        // ---- automatic (config files written for you) ----
        .init(id: "codex", name: "OpenAI Codex CLI", category: "Coding agents", wire: "OpenAI Responses", mode: .auto,
              how: "~/.codex/vortex.config.toml (Codex 0.163+ profile file): model_provider + [model_providers.vortex] with wire_api=\"responses\". Run: codex --profile vortex"),
        .init(id: "claude-code", name: "Claude Code", category: "Coding agents", wire: "Anthropic Messages", mode: .auto,
              how: "~/.claude/settings.json → env: ANTHROPIC_BASE_URL, ANTHROPIC_AUTH_TOKEN, ANTHROPIC_MODEL (gateway /v1/messages shim)"),
        .init(id: "gemini-cli", name: "Gemini CLI", category: "Coding agents", wire: "Gemini API", mode: .auto,
              how: "~/.gemini/.env: GOOGLE_GEMINI_BASE_URL + GEMINI_API_KEY + GEMINI_MODEL (gateway /v1beta Gemini shim). Run: gemini"),
        .init(id: "opencode", name: "OpenCode", category: "Coding agents", wire: "OpenAI Chat", mode: .auto,
              how: "~/.config/opencode/opencode.json → provider \"vortex\" (@ai-sdk/openai-compatible, baseURL, apiKey {env:VORTEX_API_KEY})"),
        .init(id: "grok-cli", name: "Grok CLI (open-source)", category: "Coding agents", wire: "OpenAI Chat", mode: .auto,
              how: "~/.grok/user-settings.json → baseURL, apiKey, defaultModel"),
        .init(id: "aider", name: "Aider", category: "Coding agents", wire: "OpenAI Chat", mode: .auto,
              how: "~/.aider.conf.yml → openai-api-base, openai-api-key, model openai/<model> (only if you have no aider config yet)"),
        .init(id: "continue", name: "VS Code / JetBrains: Continue", category: "Editors", wire: "OpenAI Chat", mode: .auto,
              how: "~/.continue/config.yaml → model with provider openai + apiBase (only if you have no Continue config yet)"),
        .init(id: "raycast", name: "Raycast AI", category: "Desktop chat", wire: "OpenAI Chat", mode: .auto,
              how: "~/.config/raycast/ai/providers.yaml (Custom Providers) (only if you have no providers.yaml yet)"),
        // ---- guided (key copied to clipboard + exact steps) ----
        .init(id: "cursor", name: "Cursor", category: "Editors", wire: "OpenAI Chat", mode: .guided,
              how: "Settings → Models → OpenAI API Key + Override OpenAI Base URL",
              steps: "Cursor → Settings → Models → API Keys → OpenAI: paste the key, turn on Override OpenAI Base URL = {BASE}, then add model {MODEL}.", publicOnly: true),
        .init(id: "cline", name: "Cline", category: "Editors", wire: "OpenAI Chat", mode: .guided, how: "API Provider: OpenAI Compatible",
              steps: "Cline settings → API Provider: OpenAI Compatible → Base URL {BASE}, API Key: paste, Model ID {MODEL}."),
        .init(id: "roo", name: "Roo Code", category: "Editors", wire: "OpenAI Chat", mode: .guided, how: "API Provider: OpenAI Compatible",
              steps: "Roo Code settings → API Provider: OpenAI Compatible → Base URL {BASE}, API Key: paste, Model {MODEL}."),
        .init(id: "kilo", name: "Kilo Code", category: "Editors", wire: "OpenAI Chat", mode: .guided, how: "API Provider: OpenAI Compatible",
              steps: "Kilo Code settings → API Provider: OpenAI Compatible → Base URL {BASE}, API Key: paste, Model {MODEL}."),
        .init(id: "copilot", name: "GitHub Copilot (VS Code BYOK)", category: "Editors", wire: "OpenAI Chat", mode: .guided,
              how: "Chat → Manage Models → OpenAI Compatible (custom endpoint)",
              steps: "VS Code → Copilot Chat → model picker → Manage Models… → OpenAI Compatible → URL {BASE}/chat/completions, key: paste, model {MODEL}. (Copilot's Ollama option can't send an API key, so use OpenAI Compatible.)"),
        .init(id: "zed", name: "Zed", category: "Editors", wire: "OpenAI Chat", mode: .guided, how: "settings.json → language_models.openai_compatible",
              steps: "Zed settings.json: \"language_models\": { \"openai_compatible\": { \"Vortex\": { \"api_url\": \"{BASE}\", \"available_models\": [{ \"name\": \"{MODEL}\", \"max_tokens\": 32768 }] } } }. Then Agent panel → Configure → Vortex → paste the key."),
        .init(id: "jetbrains", name: "JetBrains AI Assistant", category: "Editors", wire: "OpenAI Chat", mode: .guided, how: "Settings → AI Assistant → Models → Third-party providers → OpenAI-compatible",
              steps: "Settings → Tools → AI Assistant → Models → Third-party AI providers → OpenAI-compatible: URL {BASE}, API key: paste, model {MODEL}. (Its Ollama/LM Studio options send no key, so use OpenAI-compatible.)"),
        .init(id: "goose", name: "Goose", category: "Coding agents", wire: "OpenAI Chat", mode: .guided, how: "goose configure → OpenAI (OPENAI_HOST)",
              steps: "Run goose configure → Configure Providers → OpenAI → OPENAI_HOST = {HOST}, OPENAI_BASE_PATH = v1/chat/completions, API key: paste, model {MODEL}."),
        .init(id: "openwebui", name: "Open WebUI", category: "Chat apps", wire: "OpenAI Chat", mode: .guided, how: "Admin Settings → Connections → OpenAI API",
              steps: "Admin Settings → Connections → OpenAI API → + : URL {BASE}, key: paste. Models appear automatically."),
        .init(id: "librechat", name: "LibreChat", category: "Chat apps", wire: "OpenAI Chat", mode: .guided, how: "librechat.yaml → endpoints.custom",
              steps: "librechat.yaml: endpoints: custom: - name: Vortex, apiKey: ${VORTEX_API_KEY}, baseURL: {BASE}, models: { default: [\"{MODEL}\"], fetch: true }. Put the key in LibreChat's .env as VORTEX_API_KEY."),
        .init(id: "anythingllm", name: "AnythingLLM", category: "Chat apps", wire: "OpenAI Chat", mode: .guided, how: "LLM Preference → Generic OpenAI",
              steps: "Settings → LLM Preference → Generic OpenAI: Base URL {BASE}, API key: paste, Chat Model {MODEL}."),
        .init(id: "msty", name: "Msty", category: "Chat apps", wire: "OpenAI Chat", mode: .guided, how: "Remote Model Providers → OpenAI Compatible",
              steps: "Add Remote Model Provider → OpenAI Compatible: endpoint {BASE}, key: paste, add model {MODEL}."),
        .init(id: "jan", name: "Jan", category: "Chat apps", wire: "OpenAI Chat", mode: .guided, how: "Settings → Model Providers → add OpenAI-compatible",
              steps: "Settings → Model Providers → Add provider: Base URL {BASE}, API key: paste, then add model {MODEL}."),
        .init(id: "boltai", name: "BoltAI", category: "Chat apps", wire: "OpenAI Chat", mode: .guided, how: "Settings → Models → OpenAI-compatible server",
              steps: "Settings → Models → + → OpenAI-compatible: API URL {BASE}, key: paste, model {MODEL}."),
        .init(id: "chatbox", name: "Chatbox", category: "Chat apps", wire: "OpenAI Chat", mode: .guided, how: "Settings → Model Provider → Add (OpenAI API Compatible)",
              steps: "Settings → Model Provider → Add → OpenAI API Compatible: API Host {BASE}, key: paste, model {MODEL}."),
        .init(id: "obsidian-copilot", name: "Obsidian Copilot", category: "Chat apps", wire: "OpenAI Chat", mode: .guided, how: "Settings → Model → Add Custom Model → 3rd party (openai-format)",
              steps: "Copilot settings → Model → Add Custom Model: provider 3rd party (openai-format), Base URL {BASE}, key: paste, name {MODEL}. Turn on CORS if requests fail."),
        .init(id: "lmstudio", name: "Apps built for LM Studio", category: "Chat apps", wire: "OpenAI Chat", mode: .guided, how: "Same OpenAI-compatible base URL",
              steps: "LM Studio itself serves models and can't use a remote endpoint. Apps that talk to LM Studio's API (http://localhost:1234/v1) can point at {BASE} with the key instead."),
        .init(id: "n8n", name: "n8n", category: "Automation", wire: "OpenAI Chat", mode: .guided, how: "OpenAI credential → Base URL",
              steps: "Credentials → OpenAI: API Key: paste, Base URL {BASE}. Use the OpenAI Chat Model node with model {MODEL}.", publicOnly: true),
        .init(id: "flowise", name: "Flowise", category: "Automation", wire: "OpenAI Chat", mode: .guided, how: "ChatOpenAI Custom node → Base Path",
              steps: "Use ChatOpenAI Custom (or ChatOpenAI → Additional Parameters → BasePath {BASE}); credential = the key; model {MODEL}.", publicOnly: true),
        .init(id: "gpt-actions", name: "ChatGPT Custom GPT (Actions)", category: "Chat apps", wire: "OpenAPI", mode: .guided, how: "GPT editor → Actions → import docs/openapi-gpt-actions.yaml",
              steps: "GPT editor → Configure → Actions → Import the schema (docs/openapi-gpt-actions.yaml, server = your public URL) → Authentication: API Key, Bearer → paste the key.", publicOnly: true),
        // ---- not supported ----
        .init(id: "antigravity", name: "Google Antigravity", category: "Not supported", wire: "—", mode: .unsupported,
              how: "Not supported by that app: the Antigravity IDE has no custom endpoint or bring-your-own-model setting (only its SDK does)."),
        .init(id: "chatgpt-app", name: "ChatGPT app", category: "Not supported", wire: "—", mode: .unsupported,
              how: "Not supported by that app: ChatGPT (desktop, web, mobile) only uses OpenAI's models. Use a Custom GPT with Actions instead."),
        .init(id: "gemini-app", name: "Gemini app", category: "Not supported", wire: "—", mode: .unsupported,
              how: "Not supported by that app: the Gemini app has no custom model endpoint. Gemini CLI is supported."),
        .init(id: "grok-app", name: "Grok app", category: "Not supported", wire: "—", mode: .unsupported,
              how: "Not supported by that app: the official Grok app has no custom endpoint. The open-source Grok CLI is supported."),
        .init(id: "claude-ai", name: "Claude.ai / Claude desktop", category: "Not supported", wire: "—", mode: .unsupported,
              how: "Not supported by that app: Claude.ai and the Claude desktop app only use Anthropic's models. Claude Code is supported."),
    ]
}

struct IntegrationState: Codable { var model: String; var keyID: String; var at: Date; var files: [FileBackup]; var envVars: [String] }
struct FileBackup: Codable { var path: String; var existed: Bool; var backup: String }

@MainActor final class IntegrationStore: ObservableObject {
    static let shared = IntegrationStore()
    @Published var state: [String: IntegrationState] = [:]
    @Published var message = ""
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var localBase: String { "http://127.0.0.1:\(Defaults.sshLocalPort - 1)" }
    var publicBase: String { (UserDefaults.standard.string(forKey: "publicBaseURL") ?? "").replacingOccurrences(of: "/v1", with: "") }
    var envFile: String { home + "/.config/red-xai-vortex/env" }
    static let marker = "# red-xai-vortex integrations (added by the Red-XAI Vortex app; removed on Disconnect)"

    init() {
        if let d = UserDefaults.standard.data(forKey: "integrationsState"), let s = try? JSONDecoder().decode([String: IntegrationState].self, from: d) { state = s }
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(state), forKey: "integrationsState") }
    func base(_ i: Integration) -> String { (i.publicOnly && !publicBase.isEmpty) ? publicBase : localBase }

    // ---------- files ----------
    func backup(_ id: String, _ path: String, into list: inout [FileBackup]) throws {
        if list.contains(where: { $0.path == path }) { return }
        let fm = FileManager.default
        let dir = ChatStore.dir.appendingPathComponent("integration-backups/\(id)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(String(Date().timeIntervalSince1970) + "-" + (path as NSString).lastPathComponent).path
        let existed = fm.fileExists(atPath: path)
        if existed { try fm.copyItem(atPath: path, toPath: dst) }
        list.append(FileBackup(path: path, existed: existed, backup: existed ? dst : ""))
    }
    func write(_ path: String, _ s: String, secret: Bool = false) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try s.write(toFile: path, atomically: true, encoding: .utf8)
        if secret { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }
    }
    func readJSON(_ path: String) -> [String: Any]? {
        guard let d = FileManager.default.contents(atPath: path) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]   // nil = unparseable (e.g. comments) → don't touch
    }
    func writeJSON(_ path: String, _ o: [String: Any]) throws {
        let d = try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys])
        try write(path, String(data: d, encoding: .utf8)!, secret: true)
    }
    /// shared env file (mode 600) sourced by ~/.zshrc and ~/.bash_profile through one marked line
    func setEnv(_ name: String, _ value: String?, files: inout [FileBackup], id: String) throws {
        var lines = ((try? String(contentsOfFile: envFile, encoding: .utf8)) ?? "").components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("export \(name)=") }
        if let value { lines.append("export \(name)='\(value)'") }
        try write(envFile, lines.joined(separator: "\n") + "\n", secret: true)
        for rc in [home + "/.zshrc", home + "/.bash_profile"] where value != nil {
            let cur = (try? String(contentsOfFile: rc, encoding: .utf8)) ?? ""
            if !cur.contains(Self.marker) && (FileManager.default.fileExists(atPath: rc) || rc.hasSuffix(".zshrc")) {
                try backup(id, rc, into: &files)
                try write(rc, cur + (cur.hasSuffix("\n") || cur.isEmpty ? "" : "\n") + Self.marker + "\n[ -f \"$HOME/.config/red-xai-vortex/env\" ] && . \"$HOME/.config/red-xai-vortex/env\"\n")
            }
        }
    }

    // ---------- connect ----------
    func connect(_ i: Integration, model: String) async {
        message = ""
        do {
            let r = try await Admin.call("POST", "/admin/keys", ["name": "integration: \(i.name)", "rpm": 600])
            guard let key = r["key"] as? String, let kid = r["id"] as? String else { throw NSError(domain: "Vortex", code: 1, userInfo: [NSLocalizedDescriptionKey: "key creation failed"]) }
            Keychain.set(key, account: "integration-\(i.id)")
            var files: [FileBackup] = []; var env: [String] = []
            let b = base(i)
            switch i.id {
            case "codex":
                // Codex 0.163+: profiles live in ~/.codex/<name>.config.toml (not [profiles.*] in config.toml)
                let p = home + "/.codex/vortex.config.toml"
                try backup(i.id, p, into: &files)
                let body = """
                # codex --profile vortex
                # Red-XAI Vortex (Integrations)
                model = "\(model)"
                model_provider = "vortex"

                [model_providers.vortex]
                name = "Red-XAI Vortex"
                base_url = "\(b)/v1"
                wire_api = "responses"
                env_key = "VORTEX_API_KEY"
                requires_openai_auth = false
                """.replacingOccurrences(of: "\n                ", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
                try write(p, body)
                try setEnv("VORTEX_API_KEY", key, files: &files, id: i.id); env.append("VORTEX_API_KEY")
            case "claude-code":
                let p = home + "/.claude/settings.json"
                guard var o = readJSON(p) else { throw NSError(domain: "Vortex", code: 2, userInfo: [NSLocalizedDescriptionKey: "~/.claude/settings.json isn't plain JSON; not changing it"]) }
                try backup(i.id, p, into: &files)
                var e = o["env"] as? [String: Any] ?? [:]
                e["ANTHROPIC_BASE_URL"] = b; e["ANTHROPIC_AUTH_TOKEN"] = key; e["ANTHROPIC_MODEL"] = model; e["ANTHROPIC_SMALL_FAST_MODEL"] = model
                o["env"] = e
                try writeJSON(p, o)
            case "gemini-cli":
                let p = home + "/.gemini/.env"
                try backup(i.id, p, into: &files)
                var lines = ((try? String(contentsOfFile: p, encoding: .utf8)) ?? "").components(separatedBy: "\n").filter { l in !l.isEmpty && !["GOOGLE_GEMINI_BASE_URL=", "GEMINI_API_KEY=", "GEMINI_MODEL="].contains { l.hasPrefix($0) } }
                lines += ["GOOGLE_GEMINI_BASE_URL=\(b)", "GEMINI_API_KEY=\(key)", "GEMINI_MODEL=\(model)"]
                try write(p, lines.joined(separator: "\n") + "\n", secret: true)
            case "opencode":
                let p = home + "/.config/opencode/opencode.json"
                guard var o = readJSON(p) else { throw NSError(domain: "Vortex", code: 2, userInfo: [NSLocalizedDescriptionKey: "opencode.json has comments; add the provider by hand (see Help)"]) }
                try backup(i.id, p, into: &files)
                var prov = o["provider"] as? [String: Any] ?? [:]
                prov["vortex"] = ["npm": "@ai-sdk/openai-compatible", "name": "Red-XAI Vortex", "options": ["baseURL": "\(b)/v1", "apiKey": "{env:VORTEX_API_KEY}"], "models": [model: ["name": model]]]
                o["provider"] = prov; o["model"] = "vortex/\(model)"
                if o["$schema"] == nil { o["$schema"] = "https://opencode.ai/config.json" }
                try writeJSON(p, o)
                try setEnv("VORTEX_API_KEY", key, files: &files, id: i.id); env.append("VORTEX_API_KEY")
            case "grok-cli":
                let p = home + "/.grok/user-settings.json"
                guard var o = readJSON(p) else { throw NSError(domain: "Vortex", code: 2, userInfo: [NSLocalizedDescriptionKey: "user-settings.json isn't plain JSON"]) }
                try backup(i.id, p, into: &files)
                o["apiKey"] = key; o["baseURL"] = "\(b)/v1"; o["defaultModel"] = model
                var ms = o["models"] as? [String] ?? []; if !ms.contains(model) { ms.insert(model, at: 0) }; o["models"] = ms
                try writeJSON(p, o)
            case "aider", "continue", "raycast":
                let p = home + (i.id == "aider" ? "/.aider.conf.yml" : i.id == "continue" ? "/.continue/config.yaml" : "/.config/raycast/ai/providers.yaml")
                if FileManager.default.fileExists(atPath: p) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(key, forType: .string)
                    files = []
                    message = "\(i.name): you already have \(p.replacingOccurrences(of: home, with: "~")), so it wasn't changed. The key is on your clipboard; add the snippet from Help → Integrations."
                } else {
                    try backup(i.id, p, into: &files)
                    let y: String
                    switch i.id {
                    case "aider": y = "openai-api-base: \(b)/v1\nopenai-api-key: \(key)\nmodel: openai/\(model)\n"
                    case "continue": y = "name: Red-XAI Vortex\nversion: 1.0.0\nschema: v1\nmodels:\n  - name: Vortex · \(model)\n    provider: openai\n    model: \(model)\n    apiBase: \(b)/v1\n    apiKey: \(key)\n    roles: [chat, edit, apply]\n"
                    default: y = "providers:\n  - id: vortex\n    name: Red-XAI Vortex\n    base_url: \(b)/v1\n    api_keys:\n      vortex: \(key)\n    models:\n      - id: \(model)\n        name: \(model)\n        provider: vortex\n        context: 32768\n        abilities:\n          temperature:\n            supported: true\n          system_message:\n            supported: true\n          tools:\n            supported: true\n"
                    }
                    try write(p, y, secret: true)
                }
            default: // guided
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(key, forType: .string)
                message = "\(i.name): a dedicated key is on your clipboard (it's also in your Keychain). Follow the steps on the card."
            }
            state[i.id] = IntegrationState(model: model, keyID: kid, at: Date(), files: files, envVars: env); save()
            if message.isEmpty { message = "\(i.name) connected to \(model). Back-ups are in Application Support/Red-XAI Vortex/integration-backups." }
        } catch { message = "\(i.name): \(error.localizedDescription)" }
    }

    func disconnect(_ i: Integration) async {
        guard let st = state[i.id] else { return }
        let fm = FileManager.default
        for f in st.files.reversed() {
            if f.path.hasSuffix(".zshrc") || f.path.hasSuffix(".bash_profile") {
                // only remove our two lines, keep anything JF changed since
                if let cur = try? String(contentsOfFile: f.path, encoding: .utf8), state.values.filter({ !$0.envVars.isEmpty }).count <= 1 {
                    let kept = cur.components(separatedBy: "\n").filter { $0 != Self.marker && !$0.contains(".config/red-xai-vortex/env") }
                    try? kept.joined(separator: "\n").write(toFile: f.path, atomically: true, encoding: .utf8)
                }
                continue
            }
            if f.existed { _ = try? fm.removeItem(atPath: f.path); try? fm.copyItem(atPath: f.backup, toPath: f.path) } else { try? fm.removeItem(atPath: f.path) }
        }
        var files = st.files
        for v in st.envVars where !state.contains(where: { $0.key != i.id && $0.value.envVars.contains(v) }) { try? setEnv(v, nil, files: &files, id: i.id) }
        _ = try? await Admin.call("DELETE", "/admin/keys/\(st.keyID)")
        Keychain.set("", account: "integration-\(i.id)")
        state[i.id] = nil; save()
        message = "\(i.name) disconnected: original config restored and its key revoked."
    }

    static func stripBlock(_ s: String) -> String {
        guard let a = s.range(of: "\n# >>> red-xai-vortex >>>"), let b = s.range(of: "# <<< red-xai-vortex <<<\n") else { return s }
        return String(s[..<a.lowerBound]) + String(s[b.upperBound...])
    }
}

struct IntegrationsView: View {
    @StateObject var store = IntegrationStore.shared
    @Local var models: [String] = []
    @Local var picks: [String: String] = [:]
    @Local var busy = ""
    let cols = [GridItem(.adaptive(minimum: 300), spacing: 12)]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Integrations").font(.largeTitle.bold())
                Text("Connect your tools to Vortex, any server or local model, merges and providers. Each tool gets its own revocable key. Automatic cards write the tool's official config (backed up first); Disconnect restores it. Tools on this Mac use \(store.localBase) while this app's tunnel is open.").font(.callout).foregroundStyle(.secondary)
                if !store.message.isEmpty { Text(store.message).font(.callout).foregroundStyle(.orange) }
                ForEach(["Coding agents", "Editors", "Desktop chat", "Chat apps", "Automation", "Not supported"], id: \.self) { cat in
                    Text(cat).font(.title3.bold()).padding(.top, 6)
                    LazyVGrid(columns: cols, alignment: .leading, spacing: 12) {
                        ForEach(IntegrationCatalog.all.filter { $0.category == cat }) { card($0) }
                    }
                }
            }.padding(20)
        }
        .task { if let r = try? await Admin.call("GET", "/v1/models"), let d = r["data"] as? [[String: Any]] { models = d.compactMap { $0["id"] as? String }.filter { !$0.contains("embed") } } }
    }
    @ViewBuilder func card(_ i: Integration) -> some View {
        let st = store.state[i.id]
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(i.name).font(.headline)
                Spacer()
                if i.mode == .unsupported { Text("Not supported").font(.caption.bold()).foregroundStyle(.secondary) }
                else if let st { Text("\(i.id == "codex" ? "Codex" : i.name): \(st.model)").font(.caption.bold()).foregroundStyle(.green) }
            }
            Text(i.how).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if i.mode != .unsupported {
                Text("\(i.wire) · \(i.mode == .auto ? "automatic" : "guided")\(i.publicOnly ? " · needs the public https URL" : "")").font(.caption2).foregroundStyle(.secondary)
                if st == nil {
                    HStack {
                        Picker("Model", selection: Binding(get: { picks[i.id] ?? (models.contains("vortex") ? "vortex" : models.first ?? "") }, set: { picks[i.id] = $0 })) {
                            ForEach(models, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden()
                        Button(busy == i.id ? "Connecting…" : "Connect") {
                            let m = picks[i.id] ?? (models.contains("vortex") ? "vortex" : models.first ?? "")
                            busy = i.id; Task { await store.connect(i, model: m); busy = "" }
                        }.buttonStyle(.borderedProminent).disabled(models.isEmpty || !busy.isEmpty)
                    }
                } else {
                    if i.mode == .guided {
                        Text(i.steps.replacingOccurrences(of: "{BASE}", with: store.base(i) + "/v1").replacingOccurrences(of: "{HOST}", with: store.base(i)).replacingOccurrences(of: "{MODEL}", with: st!.model))
                            .font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Button("Copy key again") { if let k = Keychain.get(account: "integration-\(i.id)") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(k, forType: .string); store.message = "Key copied to the clipboard." } }
                    }
                    Button("Disconnect", role: .destructive) { busy = i.id; Task { await store.disconnect(i); busy = "" } }.disabled(!busy.isEmpty)
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(i.mode == .unsupported ? 0.25 : 0.5)))
    }
}
