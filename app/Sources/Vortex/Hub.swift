import SwiftUI
import AppKit

// MARK: - Admin API (gateway admin port, reached through the SSH tunnel)
enum Admin {
    static var base: String {
        let s = UserDefaults.standard.string(forKey: "serverURL") ?? Defaults.serverURL
        var b = s.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if b.hasSuffix("/v1") { b.removeLast(3) }
        return b
    }
    static func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let u = URL(string: base + path) else { throw URLError(.badURL) }
        var r = URLRequest(url: u); r.httpMethod = method; r.timeoutInterval = 120
        r.setValue("Bearer \(Keychain.get() ?? "")", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(DeviceID.value, forHTTPHeaderField: DeviceID.header)
        if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (d, resp) = try await URLSession.shared.data(for: r)
        let j = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        if let h = resp as? HTTPURLResponse, h.statusCode >= 300 {
            if h.statusCode == 403, (j["wipe"] as? Bool == true) || (j["banned"] as? Bool == true) ||
                ((j["error"] as? [String: Any])?["message"] as? String)?.contains("banned") == true {
                await MainActor.run { OwnerWipe.run() }
            }
            // unlock failures include remaining in the JSON body
            if path.hasSuffix("/owner/unlock"), j["ok"] != nil { return j }
            let m = ((j["error"] as? [String: Any])?["message"] as? String)
                ?? (j["remaining"] != nil ? "Wrong password. \(j["remaining"] ?? "") tries left." : nil)
                ?? "HTTP \(h.statusCode)"
            throw NSError(domain: "Vortex", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: m])
        }
        if let e = j["error"] as? String { throw NSError(domain: "Vortex", code: 1, userInfo: [NSLocalizedDescriptionKey: e]) }
        return j
    }
}

func gbString(_ b: Double) -> String { String(format: "%.1f GB", b / 1e9) }
func copyToClipboard(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }

struct CatalogModel: Identifiable {
    var id: String; var name: String; var category: String; var about: String; var license: String
    var bytes: Double; var ram: Double; var speed: String; var installed: Bool; var fits: Bool; var pullable: Bool
}
struct MergeDef: Identifiable, Hashable {
    var id: String { name }
    var name: String; var mode: String; var models: [String]; var judge: String; var note: String
    var dict: [String: Any] { ["name": name, "mode": mode, "models": models, "judge": judge, "note": note] }
    var stepCount: Int { mode == "router" ? 1 : mode == "draft_refine" ? 2 : models.count + 1 }
}
struct APIKeyRow: Identifiable {
    var id: String; var name: String; var prefix: String; var models: [String]; var rpm: Int
    var created: Date; var lastUsed: Date?; var revoked: Bool; var requests: Int; var tokens: Int
}

@MainActor
final class HubStore: ObservableObject {
    static let shared = HubStore()
    @Published var catalog: [CatalogModel] = []
    @Published var defaultModel = ""
    @Published var modelsBytes: Double = 0
    @Published var diskFree: Double = 0
    @Published var capBytes: Double = 200e9
    @Published var jobs: [String: (done: Double, total: Double, state: String)] = [:]
    @Published var merges: [MergeDef] = []
    @Published var keys: [APIKeyRow] = []
    @Published var error = ""
    @Published var busy: Set<String> = []
    private var poll: Task<Void, Never>?

    static let categories: [(String, String, String)] = [
        ("general", "General chat", "bubble.left.and.bubble.right"), ("coding", "Coding", "chevron.left.forwardslash.chevron.right"),
        ("reasoning", "Reasoning", "brain"), ("fast", "Fast & small", "hare"), ("vision", "Vision", "eye"),
        ("writing", "Writing & roleplay", "pencil.and.outline"), ("multilingual", "Multilingual", "globe"),
        ("embeddings", "Embeddings", "point.3.connected.trianglepath.dotted")]

