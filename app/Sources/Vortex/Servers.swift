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
    var baseURL: String { "http://127.0.0.1:\(localPort)/v1" }
    var keychainAccount: String { primary ? "admin-primary" : "admin-\(id)" }
}

extension Keychain {
    static func get(account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func set(_ value: String, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
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
            let ud = UserDefaults.standard
            servers = [ServerDef(name: "Main server", sshHost: ud.string(forKey: "sshHost") ?? Defaults.sshHost,
                                 keyPath: ud.string(forKey: "sshKey") ?? "~/.ssh/id_ed25519", localPort: Defaults.sshLocalPort, primary: true)]
            save()
        }
        if Keychain.get(account: "admin-primary") == nil, let k = Keychain.get() { Keychain.set(k, account: "admin-primary") }
        activeID = UserDefaults.standard.string(forKey: "activeServer") ?? servers[0].id
        if !servers.contains(where: { $0.id == activeID }) { activeID = servers[0].id }
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
        activeID = id; UserDefaults.standard.set(id, forKey: "activeServer")
        UserDefaults.standard.set(s.baseURL, forKey: "serverURL")
        Keychain.set(key(for: s))   // chat + hub use the "api-key" entry of the active server
        ensureTunnel(s)
    }

    func ping(_ s: ServerDef) async -> Bool {
        ensureTunnel(s)
        for _ in 0..<6 {
            if let u = URL(string: s.baseURL + "/models") {
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
        let port = (servers.map(\.localPort).max() ?? 18092) + 1
        servers.append(ServerDef(name: name, sshHost: host, keyPath: keyPath, localPort: port)); save()
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
                if c2 == 0 && key.hasPrefix("redx_ai_") {
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
    @AppStorage("autoFailover") var autoFailover = true
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupBox("Add a server (Ubuntu/Debian VPS with SSH key login)") {
                HStack {
                    TextField("Name", text: $name).frame(width: 140)
                    TextField("user@host", text: $host)
                    TextField("SSH key", text: $keyPath).frame(width: 170)
                    Button("Add") { ss.add(name: name.isEmpty ? host : name, host: host, keyPath: keyPath); name = ""; host = "" }
                        .disabled(!host.contains("@"))
                }.padding(4)
            }
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
            Text("Install / Update runs the bundled server installer over SSH: llama.cpp, the gateway and the model manager. Nothing is opened to the internet; Red-XAI Vortex talks to each server through its own SSH tunnel.").font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .sheet(item: $keyEdit) { s in
            VStack(alignment: .leading, spacing: 10) {
                Text("Admin key for \(s.name)").font(.headline)
                SecureField("redx_ai_… (from /root/dolphino-admin.key)", text: $keyText)
                HStack { Spacer(); Button("Cancel") { keyEdit = nil }
                    Button("Save") { Keychain.set(keyText, account: s.keychainAccount); if s.id == ss.activeID { Keychain.set(keyText) }; keyEdit = nil }.disabled(!keyText.hasPrefix("redx_ai_")) }
            }.padding(20).frame(width: 460)
        }
    }
}
