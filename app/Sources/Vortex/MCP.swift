import SwiftUI

/// MCP servers (Model Context Protocol): stdio (local command) or Streamable HTTP. Their tools are offered to models.
struct MCPServerDef: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var type: String = "stdio"            // stdio | http
    var command: String = ""
    var args: [String] = []
    var env: [String: String] = [:]
    var url: String = ""
    var headers: [String: String] = [:]
    var enabled = true
}

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
        if def.type == "stdio" {
            let p = Process()
            // run through a login shell so npx/uvx/node from Homebrew/nvm are on PATH
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            let cmd = ([def.command] + def.args).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
            p.arguments = ["-lc", "exec " + cmd]
            var e = ProcessInfo.processInfo.environment; for (k, v) in def.env { e[k] = v }; p.environment = e
            p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
            outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in self?.onData(h.availableData) }
            errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
                if let s = String(data: h.availableData, encoding: .utf8) { self?.lock.lock(); self?.stderrTail = String(((self?.stderrTail ?? "") + s).suffix(800)); self?.lock.unlock() }
            }
            p.terminationHandler = { [weak self] _ in self?.failAll("MCP server exited. \(self?.stderrTail ?? "")") }
            try p.run(); proc = p
        }
        _ = try await request("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:] as [String: Any],
                                              "clientInfo": ["name": "Red-XAI Vortex", "version": "2.2"]], timeout: 60)
        try await notify("notifications/initialized")
        let r = try await request("tools/list", [:], timeout: 30)
        return (r["tools"] as? [[String: Any]] ?? []).map {
            let ann = $0["annotations"] as? [String: Any] ?? [:]
            return MCPTool(name: $0["name"] as? String ?? "", description: $0["description"] as? String ?? "",
                           schema: $0["inputSchema"] as? [String: Any] ?? ["type": "object", "properties": [:] as [String: Any]],
                           destructive: (ann["destructiveHint"] as? Bool) == true)
        }
    }
    func stop() { outPipe.fileHandleForReading.readabilityHandler = nil; errPipe.fileHandleForReading.readabilityHandler = nil; if proc?.isRunning == true { proc?.terminate() }; proc = nil; failAll("stopped") }

    func call(_ tool: String, _ args: [String: Any]) async throws -> String {
        let r = try await request("tools/call", ["name": tool, "arguments": args], timeout: 300)
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
        if def.type == "stdio" { try write(msg) } else { _ = try? await http(msg) }
    }
    private func write(_ o: [String: Any]) throws {
        var d = try JSONSerialization.data(withJSONObject: o); d.append(0x0A)
        try inPipe.fileHandleForWriting.write(contentsOf: d)
    }
    func request(_ method: String, _ params: [String: Any], timeout: Double) async throws -> [String: Any] {
        lock.lock(); let id = nextID; nextID += 1; lock.unlock()
        let msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        if def.type == "http" {
            let o = try await http(msg)
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
    private func http(_ msg: [String: Any]) async throws -> [String: Any] {
        guard let u = URL(string: def.url) else { throw URLError(.badURL) }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 300
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        r.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        if let s = session { r.setValue(s, forHTTPHeaderField: "Mcp-Session-Id") }
        for (k, v) in def.headers { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = try JSONSerialization.data(withJSONObject: msg)
        let (d, resp) = try await URLSession.shared.data(for: r)
        let h = resp as? HTTPURLResponse
        if let s = h?.value(forHTTPHeaderField: "Mcp-Session-Id") { session = s }
        if let c = h?.statusCode, c >= 300 { throw NSError(domain: "MCP", code: c, userInfo: [NSLocalizedDescriptionKey: "HTTP \(c): \(String(data: d.prefix(300), encoding: .utf8) ?? "")"]) }
        if msg["id"] == nil { return [:] }
        if (h?.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/event-stream") {
            let text = String(data: d, encoding: .utf8) ?? ""
            for line in text.components(separatedBy: "\n") where line.hasPrefix("data:") {
                if let o = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any], o["id"] != nil { return o }
            }
            return [:]
        }
        return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }
}

@MainActor final class MCPStore: ObservableObject {
    static let shared = MCPStore()
    @Published var servers: [MCPServerDef] = []
    @Published var tools: [String: [MCPTool]] = [:]
    @Published var status: [String: String] = [:]
    @Published var message = ""
    private var clients: [String: MCPClient] = [:]
    var file: URL { ChatStore.dir.appendingPathComponent("mcp.json") }

    init() {
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode([MCPServerDef].self, from: d) { servers = s }
    }
    func save() { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; if let d = try? e.encode(servers) { try? d.write(to: file, options: .atomic); try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) } }
    func upsert(_ s: MCPServerDef) { if let i = servers.firstIndex(where: { $0.id == s.id }) { servers[i] = s } else { servers.append(s) }; save() }
    func delete(_ id: String) { disconnect(id); servers.removeAll { $0.id == id }; save() }

    func connect(_ id: String) async {
        guard let d = servers.first(where: { $0.id == id }) else { return }
        disconnect(id); status[id] = "Connecting…"
        let c = MCPClient(d)
        do {
            let t = try await c.start()
            clients[id] = c; tools[id] = t; status[id] = "Connected · \(t.count) tools"
        } catch { c.stop(); status[id] = "Error: \(error.localizedDescription)" }
    }
    func disconnect(_ id: String) { clients[id]?.stop(); clients[id] = nil; tools[id] = nil; status[id] = nil }
    func connectEnabled() async { for s in servers where s.enabled && clients[s.id] == nil { await connect(s.id) } }
    func stopAll() { for id in clients.keys { disconnect(id) } }

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
            s.enabled = false
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
        .sheet(item: $editing) { s in MCPEditor(def: s) { ms.upsert($0); editing = nil; let id = $0.id; Task { await ms.connect(id) } } cancel: { editing = nil } }
    }
}

