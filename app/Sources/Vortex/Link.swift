import SwiftUI
import Foundation

/// RedX Link: the default way to reach the RedX servers. No SSH needed — just a server address and an API key.
/// The bundled `redx-link` helper runs a local OpenAI-compatible proxy on 127.0.0.1 and speaks the
/// Red-SecretsXAI–encrypted RedX Link protocol to the servers, failing over between them.
/// The SSH tunnel stays available as an owner-only connection (admin/owner tools always use SSH).
@MainActor
final class RedXLink: ObservableObject {
    static let shared = RedXLink()
    static let port = 18191
    static let base = "http://127.0.0.1:\(port)"
    static let chatURL = base + "/v1"
    static let defaultPort = 8093

    @Published var running = false
    @Published var status = ""
    @Published var lastServers: [String] = []
    private var proc: Process?

    /// "link" (default) or "ssh" (owner-only tunnel).
    static var mode: String {
        get { UserDefaults.standard.string(forKey: "connectionMode") ?? "link" }
        set { UserDefaults.standard.set(newValue, forKey: "connectionMode") }
    }
    static var enabled: Bool { mode == "link" }
    static var binary: URL? {
        guard let u = Bundle.main.url(forResource: "redx-link", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: u.path) else { return nil }
        return u
    }

    /// host[:port] for a server's RedX Link endpoint (taken from its address; no SSH involved).
    static func address(_ s: ServerDef) -> String? {
        if let a = s.linkAddr?.trimmingCharacters(in: .whitespaces), !a.isEmpty { return a.contains(":") ? a : "\(a):\(defaultPort)" }
        guard let h = s.sshHost.split(separator: "@").last.map(String.init), !h.isEmpty, h != "YOUR_SERVER" else { return nil }
        return "\(h):\(defaultPort)"
    }

    /// Active server first, then the others: the helper fails over in this order.
    func serverList() -> [String] {
        let ss = ServerStore.shared
        let ordered = ss.servers.filter { $0.id == ss.activeID } + ss.servers.filter { $0.id != ss.activeID }
        return ordered.compactMap { Self.address($0) }
    }

    /// Start (or restart with a new failover order) the local helper. Never blocks the main thread.
    func start(force: Bool = false) {
        guard Self.enabled, let bin = Self.binary else { status = Self.binary == nil ? "redx-link helper missing from app bundle" : ""; return }
        let list = serverList()
        guard !list.isEmpty else { status = "no server address configured"; return }
        if !force, proc?.isRunning == true, list == lastServers { return }
        let old = proc; proc = nil; lastServers = list; running = false
        let log = ChatStore.dir.appendingPathComponent("redx-link.log")
        Task.detached(priority: .utility) {
            if let old, old.isRunning { old.terminate(); old.waitUntilExit() }
            // a stale helper from a previous app run may still own the port: ask it, never kill foreign processes
            if TunnelManager.portOpen(Self.port), old == nil {
                if await Self.statusOK() { await MainActor.run { RedXLink.shared.running = true; RedXLink.shared.status = "connected (existing helper)" }; return }
            }
            let p = Process(); p.executableURL = bin
            p.arguments = ["proxy", "-listen", "127.0.0.1:\(Self.port)", "-servers", list.joined(separator: ",")]
            p.standardOutput = FileHandle.nullDevice
            FileManager.default.createFile(atPath: log.path, contents: nil)
            p.standardError = try? FileHandle(forWritingTo: log)
            do { try p.run() } catch {
                await MainActor.run { RedXLink.shared.status = "could not start helper: \(error.localizedDescription)" }; return
            }
            for _ in 0..<20 where !TunnelManager.portOpen(Self.port) { try? await Task.sleep(for: .milliseconds(100)) }
            let ok = await Self.statusOK()
            await MainActor.run {
                RedXLink.shared.proc = p; RedXLink.shared.running = ok
                RedXLink.shared.status = ok ? "connected · \(list.count) server(s), encrypted with Red-SecretsXAI (forward secrecy)" : "helper started but not answering"
            }
        }
    }
    func stop() { proc?.terminate(); proc = nil; running = false }

    nonisolated static func statusOK() async -> Bool {
        guard let u = URL(string: base + "/link/status") else { return false }
        var r = URLRequest(url: u); r.timeoutInterval = 2
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        return j["ok"] as? Bool == true
    }

