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
              how: "Adds ~/.claude/vortex-settings.json + a `claude-vortex` command (~/.local/bin). Your normal `claude` and its models are untouched. Run: claude-vortex"),
        .init(id: "gemini-cli", name: "Gemini CLI", category: "Coding agents", wire: "Gemini API", mode: .auto,
              how: "Adds a `gemini-vortex` command (~/.local/bin) that points Gemini CLI at the gateway's /v1beta shim. Your normal `gemini` setup is untouched."),
        .init(id: "opencode", name: "OpenCode", category: "Coding agents", wire: "OpenAI Chat", mode: .auto,
              how: "~/.config/opencode/opencode.json → adds provider \"vortex\" next to your existing providers (default model is not changed). Pick vortex/<model> in /models."),
        .init(id: "grok-cli", name: "Grok CLI (open-source)", category: "Coding agents", wire: "OpenAI Chat", mode: .auto,
              how: "Adds a `grok-vortex` command (~/.local/bin) using --base-url/--api-key. Your Grok CLI settings are untouched."),
        .init(id: "aider", name: "Aider", category: "Coding agents", wire: "OpenAI Chat", mode: .auto,
              how: "Adds an `aider-vortex` command (~/.local/bin). Your ~/.aider.conf.yml is untouched."),
        .init(id: "continue", name: "VS Code / JetBrains: Continue", category: "Editors", wire: "OpenAI Chat", mode: .auto,
              how: "~/.continue/config.yaml → appends a Vortex model to your models list (existing models kept). VS Code is relaunched."),
        .init(id: "raycast", name: "Raycast AI", category: "Desktop chat", wire: "OpenAI Chat", mode: .auto,
              how: "~/.config/raycast/ai/providers.yaml → appends a Vortex provider (existing providers kept). Raycast is relaunched."),
        .init(id: "zed", name: "Zed", category: "Editors", wire: "OpenAI Chat", mode: .auto,
              how: "~/.config/zed/settings.json → adds language_models.openai_compatible.Vortex (existing providers kept); key via VORTEX_API_KEY. Zed is relaunched."),
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
        .init(id: "omniroute", name: "OmniRoute", category: "Automation", wire: "OpenAI Chat", mode: .guided,
              how: "OmniRoute dashboard → Providers → Add OpenAI-compatible (stored in OmniRoute's own database; no config file to write)",
              steps: "OmniRoute (http://127.0.0.1:20128) → Providers → Add → OpenAI Compatible (Chat). Name: Red-XAI · Prefix: redxai · Base URL: {BASE} · Chat path: leave empty (/chat/completions) · Models path: /models · API key: paste (on your clipboard) · Default model: {MODEL} (a model id, NOT /models) · turn OFF Proxy egress for this provider (it's local). Save → Test → Sync models. Use as redxai/{MODEL}."),
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

    // ---------- target apps ----------
    /// Desktop apps that read the config we write; relaunched after Connect so they pick it up.
    static let bundleIDs: [String: [String]] = [
        "codex": ["com.openai.codex", "com.openai.chat"],
        "continue": ["com.microsoft.VSCode"], "cline": ["com.microsoft.VSCode"], "roo": ["com.microsoft.VSCode"],
        "kilo": ["com.microsoft.VSCode"], "copilot": ["com.microsoft.VSCode"],
        "cursor": ["com.todesktop.230313mzl4w4u92"], "zed": ["dev.zed.Zed"], "raycast": ["com.raycast.macos"],
        "jan": ["jan.ai.app"], "lmstudio": ["ai.elementlabs.lmstudio"], "msty": ["app.msty.app"],
        "anythingllm": ["com.anythingllm"], "boltai": ["co.podzim.BoltGPT"], "chatbox": ["xyz.chatboxapp.app"],
        "obsidian-copilot": ["md.obsidian"], "jetbrains": [],
    ]
    static let webApps: [String: String] = ["omniroute": "http://127.0.0.1:20128", "openwebui": "http://127.0.0.1:8080", "n8n": "http://127.0.0.1:5678", "flowise": "http://127.0.0.1:3000"]
    func appURL(_ id: String) -> URL? {
        for b in Self.bundleIDs[id] ?? [] { if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) { return u } }
        return nil
    }
    func appInstalled(_ id: String) -> Bool { appURL(id) != nil }
    /// Quit (if running) and relaunch the target app so it reloads the config. Returns a status line.
    func relaunch(_ id: String, name: String) async -> String {
        guard let url = appURL(id) else {
            if let w = Self.webApps[id], let u = URL(string: w) { NSWorkspace.shared.open(u); return "Opened \(w)." }
            return ""
        }
        let bids = Self.bundleIDs[id] ?? []
        let running = NSWorkspace.shared.runningApplications.filter { bids.contains($0.bundleIdentifier ?? "") }
        for a in running { a.terminate() }
        for _ in 0..<40 where running.contains(where: { !$0.isTerminated }) { try? await Task.sleep(nanoseconds: 250_000_000) }
        let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        return running.isEmpty ? "Opened \(url.deletingPathExtension().lastPathComponent)." : "Relaunched \(url.deletingPathExtension().lastPathComponent)."
    }
    /// For GUI apps: make VORTEX_API_KEY visible to apps launched from Finder/Dock.
    func setLaunchEnv(_ name: String, _ value: String?) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = value.map { ["setenv", name, $0] } ?? ["unsetenv", name]
        try? p.run()   // fire and forget; never waitUntilExit on the main actor
    }
    /// ~/.local/bin/<name> launcher (mode 700) that sources the env file and execs the real tool.
    func writeLauncher(_ name: String, _ body: String, id: String, files: inout [FileBackup]) throws -> String {
        let p = home + "/.local/bin/" + name
        try backup(id, p, into: &files)
        try write(p, "#!/bin/zsh\n# Red-XAI Vortex launcher (Integrations). Removed on Disconnect.\n[ -f \"$HOME/.config/red-xai-vortex/env\" ] && . \"$HOME/.config/red-xai-vortex/env\"\n" + body + "\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: p)
        return p
    }
    /// Insert YAML list item text right after a top-level `<key>:` line (append the key if missing).
    func yamlAppend(_ y: String, key: String, item: String) -> String {
        var lines = y.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.hasPrefix(key + ":") }) {
            if lines[i].trimmingCharacters(in: .whitespaces).hasSuffix("[]") { lines[i] = key + ":" }
            // match the indentation of the existing list items so the YAML stays valid
            var indent = "  "
            if let n = lines[(i + 1)...].first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }),
               n.trimmingCharacters(in: .whitespaces).hasPrefix("-") {
                indent = String(n.prefix { $0 == " " })
            }
            let items = item.components(separatedBy: "\n").filter { !$0.isEmpty }.map { $0.hasPrefix("  ") ? indent + $0.dropFirst(2) : $0 }
            lines.insert(contentsOf: items, at: i + 1)
            return lines.joined(separator: "\n")
        }
        return y + (y.hasSuffix("\n") || y.isEmpty ? "" : "\n") + key + ":\n" + item
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
                // Alongside, not instead: a separate settings file + claude-vortex launcher. ~/.claude/settings.json untouched.
                let p = home + "/.claude/vortex-settings.json"
                try backup(i.id, p, into: &files)
                try writeJSON(p, ["env": ["ANTHROPIC_BASE_URL": b, "ANTHROPIC_AUTH_TOKEN": key, "ANTHROPIC_MODEL": model,
                                          "ANTHROPIC_SMALL_FAST_MODEL": model, "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"]])
                let bin = toolPaths["claude-code"] ?? (home + "/.local/bin/claude")
                _ = try writeLauncher("claude-vortex", "exec \"\(bin)\" --settings \"$HOME/.claude/vortex-settings.json\" \"$@\"", id: i.id, files: &files)
            case "gemini-cli":
                try setEnv("VORTEX_API_KEY", key, files: &files, id: i.id); env.append("VORTEX_API_KEY")
                let bin = toolPaths["gemini-cli"] ?? "gemini"
                _ = try writeLauncher("gemini-vortex", "export GOOGLE_GEMINI_BASE_URL='\(b)' GEMINI_API_KEY=\"$VORTEX_API_KEY\" GEMINI_MODEL='\(model)'\nexec \"\(bin)\" -m '\(model)' \"$@\"", id: i.id, files: &files)
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
                if o["model"] == nil { o["model"] = "vortex/\(model)" }   // never replace the user's default
                try writeJSON(p, o)
                try setEnv("VORTEX_API_KEY", key, files: &files, id: i.id); env.append("VORTEX_API_KEY")
            case "grok-cli":
                try setEnv("VORTEX_API_KEY", key, files: &files, id: i.id); env.append("VORTEX_API_KEY")
                let bin = toolPaths["grok-cli"] ?? "grok"
                _ = try writeLauncher("grok-vortex", "exec \"\(bin)\" --base-url '\(b)/v1' --api-key \"$VORTEX_API_KEY\" --model '\(model)' \"$@\"", id: i.id, files: &files)
            case "aider":
                try setEnv("VORTEX_API_KEY", key, files: &files, id: i.id); env.append("VORTEX_API_KEY")
                let bin = toolPaths["aider"] ?? "aider"
                _ = try writeLauncher("aider-vortex", "exec \"\(bin)\" --openai-api-base '\(b)/v1' --openai-api-key \"$VORTEX_API_KEY\" --model 'openai/\(model)' \"$@\"", id: i.id, files: &files)
            case "continue":
                let p = home + "/.continue/config.yaml"
                try backup(i.id, p, into: &files)
                var y = (try? String(contentsOfFile: p, encoding: .utf8)) ?? "name: Local Config\nversion: 1.0.0\nschema: v1\n"
                y = Self.stripItem(y)
                let item = "  # red-xai-vortex begin\n  - name: Vortex · \(model)\n    provider: openai\n    model: \(model)\n    apiBase: \(b)/v1\n    apiKey: \(key)\n    roles: [chat, edit, apply]\n  # red-xai-vortex end\n"
                try write(p, yamlAppend(y, key: "models", item: item), secret: true)
            case "raycast":
                let p = home + "/.config/raycast/ai/providers.yaml"
                try backup(i.id, p, into: &files)
                var y = (try? String(contentsOfFile: p, encoding: .utf8)) ?? ""
                y = Self.stripItem(y)
                let item = "  # red-xai-vortex begin\n  - id: vortex\n    name: Red-XAI Vortex\n    base_url: \(b)/v1\n    api_keys:\n      vortex: \(key)\n    models:\n      - id: \(model)\n        name: \(model)\n        provider: vortex\n        context: 32768\n  # red-xai-vortex end\n"
                try write(p, yamlAppend(y, key: "providers", item: item), secret: true)
            case "zed":
                let p = home + "/.config/zed/settings.json"
                var o: [String: Any] = [:]
                if FileManager.default.fileExists(atPath: p) {
                    guard let parsed = readJSON(p) else {
                        throw NSError(domain: "Vortex", code: 2, userInfo: [NSLocalizedDescriptionKey: "Zed's settings.json has comments, so it wasn't changed (backed up nothing). Add the Vortex block from Help → Integrations by hand."])
                    }
                    o = parsed
                }
                try backup(i.id, p, into: &files)
                var lm = o["language_models"] as? [String: Any] ?? [:]
                var oc = lm["openai_compatible"] as? [String: Any] ?? [:]
                oc["Vortex"] = ["api_url": "\(b)/v1", "available_models": [["name": model, "display_name": "Vortex · \(model)", "max_tokens": 32768]]]
                lm["openai_compatible"] = oc; o["language_models"] = lm
                try writeJSON(p, o)
                try setEnv("VORTEX_API_KEY", key, files: &files, id: i.id); env.append("VORTEX_API_KEY")
                setLaunchEnv("VORTEX_API_KEY", key)
            default: // guided: app keeps its config in its own database/UI
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(key, forType: .string)
                message = "\(i.name): a dedicated key is on your clipboard (it's also in your Keychain). Follow the steps on the card, then press Test."
            }
            if i.id == "codex" { setLaunchEnv("VORTEX_API_KEY", key) }
            state[i.id] = IntegrationState(model: model, keyID: kid, at: Date(), files: files, envVars: env); save()
            let rl = await relaunch(i.id, name: i.name)
            let ok = "\(i.name) connected to \(model) via \(b). \(rl)"
            cardOK[i.id] = ok
            if message.isEmpty { message = ok + " Your existing models are kept. Disconnect restores the backup and revokes the key." }
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
        if !state.contains(where: { $0.key != i.id && $0.value.envVars.contains("VORTEX_API_KEY") }) { setLaunchEnv("VORTEX_API_KEY", nil) }
        _ = try? await Admin.call("DELETE", "/admin/keys/\(st.keyID)")
        Keychain.set("", account: "integration-\(i.id)")
        state[i.id] = nil; save()
        message = "\(i.name) disconnected: original config restored and its key revoked."
        cardOK[i.id] = message
    }

    /// Test = a real chat call through the endpoint + key the tool is configured with (read back from its config),
    /// or through the tool's own CLI where it has a non-interactive mode.
    func test(_ i: Integration) async {
        cardError[i.id] = nil; cardOK[i.id] = "Testing…"; message = ""
        guard let st = state[i.id], let key = Keychain.get(account: "integration-\(i.id)"), !key.isEmpty else {
            cardOK[i.id] = nil
            cardError[i.id] = "Not connected (no key in Keychain). Press Connect first."
            message = "\(i.name): \(cardError[i.id]!)"
            return
        }
        if !toolsScanned { refreshInstalledTools() }
        let b = base(i)
        let t0 = Date()
        func secs() -> String { String(format: "%.1fs", Date().timeIntervalSince(t0)) }
        do {
            var result = ""
            switch i.id {
            case "codex":
                guard let bin = codexBinary() else { throw NSError(domain: "Vortex", code: 4, userInfo: [NSLocalizedDescriptionKey: "Codex CLI not found. Use Install, then Test again."]) }
                // --ignore-user-config skips your MCP servers/skills so the probe is fast; the vortex profile is still layered on.
                let out = try await runProcess(bin, ["exec", "--ignore-user-config", "-p", "vortex", "--skip-git-repo-check", "-c", "model_reasoning_effort=\"low\"",
                                                     "Reply with exactly: VORTEX_OK"], env: ["VORTEX_API_KEY": key], timeout: 300)
                guard out.combined.contains("VORTEX_OK") else {
                    throw NSError(domain: "Vortex", code: 5, userInfo: [NSLocalizedDescriptionKey: "Codex exit \(out.status): \(String(out.combined.suffix(400)))"])
                }
                result = "codex exec -p vortex → VORTEX_OK"
            case "claude-code":
                let launcher = home + "/.local/bin/claude-vortex"
                if FileManager.default.isExecutableFile(atPath: launcher) {
                    let out = try await runProcess(launcher, ["-p", "Reply with exactly: VORTEX_OK"], env: [:], timeout: 300)
                    if out.combined.contains("VORTEX_OK") { result = "claude-vortex -p → VORTEX_OK" }
                    else { result = "claude-vortex didn't answer (\(out.status)); /v1/messages: " + (try await httpProbeAnthropic(base: b, key: key, model: st.model)) }
                } else { result = "/v1/messages: " + (try await httpProbeAnthropic(base: b, key: key, model: st.model)) }
            case "opencode":
                let o = readJSON(home + "/.config/opencode/opencode.json") ?? [:]
                let opts = ((o["provider"] as? [String: Any])?["vortex"] as? [String: Any])?["options"] as? [String: Any]
                let cfgBase = opts?["baseURL"] as? String ?? b + "/v1"
                result = "opencode.json provider vortex (\(cfgBase)): " + (try await httpProbeChat(base: cfgBase, key: key, model: st.model))
            case "zed":
                let o = readJSON(home + "/.config/zed/settings.json") ?? [:]
                let v = ((o["language_models"] as? [String: Any])?["openai_compatible"] as? [String: Any])?["Vortex"] as? [String: Any]
                guard let u = v?["api_url"] as? String else { throw NSError(domain: "Vortex", code: 7, userInfo: [NSLocalizedDescriptionKey: "Vortex block missing from Zed settings.json"]) }
                result = "Zed settings api_url \(u): " + (try await httpProbeChat(base: u, key: key, model: st.model))
            case "continue", "raycast":
                let p = home + (i.id == "continue" ? "/.continue/config.yaml" : "/.config/raycast/ai/providers.yaml")
                let y = (try? String(contentsOfFile: p, encoding: .utf8)) ?? ""
                let line = y.components(separatedBy: "\n").first { $0.contains("apiBase:") || $0.contains("base_url:") } ?? ""
                let u = line.components(separatedBy: ": ").dropFirst().joined(separator: ": ").trimmingCharacters(in: .whitespaces)
                guard !u.isEmpty else { throw NSError(domain: "Vortex", code: 7, userInfo: [NSLocalizedDescriptionKey: "Vortex entry missing from \(p)"]) }
                result = "\((p as NSString).lastPathComponent) → \(u): " + (try await httpProbeChat(base: u, key: key, model: st.model))
            case "gemini-cli", "grok-cli", "aider":
                result = "\(i.id.replacingOccurrences(of: "-cli", with: ""))-vortex endpoint \(b): " + (try await httpProbeChat(base: b + "/v1", key: key, model: st.model))
            default:
                result = "\(b)/v1 with this app's key: " + (try await httpProbeChat(base: b + "/v1", key: key, model: st.model))
            }
            cardOK[i.id] = "Test OK (\(secs())) — \(result)"
            message = "\(i.name): \(cardOK[i.id]!)"
        } catch {
            cardOK[i.id] = nil
            cardError[i.id] = "Test failed (\(secs())): \(error.localizedDescription)"
            message = "\(i.name): \(cardError[i.id]!)"
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
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 300
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
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 300
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

    /// Remove a previous "# red-xai-vortex begin … end" list item (re-Connect replaces it instead of duplicating).
    static func stripItem(_ s: String) -> String {
        var out: [String] = []; var skip = false
        for l in s.components(separatedBy: "\n") {
            if l.contains("# red-xai-vortex begin") { skip = true; continue }
            if l.contains("# red-xai-vortex end") { skip = false; continue }
            if !skip { out.append(l) }
        }
        return out.joined(separator: "\n")
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
    @Local var confirmConnect: Integration?
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
        .confirmationDialog("Connect \(confirmConnect?.name ?? "app") to Red-XAI Vortex?", isPresented: Binding(get: { confirmConnect != nil }, set: { if !$0 { confirmConnect = nil } }), titleVisibility: .visible) {
            Button("Connect") {
                if let i = confirmConnect {
                    let m = picks[i.id] ?? (models.contains("vortex") ? "vortex" : models.first ?? "")
                    busy = i.id; Task { await store.connect(i, model: m); busy = "" }
                }
                confirmConnect = nil
            }
            Button("Cancel", role: .cancel) { confirmConnect = nil }
        } message: {
            if let i = confirmConnect {
                Text(i.mode == .auto
                     ? "Creates a dedicated revocable key and adds Vortex models next to the app's existing models (\(i.how)). The original config is backed up first\(IntegrationStore.bundleIDs[i.id]?.isEmpty == false ? ", then the app is quit and relaunched" : "")."
                     : "Creates a dedicated revocable key, copies it to your clipboard and opens \(i.name). Then follow the steps on the card and press Test.")
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
                        Button(busy == i.id ? "Connecting…" : "Connect") { confirmConnect = i }.buttonStyle(.borderedProminent).disabled(models.isEmpty || !busy.isEmpty)
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
