import Foundation

enum MCPSecrets {
    static func account(_ id: String) -> String { "mcp-secrets-" + id }
    static func load(_ config: MCPServerDef) -> MCPServerDef {
        var value = config
        if let saved = Keychain.get(account: account(config.id)), let data = saved.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            value.secret = json["secret"] as? String ?? ""
            value.username = json["username"] as? String ?? ""
            value.headers = json["headers"] as? [String: String] ?? value.headers
            value.env = json["env"] as? [String: String] ?? value.env
        }
        return value
    }
    static func persist(_ value: MCPServerDef) throws -> MCPServerDef {
        let payload: [String: Any] = ["secret": value.secret, "username": value.username, "headers": value.headers, "env": value.env]
        let bytes = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
        guard let text = String(data: bytes, encoding: .utf8), Keychain.store(text, account: account(value.id)) else {
            throw MCPConfigError("OS Keychain is unavailable. No secret was written to a JSON file.")
        }
        return value // encode(to:) omits credentials
    }
}