    func run(_ f: @escaping () async throws -> Void) { Task { do { try await f(); error = "" } catch { self.error = error.localizedDescription } } }

    func refreshAll() { run { try await self.loadCatalog(); try await self.loadMerges(); try await self.loadKeys() } }

    func loadCatalog() async throws {
        let c = try await Admin.call("GET", "/admin/catalog")
        let l = try await Admin.call("GET", "/admin/models")
        catalog = (c["catalog"] as? [[String: Any]] ?? []).map {
            CatalogModel(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "", category: $0["category"] as? String ?? "",
                         about: $0["about"] as? String ?? "", license: $0["license"] as? String ?? "",
                         bytes: ($0["bytes"] as? Double) ?? 0, ram: ($0["ram_bytes"] as? Double) ?? 0, speed: $0["speed"] as? String ?? "",
                         installed: $0["installed"] as? Bool ?? false, fits: $0["fits"] as? Bool ?? true, pullable: $0["pullable"] as? Bool ?? false)
        }
        defaultModel = l["default"] as? String ?? ""
        modelsBytes = l["models_bytes"] as? Double ?? 0
        diskFree = l["disk_free"] as? Double ?? 0
        capBytes = l["cap_bytes"] as? Double ?? 200e9
    }
    func loadJobs() async throws {
        let j = try await Admin.call("GET", "/admin/jobs")
        var out: [String: (Double, Double, String)] = [:]
        for x in j["jobs"] as? [[String: Any]] ?? [] {
            out[x["id"] as? String ?? ""] = ((x["done"] as? Double) ?? 0, (x["total"] as? Double) ?? 1, x["state"] as? String ?? "")
        }
        jobs = out.mapValues { (done: $0.0, total: $0.1, state: $0.2) }
    }
    func pull(_ id: String) {
        busy.insert(id)
        run {
            _ = try await Admin.call("POST", "/admin/models/pull", ["id": id])
            self.startPolling()
        }
    }
    func startPolling() {
        poll?.cancel()
        poll = Task {
            while !Task.isCancelled {
                try? await loadJobs()
                let active = jobs.values.contains { $0.state == "downloading" }
                if !active {
                    try? await loadCatalog(); busy.removeAll()
                    await ChatStoreRef.refresh()
                    break
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    func remove(_ id: String) {
        busy.insert(id)
        run {
            let r = try await Admin.call("DELETE", "/admin/models/\(id)")
            if let f = r["freed_bytes"] as? Double { self.error = "Removed \(id), freed \(gbString(f))" }
            try await self.loadCatalog(); self.busy.remove(id)
            await ChatStoreRef.refresh()
        }
    }
    func setDefault(_ id: String) {
        run {
            _ = try await Admin.call("POST", "/admin/default", ["id": id]); self.defaultModel = id
            UserDefaults.standard.set(id, forKey: "model")
        }
    }

    func loadMerges() async throws {
        let j = try await Admin.call("GET", "/admin/merges")
        merges = (j["merges"] as? [[String: Any]] ?? []).map {
            MergeDef(name: $0["name"] as? String ?? "", mode: $0["mode"] as? String ?? "router", models: $0["models"] as? [String] ?? [],
                     judge: $0["judge"] as? String ?? "", note: $0["note"] as? String ?? "")
        }
    }
    func saveMerge(_ m: MergeDef) { run { _ = try await Admin.call("POST", "/admin/merges", m.dict); try await self.loadMerges(); await ChatStoreRef.refresh() } }
    func deleteMerge(_ n: String) { run { _ = try await Admin.call("DELETE", "/admin/merges/\(n)"); try await self.loadMerges(); await ChatStoreRef.refresh() } }

    func loadKeys() async throws {
        let j = try await Admin.call("GET", "/admin/keys")
        keys = (j["keys"] as? [[String: Any]] ?? []).map {
            let lu = ($0["last_used"] as? Double) ?? 0
            return APIKeyRow(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "", prefix: $0["prefix"] as? String ?? "",
                      models: $0["models"] as? [String] ?? [], rpm: ($0["rpm"] as? Int) ?? 60,
                      created: Date(timeIntervalSince1970: ($0["created"] as? Double) ?? 0),
                      lastUsed: lu > 0 ? Date(timeIntervalSince1970: lu) : nil, revoked: (($0["revoked"] as? Double) ?? 0) > 0,
                      requests: ($0["requests"] as? Int) ?? 0, tokens: ($0["tokens"] as? Int) ?? 0)
        }
    }
    func createKey(name: String, models: [String], rpm: Int, xaiScopes: [String]? = nil) async -> String? {
        do {
            var b: [String: Any] = ["name": name, "models": models, "rpm": rpm]
            if let s = xaiScopes { b["kind"] = "xai"; b["scopes"] = s }
            let r = try await Admin.call("POST", "/admin/keys", b)
            try await loadKeys(); error = ""
            return r["key"] as? String
        } catch { self.error = error.localizedDescription; return nil }
    }
    func revoke(_ id: String) { run { _ = try await Admin.call("DELETE", "/admin/keys/\(id)"); try await self.loadKeys() } }
}

/// Lets the hub tell the chat window to refresh its model list.
enum ChatStoreRef {
    @MainActor static weak var store: ChatStore?
    @MainActor static func refresh() async {
        if let m = try? await API.models(base: UserDefaults.standard.string(forKey: "serverURL") ?? Defaults.serverURL, key: Keychain.get() ?? ""), !m.isEmpty {
            store?.availableModels = m
        }
        try? await HubStore.shared.loadMerges()
    }
}

// MARK: - Hub window
struct HubView: View {
    @StateObject var hub = HubStore.shared
    @AppStorage("hubTab") var tab = "library"
    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $tab) {
                LibraryView().tabItem { Label("Library", systemImage: "books.vertical") }.tag("library")
                MergesView().tabItem { Label("Merges", systemImage: "arrow.triangle.merge") }.tag("merges")
                RedXAIView().tabItem { Label("Vortex", systemImage: "sparkles") }.tag("redxai")
                ServersView().tabItem { Label("Servers", systemImage: "server.rack") }.tag("servers")
                ProvidersView().tabItem { Label("Providers", systemImage: "cloud") }.tag("providers")
                KeysView().tabItem { Label("API Keys", systemImage: "key") }.tag("keys")
                OwnerPanelView().tabItem { Label("Owner", systemImage: "lock.shield") }.tag("owner")
                DocsView().tabItem { Label("Use in Other Apps", systemImage: "app.connected.to.app.below.fill") }.tag("docs")
                IntegrationsView().tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }.tag("integrations")
                HelpView().tabItem { Label("Help", systemImage: "questionmark.circle") }.tag("help")
            }
            if !hub.error.isEmpty {
                HStack { Image(systemName: "info.circle"); Text(hub.error).lineLimit(2); Spacer(); Button("Dismiss") { hub.error = "" } }
                    .font(.caption).padding(8).background(.yellow.opacity(0.15))
            }
        }
        .environmentObject(hub)
        .frame(minWidth: 820, minHeight: 560)
        .onAppear { hub.refreshAll(); hub.startPolling() }
    }
}

