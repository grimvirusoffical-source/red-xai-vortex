import SwiftUI
import Foundation

/// A model server (VPS) reached through its own SSH tunnel to the gateway admin port.
struct ServerDef: Identifiable, Codable, Hashable {
    var id = UUID().uuidString
    var name: String
    var sshHost: String          // user@host
    var keyPath: String = "~/.ssh/id_ed25519"
    var localPort: Int
    var remotePort: Int = 8092
    var primary = false          // the original server: uses the "api-key" Keychain entry
    var linkAddr: String?        // RedX Link address (host[:port]); nil = derive from sshHost
    /// Admin API (8092) through the SSH tunnel — Hub / Owner / keys / pulls.
    var baseURL: String { "http://127.0.0.1:\(localPort)/v1" }
    var adminBase: String { "http://127.0.0.1:\(localPort)" }
    /// Public keyed API (8091). When the tunnel maps admin on localPort, public is localPort-1 (18091).
    var chatURL: String {
        if remotePort == 8092 { return "http://127.0.0.1:\(localPort - 1)/v1" }
        return baseURL
    }
    var keychainAccount: String { primary ? "admin-primary" : "admin-\(id)" }
}

extension Keychain {
    static func get(account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: AccountProfile.credentialAccount(account), kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func set(_ value: String, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: AccountProfile.credentialAccount(account)]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base; add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

@MainActor
final class ServerStore: ObservableObject {
    static let shared = ServerStore()
    @Published var servers: [ServerDef] = []
    @Published var activeID: String = ""
    @Published var installLog: [String: String] = [:]
    @Published var installing: Set<String> = []
    @Published var health: [String: Bool] = [:]
    var tunnels: [String: TunnelManager] = [:]
    private var file: URL { ChatStore.dir.appendingPathComponent("servers.json") }

    init() {
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode([ServerDef].self, from: d), !s.isEmpty { servers = s }
        else {
            let ud = AccountProfile.preferences
            servers = [ServerDef(name: "Main server", sshHost: ud.string(forKey: "sshHost") ?? Defaults.sshHost,
                                 keyPath: ud.string(forKey: "sshKey") ?? "~/.ssh/id_ed25519", localPort: Defaults.sshLocalPort, primary: true)]
            save()
        }
        // Model credentials are never promoted into owner/admin credentials.
        repair()
        activeID = AccountProfile.preferences.string(forKey: "activeServer") ?? servers[0].id
        if !servers.contains(where: { $0.id == activeID }) { activeID = servers[0].id }
        startMonitor()
        // Never stay on a server whose SSH host is unusable; fall back to the primary.
        if let a = active, !Self.validHost(a.sshHost), let p = servers.first(where: { $0.primary }) { activate(p.id) }
        if AccountGate.shared.ready && RedXLink.enabled {
            AccountProfile.preferences.set(RedXLink.chatURL, forKey: "serverURL")
            Task { @MainActor in RedXLink.shared.start() }
        }
    }
    func setLinkAddr(_ id: String, _ a: String) {
        guard let i = servers.firstIndex(where: { $0.id == id }) else { return }
        let v = a.trimmingCharacters(in: .whitespaces)
        servers[i].linkAddr = v.isEmpty ? nil : v; save(); RedXLink.shared.start(force: true)
    }
    /// SSH tunnels are owner-only: start them only when this Mac has the SSH key.
    static func hasSSHKey(_ s: ServerDef) -> Bool { FileManager.default.fileExists(atPath: (s.keyPath as NSString).expandingTildeInPath) }
    static func validHost(_ h: String) -> Bool { h.range(of: "^[A-Za-z0-9._-]+@[A-Za-z0-9.:-]+$", options: .regularExpression) != nil }
    static func normalizeHost(_ h: String) -> String {
        var s = h.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("@") { s = "root" + s } else if !s.contains("@") && !s.isEmpty { s = "root@" + s }
        return s
    }
    /// Fix entries saved by older builds: "@host" with no user, and local ports whose chat port (local-1)
    /// collided with another server's admin port.
    private func repair() {
        var changed = false, used = Set<Int>()
        for i in servers.indices {
            let h = Self.normalizeHost(servers[i].sshHost); if h != servers[i].sshHost { servers[i].sshHost = h; changed = true }
            var p = servers[i].localPort
            while used.contains(p) || used.contains(p - 1) { p += 2 }
            if p != servers[i].localPort { servers[i].localPort = p; changed = true }
            used.insert(p); used.insert(p - 1)
        }
        if changed { save() }
    }
    /// After launch: if the active server's tunnel can't come up but the primary answers, switch back.
    func healthCheckActive() async {
        guard let a = active else { return }
        if await ping(a) { return }
        if a.primary { if await failover() != nil { await ChatStoreRef.refresh() }; return }
        guard let p = servers.first(where: { $0.primary }) else { return }
        if await ping(p) { activate(p.id); await ChatStoreRef.refresh() }
    }
    /// Runs for the app's lifetime: every 30 s, if the active server stops answering, switch to the next
    /// reachable one (respecting the auto-failover toggle); when the primary returns, prefer it again.
    private var monitor: Task<Void, Never>?
    func startMonitor() {
        guard monitor == nil else { return }
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, AccountProfile.preferences.object(forKey: "autoFailover") as? Bool ?? true, let a = self.active else { continue }
                if await self.ping(a) {
                    if !a.primary, let p = self.servers.first(where: { $0.primary }), await self.ping(p) { self.activate(p.id); await ChatStoreRef.refresh() }
                    continue
                }
                if await self.failover() != nil { await ChatStoreRef.refresh() }
            }
        }
    }
    func save() { if let d = try? JSONEncoder().encode(servers) { try? d.write(to: file, options: .atomic) } }
    var active: ServerDef? { servers.first { $0.id == activeID } }
    func key(for s: ServerDef) -> String { Keychain.get(account: s.keychainAccount) ?? "" }
    func server(_ id: String) -> ServerDef? { servers.first { $0.id == id } }

