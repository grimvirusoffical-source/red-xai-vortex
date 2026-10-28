import SwiftUI

/// MCP servers (Model Context Protocol): stdio (local command) or Streamable HTTP. Their tools are offered to models.
struct MCPTool { var name: String; var description: String; var schema: [String: Any]; var destructive: Bool }

/// One live connection. JSON-RPC 2.0 over newline-delimited stdio, or HTTP POST (JSON or SSE replies).
final class MCPClient: @unchecked Sendable {
    let def: MCPServerDef
    private var proc: Process?
    private var inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
    private var buf = Data()
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private let lock = NSLock()
    private var session: String?
    var stderrTail = ""

    init(_ d: MCPServerDef) { def = d }

    func start() async throws -> [MCPTool] {
        try def.validate()
        if def.type == "stdio" {
            let p = Process()
            // run through a login shell so npx/uvx/node from Homebrew/nvm are on PATH
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            let cmd = ([def.command] + def.args).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
            p.arguments = ["-lc", "exec " + cmd]
            var e: [String: String] = [:]
            for key in ["PATH", "HOME", "USER", "SHELL", "TMPDIR", "LANG"] { e[key] = ProcessInfo.processInfo.environment[key] }
            for (k, v) in try def.effectiveEnvironment() { e[k] = v }; p.environment = e
            if !def.workingDirectory.isEmpty { p.currentDirectoryURL = URL(fileURLWithPath: (def.workingDirectory as NSString).expandingTildeInPath) }
            p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
            outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in self?.onData(h.availableData) }
            errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
                if let s = String(data: h.availableData, encoding: .utf8) { self?.lock.lock(); self?.stderrTail = String(((self?.stderrTail ?? "") + s).suffix(800)); self?.lock.unlock() }
            }
            p.terminationHandler = { [weak self] _ in self?.failAll("MCP server exited. Check the command and credentials; stderr is not displayed because it may contain secrets.") }
            try p.run(); proc = p
        }
        _ = try await request("initialize", ["protocolVersion": def.protocolVersion, "capabilities": [:] as [String: Any],
                                              "clientInfo": ["name": "Red-XAI Vortex", "version": "2.2"]], timeout: def.initializeTimeout)
        try await notify("notifications/initialized")
        let r = try await request("tools/list", [:], timeout: def.requestTimeout)
        return (r["tools"] as? [[String: Any]] ?? []).map {
            let ann = $0["annotations"] as? [String: Any] ?? [:]
            return MCPTool(name: $0["name"] as? String ?? "", description: $0["description"] as? String ?? "",
                           schema: $0["inputSchema"] as? [String: Any] ?? ["type": "object", "properties": [:] as [String: Any]],
                           destructive: (ann["destructiveHint"] as? Bool) == true)
        }
    }
    func stop() { outPipe.fileHandleForReading.readabilityHandler = nil; errPipe.fileHandleForReading.readabilityHandler = nil; if proc?.isRunning == true { proc?.terminate() }; proc = nil; failAll("stopped") }

    func call(_ tool: String, _ args: [String: Any]) async throws -> String {
        let r = try await request("tools/call", ["name": tool, "arguments": args], timeout: def.requestTimeout)
        let parts = (r["content"] as? [[String: Any]] ?? []).map { c -> String in
            if let t = c["text"] as? String { return t }
            if let t = c["type"] as? String { return "[\(t) content]" }
            return ""
        }
        var out = parts.joined(separator: "\n")
        if out.isEmpty, let sc = r["structuredContent"], let d = try? JSONSerialization.data(withJSONObject: sc) { out = String(data: d, encoding: .utf8) ?? "" }
        if (r["isError"] as? Bool) == true { return "error: " + out }
        return out
    }

    // MARK: transport
    private func onData(_ d: Data) {
        lock.lock(); buf.append(d)
        if buf.count > def.maxResponseBytes { buf.removeAll(); lock.unlock(); failAll("MCP response exceeds the configured byte limit."); return }
        var msgs: [[String: Any]] = []
        while let nl = buf.firstIndex(of: 0x0A) {
            let line = buf[..<nl]; buf.removeSubrange(...nl)
            if let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { msgs.append(o) }
        }
        lock.unlock()
        msgs.forEach(deliver)
    }
    private func deliver(_ o: [String: Any]) {
        guard let id = o["id"] as? Int else { return }    // ignore server notifications/requests
        lock.lock(); let c = waiting.removeValue(forKey: id); lock.unlock()
        if let e = o["error"] as? [String: Any] { c?.resume(throwing: NSError(domain: "MCP", code: e["code"] as? Int ?? -1, userInfo: [NSLocalizedDescriptionKey: e["message"] as? String ?? "MCP error"])) }
        else { c?.resume(returning: o["result"] as? [String: Any] ?? [:]) }
    }
    private func failAll(_ m: String) {
        lock.lock(); let all = waiting; waiting = [:]; lock.unlock()
        for c in all.values { c.resume(throwing: NSError(domain: "MCP", code: -1, userInfo: [NSLocalizedDescriptionKey: m])) }
    }
    private func notify(_ method: String) async throws {
        let msg: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if def.type == "stdio" { try write(msg) } else { _ = try await http(msg, timeout: def.requestTimeout) }
    }
    private func write(_ o: [String: Any]) throws {
        var d = try JSONSerialization.data(withJSONObject: o); d.append(0x0A)
        try inPipe.fileHandleForWriting.write(contentsOf: d)
    }
    func request(_ method: String, _ params: [String: Any], timeout: Double) async throws -> [String: Any] {
        lock.lock(); let id = nextID; nextID += 1; lock.unlock()
        let msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        if def.type == "http" {
            let o = try await http(msg, timeout: timeout)
            if let e = o["error"] as? [String: Any] { throw NSError(domain: "MCP", code: -1, userInfo: [NSLocalizedDescriptionKey: e["message"] as? String ?? "MCP error"]) }
            return o["result"] as? [String: Any] ?? [:]
        }
        return try await withThrowingTaskGroup(of: [String: Any].self) { g in
            g.addTask {
                try await withCheckedThrowingContinuation { c in
                    self.lock.lock(); self.waiting[id] = c; self.lock.unlock()
                    do { try self.write(msg) } catch { self.lock.lock(); self.waiting.removeValue(forKey: id); self.lock.unlock(); c.resume(throwing: error) }
                }
            }
            g.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
                self.lock.lock(); let c = self.waiting.removeValue(forKey: id); self.lock.unlock()
                c?.resume(throwing: NSError(domain: "MCP", code: -2, userInfo: [NSLocalizedDescriptionKey: "\(method) timed out"]))
                throw CancellationError()
            }
            let r = try await g.next()!; g.cancelAll(); return r
        }
    }
    private func http(_ msg: [String: Any], timeout: Double) async throws -> [String: Any] {
        try def.validate()
        guard let u = URL(string: def.url) else { throw URLError(.badURL) }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = timeout
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        r.setValue(def.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let s = session { r.setValue(s, forHTTPHeaderField: "Mcp-Session-Id") }
        for (k, v) in try def.effectiveHeaders() { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = try JSONSerialization.data(withJSONObject: msg)
        let (d, resp) = try await AccountHTTP.session.data(for: r)
        let h = resp as? HTTPURLResponse
        if let s = h?.value(forHTTPHeaderField: "Mcp-Session-Id") { session = s }
        if let c = h?.statusCode, c >= 300 { throw NSError(domain: "MCP", code: c, userInfo: [NSLocalizedDescriptionKey: "MCP HTTP \(c). Check the selected authentication method, endpoint and granted scopes. Credentials and response bodies are not logged."]) }
        guard d.count <= def.maxResponseBytes else { throw MCPConfigError("MCP response exceeds the configured byte limit.") }
        if msg["id"] == nil { return [:] }
        if (h?.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/event-stream") {
            return try MCPResponse.parseSSE(d, requestID: msg["id"])
        }

        guard let object = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              MCPResponse.sameID(object["id"], msg["id"]) else { throw MCPConfigError("MCP returned a mismatched response ID.") }
        return object
    }
}

@MainActor final class MCPStore: ObservableObject {
    static let shared = MCPStore()
    @Published var servers: [MCPServerDef] = []
    @Published var tools: [String: [MCPTool]] = [:]
    @Published var status: [String: String] = [:]
    @Published var message = ""
    private var clients: [String: MCPClient] = [:]
    private var connectionEpoch = 0
    var file: URL { ChatStore.dir.appendingPathComponent("mcp.json") }

    init() {
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode([MCPServerDef].self, from: d) { servers = s.map { MCPSecrets.load($0) } }
    }
    @discardableResult func save() -> Bool {
        do {
            let clean = try servers.map { try MCPSecrets.persist($0) }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(clean).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch { message = "MCP settings could not be saved securely: " + error.localizedDescription; return false }
    }
    func upsert(_ s: MCPServerDef) { if let i = servers.firstIndex(where: { $0.id == s.id }) { servers[i] = s } else { servers.append(s) }; save() }
    func delete(_ id: String) { disconnect(id); Keychain.set("", account: MCPSecrets.account(id)); servers.removeAll { $0.id == id }; save() }

    func connect(_ id: String) async {
        guard AccountProfile.isActive, let d = servers.first(where: { $0.id == id }) else { return }
        let epoch = connectionEpoch
        disconnect(id); status[id] = "Connecting…"
        let c = MCPClient(d)
        do {
            let t = try await c.start()
            guard epoch == connectionEpoch, AccountProfile.isActive else { c.stop(); return }
            clients[id] = c; tools[id] = t; status[id] = "Connected · \(t.count) tools"
        } catch { c.stop(); status[id] = "Error: \(error.localizedDescription)" }
    }
    func disconnect(_ id: String) { clients[id]?.stop(); clients[id] = nil; tools[id] = nil; status[id] = nil }
    func connectEnabled() async { for s in servers where AccountProfile.isActive && s.enabled && s.autoConnect && clients[s.id] == nil { await connect(s.id) } }
    func stopAll() { connectionEpoch += 1; for id in Array(clients.keys) { disconnect(id) } }

    static func toolName(_ server: String, _ tool: String) -> String {
        let raw = "mcp_\(server)_\(tool)".map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" }
        return String(String(raw).prefix(64))
    }
    func enabledTools() -> [ToolSpec] {
        servers.filter { $0.enabled }.flatMap { s -> [ToolSpec] in
            guard let c = clients[s.id] else { return [] }
            return (tools[s.id] ?? []).map { t in
                ToolSpec(name: Self.toolName(s.id, t.name), description: "[\(s.name)] " + t.description, schema: t.schema,
                         source: "mcp:\(s.id)", destructive: t.destructive) { args in try await c.call(t.name, args) }
            }
        }
    }

    /// Import servers from Claude Desktop / Cursor style JSON ({"mcpServers": {...}}).
    func importConfig(_ url: URL) {
        guard let d = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let m = (o["mcpServers"] ?? o["servers"]) as? [String: [String: Any]] else { message = "No mcpServers found in \(url.lastPathComponent)."; return }
        var n = 0
        for (k, v) in m {
            let id = k.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce("") { $0 + String($1) }
            var s = MCPServerDef(id: id, name: k)
            if let u = v["url"] as? String { s.type = "http"; s.url = u; s.headers = v["headers"] as? [String: String] ?? [:] }
            else { s.command = v["command"] as? String ?? ""; s.args = v["args"] as? [String] ?? []; s.env = v["env"] as? [String: String] ?? [:] }
            s.enabled = false; s.autoConnect = false
            upsert(s); n += 1
        }
        message = "Imported \(n) server(s) (off until you enable them)."
    }
}

struct MCPView: View {
    @StateObject var ms = MCPStore.shared
    @Local var editing: MCPServerDef?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("MCP Servers").font(.largeTitle.bold()); Spacer()
                    Button("Add Server") { editing = MCPServerDef(id: "server-\(ms.servers.count + 1)", name: "") }
                    Button("Import from Claude Desktop") {
                        ms.importConfig(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json"))
                    }
                    Button("Import JSON…") {
                        let p = NSOpenPanel(); p.allowedContentTypes = [.json]
                        p.begin { if $0 == .OK, let u = p.url { Task { @MainActor in MCPStore.shared.importConfig(u) } } }
                    }
                }
                Text("Model Context Protocol servers give models more tools: local commands (stdio, e.g. npx -y @modelcontextprotocol/server-filesystem ~/Documents) or remote Streamable HTTP endpoints. Tools appear to the model as mcp_<server>_<tool>. Tools marked destructive always ask first.")
                    .font(.callout).foregroundStyle(.secondary)
                if !ms.message.isEmpty { Text(ms.message).font(.callout) }
                ForEach(ms.servers) { s in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(s.name).bold(); Text(s.type).font(.caption).padding(.horizontal, 6).background(Capsule().fill(.quaternary))
                                Spacer()
                                Toggle("Enabled", isOn: Binding(get: { s.enabled }, set: { v in var x = s; x.enabled = v; ms.upsert(x); Task { v ? await ms.connect(s.id) : ms.disconnect(s.id) } }))
                                Button("Reconnect") { Task { await ms.connect(s.id) } }.disabled(!s.enabled)
                                Button("Edit") { editing = s }
                                Button(role: .destructive) { ms.delete(s.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                            }
                            Text(s.type == "http" ? s.url : ([s.command] + s.args).joined(separator: " ")).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            if let st = ms.status[s.id] { Text(st).font(.caption).foregroundStyle(st.hasPrefix("Error") ? .red : .green).textSelection(.enabled) }
                            if let t = ms.tools[s.id], !t.isEmpty {
                                Text(t.map { $0.name + ($0.destructive ? " ⚠︎" : "") }.joined(separator: " · ")).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                        }.padding(4)
                    }
                }
                if ms.servers.isEmpty { Text("No servers yet.").foregroundStyle(.secondary) }
            }.padding(20)
        }
        .task { await ms.connectEnabled() }
        .sheet(item: $editing) { s in MCPEditor(def: s) { ms.upsert($0); editing = nil; let id = $0.id; if $0.enabled && $0.autoConnect { Task { await ms.connect(id) } } } cancel: { editing = nil } }
    }
}

