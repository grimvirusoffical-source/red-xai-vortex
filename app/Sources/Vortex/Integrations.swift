import SwiftUI
import AppKit
import Darwin

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
    @Published var cardError: [String: String] = [:]
    @Published var cardOK: [String: String] = [:]
    /// Tool presence detected off the main render path (never Process in a View body).
    @Published var installedTools: [String: Bool] = [:]
    @Published var toolPaths: [String: String] = [:]
    @Published var toolsScanned = false
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
        message = ""; cardError[i.id] = nil; cardOK[i.id] = nil
        do {
            // Ensure tunnel public port is up (Integrations use localBase = sshLocalPort-1 → 18091)
            let probe = localBase + "/health"
            if let u = URL(string: probe) {
                var ok = false
                if let (_, resp) = try? await URLSession.shared.data(from: u), (resp as? HTTPURLResponse)?.statusCode == 200 { ok = true }
                if !ok { throw NSError(domain: "Vortex", code: 3, userInfo: [NSLocalizedDescriptionKey: "Gateway tunnel \(localBase) is down. Open the app and wait until the server connection is green, then try again."]) }
            }
            let r = try await Admin.call("POST", "/admin/keys", ["name": "integration: \(i.name)", "rpm": 600])
            guard let key = r["key"] as? String, let kid = r["id"] as? String else {
                throw NSError(domain: "Vortex", code: 1, userInfo: [NSLocalizedDescriptionKey: "key creation failed (no key in response)"])
            }
            Keychain.set(key, account: "integration-\(i.id)")
            var files: [FileBackup] = []; var env: [String] = []
            let b = base(i)
            switch i.id {
            case "codex":
                let p = home + "/.codex/vortex.config.toml"
                try backup(i.id, p, into: &files)
                let body = """
                # codex --profile vortex
                # Red-XAI Vortex (Integrations)
                model = "\(model)"
                model_provider = "vortex"
                model_context_window = 32768
                model_auto_compact_token_limit = 28000

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
                var o = readJSON(p) ?? [:]
                if readJSON(p) == nil && FileManager.default.fileExists(atPath: p) {
                    throw NSError(domain: "Vortex", code: 2, userInfo: [NSLocalizedDescriptionKey: "~/.claude/settings.json isn't plain JSON; not changing it"])
                }
                try backup(i.id, p, into: &files)
                var e = o["env"] as? [String: Any] ?? [:]
                e["ANTHROPIC_BASE_URL"] = b
                e["ANTHROPIC_AUTH_TOKEN"] = key
                e["ANTHROPIC_MODEL"] = model
                e["ANTHROPIC_SMALL_FAST_MODEL"] = model
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
                var o: [String: Any]
                if FileManager.default.fileExists(atPath: p) {
                    guard let parsed = readJSON(p) else {
                        throw NSError(domain: "Vortex", code: 2, userInfo: [NSLocalizedDescriptionKey: "opencode.json has comments; fix or remove it, then Connect again"])
                    }
                    o = parsed
                    try backup(i.id, p, into: &files)
                } else {
                    o = ["$schema": "https://opencode.ai/config.json"]
                    try backup(i.id, p, into: &files)
                }
                var prov = o["provider"] as? [String: Any] ?? [:]
                prov["vortex"] = [
                    "npm": "@ai-sdk/openai-compatible",
                    "name": "Red-XAI Vortex",
                    "options": ["baseURL": "\(b)/v1", "apiKey": "{env:VORTEX_API_KEY}"],
                    "models": [model: ["name": model]]
                ]
                o["provider"] = prov
                o["model"] = "vortex/\(model)"
                try writeJSON(p, o)
                try setEnv("VORTEX_API_KEY", key, files: &files, id: i.id); env.append("VORTEX_API_KEY")
            case "grok-cli":
                let p = home + "/.grok/user-settings.json"
                var o: [String: Any]
                if FileManager.default.fileExists(atPath: p) {
                    guard let parsed = readJSON(p) else { throw NSError(domain: "Vortex", code: 2, userInfo: [NSLocalizedDescriptionKey: "user-settings.json isn't plain JSON"]) }
                    o = parsed; try backup(i.id, p, into: &files)
                } else {
                    o = [:]; try backup(i.id, p, into: &files)
                }
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
            let ok = "\(i.name) connected to \(model) via \(b)."
            cardOK[i.id] = ok
            if message.isEmpty { message = ok + " Disconnect restores the backup and revokes the key." }
        } catch {
            var msg = error.localizedDescription
            if msg.contains("owner unlock") {
                msg = "Owner unlock required for this action. Open the Owner tab, unlock, then try Connect again. (Integration keys should not need this — update the gateway if you still see it.)"
            }
            cardError[i.id] = msg
            message = "\(i.name): \(msg)"
        }
    }

    func disconnect(_ i: Integration) async {
        guard let st = state[i.id] else { return }
        cardError[i.id] = nil; cardOK[i.id] = nil
        let fm = FileManager.default
        for f in st.files.reversed() {
            if f.path.hasSuffix(".zshrc") || f.path.hasSuffix(".bash_profile") {
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
        cardOK[i.id] = message
    }

    /// Run a one-shot probe through the tool's own CLI (or a direct HTTP check for guided).
    func test(_ i: Integration) async {
        cardError[i.id] = nil; cardOK[i.id] = nil; message = ""
        guard let st = state[i.id], let key = Keychain.get(account: "integration-\(i.id)"), !key.isEmpty else {
            cardError[i.id] = "Not connected (no key in Keychain)."
            message = "\(i.name): \(cardError[i.id]!)"
            return
        }
        let b = base(i)
        do {
            switch i.id {
            case "codex":
                if !toolsScanned { refreshInstalledTools() }
                guard let bin = codexBinary() else { throw NSError(domain: "Vortex", code: 4, userInfo: [NSLocalizedDescriptionKey: "Codex CLI not found. Use Install, then Test again."]) }
                let out = try await runProcess(bin, ["exec", "-p", "vortex", "--skip-git-repo-check", "Reply with exactly: VORTEX_OK"], env: ["VORTEX_API_KEY": key], timeout: 120)
                if out.combined.contains("VORTEX_OK") || out.status == 0 && !out.stdout.isEmpty {
                    cardOK[i.id] = "Test OK — Codex replied via \(b)."
                } else {
                    throw NSError(domain: "Vortex", code: 5, userInfo: [NSLocalizedDescriptionKey: "Codex exit \(out.status): \(String(out.combined.suffix(400)))"])
                }
            case "claude-code":
                if !toolsScanned { refreshInstalledTools() }
                let bin = toolPaths["claude-code"] ?? (home + "/.local/bin/claude")
                guard FileManager.default.isExecutableFile(atPath: bin) else {
                    throw NSError(domain: "Vortex", code: 4, userInfo: [NSLocalizedDescriptionKey: "Claude Code not found. Use Install."])
                }
                // Prefer a direct Anthropic-messages probe (same wire as Claude Code) so we don't need an interactive TTY
                let reply = try await httpProbeAnthropic(base: b, key: key, model: st.model)
                cardOK[i.id] = "Test OK — /v1/messages: \(reply)"
            case "opencode":
                // Direct OpenAI chat probe matching OpenCode's openai-compatible provider
                let reply = try await httpProbeChat(base: b + "/v1", key: key, model: st.model)
                cardOK[i.id] = "Test OK — chat completions: \(reply)"
            default:
                let reply = try await httpProbeChat(base: b + "/v1", key: key, model: st.model)
                cardOK[i.id] = "Test OK — \(reply)"
            }
            message = "\(i.name): \(cardOK[i.id]!)"
        } catch {
            cardError[i.id] = error.localizedDescription
            message = "\(i.name) test failed: \(error.localizedDescription)"
        }
    }

    func install(_ i: Integration) async {
        cardError[i.id] = nil; cardOK[i.id] = nil
        guard let cmd = Self.installCommand(i.id) else {
            cardError[i.id] = "No official installer mapped for \(i.name)."
            message = cardError[i.id]!
            return
        }
        do {
            let out = try await runProcess("/bin/zsh", ["-lc", cmd], env: [:], timeout: 600)
            if out.status == 0 {
                refreshInstalledTools()
                cardOK[i.id] = "Installed. \(String(out.stdout.suffix(200)))"
                message = "\(i.name): installed."
            } else {
                throw NSError(domain: "Vortex", code: 6, userInfo: [NSLocalizedDescriptionKey: "Install exit \(out.status): \(String(out.combined.suffix(500)))"])
            }
        } catch {
            cardError[i.id] = error.localizedDescription
            message = "\(i.name) install failed: \(error.localizedDescription)"
        }
    }

    func toolInstalled(_ id: String) -> Bool {
        // Safe for View bodies: only reads cached @Published state.
        installedTools[id] ?? false
    }

    /// Scan known bin dirs with FileManager only (no Process / which). Call from .task / button, never from body.
    func refreshInstalledTools() {
        let home = self.home
        let fm = FileManager.default
        var pathEnv = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        let dirs = [
            home + "/.local/bin",
            home + "/.npm-global/bin",
            home + "/.bun/bin",
            home + "/.cargo/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            home + "/Library/Application Support/Claude/claude",
        ] + pathEnv
        func findExec(_ names: [String], extra: [String] = []) -> String? {
            for p in extra + names.flatMap({ n in dirs.map { $0 + "/" + n } }) {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue, fm.isExecutableFile(atPath: p) {
                    return p
                }
            }
            return nil
        }
        let codex = findExec(["codex"], extra: [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            home + "/.npm-global/bin/codex",
        ])
        let claude = findExec(["claude"], extra: [home + "/.local/bin/claude"])
        let opencode = findExec(["opencode"])
        let gemini = findExec(["gemini"])
        let grok = findExec(["grok"])
        let aider = findExec(["aider"])
        var paths: [String: String] = [:]
        var inst: [String: Bool] = [:]
        if let c = codex { paths["codex"] = c; inst["codex"] = true } else { inst["codex"] = false }
        if let c = claude { paths["claude-code"] = c; inst["claude-code"] = true } else { inst["claude-code"] = false }
        if let c = opencode { paths["opencode"] = c; inst["opencode"] = true } else { inst["opencode"] = false }
        if let c = gemini { paths["gemini-cli"] = c; inst["gemini-cli"] = true } else { inst["gemini-cli"] = false }
        if let c = grok { paths["grok-cli"] = c; inst["grok-cli"] = true }
        else { inst["grok-cli"] = fm.fileExists(atPath: home + "/.grok/user-settings.json") }
        if let c = aider { paths["aider"] = c; inst["aider"] = true } else { inst["aider"] = false }
        // Guided tools: treat as "installed" so we don't show Install
        for id in ["cursor", "cline", "roo", "kilo", "copilot", "zed", "jetbrains", "goose",
                   "openwebui", "librechat", "anythingllm", "msty", "jan", "boltai", "chatbox",
                   "obsidian", "lmstudio", "n8n", "flowise", "chatgpt-actions", "continue", "raycast"] {
            inst[id] = true
        }
        self.toolPaths = paths
        self.installedTools = inst
        self.toolsScanned = true
    }

    func codexBinary() -> String? { toolPaths["codex"] }

    static func installCommand(_ id: String) -> String? {
        switch id {
        case "codex": return "npm install -g @openai/codex"
        case "claude-code": return "curl -fsSL https://claude.ai/install.sh | bash"
        case "opencode": return "curl -fsSL https://opencode.ai/install | bash"
        case "gemini-cli": return "npm install -g @google/gemini-cli"
        case "aider": return "pipx install aider-chat || pip3 install --user aider-chat"
        case "grok-cli": return "npm install -g @vibe-tools/grok-cli || npm install -g grok-cli"
        default: return nil
        }
    }

    struct ProcOut { var status: Int32; var stdout: String; var stderr: String; var combined: String { stdout + stderr } }
    func runProcess(_ bin: String, _ args: [String], env: [String: String], timeout: TimeInterval) async throws -> ProcOut {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: bin)
                p.arguments = args
                var e = ProcessInfo.processInfo.environment
                for (k, v) in env { e[k] = v }
                p.environment = e
                let out = Pipe(), err = Pipe()
                p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(throwing: error); return }
                let deadline = Date().addingTimeInterval(timeout)
                while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
                if p.isRunning { p.terminate(); Thread.sleep(forTimeInterval: 0.3); if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
                let so = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let se = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                cont.resume(returning: ProcOut(status: p.terminationStatus, stdout: so, stderr: se))
            }
        }
    }

    func httpProbeChat(base: String, key: String, model: String) async throws -> String {
        guard let u = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions") else { throw URLError(.badURL) }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 90
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "max_tokens": 32,
            "messages": [["role": "user", "content": "Reply with exactly: VORTEX_OK"]]
        ])
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let j = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        if code >= 300 {
            let m = ((j["error"] as? [String: Any])?["message"] as? String) ?? String(data: d, encoding: .utf8) ?? "HTTP \(code)"
            throw NSError(domain: "Vortex", code: code, userInfo: [NSLocalizedDescriptionKey: m])
        }
        let text = (((j["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80).description
    }
    func httpProbeAnthropic(base: String, key: String, model: String) async throws -> String {
        guard let u = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/messages") else { throw URLError(.badURL) }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 90
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        r.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "max_tokens": 32,
            "messages": [["role": "user", "content": "Reply with exactly: VORTEX_OK"]]
        ])
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let j = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        if code >= 300 {
            let m = ((j["error"] as? [String: Any])?["message"] as? String) ?? String(data: d, encoding: .utf8) ?? "HTTP \(code)"
            throw NSError(domain: "Vortex", code: code, userInfo: [NSLocalizedDescriptionKey: m])
        }
        let blocks = j["content"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { $0["text"] as? String }.joined()
        return text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80).description
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
    @Local var confirmInstall: String?
    let cols = [GridItem(.adaptive(minimum: 300), spacing: 12)]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Integrations").font(.largeTitle.bold())
                Text("Connect your tools to Vortex. Each tool gets its own revocable key. Automatic cards write the tool's official config (backed up first). Tools on this Mac use \(store.localBase) while this app's tunnel is open (not 18090).").font(.callout).foregroundStyle(.secondary)
                if !store.message.isEmpty {
                    Text(store.message).font(.callout)
                        .foregroundStyle(store.message.contains("fail") || store.message.contains("error") || store.message.contains("required") ? .red : .green)
                        .textSelection(.enabled)
                }
                ForEach(["Coding agents", "Editors", "Desktop chat", "Chat apps", "Automation", "Not supported"], id: \.self) { cat in
                    Text(cat).font(.title3.bold()).padding(.top, 6)
                    LazyVGrid(columns: cols, alignment: .leading, spacing: 12) {
                        ForEach(IntegrationCatalog.all.filter { $0.category == cat }) { card($0) }
                    }
                }
            }.padding(20)
        }
        .task {
            await Task.detached(priority: .utility) {
                await MainActor.run { store.refreshInstalledTools() }
            }.value
            // Prefer public API via tunnel 18091 so the model list works even before owner unlock
            if let u = URL(string: store.localBase + "/v1/models"),
               var req = Optional(URLRequest(url: u)) {
                req.setValue("Bearer \(Keychain.get() ?? "")", forHTTPHeaderField: "Authorization")
                if let (d, _) = try? await URLSession.shared.data(for: req),
                   let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let data = j["data"] as? [[String: Any]] {
                    models = data.compactMap { $0["id"] as? String }.filter { !$0.contains("embed") }
                }
            }
            if models.isEmpty, let r = try? await Admin.call("GET", "/v1/models"), let d = r["data"] as? [[String: Any]] {
                models = d.compactMap { $0["id"] as? String }.filter { !$0.contains("embed") }
            }
        }
        .confirmationDialog("Install \(confirmInstall.flatMap { id in IntegrationCatalog.all.first { $0.id == id }?.name } ?? "tool")?", isPresented: Binding(get: { confirmInstall != nil }, set: { if !$0 { confirmInstall = nil } })) {
            Button("Install") {
                if let id = confirmInstall, let i = IntegrationCatalog.all.first(where: { $0.id == id }) {
                    busy = id; Task { await store.install(i); busy = ""; confirmInstall = nil }
                }
            }
            Button("Cancel", role: .cancel) { confirmInstall = nil }
        } message: {
            Text(confirmInstall.flatMap { IntegrationStore.installCommand($0) } ?? "")
        }
    }
    @ViewBuilder func card(_ i: Integration) -> some View {
        let st = store.state[i.id]
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(i.name).font(.headline)
                Spacer()
                if i.mode == .unsupported { Text("Not supported").font(.caption.bold()).foregroundStyle(.secondary) }
                else if let st { Text("\(i.id == "codex" ? "Codex" : i.name): \(st.model)").font(.caption.bold()).foregroundStyle(.green) }
                else if !store.toolInstalled(i.id) && IntegrationStore.installCommand(i.id) != nil {
                    Text("Not installed").font(.caption).foregroundStyle(.orange)
                }
            }
            Text(i.how).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let e = store.cardError[i.id] { Text(e).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let o = store.cardOK[i.id] { Text(o).font(.caption).foregroundStyle(.green).textSelection(.enabled) }
            if i.mode != .unsupported {
                Text("\(i.wire) · \(i.mode == .auto ? "automatic" : "guided") · base \(store.base(i))\(i.publicOnly ? " · needs public https" : "")").font(.caption2).foregroundStyle(.secondary)
                if st == nil {
                    HStack {
                        Picker("Model", selection: Binding(get: { picks[i.id] ?? (models.contains("vortex") ? "vortex" : models.first ?? "") }, set: { picks[i.id] = $0 })) {
                            ForEach(models, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden()
                        Button(busy == i.id ? "Connecting…" : "Connect") {
                            let m = picks[i.id] ?? (models.contains("vortex") ? "vortex" : models.first ?? "")
                            busy = i.id; Task { await store.connect(i, model: m); busy = "" }
                        }.buttonStyle(.borderedProminent).disabled(models.isEmpty || !busy.isEmpty)
                        if !store.toolInstalled(i.id), IntegrationStore.installCommand(i.id) != nil {
                            Button("Install") { confirmInstall = i.id }.disabled(!busy.isEmpty)
                        }
                    }
                } else {
                    if i.mode == .guided {
                        Text(i.steps.replacingOccurrences(of: "{BASE}", with: store.base(i) + "/v1").replacingOccurrences(of: "{HOST}", with: store.base(i)).replacingOccurrences(of: "{MODEL}", with: st!.model))
                            .font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Button("Copy key again") { if let k = Keychain.get(account: "integration-\(i.id)") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(k, forType: .string); store.message = "Key copied to the clipboard." } }
                    }
                    HStack {
                        Button(busy == "test-\(i.id)" ? "Testing…" : "Test") {
                            busy = "test-\(i.id)"; Task { await store.test(i); busy = "" }
                        }.disabled(!busy.isEmpty)
                        Button("Disconnect", role: .destructive) { busy = i.id; Task { await store.disconnect(i); busy = "" } }.disabled(!busy.isEmpty)
                    }
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(i.mode == .unsupported ? 0.25 : 0.5)))
    }
}
