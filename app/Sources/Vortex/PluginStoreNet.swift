import Foundation
import AppKit
import Security
import SwiftUI

/// Client for the Vortex Plugin Store on Vultr (https://45.77.105.187/plugins/).
/// TLS is pinned to the Vultr self-signed CA. The RedX session comes from the Keychain and is never shown.
final class VultrTLS: NSObject, URLSessionDelegate {
    static let caDER = Data(base64Encoded: "MIIDIjCCAgqgAwIBAgIUaVRVNfJipCztHOhJzGeD7YWW2zowDQYJKoZIhvcNAQELBQAwGDEWMBQGA1UEAwwNNDUuNzcuMTA1LjE4NzAeFw0yNjEwMjUxODI0MjlaFw0zNjEwMjIxODI0MjlaMBgxFjAUBgNVBAMMDTQ1Ljc3LjEwNS4xODcwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCo6ShhAc4sjRHmZKgSb3uPlb2Z049Lr6uc78UNJW4Ky5uAltux0dstX9K+dskPRKPvso5PMc9n6ieJ+MqKmiTBnPZA1zfwefYPxjBOHuisM0g26XXUWTEGxyGGxzvs17BzzyNwKLDxms/JwfGOFGjl3j9Wz4pO29c5PBDH2LPmeG5/WIpNFK8m7I7hTKeY7NWEQfKXYWrDoQUpiXevn25ieFFhR10DKo0P+Eks4q1EwkWcUDGGFZOJwVhRjSEKpjYna0LPZCRPdvhSvociyoDy/64uIoiWDlP1ytEbhZkJNyC35WBTAwwtifUa51to5InPwauyRUSG8ZI7pSjmEvdXAgMBAAGjZDBiMB0GA1UdDgQWBBQibQ2jP3yk/ftJewamqqqsxp2INzAPBgNVHRMBAf8EBTADAQH/MDAGA1UdEQQpMCeHBC1NabuCEnZvcnRleC5yZWQteGFpLmNvbYILcmVkLXhhaS5jb20wDQYJKoZIhvcNAQELBQADggEBACb3DL1ToCAi369SJBdwM2qOtzHiFD2pcemOlCoJHolEwnVIzGA7jdL42gHMARpG8VB6KsaL0VuL8tWsQueAwtVLDlsqHE2kzNt/DO34yHCMYziDGREvkXKuUE9z93dT3QwQjoN89PAA75FAj4U9ucGq7com5De3dBmaWr56bs1zoi0htCW+fBWHbGGkhq4YwntQyrr91bB3CKPzY2Z48hYhfF7roQbWPxgAb7ppXX6IuIVJQQIVV6wx4EeRzl8WpjEkhT0DXHfyhoPsdgYggPR2AWGDW1Y0hdSBk5wyRnG7VWXDbFzXwDXeAT+bnOMi6GpV/1xq75qKEskfAzkRpC0=")!
    static let session = URLSession(configuration: .ephemeral, delegate: VultrTLS(), delegateQueue: nil)
    func urlSession(_ s: URLSession, didReceive ch: URLAuthenticationChallenge, completionHandler done: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard ch.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let t = ch.protectionSpace.serverTrust,
              let ca = SecCertificateCreateWithData(nil, VultrTLS.caDER as CFData) else { done(.performDefaultHandling, nil); return }
        SecTrustSetAnchorCertificates(t, [ca] as CFArray); SecTrustSetAnchorCertificatesOnly(t, true)
        if SecTrustEvaluateWithError(t, nil) { done(.useCredential, URLCredential(trust: t)) } else { done(.cancelAuthenticationChallenge, nil) }
    }
}

struct StorePlugin: Identifiable, Hashable {
    var id: String; var name: String; var version: String; var description: String
    var author: String; var hasIcon: Bool; var icon: String; var installs: Int; var updated: String
    init(_ d: [String: Any]) {
        id = d["id"] as? String ?? ""; name = d["name"] as? String ?? id; version = d["version"] as? String ?? "1.0.0"
        description = d["description"] as? String ?? ""; author = (d["author"] as? String) ?? (d["uploader"] as? String) ?? "?"
        hasIcon = d["hasIcon"] as? Bool ?? false; icon = d["icon"] as? String ?? ""; installs = d["installs"] as? Int ?? 0; updated = d["updated"] as? String ?? ""
    }
}

