import SwiftUI
import Darwin

struct MCPTool { var name: String; var description: String; var schema: [String: Any]; var destructive: Bool }

/// JSON-RPC over stdio or Streamable HTTP. Model execution retains the existing
/// ToolSpec destructive-action confirmation and never bypasses server permissions.
final class MCPClient: @unchecked Sendable {
    let def: MCPServerDef
    private var proc: Process?
    private let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
    private var buf = Data()
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private let lock = NSLock()
    private var sessionID: String?
    private var protocolVersion = "2025-11-25"
    private var stderrTail = ""
    private let transport = MCPHTTPTransport()

    init(_ definition: MCPServerDef) { def = definition }
    func start() async throws -> [MCPTool] {
        _ = try def.validated()
        if def.type == "stdio" {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            let command = ([def.command] + def.args).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
            p.arguments = [def.inheritEnvironment ? "-lc" : "-c", "exec " + command]
            p.environment = try def.resolvedEnvironment(base: ProcessInfo.processInfo.environment)
            if !def.workingDirectory.isEmpty {
                let directory = (def.workingDirectory as NSString).expandingTildeInPath
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else { throw MCPConfig.error("The configured working directory does not exist.") }
                p.currentDirectoryURL = URL(fileURLWithPath: directory)
            }
            p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
            outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.onData(handle.availableData) }
            errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let bytes = handle.availableData
                guard let self, !bytes.isEmpty, let value = String(data: bytes, encoding: .utf8) else { return }
                self.lock.lock(); self.stderrTail = String((self.stderrTail + self.def.redacted(value)).suffix(800)); self.lock.unlock()
            }
            p.terminationHandler = { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); let tail = self.stderrTail; self.lock.unlock()
                self.failAll("MCP server exited. " + self.def.redacted(tail))
            }
            try p.run(); proc = p
        }
        let initialized = try await request("initialize", ["protocolVersion": protocolVersion, "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "Red-XAI Vortex", "version": "2.12.1"]], timeout: Double(def.connectTimeoutSeconds))
        if let version = initialized["protocolVersion"] as? String {
            guard ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"].contains(version) else { throw MCPConfig.error("MCP server negotiated an unsupported protocol version.") }
            protocolVersion = version
        }
        try await notify("notifications/initialized")
        var tools: [MCPTool] = [], cursor: String?, visited = Set<String>()
        repeat {
            let result = try await request("tools/list", cursor.map { ["cursor": $0] } ?? [:], timeout: Double(def.connectTimeoutSeconds))
            guard let rows = result["tools"] as? [[String: Any]] else { throw MCPConfig.error("MCP server returned an invalid tool list.") }
            for row in rows {
                guard let name = row["name"] as? String, !name.isEmpty, def.permitsTool(name) else { continue }
                let annotations = row["annotations"] as? [String: Any] ?? [:]
                tools.append(MCPTool(name: name, description: row["description"] as? String ?? "",
                    schema: row["inputSchema"] as? [String: Any] ?? ["type": "object", "properties": [:] as [String: Any]],
                    destructive: annotations["destructiveHint"] as? Bool == true))
            }
            cursor = result["nextCursor"] as? String
            if let cursor { guard visited.insert(cursor).inserted, visited.count <= 100 else { throw MCPConfig.error("MCP tool pagination repeated or exceeded its limit.") } }
            guard tools.count <= 2000 else { throw MCPConfig.error("MCP server advertised too many tools.") }
        } while cursor != nil
        return tools
    }
    func stop() {
        transport.cancelAll()
        outPipe.fileHandleForReading.readabilityHandler = nil; errPipe.fileHandleForReading.readabilityHandler = nil
        if proc?.isRunning == true { proc?.terminate() }
        proc = nil; failAll("MCP connection stopped.")
    }
    func call(_ tool: String, _ args: [String: Any]) async throws -> String {
        guard def.permitsTool(tool) else { throw MCPConfig.error("This MCP tool is disabled in server settings.") }
        let result = try await request("tools/call", ["name": tool, "arguments": args], timeout: Double(def.requestTimeoutSeconds))
        var output = (result["content"] as? [[String: Any]] ?? []).map { content -> String in
            if let value = content["text"] as? String { return value }
            if let type = content["type"] as? String { return "[\(type) content]" }
            return ""
        }.joined(separator: "\n")
        if output.isEmpty, let structured = result["structuredContent"], let data = try? JSONSerialization.data(withJSONObject: structured) { output = String(data: data, encoding: .utf8) ?? "" }
        if result["isError"] as? Bool == true { return "error: " + def.redacted(output) }
        return output
    }
    private func onData(_ data: Data) {
        guard !data.isEmpty else { failAll("MCP server closed its output stream."); return }
        lock.lock(); buf.append(data)
        if buf.count > def.maxResponseBytes { buf.removeAll(); lock.unlock(); failAll("MCP response exceeds the configured size limit."); return }
        var messages: [[String: Any]] = []
        while let newline = buf.firstIndex(of: 10) {
            let line = buf[..<newline]; buf.removeSubrange(...newline)
            if let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { messages.append(message) }
        }
        lock.unlock(); messages.forEach(deliver)
    }
    private func deliver(_ message: [String: Any]) {
        guard let id = message["id"] as? Int else { return }
        lock.lock(); let continuation = waiting.removeValue(forKey: id); lock.unlock()
        if let error = message["error"] as? [String: Any] { continuation?.resume(throwing: MCPConfig.error(def.redacted(error["message"] as? String ?? "MCP error"))) }
        else { continuation?.resume(returning: message["result"] as? [String: Any] ?? [:]) }
    }
    private func failAll(_ message: String) {
        lock.lock(); let all = waiting; waiting.removeAll(); lock.unlock()
        for continuation in all.values { continuation.resume(throwing: MCPConfig.error(def.redacted(message))) }
    }
    private func write(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message); data.append(10)
        guard data.count <= def.maxResponseBytes else { throw MCPConfig.error("MCP request exceeds the configured size limit.") }
        try inPipe.fileHandleForWriting.write(contentsOf: data)
    }
    private func notify(_ method: String) async throws {
        let message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if def.type == "stdio" { try write(message) }
        else { _ = try await http(message, timeout: Double(def.connectTimeoutSeconds)) }
    }
    func request(_ method: String, _ params: [String: Any], timeout: Double) async throws -> [String: Any] {
        lock.lock(); let id = nextID; nextID += 1; lock.unlock()
        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        if def.type == "http" {
            let response = try await http(message, timeout: timeout)
            if let error = response["error"] as? [String: Any] { throw MCPConfig.error(def.redacted(error["message"] as? String ?? "MCP error")) }
            return response["result"] as? [String: Any] ?? [:]
        }
        return try await withThrowingTaskGroup(of: [String: Any].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.lock.lock(); self.waiting[id] = continuation; self.lock.unlock()
                    do { try self.write(message) }
                    catch { self.lock.lock(); let pending = self.waiting.removeValue(forKey: id); self.lock.unlock(); pending?.resume(throwing: error) }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
                self.lock.lock(); let pending = self.waiting.removeValue(forKey: id); self.lock.unlock()
                pending?.resume(throwing: MCPConfig.error("\(method) timed out."))
                throw CancellationError()
            }
            let result = try await group.next()!; group.cancelAll(); return result
        }
    }
    private func http(_ message: [String: Any], timeout: Double) async throws -> [String: Any] {
        var request = URLRequest(url: try MCPConfig.endpoint(def.url)); request.httpMethod = "POST"; request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        lock.lock(); let savedSession = sessionID; lock.unlock()
        if let savedSession { request.setValue(savedSession, forHTTPHeaderField: "Mcp-Session-Id") }
        for (key, value) in try def.resolvedHeaders() { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: message)
        let response = try await transport.post(request, messageID: message["id"] as? Int, limit: def.maxResponseBytes)
        if let newSession = response.sessionID { lock.lock(); sessionID = newSession; lock.unlock() }
        return response.object
    }
}