struct LibraryView: View {
    @EnvironmentObject var hub: HubStore
    @Local var filter = "all"
    @Local var confirmRemove: CatalogModel?
    var shown: [CatalogModel] {
        switch filter { case "all": return hub.catalog; case "installed": return hub.catalog.filter(\.installed)
        default: return hub.catalog.filter { $0.category == filter } }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: $filter) {
                    Text("All").tag("all"); Text("Installed").tag("installed")
                    ForEach(HubStore.categories, id: \.0) { Text($0.1).tag($0.0) }
                }.frame(width: 220)
                Spacer()
                ProgressView(value: min(hub.modelsBytes, hub.capBytes), total: hub.capBytes).frame(width: 160)
                Text("Models \(gbString(hub.modelsBytes)) of \(gbString(hub.capBytes)) · disk free \(gbString(hub.diskFree))").font(.caption).foregroundStyle(.secondary)
                Button { ModelBrowserServer.shared.open() } label: { Label("Browse Models", systemImage: "safari") }
                Button { hub.refreshAll() } label: { Image(systemName: "arrow.clockwise") }
            }.padding([.horizontal, .top])
            List {
                ForEach(HubStore.categories, id: \.0) { cat in
                    let items = shown.filter { $0.category == cat.0 }
                    if !items.isEmpty {
                        Section { ForEach(items) { row($0) } } header: { Label(cat.1, systemImage: cat.2) }
                    }
                }
            }
        }
        .confirmationDialog("Uninstall \(confirmRemove?.name ?? "")?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button("Uninstall and free \(gbString(confirmRemove?.bytes ?? 0))", role: .destructive) { if let m = confirmRemove { hub.remove(m.id) }; confirmRemove = nil }
        } message: {
            Text(confirmRemove?.pullable == false ? "This model isn't in the download catalog, so it can't be re-downloaded from here." : "The file is deleted from the server. You can download it again any time.")
        }
    }
    @ViewBuilder func row(_ m: CatalogModel) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(m.name).font(.headline)
                    if m.id == hub.defaultModel { Text("DEFAULT").font(.caption2.bold()).padding(.horizontal, 5).background(Capsule().fill(.green.opacity(0.25))) }
                    if m.installed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Installed") }
                }
                Text(m.about).font(.caption).foregroundStyle(.secondary)
                Text("\(gbString(m.bytes)) download · needs \(gbString(m.ram)) RAM · \(m.speed) · \(m.license)").font(.caption2).foregroundStyle(.secondary)
                if let j = hub.jobs[m.id], j.state == "downloading" {
                    ProgressView(value: j.done, total: max(j.total, 1)) { Text("Downloading \(Int(j.done / max(j.total, 1) * 100))%").font(.caption2) }.frame(maxWidth: 320)
                } else if let j = hub.jobs[m.id], j.state == "error" {
                    Text("Download failed").font(.caption2).foregroundStyle(.red)
                }
            }
            Spacer()
            if m.installed {
                if m.category != "embeddings" && m.id != hub.defaultModel { Button("Set Default") { hub.setDefault(m.id) } }
                Button(role: .destructive) { confirmRemove = m } label: { Label("Uninstall", systemImage: "trash") }
                    .disabled(hub.busy.contains(m.id))
            } else if hub.jobs[m.id]?.state == "downloading" || hub.busy.contains(m.id) {
                ProgressView().controlSize(.small)
            } else {
                Button { hub.pull(m.id) } label: { Label("Download", systemImage: "arrow.down.circle") }
                    .disabled(!m.fits || !m.pullable).help(m.fits ? "" : "Too big for the server's RAM")
            }
        }.padding(.vertical, 4)
    }
}

