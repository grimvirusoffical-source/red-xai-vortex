import Foundation
import SwiftUI
import Combine
import AppKit

struct HostedBaseGrant: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var credentialID: UUID
    var expiresAt: String
    var scopes: [String]
}
struct HostedBaseConfiguration: Identifiable, Codable, Equatable {
    var id: UUID
    var httpsAlias = ""
    var quotaMiB = 2048
    var grants: [HostedBaseGrant] = []
}
struct HostedBaseStatus: Equatable {
    var running = false
    var endpoint = ""
    var hostID = ""
    var message = "Stopped"
}

/// Owns only helper processes started by this app. It never configures a router, firewall or tunnel.
@MainActor final class ManagedBaseHosting: ObservableObject {
    static let shared = ManagedBaseHosting()
    @Published var statuses: [UUID: HostedBaseStatus] = [:]
    @Published var busy: Set<UUID> = []
    private var processes: [UUID: Process] = [:]
    private var fingerprints: [UUID: Data] = [:]
    private var watcher: AnyCancellable?
    let workspace: WorkspaceStore
    var helperURL: URL? {
        if let path = ProcessInfo.processInfo.environment["VORTEX_BASE_HELPER"], FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        if let url = Bundle.main.resourceURL?.appendingPathComponent("vortex-base"), FileManager.default.isExecutableFile(atPath: url.path) { return url }
        return nil
    }
    init(workspace: WorkspaceStore? = nil) {
        let workspace = workspace ?? WorkspaceStore.shared
        self.workspace = workspace
        workspace.willDeleteBase = { [weak self] id in self?.deletePublishedBase(id) }
        watcher = workspace.$state.debounce(for: .milliseconds(500), scheduler: RunLoop.main).sink { [weak self] _ in
            Task { @MainActor in await self?.syncRunningBases() }
        }
    }
    func folder(_ id: UUID) -> URL { workspace.directory.appendingPathComponent("hosting", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true) }
    func hostDirectory(_ id: UUID) -> URL { folder(id).appendingPathComponent("host", isDirectory: true) }
    func configuration(_ id: UUID) -> HostedBaseConfiguration { workspace.state.hosting.first { $0.id == id } ?? HostedBaseConfiguration(id: id) }
    func updateConfiguration(_ value: HostedBaseConfiguration) {
        if let i = workspace.state.hosting.firstIndex(where: { $0.id == value.id }) { workspace.state.hosting[i] = value } else { workspace.state.hosting.append(value) }
        workspace.save()
    }
    nonisolated static func snapshot(base: XAIBase, assetPath: (WorkspaceAsset) -> String?) throws -> Data {
        var sources: [[String: Any]] = []
        let formatter = ISO8601DateFormatter()
        for asset in base.sources where asset.sourceAvailable != false {
            var row: [String: Any] = ["id": asset.id.uuidString, "name": asset.name, "kind": asset.kind, "text": asset.text ?? "", "bytes": asset.bytes, "updatedAt": formatter.string(from: asset.updatedAt)]
            if let mime = asset.mimeType { row["mimeType"] = mime }
            if let url = asset.sourceURL { row["url"] = try BaseClient.documentCitation(url) ?? "" }
            if let path = assetPath(asset) { row["attachmentPath"] = path }
            sources.append(row)
        }
        return try JSONSerialization.data(withJSONObject: ["name": base.name, "sources": sources], options: [.sortedKeys])
    }
    private func run(_ args: [String]) async throws -> Data {
        guard let helper = helperURL else { throw WorkspaceStore.error("This build does not contain the Base host helper. Install a packaged Vortex release to host a Base.") }
        return try await Task.detached(priority: .utility) {
            let process = Process(), output = Pipe()
            process.executableURL = helper; process.arguments = args; process.standardOutput = output; process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw WorkspaceStore.error("The Base helper could not complete the operation. Check available storage and the host configuration.") }
            return Data(data.prefix(1 << 20))
        }.value
    }
    private func ensureInitialized(_ base: XAIBase) async throws {
        let location = folder(base.id)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: location.path)
        if !FileManager.default.fileExists(atPath: hostDirectory(base.id).appendingPathComponent("catalog.json").path) {
            _ = try await run(["init", "-dir", hostDirectory(base.id).path, "-name", base.name, "-quota-mib", String(configuration(base.id).quotaMiB)])
        }
        if !workspace.state.hosting.contains(where: { $0.id == base.id }) { updateConfiguration(configuration(base.id)) }
    }
    private func sync(_ base: XAIBase) async throws {
        let data = try Self.snapshot(base: base) { workspace.assetURL($0)?.path }
        if fingerprints[base.id] == data { return }
        try await ensureInitialized(base)
        let file = folder(base.id).appendingPathComponent("snapshot.json")
        try data.write(to: file, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        _ = try await run(["sync", "-dir", hostDirectory(base.id).path, "-snapshot", file.path])
        fingerprints[base.id] = data
    }
    private func syncRunningBases() async {
        let present = Set(workspace.state.bases.map(\.id))
        for id in processes.keys where !present.contains(id) { stop(id) }
        for base in workspace.state.bases where !base.isRemote && processes[base.id]?.isRunning == true && !busy.contains(base.id) {
            do { try await sync(base) } catch { statuses[base.id]?.message = "Source sync failed. The previous hosted revision remains available." }
        }
    }
    func start(_ id: UUID) async {
        guard !busy.contains(id), processes[id]?.isRunning != true, let base = workspace.state.bases.first(where: { $0.id == id }), !base.isRemote else { return }
        busy.insert(id); defer { busy.remove(id) }
        do {
            guard let helper = helperURL else { throw WorkspaceStore.error("The packaged Base host helper is unavailable in this build.") }
            try await sync(base)
            let ready = folder(id).appendingPathComponent("ready.json"); try? FileManager.default.removeItem(at: ready)
            let process = Process(), pipe = Pipe()
            process.executableURL = helper; process.arguments = ["serve", "-dir", hostDirectory(id).path, "-listen", "127.0.0.1:0", "-ready-file", ready.path, "-parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
            process.standardOutput = pipe; process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { handle in if handle.availableData.isEmpty { handle.readabilityHandler = nil } }
            process.terminationHandler = { [weak self] ended in Task { @MainActor in
                guard self?.processes[id]?.processIdentifier == ended.processIdentifier else { return }
                self?.processes.removeValue(forKey: id); self?.statuses[id] = HostedBaseStatus(message: "Stopped")
            } }
            try process.run(); processes[id] = process; statuses[id] = HostedBaseStatus(message: "Starting private host…")
            struct Ready: Decodable { var endpoint: String; var baseID: String; var pid: Int32 }
            for _ in 0..<100 {
                if let data = try? Data(contentsOf: ready), let result = try? JSONDecoder().decode(Ready.self, from: data), result.pid == process.processIdentifier {
                    let endpoint = try BaseClient.endpoint(result.endpoint)
                    guard endpoint.host == "127.0.0.1", endpoint.scheme == "http" else { throw WorkspaceStore.error("The Base helper returned an unexpected listener.") }
                    statuses[id] = HostedBaseStatus(running: true, endpoint: endpoint.absoluteString, hostID: result.baseID, message: "Hosting privately · sources sync automatically")
                    return
                }
                guard process.isRunning else { throw WorkspaceStore.error("The Base host stopped before it became ready.") }
                try await Task.sleep(for: .milliseconds(100))
            }
            stop(id); throw WorkspaceStore.error("The Base host did not become ready in time.")
        } catch { statuses[id] = HostedBaseStatus(message: error.localizedDescription); workspace.errorMessage = error.localizedDescription }
    }
    func stop(_ id: UUID) {
        if let process = processes[id], process.isRunning { process.terminate() }
        processes.removeValue(forKey: id); statuses[id] = HostedBaseStatus(message: "Stopped")
    }
    func stopAll() { for id in Array(processes.keys) { stop(id) } }
    func deletePublishedBase(_ id: UUID) {
        stop(id)
        for grant in configuration(id).grants { try? BaseCredentials.set(nil, for: grant.credentialID) }
        workspace.state.hosting.removeAll { $0.id == id }; fingerprints.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: folder(id)); workspace.save()
    }
    func createGrant(_ id: UUID, name: String, days: Int) async {
        guard processes[id]?.isRunning == true else { workspace.errorMessage = "Start the private Base host before creating an invite."; return }
        guard !busy.contains(id), (1...365).contains(days), let base = workspace.state.bases.first(where: { $0.id == id }), !base.isRemote else { return }
        busy.insert(id); defer { busy.remove(id) }
        do {
            try await sync(base)
            let path = folder(id).appendingPathComponent("invite-" + UUID().uuidString + ".token")
            defer { try? FileManager.default.removeItem(at: path) }
            struct GrantResult: Decodable { var id: String; var scopes: [String]; var expiresAt: String }
            let data = try await run(["grant", "-json", "-dir", hostDirectory(id).path, "-name", name.isEmpty ? "Read-only invite" : name, "-out", path.path, "-scopes", "read,search", "-days", String(days)])
            let result = try JSONDecoder().decode(GrantResult.self, from: data)
            let grant = GrantStatus(id: result.id, name: name.isEmpty ? "Read-only invite" : name, expiresAt: result.expiresAt, scopes: result.scopes)
            let token = try String(contentsOf: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), credential = UUID()
            do { try BaseCredentials.set(token, for: credential) } catch { _ = try? await run(["revoke", "-dir", hostDirectory(id).path, "-id", grant.id]); throw error }
            var config = configuration(id)
            config.grants.append(HostedBaseGrant(id: grant.id, name: grant.name, credentialID: credential, expiresAt: grant.expiresAt, scopes: grant.scopes)); updateConfiguration(config)
        } catch { workspace.errorMessage = error.localizedDescription }
    }
    private struct GrantStatus: Decodable { var id: String; var name: String; var expiresAt: String; var scopes: [String] }
    private func grantStatus(_ id: UUID) async throws -> [GrantStatus] {
        struct Status: Decodable { var grants: [GrantStatus] }
        return try JSONDecoder().decode(Status.self, from: await run(["status", "-dir", hostDirectory(id).path])).grants
    }
    func revoke(_ id: UUID, grant: HostedBaseGrant) async {
        do {
            _ = try await run(["revoke", "-dir", hostDirectory(id).path, "-id", grant.id]); try BaseCredentials.set(nil, for: grant.credentialID)
            var config = configuration(id); config.grants.removeAll { $0.id == grant.id }; updateConfiguration(config)
        } catch { workspace.errorMessage = error.localizedDescription }
    }
    func copyInvite(_ id: UUID, grant: HostedBaseGrant) {
        do {
            guard let base = workspace.state.bases.first(where: { $0.id == id }), let token = BaseCredentials.get(grant.credentialID), !token.isEmpty else { throw WorkspaceStore.error("This invite token is unavailable in Keychain. Create a new grant.") }
            let alias = configuration(id).httpsAlias.trimmingCharacters(in: .whitespacesAndNewlines)
            let endpoint: String
            if alias.isEmpty { guard let local = statuses[id], local.running else { throw WorkspaceStore.error("Start the private host or configure its existing HTTPS tunnel alias before copying an invite.") }; endpoint = local.endpoint }
            else { guard let parsed = try BaseClient.documentCitation(alias), try BaseClient.endpoint(parsed).scheme == "https" else { throw WorkspaceStore.error("Use an HTTPS sharing alias for an existing private tunnel.") }; endpoint = parsed }
            let data = try JSONSerialization.data(withJSONObject: ["format": "vortex-base-invite", "version": 1, "name": base.name, "endpoint": endpoint, "token": token, "grantID": grant.id, "expiresAt": grant.expiresAt], options: .prettyPrinted)
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
            statuses[id]?.message = "Invite copied. It contains a read token; share it privately."
        } catch { workspace.errorMessage = error.localizedDescription }
    }
}

