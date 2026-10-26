import Foundation
import AppKit
import SwiftUI
import CryptoKit
import Security

/// A separate Vortex-scoped approval. GenDragoon receiver tokens are never reused.
private final class VortexNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
private struct VortexApprovedSession {
    let access: String
    let refresh: String
    let sub: String
    let email: String
    let expires: Date
}

@MainActor final class VortexQuickLogin: ObservableObject {
    static let shared = VortexQuickLogin()
    @Published private(set) var code = ""
    @Published private(set) var message = ""
    @Published private(set) var busy = false
    private let issuer = "https://red-xai.com"
    private let clientID = "vortex"
    private let scope = "vortex.app"
    private let refreshKey = "redx-vortex-refresh"
    private let subKey = "redx-vortex-subject"
    private let session = URLSession(configuration: .ephemeral, delegate: VortexNoRedirect(), delegateQueue: nil)
    private var linked: VortexApprovedSession?
    private var generation = 0
    private var connectTask: Task<Void, Never>?

    private static func randomVerifier() throws -> String {
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw Failure("Secure random generation failed.") }
        return base64URL(bytes)
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func valid(_ value: String, length: Int, alphabet: CharacterSet) -> Bool {
        value.count == length && value.unicodeScalars.allSatisfy { alphabet.contains($0) }
    }
    private struct Failure: LocalizedError {
        let text: String
        init(_ text: String) { self.text = text }
        var errorDescription: String? { text }
    }

    private func call(_ path: String, body: [String: Any]) async throws -> (Int, [String: Any]) {
        guard ["start", "token", "refresh", "revoke"].contains(path),
              let url = URL(string: issuer + "/redxai-connect/" + path) else {
            throw Failure("Unsafe Red-XAI approval endpoint.")
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.url == url, data.count <= 128 * 1024,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure("Red-XAI returned an invalid approval response.")
        }
        return (http.statusCode, json)
    }
    private func readSession(_ json: [String: Any], expected: String? = nil) throws -> VortexApprovedSession {
        guard json["protocol"] as? String == "redx-site-session-v1",
              json["issuer"] as? String == issuer,
              json["client_id"] as? String == clientID,
              json["scope"] as? String == scope,
              (json["token_type"] as? String)?.lowercased() == "bearer",
              let access = json["access_token"] as? String, access.hasPrefix("rxca_"), access.count == 48,
              let refresh = json["refresh_token"] as? String, refresh.hasPrefix("rxcr_"), refresh.count == 48,
              let expiry = json["expires_in"] as? NSNumber, expiry.doubleValue > 0, expiry.doubleValue <= 3600,
              let user = json["user"] as? [String: Any], user["email_verified"] as? Bool == true,
              let sub = user["sub"] as? String, !sub.isEmpty, sub.count <= 256,
              expected == nil || expected == sub else {
            throw Failure("Red-XAI returned an invalid or unverified Vortex session.")
        }
        let alphabet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        guard Self.valid(String(access.dropFirst(5)), length: 43, alphabet: alphabet),
              Self.valid(String(refresh.dropFirst(5)), length: 43, alphabet: alphabet) else {
            throw Failure("Red-XAI returned invalid credentials.")
        }
        return VortexApprovedSession(access: access, refresh: refresh, sub: sub,
                                     email: user["email"] as? String ?? "Red-XAI account",
                                     expires: Date().addingTimeInterval(expiry.doubleValue))
    }
    private func save(_ approved: VortexApprovedSession) throws {
        Keychain.set(approved.sub, account: subKey)
        Keychain.set(approved.refresh, account: refreshKey)
        guard Keychain.get(account: subKey) == approved.sub,
              Keychain.get(account: refreshKey) == approved.refresh else {
            Keychain.set("", account: refreshKey)
            Keychain.set("", account: subKey)
            throw Failure("macOS Keychain could not save your Red-XAI session.")
        }
        linked = approved
    }

