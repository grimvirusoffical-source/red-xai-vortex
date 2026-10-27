import SwiftUI
import Foundation
import UserNotifications

/// Persistent background agents hosted by the Vortex server (or a Cloud PC). They keep running with the app closed
/// until the user turns them off. Each has its own chat history; users can chat with an agent directly.
struct BGAgent: Codable, Identifiable, Equatable {
    var id: String
    var name: String = ""
    var model: String = "vortex-mini"
    var system: String = ""
    var goal: String = ""
    var interval_s: Int = 300
    var on: Bool = false
    var run_on: String = "server"
    var status: String = ""
    var last_run: Int = 0
    var runs: Int = 0
    var unread: Int = 0
    var last_error: String?
    var history: [Turn]?
    struct Turn: Codable, Equatable, Hashable { var role: String; var content: String; var t: Int; var background: Bool? }
}

@MainActor final class BGAgentStore: ObservableObject {
    static let shared = BGAgentStore()
    @Published var agents: [BGAgent] = []
    @Published var msg = ""
    private var timer: Timer?
    private var lastUnread: [String: Int] = [:]

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in Task { @MainActor in await BGAgentStore.shared.refresh(notify: true) } }
    }
    private func req(_ path: String, _ method: String = "GET", _ body: [String: Any]? = nil, timeout: Double = 30) async throws -> Data {
        let base = UserDefaults.standard.string(forKey: "serverURL") ?? Defaults.serverURL
        var r = URLRequest(url: API.url(base, path)!, timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue("Bearer \(Keychain.get() ?? "")", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let b = body { r.httpBody = try JSONSerialization.data(withJSONObject: b) }
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 {
            let m = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["error"] as? String
            throw NSError(domain: "agents", code: code, userInfo: [NSLocalizedDescriptionKey: m ?? "HTTP \(code)"])
        }
        return d
    }
    func refresh(notify: Bool = false) async {
        struct L: Codable { var data: [BGAgent] }
        guard let d = try? await req("/agents"), let l = try? JSONDecoder().decode(L.self, from: d) else { return }
        agents = l.data
        migrateLegacyAgents(l.data)
        for a in l.data {
            if notify, a.unread > (lastUnread[a.id] ?? 0) {
                let c = UNMutableNotificationContent(); c.title = "\(a.name) has an update"; c.body = "Background run \(a.runs) finished. Open Agents to read it."
                try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ag-\(a.id)-\(a.runs)", content: c, trigger: nil))
            }
            if a.status == "error", notify, lastUnread[a.id] != -1 { }
            lastUnread[a.id] = a.unread
        }
    }
    func save(_ a: BGAgent) async {
        do {
            _ = try await req("/agents", "POST", ["id": a.id, "name": a.name, "model": a.model, "system": a.system, "goal": a.goal,
                                                  "interval_s": a.interval_s, "run_on": a.run_on, "on": a.on])
            msg = "Saved \(a.name)."; await refresh()
        } catch { msg = error.localizedDescription }
    }
    func toggle(_ a: BGAgent, _ on: Bool) async {
        do { _ = try await req("/agents/\(a.id)/toggle", "POST", ["on": on]); msg = on ? "\(a.name) is running in the background." : "\(a.name) turned off."; await refresh() }
        catch { msg = error.localizedDescription }
    }
    func delete(_ a: BGAgent) async { _ = try? await req("/agents/\(a.id)", "DELETE"); await refresh() }
    func history(_ id: String) async -> BGAgent? {
        guard let d = try? await req("/agents/\(id)") else { return nil }
        return try? JSONDecoder().decode(BGAgent.self, from: d)
    }
    func chat(_ id: String, _ text: String) async throws -> String {
        let d = try await req("/agents/\(id)/chat", "POST", ["content": text], timeout: 600)
        return ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["content"] as? String ?? ""
    }
}

/// Keep Vortex alive at login so notifications arrive (agents themselves run on the server either way).
enum LoginHelper {
    static var plist: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/com.redxai.vortex.background.plist") }
    static var enabled: Bool { FileManager.default.fileExists(atPath: plist.path) }
    static func set(_ on: Bool) {
        if on {
            let p: [String: Any] = ["Label": "com.redxai.vortex.background", "ProgramArguments": ["/usr/bin/open", "-g", "-a", "Red-XAI Vortex"], "RunAtLoad": true]
            try? FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            (p as NSDictionary).write(to: plist, atomically: true)
        } else { try? FileManager.default.removeItem(at: plist) }
    }
}

struct BackgroundAgentsView: View {
    @StateObject var s = BGAgentStore.shared
    @Local var edit: BGAgent? = nil
    @Local var chatWith: BGAgent? = nil
    @Local var atLogin = LoginHelper.enabled
    @AppStorage("model") var chatModel = Defaults.model
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Background agents").font(.headline)
                Spacer()
                Button { edit = BGAgent(id: "", name: "New agent", model: "vortex-mini") } label: { Label("New", systemImage: "plus") }
                Button { Task { await s.refresh() } } label: { Image(systemName: "arrow.clockwise") }
            }
            Text("These run on the Vortex server, or on your Cloud PC if you have approved access. They keep going after you close the app, until you switch them off. Click Chat to talk to an agent; it has its own history.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Open Vortex in the background at login (for agent notifications)", isOn: $atLogin).font(.caption)
                .onChange(of: atLogin) { _, v in LoginHelper.set(v) }
            ForEach(s.agents) { a in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack { Text(a.name).bold(); if a.unread > 0 { Text("\(a.unread) new").font(.caption2.bold()).padding(3).background(Capsule().fill(.red.opacity(0.3))) } }
                        Text("\(a.run_on == "cloudpc" ? "Cloud PC" : "Vortex server") · \(Defaults.displayName(a.model)) · every \(a.interval_s / 60) min · \(a.status) · \(a.runs) runs").font(.caption).foregroundStyle(.secondary)
                        if let e = a.last_error, a.status == "error" { Text(e).font(.caption2).foregroundStyle(.orange).lineLimit(1) }
                    }
                    Spacer()
                    Toggle("On", isOn: Binding(get: { a.on }, set: { v in Task { await s.toggle(a, v) } })).toggleStyle(.switch)
                    Button("Chat") { chatWith = a }
                    Button("Edit") { edit = a }
                    Button(role: .destructive) { Task { await s.delete(a) } } label: { Image(systemName: "trash") }
                }.padding(6).background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.3)))
            }
            if !s.msg.isEmpty { Text(s.msg).font(.caption).foregroundStyle(.secondary) }
        }
        .padding()
        .task { await s.refresh() }
        .sheet(item: $edit) { a in BGAgentEditor(a: a) }
        .sheet(item: $chatWith) { a in AgentChatView(agent: a).frame(minWidth: 620, minHeight: 520) }
    }
}

