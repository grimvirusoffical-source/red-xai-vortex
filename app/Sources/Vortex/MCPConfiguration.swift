import Foundation
import Security

struct MCPSecretBundle: Codable {
    var apiKey = ""
    var headers: [String: String] = [:]
    var environment: [String: String] = [:]
}

enum MCPConfiguration {
    static let versions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let reservedHeaders: Set<String> = ["host", "content-type", "accept", "content-length", "connection", "mcp-session-id", "mcp-protocol-version", "transfer-encoding", "cookie"]
    static func failure(_ text: String) -> NSError { NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    static func validatedURL(_ text: String) throws -> URL {
        guard let u = URL(string: text), let c = URLComponents(url: u, resolvingAgainstBaseURL: false),
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil, c.fragment == nil,
              c.scheme == "https" || (c.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)) else {
            throw failure("Use an HTTPS MCP URL (or HTTP on localhost). Credentials must not be embedded in the URL.")
        }
        if (c.queryItems ?? []).contains(where: { ["key", "api_key", "apikey", "token", "access_token", "authorization"].contains($0.name.lowercased()) }) {
            throw failure("Put credentials in the API-key field, not the server URL.")
        }
        return u
    }
    static func headerName(_ name: String) -> Bool {
        name.range(of: #"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$"#, options: .regularExpression) != nil
    }
    static func validate(_ d: MCPServerDef) throws {
        guard !d.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              d.id.range(of: "^[a-z0-9-]{1,64}$", options: .regularExpression) != nil else { throw failure("Name and a unique server ID are required.") }
        guard ["stdio", "http"].contains(d.type) else { throw failure("Unsupported transport.") }
        guard ["none", "bearer", "header", "environment"].contains(d.authMode ?? "none") else { throw failure("Unsupported authentication method.") }
        if d.type == "http" {
            _ = try validatedURL(d.url)
            guard d.authMode != "environment" else { throw failure("Environment authentication is only available for local commands.") }
        } else {
            guard !d.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !d.command.contains("\u{0}") else { throw failure("A local server command is required.") }
            guard d.authMode == nil || ["none", "environment"].contains(d.authMode!) else { throw failure("Local servers accept API keys through environment variables.") }
        }
        if let cwd = d.workingDirectory, !cwd.isEmpty {
            var directory: ObjCBool = false
            guard cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: cwd, isDirectory: &directory), directory.boolValue else { throw failure("Working directory must be an existing absolute directory.") }
        }
        for n in [d.connectTimeout ?? 60, d.callTimeout ?? 300] {
            guard n.isFinite, n >= 1, n <= 3600 else { throw failure("Timeouts must be between 1 and 3600 seconds.") }
        }
        guard versions.contains(d.protocolVersion ?? "2025-06-18") else { throw failure("Unsupported MCP protocol version.") }
        for (k,v) in d.headers {
            guard headerName(k), !reservedHeaders.contains(k.lowercased()), v.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else { throw failure("Invalid or protocol-reserved HTTP header.") }
        }
        for (k,v) in d.env {
            guard k.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil, !v.contains("\u{0}") else { throw failure("Invalid environment variable.") }
        }
        if d.authMode == "header" {
            let name = d.keyName ?? "X-API-Key"
            guard headerName(name), !reservedHeaders.contains(name.lowercased()) else { throw failure("Choose a valid API-key header name.") }
        }
        if d.authMode == "environment" {
            guard (d.keyName ?? "").range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { throw failure("Enter the provider's API-key environment variable name.") }
        }
    }
    static func effective(_ definition: MCPServerDef, secrets: MCPSecretBundle) throws -> MCPServerDef {
        var d = definition
        d.headers = secrets.headers; d.env = secrets.environment
        try validate(d)
        let key = secrets.apiKey
        guard key.utf8.count <= 4096, key.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else { throw failure("API keys cannot contain control characters.") }
        if !key.isEmpty {
            switch d.authMode ?? "none" {
            case "bearer":
                d.headers = d.headers.filter { $0.key.lowercased() != "authorization" }
                d.headers["Authorization"] = "Bearer " + key
            case "header":
                let name = d.keyName ?? "X-API-Key"
                d.headers = d.headers.filter { $0.key.lowercased() != name.lowercased() }; d.headers[name] = key
            case "environment": d.env[d.keyName ?? "API_KEY"] = key
            default: break
            }
        }
        return d
    }
    static func safeDisplayURL(_ value: String) -> String {
        guard var u = URLComponents(string: value) else { return "Invalid endpoint" }
        u.user = nil; u.password = nil; u.query = nil; u.fragment = nil
        return u.string ?? "MCP endpoint"
    }
}

final class MCPNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum MCPSecrets {
    static func read(_ d: MCPServerDef) throws -> MCPSecretBundle {
        guard let reference = d.secretReference else { return MCPSecretBundle(headers: d.headers, environment: d.env) }
        guard let value = Keychain.get(account: "mcp-" + reference), let data = value.data(using: .utf8),
              let bundle = try? JSONDecoder().decode(MCPSecretBundle.self, from: data) else {
            throw MCPConfiguration.failure("This account's saved MCP credentials are unavailable. Edit the server and save its credentials again.")
        }
        return bundle
    }
    static func store(_ bundle: MCPSecretBundle) throws -> String {
        let reference = UUID().uuidString
        let value = String(decoding: try JSONEncoder().encode(bundle), as: UTF8.self)
        let account = AccountProfile.credentialAccount("mcp-" + reference)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: Keychain.service, kSecAttrAccount as String: account,
                                  kSecValueData as String: Data(value.utf8)]
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw MCPConfiguration.failure("macOS Keychain could not securely save the MCP credentials. No settings were replaced.") }
        return reference
    }
}
