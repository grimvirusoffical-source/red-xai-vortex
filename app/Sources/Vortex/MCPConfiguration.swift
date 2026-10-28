import Foundation
import Security

/// Backward-compatible metadata; credentials are runtime-only and kept in Keychain.
struct MCPServerDef: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var type = "stdio"
    var command = ""
    var args: [String] = []
    var env: [String: String] = [:]
    var url = ""
    var headers: [String: String] = [:]
    var enabled = true
    var authMode = "none"
    var apiKeyHeader = "Authorization"
    var apiKeyPrefix = ""
    var apiKeyEnvironment = "API_KEY"
    var username = ""
    var apiKey = ""
    var secretRef: String?
    var workingDirectory = ""
    var inheritEnvironment = true
    var connectTimeoutSeconds = 60
    var requestTimeoutSeconds = 300
    var maxResponseBytes = 8 * 1024 * 1024
    var allowedTools: [String] = []
    var blockedTools: [String] = []
    var reconnectOnStart = true

    init(id: String, name: String) { self.id = id; self.name = name }

    enum CodingKeys: String, CodingKey {
        case id, name, type, command, args, env, url, headers, enabled
        case authMode, apiKeyHeader, apiKeyPrefix, apiKeyEnvironment, username, secretRef
        case workingDirectory, inheritEnvironment, connectTimeoutSeconds
        case requestTimeoutSeconds, maxResponseBytes, allowedTools, blockedTools, reconnectOnStart
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "stdio"
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        authMode = try c.decodeIfPresent(String.self, forKey: .authMode) ?? "none"
        apiKeyHeader = try c.decodeIfPresent(String.self, forKey: .apiKeyHeader) ?? "Authorization"
        apiKeyPrefix = try c.decodeIfPresent(String.self, forKey: .apiKeyPrefix) ?? ""
        apiKeyEnvironment = try c.decodeIfPresent(String.self, forKey: .apiKeyEnvironment) ?? "API_KEY"
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        secretRef = try c.decodeIfPresent(String.self, forKey: .secretRef)
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory) ?? ""
        inheritEnvironment = try c.decodeIfPresent(Bool.self, forKey: .inheritEnvironment) ?? true
        connectTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .connectTimeoutSeconds) ?? 60
        requestTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .requestTimeoutSeconds) ?? 300
        maxResponseBytes = try c.decodeIfPresent(Int.self, forKey: .maxResponseBytes) ?? 8 * 1024 * 1024
        allowedTools = try c.decodeIfPresent([String].self, forKey: .allowedTools) ?? []
        blockedTools = try c.decodeIfPresent([String].self, forKey: .blockedTools) ?? []
        reconnectOnStart = try c.decodeIfPresent(Bool.self, forKey: .reconnectOnStart) ?? true
    }
    /// env and headers are legacy decode inputs; their values are not re-encoded.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
        try c.encode(type, forKey: .type); try c.encode(command, forKey: .command)
        try c.encode(args, forKey: .args); try c.encode(url, forKey: .url)
        try c.encode(enabled, forKey: .enabled); try c.encode(authMode, forKey: .authMode)
        try c.encode(apiKeyHeader, forKey: .apiKeyHeader); try c.encode(apiKeyPrefix, forKey: .apiKeyPrefix)
        try c.encode(apiKeyEnvironment, forKey: .apiKeyEnvironment); try c.encode(username, forKey: .username)
        try c.encodeIfPresent(secretRef, forKey: .secretRef)
        try c.encode(workingDirectory, forKey: .workingDirectory)
        try c.encode(inheritEnvironment, forKey: .inheritEnvironment)
        try c.encode(connectTimeoutSeconds, forKey: .connectTimeoutSeconds)
        try c.encode(requestTimeoutSeconds, forKey: .requestTimeoutSeconds)
        try c.encode(maxResponseBytes, forKey: .maxResponseBytes)
        try c.encode(allowedTools, forKey: .allowedTools); try c.encode(blockedTools, forKey: .blockedTools)
        try c.encode(reconnectOnStart, forKey: .reconnectOnStart)
    }
    func validated() throws -> MCPServerDef {
        var d = self
        d.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        d.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        d.command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        d.apiKeyHeader = apiKeyHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        d.apiKeyPrefix = apiKeyPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.name.isEmpty, d.name.count <= 120 else { throw MCPConfig.error("Name is required (1–120 characters).") }
        guard id.range(of: "^[a-z0-9-]{1,32}$", options: .regularExpression) != nil else { throw MCPConfig.error("Id must contain 1–32 lowercase letters, digits or hyphens.") }
        guard ["stdio", "http"].contains(type) else { throw MCPConfig.error("Choose stdio or Streamable HTTP.") }
        guard ["none", "bearer", "header", "basic", "environment"].contains(authMode) else { throw MCPConfig.error("Unsupported authentication mode.") }
        guard (5...600).contains(connectTimeoutSeconds), (5...3600).contains(requestTimeoutSeconds) else { throw MCPConfig.error("Connection timeout must be 5–600 seconds; tool timeout 5–3600 seconds.") }
        guard (65536...32 * 1024 * 1024).contains(maxResponseBytes) else { throw MCPConfig.error("Response limit must be between 64 KiB and 32 MiB.") }
        guard args.count <= 128, args.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 16384 }) else { throw MCPConfig.error("Invalid or oversized command arguments.") }
        if type == "stdio" {
            guard !d.command.isEmpty, !d.command.contains("\0"), d.command.count <= 4096 else { throw MCPConfig.error("Command is required for a local server.") }
            guard ["none", "environment"].contains(authMode) else { throw MCPConfig.error("Local servers use an environment-variable key, not HTTP authentication.") }
        } else {
            _ = try MCPConfig.endpoint(d.url)
            guard authMode != "environment" else { throw MCPConfig.error("Remote servers use HTTP authentication, not local environment variables.") }
        }
        guard env.count <= 100, headers.count <= 100 else { throw MCPConfig.error("Too many environment variables or headers.") }
        for (key, value) in env {
            guard MCPConfig.validEnvironmentName(key), !value.contains("\0"), value.utf8.count <= 16384 else { throw MCPConfig.error("Invalid environment variable name or value.") }
        }
        var seen = Set<String>()
        for (key, value) in headers {
            try MCPConfig.validateHeader(key, value)
            guard seen.insert(key.lowercased()).inserted else { throw MCPConfig.error("Duplicate HTTP header names are not allowed.") }
        }
        if authMode != "none" {
            guard !apiKey.isEmpty, apiKey.utf8.count <= 16384, !apiKey.contains("\0"), !apiKey.contains("\r"), !apiKey.contains("\n") else { throw MCPConfig.error("Enter the API key, bearer token, or password for the selected authentication mode.") }
            if authMode == "basic" {
                guard !username.isEmpty, !username.contains(":"), !username.contains("\r"), !username.contains("\n") else { throw MCPConfig.error("Basic authentication needs a username without colons or line breaks.") }
            }
            if authMode == "environment" {
                guard MCPConfig.validEnvironmentName(apiKeyEnvironment) else { throw MCPConfig.error("Enter a valid environment-variable name, such as FIRECRAWL_API_KEY.") }
                guard env[apiKeyEnvironment] == nil else { throw MCPConfig.error("The API-key environment variable is also set in advanced settings. Keep only one value.") }
            } else {
                let key = authMode == "header" ? d.apiKeyHeader : "Authorization"
                try MCPConfig.validateHeader(key, d.apiKeyPrefix)
                guard !seen.contains(key.lowercased()) else { throw MCPConfig.error("Authentication is also configured in the headers. Keep only one value for that header.") }
            }
        }
        if !workingDirectory.isEmpty {
            guard (workingDirectory as NSString).expandingTildeInPath.hasPrefix("/"), !workingDirectory.contains("\0") else { throw MCPConfig.error("Working directory must be an absolute path or start with ~/.") }
        }
        for name in allowedTools + blockedTools {
            guard !name.isEmpty, name.count <= 256, !name.contains("\n") else { throw MCPConfig.error("Enter exact tool names, one per line.") }
        }
        return d
    }
    func resolvedHeaders() throws -> [String: String] {
        let d = try validated(); var result = d.headers
        switch d.authMode {
        case "bearer": result["Authorization"] = "Bearer " + d.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        case "header": result[d.apiKeyHeader] = (d.apiKeyPrefix.isEmpty ? "" : d.apiKeyPrefix + " ") + d.apiKey
        case "basic": result["Authorization"] = "Basic " + Data((d.username + ":" + d.apiKey).utf8).base64EncodedString()
        default: break
        }
        return result
    }
    func resolvedEnvironment(base: [String: String]) throws -> [String: String] {
        let d = try validated()
        var result = d.inheritEnvironment ? base : ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "HOME": NSHomeDirectory()]
        result.merge(d.env, uniquingKeysWith: { _, value in value })
        if d.authMode == "environment" { result[d.apiKeyEnvironment] = d.apiKey }
        return result
    }
    func permitsTool(_ name: String) -> Bool { !blockedTools.contains(name) && (allowedTools.isEmpty || allowedTools.contains(name)) }
    func redacted(_ message: String) -> String {
        var output = message
        var values = Array(headers.values) + Array(env.values) + [apiKey]
        if authMode == "basic" { values.append("Basic " + Data((username + ":" + apiKey).utf8).base64EncodedString()) }
        for value in values.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) { output = output.replacingOccurrences(of: value, with: "[redacted]") }
        return String(output.prefix(1200))
    }
}