@MainActor final class MCPStore: ObservableObject {
    static let shared = MCPStore()
    @Published var servers: [MCPServerDef] = []
    @Published var tools: [String: [MCPTool]] = [:]
    @Published var status: [String: String] = [:]
    @Published var message = ""
    private var clients: [String: MCPClient] = [:]
    private var unavailableSecrets = Set<String>()
    var file: URL { ChatStore.dir.appendingPathComponent("mcp.json") }
    init() {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let decoded = try JSONDecoder().decode([MCPServerDef].self, from: Data(contentsOf: file))
            for original in decoded {
                do { servers.append(try MCPSecretVault.hydrate(original)) }
                catch { servers.append(original); unavailableSecrets.insert(original.id); status[original.id] = "Error: " + error.localizedDescription }
            }
        } catch { message = "Could not read MCP settings. Existing file left unchanged: " + error.localizedDescription }
    }
    private func writeProfiles(_ profiles: [MCPServerDef]) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profiles)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = file.deletingLastPathComponent().appendingPathComponent(".mcp-" + UUID().uuidString + ".tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw MCPConfig.error("Cannot create MCP settings file.") }
        defer { try? FileManager.default.removeItem(at: temp) }
        let handle = try FileHandle(forWritingTo: temp)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        guard Darwin.rename(temp.path, file.path) == 0 else { throw MCPConfig.error("Cannot atomically save MCP settings.") }
    }
    @discardableResult func upsert(_ original: MCPServerDef) -> Bool {
        do {
            let definition = try original.validated(); var updated = servers
            let stored = try MCPSecretVault.persist(definition)
            if let index = updated.firstIndex(where: { $0.id == stored.id }) { updated[index] = stored } else { updated.append(stored) }
            for i in updated.indices where updated[i].secretRef == nil && (!updated[i].env.isEmpty || !updated[i].headers.isEmpty) { updated[i] = try MCPSecretVault.persist(updated[i]) }
            try writeProfiles(updated)
            disconnect(stored.id); servers = updated; unavailableSecrets.remove(stored.id)
            message = "Saved. MCP credentials are stored in macOS Keychain."; return true
        } catch { message = "Not saved: " + error.localizedDescription; return false }
    }
    func delete(_ id: String) {
        let definition = servers.first { $0.id == id }
        do {
            var remaining = servers.filter { $0.id != id }
            for i in remaining.indices where remaining[i].secretRef == nil && (!remaining[i].env.isEmpty || !remaining[i].headers.isEmpty) { remaining[i] = try MCPSecretVault.persist(remaining[i]) }
            try writeProfiles(remaining); disconnect(id); servers = remaining; unavailableSecrets.remove(id); MCPSecretVault.remove(definition?.secretRef)
        } catch { message = "Not deleted: " + error.localizedDescription }
    }
    func connect(_ id: String) async {
        guard let definition = servers.first(where: { $0.id == id }), definition.enabled else { return }
        guard !unavailableSecrets.contains(id) else { status[id] = "Error: Re-enter this server's unavailable Keychain credentials in Edit."; return }
        disconnect(id); status[id] = "Connecting…"
        let client = MCPClient(definition)
        do { let available = try await client.start(); clients[id] = client; tools[id] = available; status[id] = "Connected · \(available.count) tools" }
        catch { client.stop(); status[id] = "Error: " + definition.redacted(error.localizedDescription) }
    }
    func disconnect(_ id: String) { clients[id]?.stop(); clients[id] = nil; tools[id] = nil; status[id] = nil }
    func connectEnabled() async { for definition in servers where definition.enabled && definition.reconnectOnStart && clients[definition.id] == nil { await connect(definition.id) } }
    func stopAll() { for id in Array(clients.keys) { disconnect(id) } }
    static func toolName(_ server: String, _ tool: String) -> String {
        let raw = "mcp_\(server)_\(tool)".map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" }
        return String(String(raw).prefix(64))
    }
    func enabledTools() -> [ToolSpec] {
        servers.filter { $0.enabled }.flatMap { definition -> [ToolSpec] in
            guard let client = clients[definition.id] else { return [] }
            return (tools[definition.id] ?? []).map { tool in
                ToolSpec(name: Self.toolName(definition.id, tool.name), description: "[\(definition.name)] " + tool.description, schema: tool.schema,
                         source: "mcp:\(definition.id)", destructive: tool.destructive) { args in try await client.call(tool.name, args) }
            }
        }
    }
    func importConfig(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 1024 * 1024, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = (object["mcpServers"] ?? object["servers"]) as? [String: [String: Any]] else { throw MCPConfig.error("Expected a mcpServers or servers object.") }
            var imported = 0, skipped = 0
            for (name, value) in entries {
                let id = String(name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }.prefix(32))
                if servers.contains(where: { $0.id == id }) { skipped += 1; continue }
                var d = MCPServerDef(id: id, name: name)
                if let endpoint = value["url"] as? String { d.type = "http"; d.url = endpoint }
                else { d.command = value["command"] as? String ?? ""; d.args = value["args"] as? [String] ?? [] }
                d.env = value["env"] as? [String: String] ?? [:]; d.headers = value["headers"] as? [String: String] ?? [:]
                d.workingDirectory = value["cwd"] as? String ?? ""; d.enabled = false
                if upsert(d) { imported += 1 } else { skipped += 1 }
            }
            message = "Imported \(imported) server(s), disabled until enabled. Skipped \(skipped) duplicate or invalid entries. Existing profiles were not overwritten."
        } catch { message = "Import failed: " + error.localizedDescription }
    }
}