struct MergesView: View {
    @EnvironmentObject var hub: HubStore
    @StateObject var ps = ProviderStore.shared
    @Local var picked: [String] = []
    @Local var mode = "panel_judge"
    @Local var judge = ""
    @Local var name = ""
    @Local var filter = ""
    var all: [(String, String)] {
        hub.catalog.filter { $0.installed && $0.category != "embeddings" }.map { ($0.id, "Server · \($0.category)") } +
        ps.providers.flatMap { p in p.models.map { ($0.id, "Provider · \(p.name) · \($0.name)") } }
    }
    static let modes = [("draft_refine", "Draft + Refine", "Model #1 drafts fast, model #2 improves it. Pick exactly 2."),
                        ("panel_judge", "Panel + Judge", "2–3 models answer, the judge picks or combines the best."),
                        ("router", "Router", "Auto-picks one per message: code → coder, reasoning → reasoner, else general.")]
    var valid: Bool {
        name.range(of: "^[a-z0-9-]{1,32}$", options: .regularExpression) != nil && !picked.isEmpty && picked.count <= 3 &&
        (mode != "draft_refine" || picked.count == 2) && (mode != "panel_judge" || (picked.count >= 2 && !judge.isEmpty))
    }
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                Text("1. Tick up to 3 models").font(.headline)
                TextField("Filter", text: $filter)
                List(all.filter { filter.isEmpty || $0.0.localizedCaseInsensitiveContains(filter) }, id: \.0) { m in
                    Toggle(isOn: Binding(get: { picked.contains(m.0) }, set: { on in
                        if on { if picked.count < 3 { picked.append(m.0) } } else { picked.removeAll { $0 == m.0 } } })) {
                        VStack(alignment: .leading) {
                            HStack { Text(m.0); if let i = picked.firstIndex(of: m.0) { Text("#\(i + 1)").font(.caption.bold()).foregroundStyle(.secondary) } }
                            Text(m.1).font(.caption2).foregroundStyle(.secondary)
                        }
                    }.disabled(!picked.contains(m.0) && picked.count >= 3)
                }
                Text("2. Mode and judge").font(.headline)
                Picker("Mode", selection: $mode) { ForEach(Self.modes, id: \.0) { Text($0.1).tag($0.0) } }.pickerStyle(.segmented)
                Text(Self.modes.first { $0.0 == mode }?.2 ?? "").font(.caption).foregroundStyle(.secondary)
                if mode == "panel_judge" {
                    Picker("Judge", selection: $judge) { Text("Choose…").tag(""); ForEach(all, id: \.0) { Text($0.0).tag($0.0) } }
                }
                HStack {
                    TextField("Name (a-z, 0-9, -)", text: $name)
                    Button { hub.saveMerge(MergeDef(name: name, mode: mode, models: picked, judge: mode == "panel_judge" ? judge : "", note: ""))
                        picked = []; name = ""; judge = "" } label: { Label("Merge", systemImage: "arrow.triangle.merge") }
                        .buttonStyle(.borderedProminent).disabled(!valid)
                }
                Text("Steps run one after another so they fit in RAM; time ≈ the sum of each model's reply.").font(.caption2).foregroundStyle(.secondary)
            }.padding().frame(minWidth: 380)
            VStack(alignment: .leading) {
                Text("Merged models").font(.headline).padding([.top, .horizontal])
                List(hub.merges) { m in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("redx-merge-\(m.name)").font(.body.monospaced())
                            Text((Self.modes.first { $0.0 == m.mode }?.1 ?? m.mode) + " · " + m.models.joined(separator: ", ") + (m.judge.isEmpty ? "" : " · judge \(m.judge)")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Use") { UserDefaults.standard.set("redx-merge-\(m.name)", forKey: "model") }
                        Button(role: .destructive) { hub.deleteMerge(m.name) } label: { Label("Remove", systemImage: "trash") }
                    }
                }
            }.frame(minWidth: 320)
        }
        .task { await ps.load() }
    }
}