    func tunnel(_ s: ServerDef) -> TunnelManager {
        if let t = tunnels[s.id] { return t }
        let t = TunnelManager(); tunnels[s.id] = t; return t
    }
    func ensureTunnel(_ s: ServerDef) {
        let t = tunnel(s)
        if !t.running { t.start(host: s.sshHost, local: s.localPort, remote: s.remotePort, keyPath: s.keyPath) }
    }
    func stopAll() { tunnels.values.forEach { $0.stop() } }

    func activate(_ id: String) {
        guard let s = server(id) else { return }
        activeID = id; AccountProfile.preferences.set(id, forKey: "activeServer")
        // Chat: RedX Link proxy (default) or the public gateway port through SSH (18091). Admin stays on localPort (18092).
        AccountProfile.preferences.set(RedXLink.enabled ? RedXLink.chatURL : s.chatURL, forKey: "serverURL")
        AccountProfile.preferences.set(s.adminBase, forKey: "adminBaseURL")
        let k = key(for: s)
        if !k.isEmpty {
            // RedX Link: one link-enabled key serves every server, so failover keeps the chat key.
            if !RedXLink.enabled { Keychain.set(k) }  // chat api-key
            Keychain.set(k, account: s.keychainAccount)
            if s.primary { Keychain.set(k, account: "admin-primary") }
        }
        if AccountGate.shared.ready && RedXLink.enabled { RedXLink.shared.start() }
        if !RedXLink.enabled || Self.hasSSHKey(s) { ensureTunnel(s) }
    }