struct MCPView: View {
    @StateObject private var store = MCPStore.shared
    @Local private var editing: MCPServerDef?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                Text("Connect local stdio tools or remote Streamable HTTP servers. Authentication and advanced settings are optional. API keys, header values and environment values are stored in Keychain. Destructive tools retain the existing approval rules.")
                    .font(.callout).foregroundStyle(.secondary)
                if !store.message.isEmpty {
                    Text(store.message).font(.callout).textSelection(.enabled)
                }
                serverList
            }
            .padding(20)
        }
        .task { await store.connectEnabled() }
        .sheet(item: $editing) { (definition: MCPServerDef) in
            MCPEditor(def: definition, existing: store.servers.contains { $0.id == definition.id }, save: saveEdited, cancel: { editing = nil })
        }
    }

    private var header: some View {
        HStack {
            Text("MCP Servers").font(.largeTitle.bold())
            Spacer()
            Button("Add Server") {
                editing = MCPServerDef(id: "server-\(store.servers.count + 1)", name: "")
            }
            Button("Import from Claude Desktop") {
                let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
                store.importConfig(url)
            }
            Button("Import JSON…", action: importJSON)
        }
    }

    private var serverList: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(store.servers) { (definition: MCPServerDef) in
                MCPServerCard(
                    definition: definition,
                    status: store.status[definition.id],
                    tools: store.tools[definition.id] ?? [],
                    setEnabled: { (enabled: Bool) in setEnabled(definition, enabled) },
                    reconnect: { Task { await store.connect(definition.id) } },
                    edit: { editing = definition },
                    remove: { store.delete(definition.id) }
                )
            }
            if store.servers.isEmpty {
                Text("No servers yet.").foregroundStyle(.secondary)
            }
        }
    }

    private func setEnabled(_ definition: MCPServerDef, _ enabled: Bool) {
        var updated = definition
        updated.enabled = enabled
        guard store.upsert(updated), enabled else { return }
        Task { await store.connect(updated.id) }
    }

    private func saveEdited(_ definition: MCPServerDef) -> String? {
        guard store.upsert(definition) else { return store.message }
        editing = nil
        if definition.enabled { Task { await store.connect(definition.id) } }
        return nil
    }

    private func importJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in MCPStore.shared.importConfig(url) }
        }
    }
}

