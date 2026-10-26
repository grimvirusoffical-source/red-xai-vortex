import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Small owner-password prompt shown where an action needs owner unlock (e.g. creating API keys).
struct OwnerUnlockInline: View {
    var onUnlocked: () -> Void = {}
    @StateObject private var gate = OwnerGate.shared
    @Local var pw = ""
    var body: some View {
        HStack {
            Image(systemName: "lock.fill").foregroundStyle(.orange)
            SecureField("Owner password to unlock", text: $pw).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            Button(gate.busy ? "Checking…" : "Unlock") {
                Task { await gate.unlock(password: pw); pw = ""; if gate.unlocked { onUnlocked() } }
            }.disabled(pw.isEmpty || gate.busy)
            if !gate.message.isEmpty { Text(gate.message).font(.caption).foregroundStyle(.red) }
        }
    }
}

/// Edit access for one key: models, rate, expiry, enable/disable, role, downloads, IP rules.
struct KeyEditSheet: View {
    let key: APIKeyRow
    let models: [String]
    @EnvironmentObject var hub: HubStore
    @Environment(\.dismiss) var dismiss
    @Local var allowed: Set<String> = []
    @Local var rpm = 60
    @Local var disabled = false
    @Local var role = "user"
    @Local var canDownload = false
    @Local var expiryDays = -1   // -1 = keep
    @Local var ipAllow = ""
    @Local var ipDeny = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Access for \(key.name)").font(.title3.bold())
            Text(key.prefix).font(.caption.monospaced()).foregroundStyle(.secondary)
            Toggle("Enabled", isOn: Binding(get: { !disabled }, set: { disabled = !$0 }))
            Stepper("\(rpm) requests/min", value: $rpm, in: 1...10000, step: 10)
            Picker("Expiry", selection: $expiryDays) {
                Text(key.expires.map { "Keep (\($0.formatted(date: .abbreviated, time: .omitted)))" } ?? "Keep (never)").tag(-1)
                Text("Never").tag(0); Text("1 day").tag(1); Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90); Text("1 year").tag(365)
            }
            Picker("Role", selection: $role) { Text("User").tag("user"); Text("Admin").tag("admin") }.pickerStyle(.segmented)
            Toggle("Can download models to the server", isOn: $canDownload)
            Text("Allowed models (none ticked = all)").font(.headline)
            ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))], alignment: .leading) {
                ForEach(models, id: \.self) { m in
                    Toggle(m, isOn: Binding(get: { allowed.contains(m) }, set: { if $0 { allowed.insert(m) } else { allowed.remove(m) } }))
                }
            } }.frame(height: 140)
            TextField("IP allow (comma-separated IPs/CIDRs, empty = any)", text: $ipAllow)
            TextField("IP deny (comma-separated IPs/CIDRs)", text: $ipDeny)
            if !hub.keyError.isEmpty {
                Text(hub.keyError).font(.caption).foregroundStyle(.red)
                if hub.keyError.contains("owner unlock") { OwnerUnlockInline { hub.keyError = "" } }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    var b: [String: Any] = ["models": Array(allowed), "rpm": rpm, "disabled": disabled, "role": role, "can_download": canDownload,
                                            "ip_allow": split(ipAllow), "ip_deny": split(ipDeny)]
                    if expiryDays >= 0 { b["expires_days"] = expiryDays }
                    Task { await hub.patchKey(key.id, b); if hub.keyError.isEmpty { dismiss() } }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 620)
        .onAppear {
            allowed = Set(key.models); rpm = key.rpm; disabled = key.disabled; role = key.role == "user" ? "user" : "admin"
            canDownload = key.canDownload; ipAllow = key.ipAllow.joined(separator: ", "); ipDeny = key.ipDeny.joined(separator: ", ")
        }
    }
    func split(_ s: String) -> [String] { s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
}