    func ping(_ s: ServerDef) async -> Bool {
        if RedXLink.enabled, let a = RedXLink.address(s) {
            if await RedXLink.ping(a) { health[s.id] = true; return true }
            if !Self.hasSSHKey(s) { health[s.id] = false; return false }
        }
        ensureTunnel(s)
        for _ in 0..<6 {
            // Prefer the public chat port — that is what the chat window needs.
            if let u = URL(string: s.chatURL + "/models") {
                var r = URLRequest(url: u); r.timeoutInterval = 4
                r.setValue("Bearer \(key(for: s))", forHTTPHeaderField: "Authorization")
                if let (_, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 { health[s.id] = true; return true }
            }
            try? await Task.sleep(for: .milliseconds(700))
        }
        health[s.id] = false; return false
    }

    /// Switch to the next reachable server. Returns its base URL, or nil if none answered.
    func failover() async -> ServerDef? {
        let order = servers.filter { $0.id != activeID }
        for s in order where await ping(s) { activate(s.id); return s }
        return nil
    }

    func add(name: String, host: String, keyPath: String) {
        let h = Self.normalizeHost(host); guard Self.validHost(h) else { return }
        let port = (servers.map(\.localPort).max() ?? 18092) + 2      // each server uses a pair: admin = port, chat = port-1
        servers.append(ServerDef(name: name.isEmpty ? h : name, sshHost: h, keyPath: keyPath, localPort: port)); save()
    }
    func remove(_ id: String) {
        guard let s = server(id), !s.primary else { return }
        tunnels[id]?.stop(); tunnels[id] = nil
        Keychain.set("", account: s.keychainAccount)
        servers.removeAll { $0.id == id }; save()
        if activeID == id { activate(servers[0].id) }
    }

    /// One click: copy install.sh over SSH, run it, then fetch the admin key into the Keychain.
    func install(_ s: ServerDef) {
        guard let script = Bundle.main.url(forResource: "install", withExtension: "sh") else { installLog[s.id] = "install.sh missing from app bundle"; return }
        installing.insert(s.id); installLog[s.id] = "Connecting to \(s.sshHost)…\n"
        let kp = (s.keyPath as NSString).expandingTildeInPath
        Task.detached {
            func ssh(_ remote: String, stdin: URL? = nil, stream: Bool) -> (Int32, String) {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                p.arguments = ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-i", kp, s.sshHost, remote]
                if let stdin { p.standardInput = try? FileHandle(forReadingFrom: stdin) }
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
                var all = ""
                pipe.fileHandleForReading.readabilityHandler = { h in
                    let t = String(data: h.availableData, encoding: .utf8) ?? ""
                    all += t
                    if stream && !t.isEmpty { Task { @MainActor in ServerStore.shared.installLog[s.id, default: ""] += t } }
                }
                try? p.run(); p.waitUntilExit()
                pipe.fileHandleForReading.readabilityHandler = nil
                return (p.terminationStatus, all)
            }
            let (code, _) = ssh("sudo -n true 2>/dev/null || [ $(id -u) = 0 ] || exit 9; sudo bash -s 2>&1 || bash -s", stdin: script, stream: true)
            var msg = code == 0 ? "\nInstall finished.\n" : "\nInstall failed (exit \(code)).\n"
            if code == 0 {
                let (c2, k) = ssh("sudo cat /root/dolphino-admin.key 2>/dev/null || cat /root/dolphino-admin.key", stream: false)
                let key = k.trimmingCharacters(in: .whitespacesAndNewlines)
                if c2 == 0 && (key.hasPrefix("redx_ai_") || key.hasPrefix("redx_xai_")) {
                    Keychain.set(key, account: s.keychainAccount); msg += "Admin key saved to Keychain.\n"
                } else { msg += "Could not read the admin key; paste it in the server's settings.\n" }
            }
            await MainActor.run {
                ServerStore.shared.installLog[s.id, default: ""] += msg
                ServerStore.shared.installing.remove(s.id)
            }
        }
    }
}

struct ServersView: View {
    @StateObject var ss = ServerStore.shared
    @Local var name = ""
    @Local var host = ""
    @Local var keyPath = "~/.ssh/id_ed25519"
    @Local var keyEdit: ServerDef?
    @Local var keyText = ""
    @AppStorage("autoFailover", store: AccountProfile.preferences) var autoFailover = true
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LinkSettingsBox()
            GroupBox("Add a server (Ubuntu/Debian VPS with SSH key login)") {
                HStack {
                    TextField("Name", text: $name).frame(width: 140)
                    TextField("user@host (root@ is assumed)", text: $host)
                    TextField("SSH key", text: $keyPath).frame(width: 170)
                    Button("Add") { ss.add(name: name.isEmpty ? host : name, host: host, keyPath: keyPath); name = ""; host = "" }
                        .disabled(!ServerStore.validHost(ServerStore.normalizeHost(host)))
                }.padding(4)
            }
            if let a = ss.active { ServerStatsView(server: a).id(a.id) }
            Toggle("Fail over automatically to another server (or this Mac) when the current one stops answering", isOn: $autoFailover)
            List(ss.servers) { s in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle().fill(ss.health[s.id] == true ? .green : ss.health[s.id] == false ? .red : .gray).frame(width: 8, height: 8)
                        Text(s.name).font(.headline)
                        Text(s.sshHost).font(.caption.monospaced()).foregroundStyle(.secondary)
                        if s.id == ss.activeID { Text("ACTIVE").font(.caption2.bold()).padding(.horizontal, 5).background(Capsule().fill(.green.opacity(0.25))) }
                        Spacer()
                        Button("Check") { Task { _ = await ss.ping(s) } }
                        if s.id != ss.activeID { Button("Use") { ss.activate(s.id); Task { await ChatStoreRef.refresh() } } }
                        Button(ss.installing.contains(s.id) ? "Installing…" : "Install / Update") { ss.install(s) }.disabled(ss.installing.contains(s.id))
                        Button("Key…") { keyEdit = s; keyText = "" }
                        if !s.primary { Button(role: .destructive) { ss.remove(s.id) } label: { Image(systemName: "trash") } }
                    }
                    if let log = ss.installLog[s.id], !log.isEmpty {
                        ScrollView { Text(String(log.suffix(4000))).font(.caption2.monospaced()).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                            .frame(height: 120).background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
                    }
                }.padding(.vertical, 4)
            }
            Text("Install / Update runs the bundled server installer over SSH: llama.cpp, the gateway and the model manager. Only the encrypted RedX Link port is open to the internet; admin tools reach each server through its own SSH tunnel.").font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .sheet(item: $keyEdit) { s in
            VStack(alignment: .leading, spacing: 10) {
                Text("Admin key for \(s.name)").font(.headline)
                SecureField("redx_ai_… or redx_xai_… (from /root/dolphino-admin.key)", text: $keyText)
                HStack { Spacer(); Button("Cancel") { keyEdit = nil }
                    Button("Save") { Keychain.set(keyText, account: s.keychainAccount); if s.id == ss.activeID { Keychain.set(keyText) }; keyEdit = nil }.disabled(!(keyText.hasPrefix("redx_ai_") || keyText.hasPrefix("redx_xai_"))) }
            }.padding(20).frame(width: 460)
        }
    }
}