enum MCPConfig {
    static func error(_ message: String) -> NSError { NSError(domain: "MCP", code: -1, userInfo: [NSLocalizedDescriptionKey: message]) }
    static func validEnvironmentName(_ name: String) -> Bool { name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil }
    static func validateHeader(_ name: String, _ value: String) throws {
        let reserved: Set<String> = ["host", "content-length", "content-type", "accept", "connection", "transfer-encoding", "cookie", "proxy-authorization", "mcp-session-id", "mcp-protocol-version"]
        guard name.range(of: "^[!#$%&'*+.^_`|~0-9A-Za-z-]+$", options: .regularExpression) != nil, !reserved.contains(name.lowercased()), name.count <= 128,
              !value.contains("\r"), !value.contains("\n"), !value.contains("\0"), value.utf8.count <= 16384 else {
            throw error("Invalid or transport-managed HTTP header. Authentication and custom service headers are supported; Host and MCP session headers are managed by Vortex.")
        }
    }
    static func endpoint(_ value: String) throws -> URL {
        guard let u = URL(string: value), let host = u.host, !host.isEmpty, u.user == nil, u.password == nil, u.fragment == nil,
              u.scheme == "https" || (u.scheme == "http" && ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)) else {
            throw error("A remote MCP URL must use HTTPS. HTTP is allowed only on loopback. Do not put credentials in the URL.")
        }
        let protected = Set(["api_key", "apikey", "key", "token", "access_token", "authorization"])
        if URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { protected.contains($0.name.lowercased()) }) == true { throw error("Put API keys in Authentication, not in a URL query parameter.") }
        return u
    }
    static func parsePairs(_ text: String, separator: Character, headers: Bool) throws -> [String: String] {
        var result: [String: String] = [:]; var seen = Set<String>()
        for line in text.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let i = line.firstIndex(of: separator) else { throw error(headers ? "Use one Header: value per line." : "Use one NAME=value per line.") }
            let key = line[..<i].trimmingCharacters(in: .whitespaces)
            let raw = String(line[line.index(after: i)...]); let value = headers ? raw.trimmingCharacters(in: .whitespaces) : raw
            guard seen.insert(headers ? key.lowercased() : key).inserted else { throw error("Duplicate setting: " + key) }
            result[key] = value
        }
        return result
    }
}

