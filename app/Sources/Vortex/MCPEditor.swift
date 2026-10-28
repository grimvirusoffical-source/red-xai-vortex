import SwiftUI

struct MCPEditor: View {
    @State private var definition: MCPServerDef
    @State private var argumentsText: String
    @State private var environmentText: String
    @State private var headersText: String
    @State private var allowedText: String
    @State private var blockedText: String
    @State private var error = ""
    let existing: Bool
    var save: (MCPServerDef) -> String?
    var cancel: () -> Void

    init(def: MCPServerDef, existing: Bool = false, save: @escaping (MCPServerDef) -> String?, cancel: @escaping () -> Void) {
        _definition = State(initialValue: def)
        _argumentsText = State(initialValue: def.args.joined(separator: "\n"))
        _environmentText = State(initialValue: def.env.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n"))
        _headersText = State(initialValue: def.headers.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n"))
        _allowedText = State(initialValue: def.allowedTools.joined(separator: "\n"))
        _blockedText = State(initialValue: def.blockedTools.joined(separator: "\n"))
        self.existing = existing; self.save = save; self.cancel = cancel
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing ? "Edit MCP Server" : "Add MCP Server").font(.title2.bold())
            Text("Name, Id, transport, and the matching URL or command are required. Everything in Authentication and Advanced is optional unless you choose to use it.").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !existing {
                        HStack {
                            Text("Quick setup:").font(.caption)
                            Button("Firecrawl · API key") { firecrawl(local: false) }
                            Button("Firecrawl · local") { firecrawl(local: true) }
                        }
                    }
                    GroupBox("Required connection") {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Name (required)", text: $definition.name)
                            TextField("Id: a-z, 0-9, - (required)", text: $definition.id).disabled(existing)
                            Picker("Transport", selection: $definition.type) {
                                Text("stdio · local command").tag("stdio")
                                Text("Streamable HTTP").tag("http")
                            }.pickerStyle(.segmented)
                            .onChange(of: definition.type) { _, type in
                                if type == "stdio", !["none", "environment"].contains(definition.authMode) { definition.authMode = "none" }
                                if type == "http", definition.authMode == "environment" { definition.authMode = "none" }
                            }
                            if definition.type == "stdio" {
                                TextField("Command (required), e.g. npx", text: $definition.command)
                                Text("Arguments · optional, one exact argument per line").font(.caption)
                                TextEditor(text: $argumentsText).font(.caption.monospaced()).frame(height: 65).border(.quaternary)
                                Text("Connecting starts this command on your computer. Only use servers you trust.").font(.caption).foregroundStyle(.secondary)
                            } else {
                                TextField("MCP URL (required): https://…/mcp", text: $definition.url)
                                Text("Use the MCP endpoint, not the service's REST API or dashboard. HTTPS is required except for a local loopback server.").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(6)
                    }
                    GroupBox("Authentication · optional") {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Method", selection: $definition.authMode) {
                                Text("None / existing advanced settings").tag("none")
                                if definition.type == "http" {
                                    Text("API key / bearer token").tag("bearer")
                                    Text("API key in custom header").tag("header")
                                    Text("Basic · username and password").tag("basic")
                                } else { Text("API key in environment variable").tag("environment") }
                            }
                            if definition.authMode != "none" {
                                if definition.authMode == "basic" { TextField("Username", text: $definition.username) }
                                if definition.authMode == "header" {
                                    TextField("Header name, e.g. x-api-key", text: $definition.apiKeyHeader)
                                    TextField("Prefix · optional, e.g. Token", text: $definition.apiKeyPrefix)
                                }
                                if definition.authMode == "environment" { TextField("Variable name, e.g. FIRECRAWL_API_KEY", text: $definition.apiKeyEnvironment) }
                                SecureField(definition.authMode == "basic" ? "Password" : "API key / bearer token", text: $definition.apiKey).textContentType(.password)
                                Text("Saved in macOS Keychain, not mcp.json. Changing the key and saving reconnects this server. Leaving Authentication as None does not require a key.").font(.caption).foregroundStyle(.secondary)
                            }
                            if definition.authMode == "bearer" { Text("Sends Authorization: Bearer <your key>. Paste only the credential, not the header name.").font(.caption).foregroundStyle(.secondary) }
                        }.padding(6)
                    }
                    DisclosureGroup("Advanced settings · optional") {
                        VStack(alignment: .leading, spacing: 10) {
                            if definition.type == "stdio" {
                                TextField("Working directory · optional, absolute path or ~/…", text: $definition.workingDirectory)
                                Toggle("Inherit the current environment and login-shell PATH", isOn: $definition.inheritEnvironment)
                                Text("Additional environment variables · NAME=value, one per line").font(.caption)
                                TextEditor(text: $environmentText).font(.caption.monospaced()).frame(height: 70).border(.quaternary)
                            } else {
                                Text("Additional headers · Header: value, one per line").font(.caption)
                                TextEditor(text: $headersText).font(.caption.monospaced()).frame(height: 70).border(.quaternary)
                                Text("Header values are stored in Keychain. Do not duplicate the authentication header here. TLS validation stays enabled; credentials never follow redirects.").font(.caption).foregroundStyle(.secondary)
                            }
                            Stepper("Connection / discovery timeout: \(definition.connectTimeoutSeconds) seconds", value: $definition.connectTimeoutSeconds, in: 5...600, step: 5)
                            Stepper("Tool-call timeout: \(definition.requestTimeoutSeconds) seconds", value: $definition.requestTimeoutSeconds, in: 5...3600, step: 5)
                            Stepper("Maximum response: \(definition.maxResponseBytes / 1024) KiB", value: $definition.maxResponseBytes, in: 65536...(32 * 1024 * 1024), step: 65536)
                            Text("Only allow these tools · optional, exact names, one per line; empty means all").font(.caption)
                            TextEditor(text: $allowedText).font(.caption.monospaced()).frame(height: 50).border(.quaternary)
                            Text("Block these tools · optional, exact names, one per line; blocked takes precedence").font(.caption)
                            TextEditor(text: $blockedText).font(.caption.monospaced()).frame(height: 50).border(.quaternary)
                            Toggle("Reconnect enabled server when MCP tools start", isOn: $definition.reconnectOnStart)
                        }.padding(.top, 8)
                    }
                    Toggle("Enabled", isOn: $definition.enabled)
                    if !error.isEmpty { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
                }.padding(.trailing, 6)
            }
            HStack {
                Spacer(); Button("Cancel", action: cancel)
                Button(definition.enabled ? "Save & Test Connection" : "Save Disabled") { submit() }.buttonStyle(.borderedProminent)
                    .disabled(definition.name.trimmingCharacters(in: .whitespaces).isEmpty || definition.id.isEmpty || (definition.type == "http" ? definition.url.isEmpty : definition.command.isEmpty))
            }
        }.padding(20).frame(width: 680, height: 740)
    }
    private func firecrawl(local: Bool) {
        if definition.name.isEmpty { definition.name = "Firecrawl" }
        definition.id = "firecrawl"; definition.type = local ? "stdio" : "http"
        definition.command = local ? "npx" : ""; argumentsText = local ? "-y\nfirecrawl-mcp" : ""
        definition.url = local ? "" : "https://mcp.firecrawl.dev/v2/mcp"
        definition.authMode = local ? "environment" : "bearer"
        definition.apiKeyEnvironment = "FIRECRAWL_API_KEY"; definition.apiKeyHeader = "Authorization"; definition.apiKeyPrefix = ""
        headersText = ""; environmentText = ""; error = ""
    }
    private func submit() {
        do {
            var d = definition
            d.args = argumentsText.components(separatedBy: .newlines).filter { !$0.isEmpty }
            d.env = try MCPConfig.parsePairs(environmentText, separator: "=", headers: false)
            d.headers = try MCPConfig.parsePairs(headersText, separator: ":", headers: true)
            let lines: (String) -> [String] = { $0.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            d.allowedTools = lines(allowedText); d.blockedTools = lines(blockedText)
            error = save(try d.validated()) ?? ""
        } catch { self.error = error.localizedDescription }
    }
}
