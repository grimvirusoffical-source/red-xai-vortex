import Foundation

struct MCPConfigError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

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
    var autoConnect = true
    var authMode = "none"
    var keyName = "Authorization"
    var username = ""
    var secret = ""
    var workingDirectory = ""
    var protocolVersion = "2025-06-18"
    var initializeTimeout = 60.0
    var requestTimeout = 300.0
    var maxResponseBytes = 8 * 1024 * 1024

    init(id: String, name: String, type: String = "stdio", command: String = "", args: [String] = []) { self.id = id; self.name = name; self.type = type; self.command = command; self.args = args }
    enum CodingKeys: String, CodingKey {
        case id, name, type, command, args, env, url, headers, enabled, autoConnect, authMode, keyName, workingDirectory, protocolVersion, initializeTimeout, requestTimeout, maxResponseBytes
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "stdio"
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        autoConnect = try c.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? true
        authMode = try c.decodeIfPresent(String.self, forKey: .authMode) ?? "none"
        keyName = try c.decodeIfPresent(String.self, forKey: .keyName) ?? "Authorization"
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory) ?? ""
        protocolVersion = try c.decodeIfPresent(String.self, forKey: .protocolVersion) ?? "2025-06-18"
        initializeTimeout = try c.decodeIfPresent(Double.self, forKey: .initializeTimeout) ?? 60
        requestTimeout = try c.decodeIfPresent(Double.self, forKey: .requestTimeout) ?? 300
        maxResponseBytes = try c.decodeIfPresent(Int.self, forKey: .maxResponseBytes) ?? 8*1024*1024
    }
    // No secret values are ever encoded into profile JSON or exports.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(type, forKey: .type)
        try c.encode(command, forKey: .command); try c.encode(args, forKey: .args); try c.encode(url, forKey: .url)
        try c.encode(enabled, forKey: .enabled); try c.encode(autoConnect, forKey: .autoConnect)
        try c.encode(authMode, forKey: .authMode); try c.encode(keyName, forKey: .keyName)
        try c.encode(workingDirectory, forKey: .workingDirectory); try c.encode(protocolVersion, forKey: .protocolVersion)
        try c.encode(initializeTimeout, forKey: .initializeTimeout); try c.encode(requestTimeout, forKey: .requestTimeout)
        try c.encode(maxResponseBytes, forKey: .maxResponseBytes)
    }
    static let forbiddenHeaders: Set<String> = ["host", "connection", "content-length", "transfer-encoding", "content-type", "accept", "cookie", "proxy-authorization", "mcp-session-id", "mcp-protocol-version"]
    static func headerName(_ name: String) -> Bool {
        name.range(of: "^[!#$%&'*+.^_`|~0-9A-Za-z-]+$", options: .regularExpression) != nil && !forbiddenHeaders.contains(name.lowercased())
    }
    func validate() throws {
        guard id.range(of: "^[a-z0-9-]{1,32}$", options: .regularExpression) != nil,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MCPConfigError("Name and a valid ID are required.") }
        guard ["stdio", "http"].contains(type) else { throw MCPConfigError("Choose stdio or Streamable HTTP.") }
        guard initializeTimeout.isFinite, requestTimeout.isFinite,
              (1...600).contains(initializeTimeout), (1...3600).contains(requestTimeout),
              (1024...32*1024*1024).contains(maxResponseBytes) else { throw MCPConfigError("Timeout or response-size limit is outside the supported range.") }
        guard ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"].contains(protocolVersion) else { throw MCPConfigError("Select a supported MCP protocol version.") }
        guard ["none", "bearer", "header", "basic", "environment"].contains(authMode) else { throw MCPConfigError("Unsupported authentication method.") }
        if type == "http" {
            guard let u = URL(string: url), let host = u.host, u.user == nil, u.password == nil,
                  u.fragment == nil, u.query == nil,
                  u.scheme == "https" || (u.scheme == "http" && ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)) else {
                throw MCPConfigError("Remote MCP requires HTTPS; HTTP is allowed only on loopback. Put API keys in Authentication, never in the URL.")
            }
            guard authMode != "environment" else { throw MCPConfigError("Environment authentication is for local stdio servers.") }
        } else {
            guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !command.contains("\0") else { throw MCPConfigError("A local command is required.") }
            guard ["none", "environment"].contains(authMode) else { throw MCPConfigError("Local servers receive API keys through their environment.") }
        }
        for (key, value) in headers {
            guard Self.headerName(key), !value.contains("\r"), !value.contains("\n") else { throw MCPConfigError("Invalid or protected HTTP header.") }
        }
        guard Set(headers.keys.map { $0.lowercased() }).count == headers.count else { throw MCPConfigError("Duplicate HTTP header names are not allowed.") }
        for (key, value) in env {
            guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil, !value.contains("\0") else { throw MCPConfigError("Invalid environment variable.") }
        }
        if authMode != "none" {
            guard !secret.isEmpty, secret.utf8.count <= 16384, !secret.contains("\r"), !secret.contains("\n"), !secret.contains("\0") else { throw MCPConfigError("The selected authentication method requires a credential.") }
            if authMode == "header" && !Self.headerName(keyName) { throw MCPConfigError("Choose a valid, non-protected API-key header.") }
            if authMode == "environment" && keyName.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) == nil { throw MCPConfigError("Choose a valid environment variable name.") }
            if authMode == "basic" && (username.isEmpty || username.contains(":")) { throw MCPConfigError("HTTP Basic requires a username without a colon.") }
            let header = authMode == "header" ? keyName.lowercased() : "authorization"
            if type == "http" && headers.keys.contains(where: { $0.lowercased() == header }) { throw MCPConfigError("Authentication is also set in Additional headers. Use only one location.") }
        }
    }
    func effectiveHeaders() throws -> [String: String] {
        try validate(); var result = headers
        if authMode == "bearer" { result["Authorization"] = "Bearer " + secret }
        if authMode == "header" { result[keyName] = secret }
        if authMode == "basic" { result["Authorization"] = "Basic " + Data((username + ":" + secret).utf8).base64EncodedString() }
        return result
    }
    func effectiveEnvironment() throws -> [String: String] {
        try validate(); var result = env
        if authMode == "environment" { result[keyName] = secret }
        return result
    }
    static func parsePairs(_ text: String, separator: Character) throws -> [String: String] {
        var result: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            if raw.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard let index = raw.firstIndex(of: separator) else { throw MCPConfigError("Each advanced setting needs a name and separator.") }
            let key = String(raw[..<index]).trimmingCharacters(in: .whitespaces)
            let value = String(raw[raw.index(after: index)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, result[key] == nil else { throw MCPConfigError("Empty or duplicate advanced setting.") }
            result[key] = value
        }
        return result
    }
}

enum MCPResponse {
    static func sameID(_ a: Any?, _ b: Any?) -> Bool {
        if let a = a as? Int, let b = b as? Int { return a == b }
        if let a = a as? String, let b = b as? String { return a == b }
        return false
    }
    static func parseSSE(_ data: Data, requestID: Any?) throws -> [String: Any] {
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        for block in text.components(separatedBy: "\n\n") {
            let payload = block.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }
                .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            if let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any], sameID(object["id"], requestID) { return object }
        }
        throw MCPConfigError("The MCP stream ended without the matching response.")
    }
}