struct MCPSecretBundle: Codable {
    var apiKey: String
    var headers: [String: String]
    var env: [String: String]
}

enum MCPSecretVault {
    private static let service = "com.redxai.vortex.mcp"
    static func persist(_ original: MCPServerDef) throws -> MCPServerDef {
        var d = original; let reference = d.secretRef ?? UUID().uuidString
        guard UUID(uuidString: reference) != nil else { throw MCPConfig.error("Invalid MCP credential reference.") }
        let data = try JSONEncoder().encode(MCPSecretBundle(apiKey: d.apiKey, headers: d.headers, env: d.env))
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: reference]
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw MCPConfig.error("Could not save MCP credentials in macOS Keychain (OSStatus \(status)). No plaintext fallback was used.") }
        d.secretRef = reference; return d
    }
    static func hydrate(_ original: MCPServerDef) throws -> MCPServerDef {
        guard let reference = original.secretRef else { return original }
        guard UUID(uuidString: reference) != nil else { throw MCPConfig.error("Invalid MCP credential reference.") }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: reference, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let bytes = out as? Data else { throw MCPConfig.error("MCP credentials are unavailable in Keychain. Re-enter the credentials in Edit; existing files have not been overwritten.") }
        let secret = try JSONDecoder().decode(MCPSecretBundle.self, from: bytes)
        var d = original; d.apiKey = secret.apiKey; d.headers = secret.headers; d.env = secret.env; return d
    }
    static func remove(_ reference: String?) {
        guard let reference, UUID(uuidString: reference) != nil else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: reference]
        SecItemDelete(query as CFDictionary)
    }
}