    /// Unauthenticated reachability check of one server's RedX Link port.
    nonisolated static func ping(_ addr: String) async -> Bool {
        guard let u = URL(string: "http://\(addr)/link/v1/ping") else { return false }
        var r = URLRequest(url: u); r.timeoutInterval = 5
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return String(data: d, encoding: .utf8)?.contains("\"rxl\"") == true
    }

    /// Runs `redx-link check` with the given key (off the main thread). Returns the JSON report.
    nonisolated static func check(key: String, servers: [String]) async -> [String: Any]? {
        guard let bin = await MainActor.run(body: { Self.binary }) else { return nil }
        return await Task.detached { () -> [String: Any]? in
            let p = Process(); p.executableURL = bin
            p.arguments = ["check", "-servers", servers.joined(separator: ",")]
            var env = ProcessInfo.processInfo.environment; env["REDX_LINK_KEY"] = key; p.environment = env
            let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        }.value
    }
}

/// Settings → Servers: connection type and API key. Plain users only need this box.
struct LinkSettingsBox: View {
    @StateObject var link = RedXLink.shared
    @StateObject var ss = ServerStore.shared
    @AppStorage("connectionMode") var mode = "link"
    @Local var keyText = ""
    @Local var addrEdit: [String: String] = [:]
    @Local var checking = false
    @Local var report = ""
    var body: some View {
        GroupBox("Connection") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Connect with", selection: $mode) {
                    Text("RedX Link (recommended — no SSH)").tag("link")
                    Text("SSH tunnel (owner only)").tag("ssh")
                }.pickerStyle(.radioGroup)
                .onChange(of: mode) { _, _ in if let a = ss.active { ss.activate(a.id) }; Task { await ChatStoreRef.refresh() } }
                if mode == "link" {
                    HStack(spacing: 6) {
                        Circle().fill(link.running ? .green : .orange).frame(width: 8, height: 8)
                        Text(link.status.isEmpty ? "starting…" : link.status).font(.caption)
                        Spacer()
                        Button(checking ? "Checking…" : "Check all servers") { runCheck() }.disabled(checking)
                        Button("Restart") { link.start(force: true) }
                    }
                    ForEach(ss.servers) { s in
                        HStack {
                            Text(s.name).frame(width: 130, alignment: .leading)
                            TextField("server address (host or host:port)", text: Binding(
                                get: { addrEdit[s.id] ?? (s.linkAddr ?? RedXLink.address(s) ?? "") },
                                set: { addrEdit[s.id] = $0 }))
                                .font(.caption.monospaced())
                            Button("Save") { ss.setLinkAddr(s.id, addrEdit[s.id] ?? ""); addrEdit[s.id] = nil }.disabled(addrEdit[s.id] == nil)
                        }
                    }
                    HStack {
                        SecureField("Your API key (redx_ai_… or redx_xai_…)", text: $keyText)
                        Button("Save key") { Keychain.set(keyText.trimmingCharacters(in: .whitespacesAndNewlines)); keyText = ""; Task { await ChatStoreRef.refresh() } }
                            .disabled(!(keyText.hasPrefix("redx_ai_") || keyText.hasPrefix("redx_xai_")))
                    }
                    if !report.isEmpty { Text(report).font(.caption.monospaced()).textSelection(.enabled) }
                    Text("Every request and reply is encrypted end-to-end with Red-SecretsXAI and authenticated with your API key (fresh session keys, replay protection). Apps on this Mac can use \(RedXLink.chatURL) with your key.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("SSH mode needs an SSH key on the server. Admin and owner tools always use SSH, whichever mode you pick.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(4)
        }
    }
    func runCheck() {
        checking = true; report = ""
        let servers = link.serverList(); let key = Keychain.get() ?? ""
        Task {
            let r = await RedXLink.check(key: key, servers: servers)
            let rows = (r?["results"] as? [[String: Any]] ?? []).map { x -> String in
                let n = x["server"] as? Int ?? 0
                if let e = x["error"] as? String { return "server \(n): ✗ \(e)" }
                return "server \(n): ✓ \(x["models"] as? Int ?? 0) models, \(x["ms"] as? Int ?? 0) ms"
            }
            report = rows.isEmpty ? "check failed (helper missing?)" : rows.joined(separator: "\n")
            checking = false
        }
    }
}
