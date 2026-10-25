import SwiftUI
import AppKit
import CryptoKit
import IOKit
import Security

/// Stable device id: rsx/SHA-256 of the Mac hardware UUID (hex). Same digest the gateway expects.
enum DeviceID {
    static let header = "X-Vortex-Device"
    static let value: String = {
        let uuid = hardwareUUID() ?? "unknown"
        let dig = SHA256.hash(data: Data(uuid.utf8))
        return dig.map { String(format: "%02x", $0) }.joined()
    }()

    static func hardwareUUID() -> String? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard let cf = IORegistryEntryCreateCFProperty(svc, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { return nil }
        return cf as? String
    }

    static func publicIP() async -> String {
        guard let u = URL(string: "https://api.ipify.org"),
              let (d, _) = try? await URLSession.shared.data(from: u),
              let s = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return "" }
        return s
    }
}

/// Nuclear option after the server returns wipe:true (3 bad owner passwords).
/// Do NOT call this from tests on the owner's real Mac — only when the gateway says so.
enum OwnerWipe {
    static func run() {
        let fm = FileManager.default
        let app = "/Applications/Red-XAI Vortex.app"
        try? fm.removeItem(atPath: app)
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? fm.removeItem(at: support.appendingPathComponent("Red-XAI Vortex"))
            try? fm.removeItem(at: support.appendingPathComponent("Vortex"))
        }
        // Keychain: all items for our service
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Keychain.service]
        SecItemDelete(q as CFDictionary)
        let q2: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.redxai.vortex"]
        SecItemDelete(q2 as CFDictionary)
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}

@MainActor
final class OwnerGate: ObservableObject {
    static let shared = OwnerGate()
    @Published var unlocked = false
    @Published var configured = false
    @Published var busy = false
    @Published var message = ""
    @Published var remaining: Int?

    func refresh() async {
        do {
            let r = try await Admin.call("GET", "/admin/owner/status")
            configured = r["configured"] as? Bool ?? false
            unlocked = r["unlocked"] as? Bool ?? false
            if r["banned"] as? Bool == true { OwnerWipe.run(); return }
        } catch {
            message = error.localizedDescription
        }
    }

    func unlock(password: String) async {
        busy = true; defer { busy = false }
        let ip = await DeviceID.publicIP()
        do {
            let r = try await Admin.call("POST", "/admin/owner/unlock", [
                "password": password,
                "device_id": DeviceID.value,
                "client_ip": ip
            ])
            if r["wipe"] as? Bool == true || r["banned"] as? Bool == true {
                message = "Too many failed attempts — this device is banned."
                OwnerWipe.run()
                return
            }
            if r["ok"] as? Bool == true {
                unlocked = true; message = ""; remaining = nil
            } else {
                remaining = r["remaining"] as? Int
                message = "Wrong password. \(remaining.map { "\($0) tries left." } ?? "")"
            }
        } catch let e as NSError {
            // Admin.call throws on HTTP >= 300; body may be in the description — re-fetch via raw
            if e.code == 403 {
                message = "Banned — wiping local app data."
                OwnerWipe.run()
                return
            }
            if e.code == 401 {
                // parse remaining from a status follow-up is hard; show generic
                message = e.localizedDescription.contains("remaining") ? e.localizedDescription : "Wrong password."
                return
            }
            message = e.localizedDescription
        }
    }

    func lock() async {
        _ = try? await Admin.call("POST", "/admin/owner/lock")
        unlocked = false
    }
}

struct OwnerPanelView: View {
    @StateObject private var gate = OwnerGate.shared
    @Local var password = ""
    @Local var bans: [String: Any] = [:]
    @EnvironmentObject var hub: HubStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Owner Panel").font(.title2.bold())
            Text("VPS downloads, servers/nodes, learning, keys, storage and bans. Locked with your owner password (checked on the server).")
                .font(.caption).foregroundStyle(.secondary)
            if !gate.configured {
                Label("Owner password is not configured on the server yet.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if !gate.unlocked {
                SecureField("Owner password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                HStack {
                    Button(gate.busy ? "Checking…" : "Unlock") {
                        Task {
                            await gate.unlock(password: password)
                            password = ""
                            if gate.unlocked { await loadBans(); hub.refreshAll() }
                        }
                    }.disabled(gate.busy || password.isEmpty).keyboardShortcut(.defaultAction)
                    if let r = gate.remaining { Text("\(r) tries left").foregroundStyle(.red) }
                }
                if !gate.message.isEmpty { Text(gate.message).foregroundStyle(.red).font(.caption) }
                Text("After 3 wrong tries this Mac is banned on the server, the app deletes itself, and you need SSH: vortex-ban clear")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                HStack {
                    Label("Unlocked", systemImage: "lock.open.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Lock") { Task { await gate.lock() } }
                }
                Form {
                    Section("VPS model downloads") {
                        Text("Use the Library tab to pull or remove models on the VPS. Those actions require this unlock.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Open Library") { UserDefaults.standard.set("library", forKey: "hubTab") }
                    }
                    Section("Servers / nodes") {
                        Button("Open Servers") { UserDefaults.standard.set("servers", forKey: "hubTab") }
                    }
                    Section("Learning & storage") {
                        Button("Open Vortex") { UserDefaults.standard.set("redxai", forKey: "hubTab") }
                    }
                    Section("API keys") {
                        Button("Open API Keys") { UserDefaults.standard.set("keys", forKey: "hubTab") }
                    }
                    AccessControlSection()
                    Section("Bans") {
                        if let ips = bans["ips"] as? [String], let devs = bans["devices"] as? [String] {
                            Text("Banned IPs: \(ips.isEmpty ? "none" : ips.joined(separator: ", "))")
                            Text("Banned devices: \(devs.isEmpty ? "none" : "\(devs.count)")")
                        }
                        Button("Refresh bans") { Task { await loadBans() } }
                        Text("SSH recovery (on the VPS): vortex-ban list | vortex-ban clear")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }.formStyle(.grouped)
            }
        }
        .padding()
        .task { await gate.refresh() }
    }

    func loadBans() async {
        bans = (try? await Admin.call("GET", "/admin/owner/bans")) ?? [:]
    }
}
