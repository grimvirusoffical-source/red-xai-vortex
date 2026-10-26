import SwiftUI
import Foundation

/// First-run gate: accept the Terms (re-prompted when the version changes), then sign in with a red-xai.com account.
/// Sign-in goes straight to api.red-xai.com over HTTPS. The session token lives in the Keychain and is never shown.
/// The owner (a valid admin key on the owner's server) is exempt from sign-in.
@MainActor final class AccountGate: ObservableObject {
    static let shared = AccountGate()
    static let api = "https://api.red-xai.com/v1/accounts/"
    @Published var termsOK = UserDefaults.standard.string(forKey: "termsAccepted") == Terms.version
    @Published var signedIn = false
    @Published var owner = false
    @Published var checking = true
    @Published var username = UserDefaults.standard.string(forKey: "redxUser") ?? ""
    @Published var msg = ""
    @Published var flow = ""          // 2FA flow token (memory only)
    @Published var totp = false
    @Published var call = false
    @Published var selectedMethod = "totp"

    var ready: Bool { termsOK && (signedIn || owner) }

    func acceptTerms() { UserDefaults.standard.set(Terms.version, forKey: "termsAccepted"); termsOK = true }

    func check() async {
        checking = true; defer { checking = false }
        owner = await isOwner()
        if let approvedEmail = await VortexQuickLogin.shared.restore() {
            username = approvedEmail; signedIn = true
            UserDefaults.standard.set(username, forKey: "redxUser")
            return
        }
        guard let tok = Keychain.get(account: "redx-session"), !tok.isEmpty else { signedIn = false; return }
        let (st, m) = await call("me", session: tok)
        if st == 200, let a = m["account"] as? [String: Any] {
            username = (a["username"] as? String) ?? username; signedIn = true
            UserDefaults.standard.set(username, forKey: "redxUser")
        } else if st == 503 && !username.isEmpty {
            signedIn = true; msg = "RedX accounts unreachable; using your saved sign-in."   // offline grace
        } else { signedIn = false; Keychain.set("", account: "redx-session") }
    }

    func isOwner() async -> Bool {
        guard let k = Keychain.get(account: "admin-primary"), !k.isEmpty,
              let u = URL(string: (UserDefaults.standard.string(forKey: "adminBaseURL") ?? "http://127.0.0.1:18092") + "/admin/system") else { return false }
        var r = URLRequest(url: u, timeoutInterval: 6); r.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization")
        guard let (_, resp) = try? await URLSession.shared.data(for: r) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    func login(_ login: String, _ password: String) async {
        msg = ""
        let (st, m) = await call("login", body: ["login": login.trimmingCharacters(in: .whitespaces), "password": password])
        guard st == 200 else { msg = (m["message"] as? String) ?? "Sign-in failed."; return }
        switch m["next"] as? String {
        case "2fa":
            flow = (m["token"] as? String) ?? ""
            let me = m["methods"] as? [String: Any]; totp = (me?["totp"] as? Bool) ?? false; call = (me?["call"] as? Bool) ?? false
            selectedMethod = totp ? "totp" : "call"
            msg = totp ? "Enter the code from your authenticator app." : "Use “Call me” to get your code."
        case "2fa_setup": msg = "Finish setting up two-step sign-in on red-xai.com first, then come back."
        default: await finish((m["token"] as? String) ?? "")
        }
    }
    func callMe() async {
        let (st, m) = await call("login/call", flow: flow, body: [:])
        if st == 200 { selectedMethod = "call" }
        msg = st == 200 ? "Calling you now." : ((m["message"] as? String) ?? "The call could not be placed.")
    }
    func twoFA(_ code: String) async {
        let (st, m) = await call("login/2fa", flow: flow, body: ["method": selectedMethod, "code": code.trimmingCharacters(in: .whitespaces)])
        if st == 200, let t = m["token"] as? String, !t.isEmpty { flow = ""; await finish(t) }
        else {
            msg = (m["message"] as? String) ?? "That code was not accepted. Check your method and try again."
            if (m["error"] as? String) == "flow_expired" { flow = "" }
        }
    }
    func finish(_ tok: String) async {
        guard !tok.isEmpty else { msg = "Sign-in failed."; return }
        await VortexQuickLogin.shared.logout()
        Keychain.set(tok, account: "redx-session"); await check()
        if !signedIn { msg = "Sign-in could not be verified." } else { await MainActor.run { PhoneHost.sync() } }
    }
    func clearLegacyForQuick() async {
        if let t = Keychain.get(account: "redx-session"), !t.isEmpty {
            _ = await call("logout", session: t, body: [:])
            Keychain.set("", account: "redx-session")
        }
    }
    func signOut() async {
        await VortexQuickLogin.shared.logout()
        if let t = Keychain.get(account: "redx-session"), !t.isEmpty { _ = await call("logout", session: t, body: [:]) }
        Keychain.set("", account: "redx-session"); signedIn = false; username = ""; UserDefaults.standard.removeObject(forKey: "redxUser")
    }

    private func call(_ route: String, flow: String = "", session: String = "", body: [String: Any]? = nil) async -> (Int, [String: Any]) {
        var r = URLRequest(url: URL(string: Self.api + route)!, timeoutInterval: 15)
        r.setValue("application/json", forHTTPHeaderField: "accept"); r.setValue("application/json", forHTTPHeaderField: "content-type")
        if !flow.isEmpty { r.setValue(flow, forHTTPHeaderField: "X-RedX-Flow") }
        if !session.isEmpty { r.setValue(session, forHTTPHeaderField: "X-RedX-Session") }
        if let b = body { r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: b) }
        guard let (d, resp) = try? await URLSession.shared.data(for: r) else { return (503, ["message": "RedX accounts are not reachable right now."]) }
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:])
    }
}

