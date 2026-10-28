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
    var authMode: String? = nil
    var keyName: String? = nil
    var workingDirectory: String? = nil
    var connectTimeout: Double? = nil
    var callTimeout: Double? = nil
    var protocolVersion: String? = nil
    var autoConnect: Bool? = nil
    var inheritEnvironment: Bool? = nil
    var secretReference: String? = nil
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
    private let writeLock = NSLock()
    private var session: String?
    var stderrTail = ""
    private let network = URLSession(configuration: .ephemeral, delegate: MCPNoRedirect(), delegateQueue: nil)
    private var negotiatedProtocol = "2025-06-18"
    private var stopped = false

    init(_ d: MCPServerDef) { def = d }

    func start() async throws -> [MCPTool] {
        try MCPConfiguration.validate(def)
        if def.type == "stdio" {
            let p = Process()
            let search = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            let candidates = def.command.hasPrefix("/") ? [def.command] : search.map { URL(fileURLWithPath: $0).appendingPathComponent(def.command).path }
            guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw MCPConfiguration.failure("MCP command was not found. Enter its installed absolute path or install it first.") }
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = def.args
            let inherited = ProcessInfo.processInfo.environment
            var e = def.inheritEnvironment == true ? inherited : inherited.filter { ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "USER", "SHELL"].contains($0.key) }
            for (k, v) in def.env { e[k] = v }; p.environment = e
            if let cwd = def.workingDirectory, !cwd.isEmpty { p.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true) }
            p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
            outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in self?.onData(h.availableData) }
            errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
                if let s = String(data: h.availableData, encoding: .utf8) { self?.lock.lock(); self?.stderrTail = String(((self?.stderrTail ?? "") + s).suffix(800)); self?.lock.unlock() }
            }
            p.terminationHandler = { [weak self] _ in self?.failAll("MCP server exited. Check its command and credentials; provider output is not included to protect secrets.") }
            try p.run(); proc = p
        }
        let initialized = try await request("initialize", ["protocolVersion": def.protocolVersion ?? "2025-06-18", "capabilities": [:] as [String: Any],
                                              "clientInfo": ["name": "Red-XAI Vortex", "version": "2.12"]], timeout: def.connectTimeout ?? 60)
        guard let version = initialized["protocolVersion"] as? String, MCPConfiguration.versions.contains(version) else { throw MCPConfiguration.failure("Server negotiated an unsupported MCP protocol.") }
        negotiatedProtocol = version
        try await notify("notifications/initialized")
        var rawTools: [[String: Any]] = []; var cursor: String?; var seen = Set<String>()
        repeat {
            let r = try await request("tools/list", cursor.map { ["cursor": $0] } ?? [:], timeout: def.connectTimeout ?? 60)
            rawTools += r["tools"] as? [[String: Any]] ?? []
            cursor = r["nextCursor"] as? String
            guard rawTools.count <= 4096, cursor == nil || seen.insert(cursor!).inserted else { throw MCPConfiguration.failure("Invalid or excessive tool pagination.") }
        } while cursor != nil
        return rawTools.map {
            let ann = $0["annotations"] as? [String: Any] ?? [:]
            return MCPTool(name: $0["name"] as? String ?? "", description: $0["description"] as? String ?? "",
                           schema: $0["inputSchema"] as? [String: Any] ?? ["type": "object", "properties": [:] as [String: Any]],
                           destructive: (ann["readOnlyHint"] as? Bool) != true || (ann["destructiveHint"] as? Bool) == true)
        }
    }
    func stop() { lock.lock(); stopped = true; lock.unlock(); network.invalidateAndCancel(); outPipe.fileHandleForReading.readabilityHandler = nil; errPipe.fileHandleForReading.readabilityHandler = nil; if proc?.isRunning == true { proc?.terminate() }; proc = nil; failAll("stopped") }

    func call(_ tool: String, _ args: [String: Any]) async throws -> String {
        let r = try await request("tools/call", ["name": tool, "arguments": args], timeout: def.callTimeout ?? 300)
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
        lock.lock()
        if buf.count + d.count > 4 * 1024 * 1024 { lock.unlock(); failAll("MCP output exceeded the 4 MiB message limit"); proc?.terminate(); return }
        buf.append(d)
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
        if let e = o["error"] as? [String: Any] { c?.resume(throwing: NSError(domain: "MCP", code: e["code"] as? Int ?? -1, userInfo: [NSLocalizedDescriptionKey: "MCP server rejected the request. Check the connection, credentials and tool arguments."])) }
        else { c?.resume(returning: o["result"] as? [String: Any] ?? [:]) }
    }
    private func failAll(_ m: String) {
        lock.lock(); let all = waiting; waiting = [:]; lock.unlock()
        for c in all.values { c.resume(throwing: NSError(domain: "MCP", code: -1, userInfo: [NSLocalizedDescriptionKey: m])) }
    }
    private func notify(_ method: String) async throws {
        let msg: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if def.type == "stdio" { try write(msg) } else { _ = try await http(msg, timeout: def.connectTimeout ?? 60) }
    }
    private func write(_ o: [String: Any]) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        var d = try JSONSerialization.data(withJSONObject: o); d.append(0x0A)
        try inPipe.fileHandleForWriting.write(contentsOf: d)
    }
    func request(_ method: String, _ params: [String: Any], timeout: Double) async throws -> [String: Any] {
        lock.lock(); if stopped { lock.unlock(); throw MCPConfiguration.failure("Connection stopped") }; let id = nextID; nextID += 1; lock.unlock()
        let msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        if def.type == "http" {
            let o = try await http(msg, timeout: timeout)
            if let e = o["error"] as? [String: Any] { throw NSError(domain: "MCP", code: -1, userInfo: [NSLocalizedDescriptionKey: "MCP server rejected the request. Check the connection, credentials and tool arguments."]) }
            return o["result"] as? [String: Any] ?? [:]
        }
        return try await withTaskCancellationHandler(operation: {
        try await withThrowingTaskGroup(of: [String: Any].self) { g in
            g.addTask {
                try await withCheckedThrowingContinuation { c in
                    self.lock.lock(); if self.stopped || Task.isCancelled { self.lock.unlock(); c.resume(throwing: CancellationError()); return }; self.waiting[id] = c; self.lock.unlock()
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
        }, onCancel: {
            self.lock.lock(); let c = self.waiting.removeValue(forKey: id); self.lock.unlock()
            c?.resume(throwing: CancellationError())
            if c != nil { Task.detached { try? self.write(["jsonrpc":"2.0", "method":"notifications/cancelled", "params":["requestId":id,"reason":"Client cancelled"]]) } }
        })
    }
    private func http(_ msg: [String: Any], timeout: Double) async throws -> [String: Any] {
        let u = try MCPConfiguration.validatedURL(def.url)
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = timeout
        for (k,v) in def.headers { r.setValue(v, forHTTPHeaderField: k) }
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        r.setValue(negotiatedProtocol, forHTTPHeaderField: "MCP-Protocol-Version")
        if let s = session { r.setValue(s, forHTTPHeaderField: "Mcp-Session-Id") }
        r.httpBody = try JSONSerialization.data(withJSONObject: msg)
        let (bytes, response) = try await network.bytes(for: r)
        guard let h = response as? HTTPURLResponse else { throw MCPConfiguration.failure("Invalid MCP HTTP response.") }
        guard (200..<300).contains(h.statusCode) else {
            let reason: String
            switch h.statusCode {
            case 401: reason = "Authentication required or rejected. Add the provider's API key or access token in this server's settings."
            case 403: reason = "This credential is not permitted to use the MCP server."
            case 404: reason = "The MCP endpoint or session was not found. Reconnect and check the URL."
            case 429: reason = "The provider rate limit was reached."
            case 300..<400: reason = "Redirect refused. Enter the final trusted MCP URL; credentials are never forwarded to redirects."
            default: reason = "MCP server returned HTTP \(h.statusCode)."
            }
            throw NSError(domain: "MCP", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: reason])
        }
        if let id = h.value(forHTTPHeaderField: "Mcp-Session-Id") {
            guard id.utf8.count <= 1024, id.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else { throw MCPConfiguration.failure("Invalid MCP session header.") }
            session = id
        }
        if msg["id"] == nil { return [:] }
        let expectedID = msg["id"] as? Int
        var data = Data()
        let isSSE = (h.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("text/event-stream")
        if isSSE {
            var lines: [String] = []; var count = 0
            for try await line in bytes.lines {
                count += line.utf8.count
                guard count <= 4 * 1024 * 1024 else { throw MCPConfiguration.failure("MCP response exceeded 4 MiB.") }
                if line.isEmpty {
                    if !lines.isEmpty, let object = try? JSONSerialization.jsonObject(with: Data(lines.joined(separator: "\n").utf8)) as? [String: Any], object["id"] as? Int == expectedID { return object }
                    lines = []
                } else if line.hasPrefix("data:") {
                    var value = String(line.dropFirst(5)); if value.hasPrefix(" ") { value.removeFirst() }; lines.append(value)
                }
            }
            if !lines.isEmpty, let object = try? JSONSerialization.jsonObject(with: Data(lines.joined(separator: "\n").utf8)) as? [String: Any], object["id"] as? Int == expectedID { return object }
        } else {
            for try await byte in bytes {
                guard data.count < 4 * 1024 * 1024 else { throw MCPConfiguration.failure("MCP response exceeded 4 MiB.") }
                data.append(byte)
            }
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["id"] as? Int == expectedID { return object }
        }
        throw MCPConfiguration.failure("MCP server did not return a matching JSON-RPC response.")
    }
}

@MainActor final class MCPStore: ObservableObject {
    static let shared = MCPStore()
    @Published var servers: [MCPServerDef] = []
    @Published var tools: [String: [MCPTool]] = [:]
    @Published var status: [String: String] = [:]
    @Published var message = ""
    private var clients: [String: MCPClient] = [:]
    private var attempts: [String: UUID] = [:]
    var file: URL { ChatStore.dir.appendingPathComponent("mcp.json") }

    init() {
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode([MCPServerDef].self, from: d) { servers = s }
    }
    func save() { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; if let d = try? e.encode(servers) { try? d.write(to: file, options: .atomic); try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) } }
    @discardableResult func upsert(_ input: MCPServerDef, apiKey: String? = nil, clearKey: Bool = false) -> Bool {
        do {
            try MCPConfiguration.validate(input)
            var secrets = try MCPSecrets.read(input)
            secrets.headers = input.headers; secrets.environment = input.env
            if let apiKey, !apiKey.isEmpty { secrets.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
            if clearKey { secrets.apiKey = "" }
            _ = try MCPConfiguration.effective(input, secrets: secrets)
            let reference = secrets.apiKey.isEmpty && secrets.headers.isEmpty && secrets.environment.isEmpty ? nil : try MCPSecrets.store(secrets)
            var stored = input; stored.headers = [:]; stored.env = [:]; stored.secretReference = reference
            var updated = servers
            if let index = updated.firstIndex(where: { $0.id == stored.id }) { updated[index] = stored } else { updated.append(stored) }
            do {
                let data = try JSONEncoder().encode(updated)
                try data.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } catch { if let reference { Keychain.set("", account: "mcp-" + reference) }; throw error }
            if let old = input.secretReference { Keychain.set("", account: "mcp-" + old) }
            servers = updated; message = "Saved server. Credentials are stored in this account's Keychain namespace."
            return true
        } catch { message = error.localizedDescription; return false }
    }
    func delete(_ id: String) {
        disconnect(id)
        if let ref = servers.first(where: { $0.id == id })?.secretReference { Keychain.set("", account: "mcp-" + ref) }
        servers.removeAll { $0.id == id }; save()
    }

    func connect(_ id: String) async {
        guard AccountGate.shared.ready else { status[id] = "Sign in before connecting MCP servers."; return }
        guard let d = servers.first(where: { $0.id == id }) else { return }
        disconnect(id); status[id] = "Connecting…"
        let attempt = UUID(); attempts[id] = attempt
        do {
            let effective = try MCPConfiguration.effective(d, secrets: MCPSecrets.read(d))
            let c = MCPClient(effective); clients[id] = c
            let t = try await c.start()
            guard attempts[id] == attempt, AccountGate.shared.ready else { c.stop(); return }
            tools[id] = t; status[id] = "Connected · \(t.count) tools"
        } catch {
            guard attempts[id] == attempt else { return }
            clients[id]?.stop(); clients[id] = nil
            status[id] = "Error: \(error.localizedDescription)"
        }
    }
    func disconnect(_ id: String) { attempts[id] = nil; clients[id]?.stop(); clients[id] = nil; tools[id] = nil; status[id] = nil }
    func connectEnabled() async { for s in servers where AccountGate.shared.ready && s.enabled && s.autoConnect != false && clients[s.id] == nil { await connect(s.id) } }
    func stopAll() { for id in Array(clients.keys) { disconnect(id) } }

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
            if upsert(s) { n += 1 }
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
                    Button("Add Server") { editing = MCPServerDef(id: "server-" + UUID().uuidString.lowercased().prefix(12), name: "") }
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
                                Toggle("Enabled", isOn: Binding(get: { s.enabled }, set: { v in var x = s; x.enabled = v; if let secret = try? MCPSecrets.read(s) { x.headers = secret.headers; x.env = secret.environment }; _ = ms.upsert(x); Task { v ? await ms.connect(s.id) : ms.disconnect(s.id) } }))
                                Button("Reconnect") { Task { await ms.connect(s.id) } }.disabled(!s.enabled)
                                Button("Edit") { editing = s }
                                Button(role: .destructive) { ms.delete(s.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                            }
                            Text(s.type == "http" ? MCPConfiguration.safeDisplayURL(s.url) : s.command).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
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
        .sheet(item: $editing) { s in MCPEditor(def: s) { value, key, clear in
            guard ms.upsert(value, apiKey: key, clearKey: clear) else { return false }
            editing = nil
            if value.enabled { Task { await ms.connect(value.id) } }
            return true
        } cancel: { editing = nil } }
    }
}