struct ManagedBaseHostingView: View {
    let baseID: UUID
    @ObservedObject var hosting = ManagedBaseHosting.shared
    @Local var inviteName = ""
    @Local var days = 30
    var body: some View {
        let status = hosting.statuses[baseID] ?? HostedBaseStatus()
        let config = hosting.configuration(baseID)
        GroupBox("Host this Base from this Mac") {
            VStack(alignment: .leading, spacing: 10) {
                Label(status.message, systemImage: status.running ? "dot.radiowaves.left.and.right" : "power").font(.callout)
                Text("The bundled host listens only on this Mac. Imported sources sync automatically while running. To share with another PC, provide an existing private HTTPS tunnel or reverse-proxy alias. Vortex does not open your router or publish a public endpoint.").font(.caption).foregroundStyle(.secondary)
                HStack { Button(status.running ? "Stop hosting" : "Start private host") { if status.running { hosting.stop(baseID) } else { Task { await hosting.start(baseID) } } }.disabled(hosting.busy.contains(baseID)); if status.running { Text("Private listener ready").font(.caption).foregroundStyle(.green) } }
                TextField("Existing HTTPS sharing alias (optional)", text: Binding(get: { hosting.configuration(baseID).httpsAlias }, set: { value in var c = hosting.configuration(baseID); c.httpsAlias = value; hosting.updateConfiguration(c) }))
                HStack { TextField("Invite name", text: $inviteName); Stepper("\(days) days", value: $days, in: 1...365); Button("Create read-only invite") { Task { await hosting.createGrant(baseID, name: inviteName, days: days) } }.disabled(hosting.busy.contains(baseID) || !status.running) }
                ForEach(config.grants) { grant in HStack { VStack(alignment: .leading) { Text(grant.name); Text("Read + search · expires " + grant.expiresAt).font(.caption2).foregroundStyle(.secondary) }; Spacer(); Button("Copy invite") { hosting.copyInvite(baseID, grant: grant) }; Button("Revoke", role: .destructive) { Task { await hosting.revoke(baseID, grant: grant) } } } }
            }.padding(8)
        }
    }
}