struct KeysView: View {
    @EnvironmentObject var hub: HubStore
    @Local var newName = ""
    @Local var rpm = 60
    @Local var restrict = false
    @Local var allowed: Set<String> = []
    @Local var shownKey: String?
    @Local var xai = false
    @Local var scopes: Set<String> = ["chat"]
    @Local var confirmRevoke: APIKeyRow?
    @StateObject var ps = ProviderStore.shared
    var modelIDs: [String] { hub.catalog.filter(\.installed).map(\.id) + ps.extModelIDs + hub.merges.map { "redx-merge-\($0.name)" } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupBox("Create a key for an app") {
                VStack(alignment: .leading) {
                    HStack {
                        TextField("App name (e.g. OmniRoute, VS Code)", text: $newName)
                        Stepper("\(rpm) requests/min", value: $rpm, in: 1...1000, step: 10).frame(width: 200)
                        Button("Create Key") {
                            Task { shownKey = await hub.createKey(name: newName, models: restrict ? Array(allowed) : [], rpm: rpm, xaiScopes: xai ? Array(scopes) : nil); newName = "" }
                        }.disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || (restrict && allowed.isEmpty))
                    }
                    Toggle("Red-XAI key (redx_xai_…) with scopes", isOn: $xai)
                    if xai {
                        HStack { ForEach(["chat", "image", "audio", "embeddings", "train:submit"], id: \.self) { s in
                            Toggle(s, isOn: Binding(get: { scopes.contains(s) }, set: { if $0 { scopes.insert(s) } else { scopes.remove(s) } })).toggleStyle(.button).controlSize(.small)
                        } }
                    }
                    Toggle("Only allow specific models", isOn: $restrict)
                    if restrict {
                        ScrollView(.horizontal) { HStack { ForEach(modelIDs, id: \.self) { id in
                            Toggle(id, isOn: Binding(get: { allowed.contains(id) }, set: { if $0 { allowed.insert(id) } else { allowed.remove(id) } })).toggleStyle(.button).controlSize(.small)
                        } } }
                    }
                }.padding(6)
            }.padding([.horizontal, .top])
            Table(hub.keys) {
                TableColumn("Name") { k in Text(k.name).strikethrough(k.revoked) }
                TableColumn("Key") { k in Text(k.prefix).font(.caption.monospaced()) }
                TableColumn("Models") { k in Text(k.models.isEmpty ? "All" : k.models.joined(separator: ", ")).lineLimit(1) }
                TableColumn("Limit") { k in Text("\(k.rpm)/min") }.width(70)
                TableColumn("Usage") { k in Text("\(k.requests) req · \(k.tokens) tok") }
                TableColumn("Created") { k in Text(k.created, style: .date) }
                TableColumn("Last used") { k in if let d = k.lastUsed { Text(d, style: .relative) } else { Text("never").foregroundStyle(.secondary) } }
                TableColumn("") { k in
                    if k.revoked { Text("Revoked").foregroundStyle(.secondary) }
                    else { Button("Revoke", role: .destructive) { confirmRevoke = k }.controlSize(.small) }
                }.width(80)
            }
        }
        .sheet(isPresented: Binding(get: { shownKey != nil }, set: { if !$0 { shownKey = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your new API key").font(.title2.bold())
                Text("Copy it now. It is shown only once and is stored on the server only as a hash.").foregroundStyle(.secondary)
                Text(shownKey ?? "").font(.body.monospaced()).textSelection(.enabled).padding(8).background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                Text("Base URL: \(DocsView.publicBase)").font(.caption.monospaced())
                HStack { Button("Copy Key") { copyToClipboard(shownKey ?? "") }; Spacer(); Button("Done") { shownKey = nil }.keyboardShortcut(.defaultAction) }
            }.padding(20).frame(width: 560)
        }
        .confirmationDialog("Revoke \(confirmRevoke?.name ?? "")'s key?", isPresented: Binding(get: { confirmRevoke != nil }, set: { if !$0 { confirmRevoke = nil } })) {
            Button("Revoke", role: .destructive) { if let k = confirmRevoke { hub.revoke(k.id) }; confirmRevoke = nil }
        } message: { Text("Apps using it stop working immediately.") }
    }
}