/// Owner panel: global IP allow/deny and the gateway audit log.
struct AccessControlSection: View {
    @Local var allow = ""
    @Local var deny = ""
    @Local var events: [[String: Any]] = []
    @Local var msg = ""
    @Local var auditMessage = ""
    @Local var auditBusy = false
    var body: some View {
        Section("IP allow / deny (whole gateway)") {
            TextField("Allow (IPs/CIDRs, empty = any; 127.0.0.1 is always kept)", text: $allow)
            TextField("Deny (IPs/CIDRs)", text: $deny)
            HStack {
                Button("Save IP rules") { Task { await save() } }
                if !msg.isEmpty { Text(msg).font(.caption).foregroundStyle(msg.hasPrefix("Saved") ? .green : .red) }
            }
        }
        Section("Audit log (newest first)") {
            Text("Only the newest 10 entries are kept. Older entries are removed automatically when new activity arrives. Mark all as read deletes the displayed logs.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Refresh") { Task { await loadAudit() } }.disabled(auditBusy)
                Button("Mark all as read") { Task { await clearDisplayedAudit() } }
                    .disabled(auditBusy || events.isEmpty)
                    .help("Delete these displayed entries. New activity is retained.")
                Button("Export JSON and delete…") { Task { await exportDisplayedAudit() } }
                    .disabled(auditBusy || events.isEmpty)
            }
            if !auditMessage.isEmpty { Text(auditMessage).font(.caption).foregroundStyle(.secondary) }
            if events.isEmpty { Text("No audit entries.").foregroundStyle(.secondary) }
            ForEach(Array(events.prefix(100).enumerated()), id: \.offset) { _, e in
                let t = Date(timeIntervalSince1970: (e["t"] as? Double) ?? 0)
                HStack(alignment: .top) {
                    Text(t.formatted(date: .omitted, time: .standard)).font(.caption.monospaced()).frame(width: 80, alignment: .leading)
                    Text(e["action"] as? String ?? "").font(.caption.bold()).frame(width: 110, alignment: .leading)
                    Text("\(e["method"] as? String ?? "") \(e["path"] as? String ?? "")").font(.caption.monospaced()).lineLimit(1)
                    Spacer()
                    Text("\(e["name"] as? String ?? "–") · \(e["ip"] as? String ?? "")").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task { await load(); await loadAudit() }
    }
    func split(_ s: String) -> [String] { s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    func load() async {
        if let j = try? await Admin.call("GET", "/admin/acl") {
            allow = (j["allow"] as? [String] ?? []).joined(separator: ", "); deny = (j["deny"] as? [String] ?? []).joined(separator: ", ")
        }
    }
    func save() async {
        do { _ = try await Admin.call("POST", "/admin/acl", ["allow": split(allow), "deny": split(deny)]); msg = "Saved."; await load() }
        catch { msg = error.localizedDescription }
    }
    @MainActor func loadAudit() async {
        do {
            let result = try await Admin.call("GET", "/admin/audit?n=10")
            events = (result["events"] as? [[String: Any]]) ?? []
        } catch { auditMessage = error.localizedDescription }
    }
    var displayedAuditIDs: [String] { events.compactMap { $0["id"] as? String } }
    @MainActor func clearDisplayedAudit() async {
        let ids = displayedAuditIDs
        guard !auditBusy, !ids.isEmpty else { return }
        auditBusy = true; defer { auditBusy = false }
        do {
            let result = try await Admin.call("POST", "/admin/audit/clear", ["ids": ids])
            events = (result["events"] as? [[String: Any]]) ?? []
            auditMessage = "Displayed logs deleted. New activity is retained."
        } catch { auditMessage = error.localizedDescription }
    }
    @MainActor func exportDisplayedAudit() async {
        let ids = displayedAuditIDs
        guard !auditBusy, !ids.isEmpty else { return }
        auditBusy = true; defer { auditBusy = false }
        do {
            var snapshot = try await Admin.call("POST", "/admin/audit/export", ["ids": ids])
            guard let token = snapshot.removeValue(forKey: "snapshotToken") as? String else {
                throw NSError(domain: "audit", code: 1, userInfo: [NSLocalizedDescriptionKey: "The server did not provide an export confirmation. No entries were deleted."])
            }
            snapshot.removeValue(forKey: "ok")
            let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
            let panel = NSSavePanel()
            panel.title = "Save owner audit log"
            panel.nameFieldStringValue = "vortex-owner-audit-\(Int(Date().timeIntervalSince1970)).json"
            panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let url = panel.url else {
                auditMessage = "Export canceled. No entries were deleted."
                return
            }
            // Confirm deletion only after the atomic local save succeeds.
            try OwnerAuditExport.save(data, to: url)
            do {
                let result = try await Admin.call("POST", "/admin/audit/export/confirm", ["snapshotToken": token, "saved": true])
                events = (result["events"] as? [[String: Any]]) ?? []
                auditMessage = "JSON saved. Exported logs deleted; new activity is retained."
            } catch { auditMessage = "JSON saved, but server deletion was not confirmed: \(error.localizedDescription)" }
        } catch { auditMessage = "Export failed. No entries were deleted: \(error.localizedDescription)" }
    }
}

/// Separate from the save panel so failed local writes can be tested safely.
enum OwnerAuditExport {
    static func save(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
