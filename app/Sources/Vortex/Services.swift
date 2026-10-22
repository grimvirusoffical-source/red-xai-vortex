import Foundation
import Security

enum Keychain {
    static let service = "com.redxai.dolphino" // kept so existing Keychain items keep working
    static let account = "api-key"
    static func get() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func set(_ value: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base; add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Keeps an SSH port-forward open to the VPS so the model API stays private (localhost on both ends).
final class TunnelManager: ObservableObject {
    @Published var running = false
    @Published var lastError = ""
    private var proc: Process?

    func start(host: String, local: Int, remote: Int, keyPath: String) {
        stop()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = ["-N", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30", "-o", "BatchMode=yes",
                    "-L", "127.0.0.1:\(local):127.0.0.1:\(remote)"]
        let kp = (keyPath as NSString).expandingTildeInPath
        if !kp.isEmpty && FileManager.default.fileExists(atPath: kp) { args += ["-i", kp] }
        args.append(host)
        p.arguments = args
        let err = Pipe(); p.standardError = err
        p.terminationHandler = { [weak self] pr in
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self?.running = false
                if pr.terminationReason != .uncaughtSignal { self?.lastError = msg.isEmpty ? "Tunnel closed (\(pr.terminationStatus))" : msg }
            }
        }
        do { try p.run(); proc = p; running = true; lastError = "" } catch { lastError = error.localizedDescription }
    }
    func stop() { proc?.terminate(); proc = nil; running = false }
}

struct ChatParams {
    var baseURL: String, apiKey: String, model: String
    var temperature, topP, repeatPenalty: Double
    var topK, maxTokens, seed: Int
}

enum API {
    static func url(_ base: String, _ path: String) -> URL? {
        URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + path)
    }
    static func models(base: String, key: String) async throws -> [String] {
        guard let u = url(base, "/models") else { throw URLError(.badURL) }
        var r = URLRequest(url: u); r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (d, resp) = try await URLSession.shared.data(for: r)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw NSError(domain: "Vortex", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(h.statusCode)"]) }
        let j = try JSONSerialization.jsonObject(with: d) as? [String: Any]
        return (j?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
    }
    static func stream(_ p: ChatParams, messages: [Message], onToken: @escaping (String) -> Void) async throws -> Double? {
        guard let u = url(p.baseURL, "/chat/completions") else { throw URLError(.badURL) }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 600
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Bearer \(p.apiKey)", forHTTPHeaderField: "Authorization")
        // training mode: let Vortex learn from whatever model is active (server must have learning on)
        if UserDefaults.standard.bool(forKey: "trainingMode"), UserDefaults.standard.bool(forKey: "trainingConsent") { r.setValue("1", forHTTPHeaderField: "X-Vortex-Train") }
        var body: [String: Any] = ["model": p.model, "stream": true,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "temperature": p.temperature, "top_p": p.topP, "top_k": p.topK,
            "repeat_penalty": p.repeatPenalty, "max_tokens": p.maxTokens, "timings_per_token": false]
        if p.seed >= 0 { body["seed"] = p.seed }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, resp) = try await URLSession.shared.bytes(for: r)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
            throw NSError(domain: "Vortex", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: "Server returned HTTP \(h.statusCode)"])
        }
        var tps: Double?
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let d = payload.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if let t = j["timings"] as? [String: Any], let v = t["predicted_per_second"] as? Double { tps = v }
            if let c = (j["choices"] as? [[String: Any]])?.first, let delta = c["delta"] as? [String: Any],
               let s = delta["content"] as? String, !s.isEmpty { onToken(s) }
        }
        return tps
    }
}