    func restore() async -> String? {
        if let linked, linked.expires > Date().addingTimeInterval(60) { return linked.email }
        guard let refresh = Keychain.get(account: refreshKey), !refresh.isEmpty,
              let savedSub = Keychain.get(account: subKey), !savedSub.isEmpty else { return nil }
        do {
            let (status, json) = try await call("refresh", body: ["client_id": clientID, "refresh_token": refresh])
            if status == 401 {
                Keychain.set("", account: refreshKey); Keychain.set("", account: subKey); linked = nil
                return nil
            }
            guard status == 200 else { message = "Red-XAI approval could not be renewed."; return nil }
            let approved = try readSession(json, expected: savedSub)
            try save(approved)
            return approved.email
        } catch {
            message = "Red-XAI is temporarily unavailable. Your saved approval was preserved."
            return nil
        }
    }

    func begin() {
        guard !busy else { return }
        generation += 1
        let current = generation
        code = ""; message = "Starting secure Red-XAI approval…"; busy = true
        connectTask = Task {
            defer { if current == generation { busy = false; connectTask = nil } }
            do {
                let verifier = try Self.randomVerifier()
                let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
                let (status, start) = try await call("start", body: [
                    "client_id": clientID, "code_challenge": challenge, "code_challenge_method": "S256"
                ])
                guard status == 200 else {
                    throw Failure("Vortex quick login isn't enabled on the Red-XAI website yet. Use password sign-in.")
                }
                let alphabet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
                let digits = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
                guard let device = start["device_code"] as? String, Self.valid(device, length: 43, alphabet: alphabet),
                      let userCode = start["user_code"] as? String, Self.valid(userCode, length: 8, alphabet: digits),
                      let link = start["verification_uri"] as? String, let url = URL(string: link),
                      url.scheme == "https", url.host == "red-xai.com", url.user == nil, url.fragment == nil,
                      ["/redxai-connect", "/redxai-connect/", "/redxai-connectx"].contains(url.path),
                      let expires = start["expires_in"] as? NSNumber, expires.doubleValue > 0, expires.doubleValue <= 300,
                      let interval = start["interval"] as? NSNumber, interval.doubleValue >= 2, interval.doubleValue <= 10 else {
                    throw Failure("Red-XAI returned an unsafe approval request.")
                }
                guard current == generation else { return }
                code = userCode
                message = "Approve Vortex in your browser using code " + userCode
                NSWorkspace.shared.open(url)
                let deadline = Date().addingTimeInterval(expires.doubleValue)
                var delay = interval.doubleValue
                while Date() < deadline && !Task.isCancelled && current == generation {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    let (codeStatus, result) = try await call("token", body: [
                        "client_id": clientID, "device_code": device, "code_verifier": verifier
                    ])
                    guard current == generation else { return }
                    if codeStatus == 428 { continue }
                    if codeStatus == 429 { delay = min(10, delay + 1); continue }
                    guard codeStatus == 200 else { throw Failure("Red-XAI approval was rejected or expired.") }
                    let approved = try readSession(result)
                    await AccountGate.shared.clearLegacyForQuick()
                    guard current == generation else { return }
                    try save(approved)
                    self.code = ""
                    message = ""
                    AccountGate.shared.username = approved.email
                    AccountGate.shared.signedIn = true
                    UserDefaults.standard.set(approved.email, forKey: "redxUser")
                    PhoneHost.sync()
                    return
                }
                if !Task.isCancelled { throw Failure("Approval timed out. Try quick login again.") }
            } catch {
                if current == generation && !Task.isCancelled { message = error.localizedDescription; code = "" }
            }
        }
    }

    func cancel() {
        generation += 1
        connectTask?.cancel(); connectTask = nil
        busy = false; code = ""; message = ""
    }
    func logout() async {
        cancel()
        let refresh = Keychain.get(account: refreshKey)
        Keychain.set("", account: refreshKey)
        Keychain.set("", account: subKey)
        linked = nil
        if let refresh, !refresh.isEmpty {
            _ = try? await call("revoke", body: ["token": refresh])
        }
    }
}