enum StoreNet {
    static let signInMsg = "You must sign in to Red-XAI first to upload."
    static var root: String { AccountProfile.preferences.string(forKey: "pluginStoreRoot") ?? "https://45.77.105.187/plugins" }
    static func iconURL(_ p: StorePlugin) -> URL? { p.hasIcon && !p.icon.isEmpty ? URL(string: root + "/" + p.icon + "?v=" + (p.updated.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")) : nil }
    struct NeedSignIn: Error {}
    /// Returns (status, json). Throws NeedSignIn when auth is required and missing/rejected.
    static func req(_ method: String, _ path: String, body: [String: Any]? = nil, auth: Bool = true) async throws -> [String: Any] {
        guard let u = URL(string: root + "/v1/plugins" + path) else { throw err("Bad store URL") }
        var r = URLRequest(url: u); r.httpMethod = method; r.timeoutInterval = 30
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let tok = Keychain.get(account: "redx-session") ?? ""
        if auth { if tok.isEmpty { throw NeedSignIn() }; r.setValue(tok, forHTTPHeaderField: "X-RedX-Session") }
        else if !tok.isEmpty { r.setValue(tok, forHTTPHeaderField: "X-RedX-Session") }
        if let b = body { r.httpBody = try JSONSerialization.data(withJSONObject: b) }
        let (d, resp) = try await VultrTLS.session.data(for: r)
        let st = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        if st == 401 && auth { throw NeedSignIn() }
        guard (200..<300).contains(st) else { throw err((j["error"] as? String) ?? "HTTP \(st)") }
        return j
    }
    static func err(_ m: String) -> NSError { NSError(domain: "Vortex", code: 1, userInfo: [NSLocalizedDescriptionKey: m]) }
    /// Center-crop and scale any image to a 256×256 PNG data URL.
    static func fit256(_ img: NSImage) -> (String, String)? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = cg.width, h = cg.height, s = min(w, h)
        guard let crop = cg.cropping(to: CGRect(x: (w - s) / 2, y: (h - s) / 2, width: s, height: s)),
              let ctx = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high; ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 256, height: 256))
        guard let out = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) else { return nil }
        let note = (w == 256 && h == 256) ? "256×256 ✓" : "\(w)×\(h) → auto-fitted to 256×256"
        return ("data:image/png;base64," + png.base64EncodedString(), note)
    }
    static func defaultIcon() -> NSImage {
        if let u = Bundle.main.url(forResource: "redx-256", withExtension: "png"), let i = NSImage(contentsOf: u) { return i }
        let i = NSImage(size: NSSize(width: 256, height: 256)); i.lockFocus()
        NSColor(white: 0.08, alpha: 1).setFill(); NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 256, height: 256), xRadius: 48, yRadius: 48).fill()
        let p = NSBezierPath(); p.lineWidth = 44; p.lineCapStyle = .round
        p.move(to: NSPoint(x: 72, y: 72)); p.line(to: NSPoint(x: 184, y: 184)); p.move(to: NSPoint(x: 72, y: 184)); p.line(to: NSPoint(x: 184, y: 72))
        NSColor(red: 0.9, green: 0.1, blue: 0.12, alpha: 1).setStroke(); p.stroke(); i.unlockFocus(); return i
    }
}

/// Sign-in sheet used inline when an upload/edit needs a RedX session.
struct RedXSignInSheet: View {
    @ObservedObject var g = AccountGate.shared
    var onDone: (Bool) -> Void
    @Local var login = ""
    @Local var password = ""
    @Local var code = ""
    @Local var busy = false
    var body: some View {
        VStack(spacing: 12) {
            Text("Sign in to Red-XAI").font(.title3.bold())
            Text("Plugins are published under your RedX username.").font(.caption).foregroundStyle(.secondary)
            if g.flow.isEmpty {
                TextField("Username or email", text: $login).textFieldStyle(.roundedBorder)
                SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
            } else {
                TextField("6-digit code", text: $code).textFieldStyle(.roundedBorder)
                if g.call { Button("Call me") { Task { await g.callMe() } } }
            }
            if !g.msg.isEmpty { Text(g.msg).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Cancel") { g.flow = ""; password = ""; onDone(false) }
                Spacer()
                Button(busy ? "…" : (g.flow.isEmpty ? "Sign in" : "Verify")) {
                    busy = true
                    Task {
                        if g.flow.isEmpty { await g.login(login, password); password = "" } else { await g.twoFA(code); code = "" }
                        busy = false
                        if g.flow.isEmpty, let t = Keychain.get(account: "redx-session"), !t.isEmpty, g.signedIn { onDone(true) }
                    }
                }.buttonStyle(.borderedProminent).disabled(busy)
            }
        }.padding(24).frame(width: 340)
    }
}