struct DocsView: View {
    static var publicBase: String { UserDefaults.standard.string(forKey: "publicBaseURL") ?? "https://ai.example.com/v1" }
    @AppStorage("publicAPIReady") var publicReady = false
    func block(_ title: String, _ code: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title).font(.headline); Spacer(); Button("Copy") { copyToClipboard(code) }.controlSize(.small) }
            Text(code).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Plug your models into other apps").font(.title2.bold())
                Text("The server speaks the OpenAI API. Any app that lets you set a custom OpenAI base URL and key works. Create a key in API Keys, then use:").foregroundStyle(.secondary)
                block("Base URL (OpenAI-compatible)", Self.publicBase)
                if !publicReady {
                    Label("If your public address isn't set up yet, apps on this Mac can use http://127.0.0.1:18091/v1 with this command running: ssh -N -L 18091:127.0.0.1:8091 root@\(UserDefaults.standard.string(forKey: "sshHost")?.components(separatedBy: "@").last ?? "YOUR_SERVER")", systemImage: "exclamationmark.triangle").font(.caption)
                }
                block("Endpoints", "Outside provider models (Providers tab) appear as ext-… ids and work the same way.\nGET  /v1/models\nPOST /v1/chat/completions\nPOST /v1/completions\nPOST /v1/embeddings   (model: nomic-embed-v1.5)\nMerge models: redx-merge-auto, redx-merge-draft-refine, redx-merge-panel, …")
                block("Connect any app", "OpenAI-style apps: base URL \(Self.publicBase), API key redx_ai_… (or redx_xai_…)\nOllama-style apps: base URL \(Self.publicBase.replacingOccurrences(of: "/v1", with: "")) with header Authorization: Bearer <key> (/api/tags, /api/chat, /api/generate, /api/embed)\nModels: any installed model, vortex (learning model), redx-merge-<name>, ext-… providers\nCustom GPT Actions: import docs/openapi-gpt-actions.yaml, Authentication = API Key, Bearer. Needs the public https URL.")
                block("Test with curl", "curl \(Self.publicBase)/chat/completions \\\n  -H \"Authorization: Bearer redx_ai_YOUR_KEY\" -H \"Content-Type: application/json\" \\\n  -d '{\"model\":\"qwen2.5-coder-14b\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'")
                block("OmniRoute", "Providers → Add provider → OpenAI-compatible\n  Name:     RedX AI\n  Base URL: \(Self.publicBase)\n  API key:  redx_ai_YOUR_KEY\n  Models:   click Fetch models (or type e.g. dolphin2.7-mixtral-8x7b-iq4xs, redx-merge-auto)")
                block("Continue (VS Code / JetBrains) — ~/.continue/config.yaml", "models:\n  - name: RedX Coder\n    provider: openai\n    model: qwen2.5-coder-14b\n    apiBase: \(Self.publicBase)\n    apiKey: redx_ai_YOUR_KEY\n    roles: [chat, edit, apply]\n  - name: RedX Autocomplete\n    provider: openai\n    model: dolphin3-llama3.2-3b-q4km\n    apiBase: \(Self.publicBase)\n    apiKey: redx_ai_YOUR_KEY\n    roles: [autocomplete]\n  - name: RedX Embed\n    provider: openai\n    model: nomic-embed-v1.5\n    apiBase: \(Self.publicBase)\n    apiKey: redx_ai_YOUR_KEY\n    roles: [embed]")
                block("VS Code (other OpenAI-compatible extensions, e.g. Cline / Roo Code)", "API Provider: OpenAI Compatible\nBase URL:     \(Self.publicBase)\nAPI Key:      redx_ai_YOUR_KEY\nModel ID:     qwen2.5-coder-14b")
                block("Python (openai package)", "from openai import OpenAI\nc = OpenAI(base_url=\"\(Self.publicBase)\", api_key=\"redx_ai_YOUR_KEY\")\nprint(c.chat.completions.create(model=\"redx-merge-auto\",\n      messages=[{\"role\":\"user\",\"content\":\"hello\"}]).choices[0].message.content)")
                Text("Limits: every request needs a key; per-key requests/minute; replies capped at 4096 tokens; one generation runs at a time (others queue). Merge models answer in one piece once all steps finish.").font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }
    }
}
