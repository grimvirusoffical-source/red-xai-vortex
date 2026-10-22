import SwiftUI

struct ExtModelRow: Identifiable, Hashable { var id: String; var name: String; var remote: String }
struct ProviderRow: Identifiable { var id: String; var name: String; var baseURL: String; var models: [ExtModelRow] }

@MainActor
final class ProviderStore: ObservableObject {
    static let shared = ProviderStore()
    @Published var providers: [ProviderRow] = []
    @Published var testResult: [String: String] = [:]
    var extModelIDs: [String] { providers.flatMap { $0.models.map(\.id) } }
    func load() async {
        guard let j = try? await Admin.call("GET", "/admin/providers") else { return }
        providers = (j["providers"] as? [[String: Any]] ?? []).map { p in
            ProviderRow(id: p["id"] as? String ?? "", name: p["name"] as? String ?? "", baseURL: p["base_url"] as? String ?? "",
                        models: (p["models"] as? [[String: Any]] ?? []).map { ExtModelRow(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "", remote: $0["remote"] as? String ?? "") })
        }
    }
    func save(id: String?, name: String, base: String, key: String, models: [ExtModelRow]) async -> String? {
        var b: [String: Any] = ["name": name, "base_url": base, "models": models.map { ["remote": $0.remote, "name": $0.name] }]
        if let id { b["id"] = id }
        if !key.isEmpty { b["api_key"] = key }
        do { _ = try await Admin.call("POST", "/admin/providers", b); await load(); await ChatStoreRef.refresh(); return nil }
        catch { return error.localizedDescription }
    }
    func remove(_ id: String) async { _ = try? await Admin.call("DELETE", "/admin/providers/\(id)"); await load(); await ChatStoreRef.refresh() }
    func test(_ id: String) async {
        testResult[id] = "Testing…"
        do {
            let r = try await Admin.call("POST", "/admin/providers/\(id)/test")
            let ok = r["ok"] as? Bool ?? false
            let n = (r["remote_models"] as? [String])?.count ?? 0
            testResult[id] = ok ? "✅ Connected · \(n) models available · chat OK" :
                "❌ models: \(r["models_status"] ?? r["models_error"] ?? "?") · chat: \(r["chat_status"] ?? r["chat_error"] ?? "–")"
        } catch { testResult[id] = "❌ \(error.localizedDescription)" }
    }
}

struct ProvidersView: View {
    @StateObject var ps = ProviderStore.shared
    @Local var editing: ProviderRow?
    static let presets: [(String, String)] = [
        ("OpenAI", "https://api.openai.com/v1"), ("Anthropic (OpenAI-compatible)", "https://api.anthropic.com/v1"),
        ("Groq", "https://api.groq.com/openai/v1"), ("OpenRouter", "https://openrouter.ai/api/v1"),
        ("Together", "https://api.together.xyz/v1"), ("Mistral", "https://api.mistral.ai/v1"),
        ("Gemini (OpenAI-compatible)", "https://generativelanguage.googleapis.com/v1beta/openai")]
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Add outside AI services. Their keys are sealed on the server and never come back to this Mac. Their models show up next to your own, work with your redx_ai_ keys, and can join Merges.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Menu { ForEach(Self.presets, id: \.0) { p in Button(p.0) { editing = ProviderRow(id: "", name: p.0.components(separatedBy: " (").first ?? p.0, baseURL: p.1, models: []) } }
                    Divider(); Button("Custom…") { editing = ProviderRow(id: "", name: "", baseURL: "https://", models: []) }
                } label: { Label("Add Provider", systemImage: "plus") }.fixedSize()
            }.padding([.horizontal, .top])
            List(ps.providers) { p in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(p.name).font(.headline); Text(p.baseURL).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                        Button("Test") { Task { await ps.test(p.id) } }
                        Button("Edit") { editing = p }
                        Button(role: .destructive) { Task { await ps.remove(p.id) } } label: { Label("Remove", systemImage: "trash") }
                    }
                    ForEach(p.models) { m in Text("• \(m.name)  →  \(m.remote)   [\(m.id)]").font(.caption) }
                    if let t = ps.testResult[p.id] { Text(t).font(.caption) }
                }.padding(.vertical, 4)
            }
        }
        .task { await ps.load() }
        .sheet(item: $editing) { p in ProviderEditor(p: p) { editing = nil } }
    }
}

struct ProviderEditor: View {
    @Local var p: ProviderRow
    var done: () -> Void
    @Local var key = ""
    @Local var newRemote = ""
    @Local var newName = ""
    @Local var err = ""
    var isNew: Bool { p.id.isEmpty }
    var body: some View {
        Form {
            TextField("Display name", text: $p.name)
            TextField("Base URL (OpenAI-compatible)", text: $p.baseURL)
            SecureField(isNew ? "API key" : "API key (leave empty to keep the saved one)", text: $key)
            Section("Models to show") {
                ForEach(p.models) { m in
                    HStack { Text(m.name); Text(m.remote).font(.caption.monospaced()).foregroundStyle(.secondary); Spacer()
                        Button(role: .destructive) { p.models.removeAll { $0 == m } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain) }
                }
                HStack {
                    TextField("Provider model id (e.g. gpt-4o-mini)", text: $newRemote)
                    TextField("Your name for it", text: $newName)
                    Button("Add") { p.models.append(ExtModelRow(id: UUID().uuidString, name: newName.isEmpty ? "\(p.name) \(newRemote)" : newName, remote: newRemote)); newRemote = ""; newName = "" }
                        .disabled(newRemote.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if !err.isEmpty { Text(err).foregroundStyle(.red).font(.caption) }
            HStack { Spacer(); Button("Cancel", action: done)
                Button("Save") { Task { if let e = await ProviderStore.shared.save(id: isNew ? nil : p.id, name: p.name, base: p.baseURL, key: key, models: p.models) { err = e } else { key = ""; done() } } }
                    .keyboardShortcut(.defaultAction).disabled(p.name.isEmpty || !p.baseURL.hasPrefix("http") || (isNew && key.isEmpty))
            }
        }.formStyle(.grouped).frame(width: 600, height: 520)
    }
}