struct GateView<Content: View>: View {
    @StateObject var g = AccountGate.shared
    @StateObject var quick = VortexQuickLogin.shared
    @ViewBuilder var content: () -> Content
    @Local var login = ""
    @Local var password = ""
    @Local var code = ""
    @Local var busy = false
    var body: some View {
        Group {
            if g.ready { content() }
            else if g.checking { ProgressView("Checking your sign-in…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if !g.termsOK { TermsView(requireAccept: true) }
            else { signIn }
        }
        .task { await g.check() }
    }
    var signIn: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text("Sign in to Red-XAI Vortex").font(.title2.bold())
            Text("Use your red-xai.com account.").foregroundStyle(.secondary)
            Button(quick.busy ? "Waiting for Red-XAI approval…" : "Quick sign in with Red-XAI") { quick.begin() }
                .buttonStyle(.borderedProminent).disabled(quick.busy || busy)
            if !quick.code.isEmpty {
                Text("Approval code: \(quick.code)").font(.headline.monospaced()).textSelection(.enabled)
                Button("Cancel approval") { quick.cancel() }.buttonStyle(.bordered)
            }
            if !quick.message.isEmpty { Text(quick.message).font(.callout).foregroundStyle(.secondary).frame(width: 360) }
            Text("Or use your password").font(.caption).foregroundStyle(.secondary)
            if g.flow.isEmpty {
                TextField("Username or email", text: $login).textFieldStyle(.roundedBorder).frame(width: 300)
                SecureField("Password", text: $password).textFieldStyle(.roundedBorder).frame(width: 300).onSubmit { go() }
                Button(busy ? "Signing in…" : "Sign in") { go() }.buttonStyle(.borderedProminent).disabled(busy || login.isEmpty || password.isEmpty)
            } else {
                if g.totp || g.call { TextField("6-digit code", text: $code).textFieldStyle(.roundedBorder).frame(width: 200) }
                HStack {
                    if g.call { Button("Call me") { Task { await g.callMe() } } }
                    if g.totp && g.selectedMethod == "call" {
                        Button("Use authenticator") { g.selectedMethod = "totp"; g.msg = "Enter the code from your authenticator app." }
                    }
                    Button("Verify") { busy = true; Task { await g.twoFA(code); busy = false; code = "" } }.buttonStyle(.borderedProminent).disabled(code.isEmpty || busy)
                }
            }
            if !g.msg.isEmpty { Text(g.msg).font(.callout).foregroundStyle(.orange).frame(width: 340) }
            HStack(spacing: 16) {
                Link("Create an account", destination: URL(string: "https://red-xai.com/")!)
                Link("Terms", destination: URL(string: "https://45.77.105.187/vortex/terms")!)
                Link("Donate", destination: URL(string: "https://45.77.105.187/vortex/donate")!)
            }.font(.caption)
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    func go() { busy = true; Task { await g.login(login, password); password = ""; busy = false } }
}

struct TermsView: View {
    var requireAccept = false
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(requireAccept ? "Please read and accept the Terms of Service" : "Terms of Service").font(.title2.bold())
            ScrollView { Text(.init(Terms.text)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8) }
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
            HStack {
                Text("Version \(Terms.version)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if requireAccept {
                    Button("Decline and Quit") { NSApp.terminate(nil) }
                    Button("Accept") { AccountGate.shared.acceptTerms() }.buttonStyle(.borderedProminent)
                }
            }
        }.padding(24).frame(minWidth: 560, minHeight: 480)
    }
}

/// About: ownership notice + donate link.
struct AboutVortexView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 80, height: 80)
            Text("Red-XAI Vortex").font(.title.bold())
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))").foregroundStyle(.secondary)
            Text("Red-XAI Vortex is property of Red-XAI LLC. Our business registration is currently pending approval.")
                .multilineTextAlignment(.center).frame(width: 360)
            if !AccountGate.shared.username.isEmpty { Text("Signed in as \(AccountGate.shared.username)").font(.caption) }
            HStack {
                Link("Terms & Privacy", destination: URL(string: "https://45.77.105.187/vortex/terms")!)
                Link("Donate", destination: URL(string: "https://45.77.105.187/vortex/donate")!)
            }
        }.padding(30)
    }
}