struct MCPEditor: View {
    @Local var def: MCPServerDef
    @Local var argsText = ""
    @Local var envText = ""
    @Local var hdrText = ""
    @Local var error = ""
    var save: (MCPServerDef) -> Void
    var cancel: () -> Void
    init(def: MCPServerDef, save: @escaping (MCPServerDef) -> Void, cancel: @escaping () -> Void) {
        _def = Local(wrappedValue: def); self.save = save; self.cancel = cancel
        _argsText = Local(wrappedValue: def.args.joined(separator: "\n"))
        _envText = Local(wrappedValue: def.env.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n"))
        _hdrText = Local(wrappedValue: def.headers.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n"))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MCP Server").font(.title2.bold())
            Text("Name, ID and the selected transport address/command are required. Authentication and advanced settings are optional unless your provider requires them.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Name (required)", text: $def.name)
                    TextField("ID (required, a-z, 0-9, -)", text: $def.id)
                    Picker("Transport", selection: $def.type) {
                        Text("Local command (stdio)").tag("stdio")
                        Text("Streamable HTTP / SSE responses").tag("http")
                    }.pickerStyle(.segmented)
                    HStack {
                        Button("Firecrawl HTTP preset") { preset(local: false) }
                        Button("Firecrawl local preset") { preset(local: true) }
                    }
                    if def.type == "stdio" {
                        TextField("Command (required, e.g. npx)", text: $def.command)
                        Text("Arguments, one per line (optional)").font(.caption)
                        TextEditor(text: $argsText).font(.caption.monospaced()).frame(height: 80).border(.quaternary)
                        TextField("Working directory (optional)", text: $def.workingDirectory)
                    } else {
                        TextField("Server URL (required, https://…/mcp)", text: $def.url)
                    }
                    GroupBox("Authentication (optional)") {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Method", selection: $def.authMode) {
                                Text("None / use advanced configuration").tag("none")
                                if def.type == "http" {
                                    Text("Bearer token / API key").tag("bearer")
                                    Text("API key in a custom header").tag("header")
                                    Text("HTTP Basic").tag("basic")
                                } else { Text("API key in an environment variable").tag("environment") }
                            }
                            if def.authMode == "header" { TextField("Header name (e.g. X-API-Key)", text: $def.keyName) }
                            if def.authMode == "environment" { TextField("Environment name (e.g. FIRECRAWL_API_KEY)", text: $def.keyName) }
                            if def.authMode == "basic" { TextField("Username", text: $def.username) }
                            if def.authMode != "none" {
                                SecureField(def.authMode == "basic" ? "Password" : "API key / token", text: $def.secret)
                                if !def.secret.isEmpty { Button("Remove saved credential") { def.secret = ""; def.authMode = "none" } }
                            }
                            Text("Credentials, header values and environment values are stored in this account’s OS Keychain, not mcp.json. OAuth access tokens can be used as Bearer tokens; browser OAuth enrollment is not performed by this editor.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(4)
                    }
                    DisclosureGroup("Advanced settings (all optional)") {
                        VStack(alignment: .leading, spacing: 8) {
                            if def.type == "stdio" {
                                Text("Environment — KEY=value per line").font(.caption)
                                TextEditor(text: $envText).font(.caption.monospaced()).frame(height: 90).border(.quaternary)
                            } else {
                                Text("Additional headers — Name: value per line").font(.caption)
                                TextEditor(text: $hdrText).font(.caption.monospaced()).frame(height: 90).border(.quaternary)
                            }
                            TextField("Protocol version", text: $def.protocolVersion)
                            HStack { Text("Initialize timeout (seconds)"); TextField("60", value: $def.initializeTimeout, format: .number) }
                            HStack { Text("Request/tool timeout (seconds)"); TextField("300", value: $def.requestTimeout, format: .number) }
                            HStack { Text("Maximum response bytes"); TextField("8388608", value: $def.maxResponseBytes, format: .number) }
                            Toggle("Enabled", isOn: $def.enabled)
                            Toggle("Connect automatically after sign-in", isOn: $def.autoConnect)
                            Text("TLS certificate verification stays enabled. Credential-bearing redirects and protected transport-header overrides are refused.").font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 8)
                    }
                }.padding(4)
            }.scrollIndicators(.visible).frame(maxWidth: .infinity, maxHeight: .infinity)
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
            Divider()
            HStack { Button("Cancel", action: cancel); Spacer()
                Button(def.enabled && def.autoConnect ? "Save & Connect" : "Save") { commit() }
                    .buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(minWidth: 540, idealWidth: 620, maxWidth: 780, minHeight: 480, idealHeight: 680, maxHeight: 800)
    }
    func preset(local: Bool) {
        def.name = "Firecrawl"; if def.id.isEmpty { def.id = "firecrawl" }
        def.type = local ? "stdio" : "http"
        def.command = "npx"; argsText = "-y\nfirecrawl-mcp"
        def.url = "https://mcp.firecrawl.dev/v2/mcp"
        def.authMode = local ? "environment" : "bearer"
        def.keyName = local ? "FIRECRAWL_API_KEY" : "Authorization"
        error = ""
    }
    func commit() {
        do {
            var value = def
            value.args = argsText.components(separatedBy: "\n").filter { !$0.isEmpty }
            value.env = try MCPServerDef.parsePairs(envText, separator: "=")
            value.headers = try MCPServerDef.parsePairs(hdrText, separator: ":")
            try value.validate()
            _ = try MCPSecrets.persist(value) // prove secure storage before closing the editor
            save(value)
        } catch { self.error = error.localizedDescription }
    }
}