struct BGAgentEditor: View {
    @Local var a: BGAgent
    @Environment(\.dismiss) var dismiss
    @StateObject var s = BGAgentStore.shared
    init(a: BGAgent) { _a = Local(wrappedValue: a) }
    var body: some View {
        Form {
            Text(a.id.isEmpty ? "New background agent" : "Edit \(a.name)").font(.headline)
            TextField("Name", text: $a.name)
            TextField("Model id", text: $a.model).help("Any Vortex model id, a group-merge id, or a connected provider model")
            TextField("Standing goal (what it works on each run)", text: $a.goal, axis: .vertical).lineLimit(2...5)
            TextField("Instructions / persona (optional)", text: $a.system, axis: .vertical).lineLimit(2...5)
            Picker("Run every", selection: $a.interval_s) {
                ForEach([60, 300, 900, 3600, 21600, 86400], id: \.self) { v in Text(v < 3600 ? "\(v / 60) min" : "\(v / 3600) h").tag(v) }
            }
            Picker("Run on", selection: $a.run_on) {
                Text("Vortex server (always on)").tag("server")
                Text("Cloud PC (approved access)").tag("cloudpc")
            }.pickerStyle(.radioGroup)
            Toggle("Running (stays on until you turn it off)", isOn: $a.on)
            if !s.msg.isEmpty { Text(s.msg).font(.caption).foregroundStyle(.orange) }
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Save") { Task { await s.save(a); if !s.msg.hasPrefix("Saved") { return }; dismiss() } }.buttonStyle(.borderedProminent).disabled(a.name.isEmpty) }
        }.padding().frame(minWidth: 460)
    }
}

/// A chat with one agent; history is kept on the server per agent (background runs are shown dimmed).
struct AgentChatView: View {
    let agent: BGAgent
    @Environment(\.dismiss) var dismiss
    @Local var turns: [BGAgent.Turn] = []
    @Local var input = ""
    @Local var busy = false
    @Local var err = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Chat with \(agent.name)").font(.headline); Spacer(); Button("Done") { dismiss() } }.padding()
            Divider()
            ScrollViewReader { sp in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(turns.enumerated()), id: \.offset) { i, t in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.role == "user" ? (t.background == true ? "Background run" : "You") : agent.name).font(.caption.bold()).foregroundStyle(.secondary)
                                Text(.init(t.content)).textSelection(.enabled)
                            }.opacity(t.background == true && t.role == "user" ? 0.5 : 1).id(i)
                        }
                        if busy { ProgressView().id(-1) }
                    }.padding()
                }.onChange(of: turns.count) { _, n in sp.scrollTo(n - 1) }
            }
            if !err.isEmpty { Text(err).font(.caption).foregroundStyle(.orange) }
            HStack {
                TextField("Message \(agent.name)…", text: $input, axis: .vertical).lineLimit(1...5).onSubmit { send() }
                Button("Send") { send() }.buttonStyle(.borderedProminent).disabled(busy || input.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding()
        }
        .task { if let a = await BGAgentStore.shared.history(agent.id) { turns = a.history ?? [] }; await BGAgentStore.shared.refresh() }
    }
    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines); guard !text.isEmpty else { return }
        input = ""; err = ""; busy = true
        turns.append(.init(role: "user", content: text, t: Int(Date().timeIntervalSince1970), background: nil))
        Task {
            do { let r = try await BGAgentStore.shared.chat(agent.id, text); turns.append(.init(role: "assistant", content: r, t: Int(Date().timeIntervalSince1970), background: nil)) }
            catch { err = error.localizedDescription }
            busy = false
        }
    }
}