private struct MCPServerCard: View {
    let definition: MCPServerDef
    let status: String?
    let tools: [MCPTool]
    let setEnabled: (Bool) -> Void
    let reconnect: () -> Void
    let edit: () -> Void
    let remove: () -> Void

    private var enabled: Binding<Bool> {
        Binding<Bool>(get: { definition.enabled }, set: setEnabled)
    }
    private var toolSummary: String {
        tools.map { $0.name + ($0.destructive ? " ⚠︎" : "") }.joined(separator: " · ")
    }
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                controls
                Text(definition.type == "http" ? definition.url : definition.command)
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                if let status {
                    Text(status).font(.caption)
                        .foregroundStyle(status.hasPrefix("Error") ? Color.red : Color.green)
                        .textSelection(.enabled)
                }
                if !tools.isEmpty {
                    Text(toolSummary).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }
            .padding(4)
        }
    }
    private var controls: some View {
        HStack {
            Text(definition.name).bold()
            Text(definition.type).font(.caption)
            if definition.authMode != "none" {
                Text(definition.authMode).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Enabled", isOn: enabled)
            Button("Test / Reconnect", action: reconnect).disabled(!definition.enabled)
            Button("Edit", action: edit)
            Button(role: .destructive, action: remove) {
                Image(systemName: "trash")
            }.buttonStyle(.borderless)
        }
    }
}
