import SwiftUI

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
            Button("Refresh") { Task { await loadAudit() } }
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
    func loadAudit() async {
        events = ((try? await Admin.call("GET", "/admin/audit?n=200"))?["events"] as? [[String: Any]]) ?? []
    }
}