struct MCPEditor: View {
    @Local var def: MCPServerDef
    @Local var argsText = ""
    @Local var envText = ""
    @Local var hdrText = ""
    var save: (MCPServerDef) -> Void
    var cancel: () -> Void
    init(def: MCPServerDef, save: @escaping (MCPServerDef) -> Void, cancel: @escaping () -> Void) {
        _def = Local(wrappedValue: def); self.save = save; self.cancel = cancel
        _argsText = Local(wrappedValue: def.args.joined(separator: "\n"))
        _envText = Local(wrappedValue: def.env.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n"))
        _hdrText = Local(wrappedValue: def.headers.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n"))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MCP Server").font(.title2.bold())
            TextField("Name", text: $def.name)
            TextField("Id (a-z, 0-9, -)", text: $def.id)
            Picker("Transport", selection: $def.type) { Text("stdio (local command)").tag("stdio"); Text("Streamable HTTP").tag("http") }.pickerStyle(.segmented)
            if def.type == "stdio" {
                TextField("Command (e.g. npx)", text: $def.command)
                Text("Arguments, one per line").font(.caption)
                TextEditor(text: $argsText).font(.caption.monospaced()).frame(height: 70).border(.quaternary)
                Text("Environment (KEY=value per line; stored in mcp.json, mode 600)").font(.caption)
                TextEditor(text: $envText).font(.caption.monospaced()).frame(height: 50).border(.quaternary)
            } else {
                TextField("URL (https://…/mcp)", text: $def.url)
                Text("Headers (Name: value per line, e.g. Authorization: Bearer …)").font(.caption)
                TextEditor(text: $hdrText).font(.caption.monospaced()).frame(height: 50).border(.quaternary)
            }
            HStack { Spacer(); Button("Cancel", action: cancel)
                Button("Save & Connect") {
                    var d = def
                    d.args = argsText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    d.env = Dictionary(envText.split(separator: "\n").compactMap { l -> (String, String)? in let p = l.split(separator: "=", maxSplits: 1); return p.count == 2 ? (String(p[0]).trimmingCharacters(in: .whitespaces), String(p[1])) : nil }, uniquingKeysWith: { $1 })
                    d.headers = Dictionary(hdrText.split(separator: "\n").compactMap { l -> (String, String)? in let p = l.split(separator: ":", maxSplits: 1); return p.count == 2 ? (String(p[0]).trimmingCharacters(in: .whitespaces), String(p[1]).trimmingCharacters(in: .whitespaces)) : nil }, uniquingKeysWith: { $1 })
                    d.enabled = true
                    save(d)
                }.buttonStyle(.borderedProminent).disabled(def.name.isEmpty || def.id.range(of: "^[a-z0-9-]{1,32}$", options: .regularExpression) == nil)
            }
        }.padding(20).frame(width: 560)
    }
}
