import SwiftUI

/// Existing connection fields remain required; credentials and advanced settings are opt-in.
struct MCPEditor: View {
    @State var def: MCPServerDef
    var save: (MCPServerDef, String, Bool) -> Bool
    var cancel: () -> Void
    @State private var apiKey = ""
    @State private var clearKey = false
    @State private var savedKey = false
    @State private var arguments = ""
    @State private var headers = "{}"
    @State private var environment = "{}"
    @State private var connectionTimeout = ""
    @State private var requestTimeout = ""
    @State private var message = ""
    @State private var testing = false
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("MCP server settings").font(.title2.bold()); Spacer() }.padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Button("Firecrawl HTTPS preset") {
                            def.name = def.name.isEmpty ? "Firecrawl" : def.name
                            def.type = "http"; def.url = "https://mcp.firecrawl.dev/v2/mcp"; def.authMode = "bearer"
                        }
                        Button("Firecrawl local preset") {
                            def.name = def.name.isEmpty ? "Firecrawl" : def.name
                            def.type = "stdio"; def.command = "npx"; arguments = "-y\nfirecrawl-mcp"
                            def.authMode = "environment"; def.keyName = "FIRECRAWL_API_KEY"
                        }
                    }
                    TextField("Name (required)", text: $def.name)
                    Text("Server ID: \(def.id)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    Picker("Transport (required)", selection: $def.type) {
                        Text("Local command · stdio").tag("stdio")
                        Text("Remote · Streamable HTTP").tag("http")
                    }.onChange(of: def.type) { _, type in
                        if type == "http" && def.authMode == "environment" { def.authMode = "none" }
                        if type == "stdio" && ["bearer", "header"].contains(def.authMode ?? "none") { def.authMode = "none" }
                    }
                    if def.type == "http" {
                        TextField("MCP server URL (required)", text: $def.url)
                        Text("HTTPS for remote servers; HTTP only on localhost. Keys belong below, not in URLs.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        TextField("Command (required)", text: $def.command)
                        Text("Arguments (optional, one argument per line)").font(.caption.bold())
                        TextEditor(text: $arguments).font(.system(.body, design: .monospaced)).frame(height: 90)
                        TextField("Working directory (optional)", text: Binding(get: { def.workingDirectory ?? "" }, set: { def.workingDirectory = $0.isEmpty ? nil : $0 }))
                    }
                    GroupBox("Authentication · optional") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Authentication", selection: Binding(get: { def.authMode ?? "none" }, set: { def.authMode = $0 })) {
                                Text("None").tag("none")
                                if def.type == "http" {
                                    Text("Bearer API key or access token").tag("bearer")
                                    Text("Custom API-key header").tag("header")
                                } else { Text("API-key environment variable").tag("environment") }
                            }
                            if ["header", "environment"].contains(def.authMode ?? "none") {
                                TextField(def.type == "http" ? "Header name (e.g. X-API-Key)" : "Variable name (e.g. FIRECRAWL_API_KEY)", text: Binding(get: { def.keyName ?? (def.type == "http" ? "X-API-Key" : "") }, set: { def.keyName = $0 }))
                            }
                            SecureField(savedKey ? "API key (optional; blank keeps saved key)" : "API key (optional)", text: $apiKey)
                                .disabled(def.authMode == nil || def.authMode == "none")
                            if savedKey { Toggle("Remove the saved API key", isOn: $clearKey) }
                            Text("Stored for this signed-in account in macOS Keychain. No key is required for public MCP servers. Selecting Bearer uses your supplied token; it does not start a browser OAuth flow.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(5)
                    }
                    DisclosureGroup("Advanced settings · all optional") {
                        VStack(alignment: .leading, spacing: 12) {
                            if def.type == "http" {
                                Text("Custom HTTP headers (JSON object; values saved in Keychain)").font(.caption)
                                TextEditor(text: $headers).font(.system(.body, design: .monospaced)).frame(height: 100)
                            } else {
                                Text("Environment variables (JSON object; values saved in Keychain)").font(.caption)
                                TextEditor(text: $environment).font(.system(.body, design: .monospaced)).frame(height: 100)
                                Toggle("Inherit all environment variables (may expose other credentials to this server)", isOn: Binding(get: { def.inheritEnvironment ?? false }, set: { def.inheritEnvironment = $0 }))
                            }
                            TextField("Connection timeout in seconds (blank = 60)", text: $connectionTimeout)
                            TextField("Tool timeout in seconds (blank = 300)", text: $requestTimeout)
                            Picker("Protocol version", selection: Binding(get: { def.protocolVersion ?? "2025-11-25" }, set: { def.protocolVersion = $0 })) {
                                ForEach(MCPConfiguration.versions, id: \.self) { Text($0).tag($0) }
                            }
                            Toggle("Connect automatically after sign-in", isOn: Binding(get: { def.autoConnect ?? true }, set: { def.autoConnect = $0 }))
                        }.padding(.top, 8)
                    }
                    Toggle("Enabled", isOn: $def.enabled)
                    if !message.isEmpty { Text(message).font(.callout).textSelection(.enabled) }
                }.textFieldStyle(.roundedBorder).padding(18)
            }.scrollIndicators(.visible).frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(testing ? "Testing…" : "Test connection") { testConnection() }.disabled(testing)
                Spacer()
                Button("Save") {
                    do {
                        let value = try prepared()
                        if !save(value, apiKey, clearKey) { message = MCPStore.shared.message }
                    } catch { message = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(testing)
            }.padding()
        }.frame(minWidth: 540, idealWidth: 650, maxWidth: 850, minHeight: 420, idealHeight: 680, maxHeight: 760)
            .onAppear(perform: load)
    }
    private func load() {
        guard !loaded else { return }; loaded = true
        arguments = def.args.joined(separator: "\n")
        connectionTimeout = def.connectTimeout.map { String($0) } ?? ""
        requestTimeout = def.callTimeout.map { String($0) } ?? ""
        do {
            let secrets = try MCPSecrets.read(def)
            savedKey = !secrets.apiKey.isEmpty
            headers = json(secrets.headers); environment = json(secrets.environment)
        } catch { message = error.localizedDescription }
    }
    private func json(_ value: [String: String]) -> String {
        (try? String(decoding: JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)) ?? "{}"
    }
    private func dictionary(_ text: String) throws -> [String: String] {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        guard let data = text.data(using: .utf8), let value = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw MCPConfiguration.failure("Headers and environment must be JSON objects with string values.")
        }
        return value
    }
    private func timeout(_ text: String) throws -> Double? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        guard let value = Double(text), value.isFinite, (1...3600).contains(value) else { throw MCPConfiguration.failure("Timeouts must be 1–3600 seconds, or blank.") }
        return value
    }
    private func prepared() throws -> MCPServerDef {
        var value = def
        value.args = arguments.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        value.headers = try dictionary(headers); value.env = try dictionary(environment)
        value.connectTimeout = try timeout(connectionTimeout); value.callTimeout = try timeout(requestTimeout)
        try MCPConfiguration.validate(value)
        return value
    }
    private func testConnection() {
        testing = true; message = "Checking initialization and tool discovery…"
        Task { @MainActor in
            defer { testing = false }
            do {
                let value = try prepared()
                var secrets = try MCPSecrets.read(value)
                secrets.headers = value.headers; secrets.environment = value.env
                if clearKey { secrets.apiKey = "" }; if !apiKey.isEmpty { secrets.apiKey = apiKey }
                let client = MCPClient(try MCPConfiguration.effective(value, secrets: secrets))
                defer { client.stop() }
                let tools = try await client.start()
                message = "Connected. Discovered \(tools.count) tools. No tool was executed."
            } catch { message = error.localizedDescription }
        }
    }
}
