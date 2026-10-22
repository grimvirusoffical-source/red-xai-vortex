import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class ChatStore: ObservableObject {
    @Published var chats: [Chat] = []
    @Published var selection: UUID?
    @Published var streaming = false
    @Published var status = ""
    @Published var availableModels: [String] = [Defaults.model, Defaults.fallbackModel]
    private var task: Task<Void, Never>?

    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("Red-XAI Vortex"), old = base.appendingPathComponent("Dolphino")
        if !FileManager.default.fileExists(atPath: d.path), FileManager.default.fileExists(atPath: old.path) { try? FileManager.default.moveItem(at: old, to: d) } // one-time move from the old app name
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    var file: URL { Self.dir.appendingPathComponent("chats.json") }

    init() {
        if let d = try? Data(contentsOf: file), let c = try? JSONDecoder().decode([Chat].self, from: d) { chats = c }
        if chats.isEmpty { newChat() } else { selection = sorted.first?.id }
    }
    var sorted: [Chat] { chats.sorted { ($0.pinned ? 1 : 0, $0.updated) > ($1.pinned ? 1 : 0, $1.updated) } }
    func save() { if let d = try? JSONEncoder().encode(chats) { try? d.write(to: file, options: .atomic) } }

    func newChat() { let c = Chat(); chats.append(c); selection = c.id; save() }
    func delete(_ id: UUID) { chats.removeAll { $0.id == id }; if selection == id { selection = sorted.first?.id }; if chats.isEmpty { newChat() }; save() }
    func rename(_ id: UUID, _ t: String) { if let i = idx(id) { chats[i].title = t; save() } }
    func togglePin(_ id: UUID) { if let i = idx(id) { chats[i].pinned.toggle(); save() } }
    func clearAll() { chats = []; newChat() }
    func idx(_ id: UUID?) -> Int? { chats.firstIndex { $0.id == id } }
    var current: Chat? { chats.first { $0.id == selection } }

    func stop() { task?.cancel(); task = nil; streaming = false }

    func send(_ text: String, attachments: [Attachment] = [], systemPrompt: String, contextTokens: Int, params: ChatParams) {
        guard let i = idx(selection), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty, !streaming else { return }
        chats[i].messages.append(Message(role: "user", content: text, attachments: attachments.isEmpty ? nil : attachments))
        if chats[i].title == "New Chat" { chats[i].title = String((text.isEmpty ? attachments.map(\.name).joined(separator: ", ") : text).prefix(40)) }
        generate(chatIndex: i, systemPrompt: systemPrompt, contextTokens: contextTokens, params: params)
    }

    func regenerate(systemPrompt: String, contextTokens: Int, params: ChatParams) {
        guard let i = idx(selection), !streaming else { return }
        if chats[i].messages.last?.role == "assistant" { chats[i].messages.removeLast() }
        generate(chatIndex: i, systemPrompt: systemPrompt, contextTokens: contextTokens, params: params)
    }

    private func generate(chatIndex i: Int, systemPrompt: String, contextTokens: Int, params: ChatParams) {
        let chatID = chats[i].id
        // Trim history to fit the context budget (approx. 4 chars per token, leave room for the reply).
        var budget = max(512, (contextTokens - params.maxTokens)) * 4 - systemPrompt.count
        var hist: [Message] = []
        for m in chats[i].messages.reversed() { budget -= m.promptChars; if budget < 0 && !hist.isEmpty { break }; hist.insert(m, at: 0) }
        if !systemPrompt.isEmpty { hist.insert(Message(role: "system", content: systemPrompt), at: 0) }
        chats[i].messages.append(Message(role: "assistant", content: ""))
        chats[i].updated = Date(); streaming = true; status = "Thinking…"
        // "Show replies only when finished" (default ON): collect the whole reply, show a typing indicator, then render it at once.
        let whole = UserDefaults.standard.object(forKey: "replyWhenFinished") as? Bool ?? true
        let buffer = ReplyBuffer()
        if whole { status = "Vortex is typing…" }
        if params.model.hasPrefix("redx-merge-") {
            let n = HubStore.shared.merges.first { "redx-merge-\($0.name)" == params.model }?.stepCount ?? 2
            status = "Thinking with \(n) models…"
        }
        task = Task { [weak self] in
            do {
                var p = params
                if p.model.hasPrefix("local:") {
                    let id = String(p.model.dropFirst(6))
                    await MainActor.run { self?.status = "Starting \(id) on this Mac…" }
                    p.baseURL = try await LocalRuntime.shared.ensure(id); p.apiKey = ""; p.model = id
                }
                let onTok: (String) -> Void = { tok in
                    if whole { buffer.append(tok); return }
                    Task { @MainActor in
                        guard let self, let j = self.idx(chatID), !self.chats[j].messages.isEmpty else { return }
                        self.chats[j].messages[self.chats[j].messages.count - 1].content += tok
                        self.status = "Streaming…"
                    }
                }
                let tools = await MainActor.run { ToolRegistry.tools(for: params.model) }
                if !tools.isEmpty {
                    let (text, log) = try await Agent.run(p, history: hist, tools: tools) { st in Task { @MainActor in self?.status = st } }
                    await MainActor.run {
                        guard let self, let j = self.idx(chatID), !self.chats[j].messages.isEmpty else { return }
                        let k = self.chats[j].messages.count - 1
                        self.chats[j].messages[k].content = text.isEmpty ? "(no answer)" : text
                        self.chats[j].messages[k].toolLog = log.isEmpty ? nil : log
                        self.status = log.isEmpty ? "Done" : "Done · \(log.count) tool call(s)"
                        self.streaming = false; self.save()
                    }
                    return
                }
                let tps: Double?
                do { tps = try await API.stream(p, messages: hist, onToken: onTok) }
                catch let e as URLError where !params.model.hasPrefix("local:") && (UserDefaults.standard.object(forKey: "autoFailover") as? Bool ?? true) {
                    await MainActor.run { self?.status = "Server unreachable, failing over…" }
                    if let s = await ServerStore.shared.failover() {
                        p.baseURL = s.chatURL; p.apiKey = ServerStore.shared.key(for: s)
                        await MainActor.run { self?.status = "Switched to \(s.name)" }
                        tps = try await API.stream(p, messages: hist, onToken: onTok)
                    } else if let lm = await MainActor.run(body: { LocalRuntime.shared.models.first(where: { !$0.contains("embed") }) }) {
                        await MainActor.run { self?.status = "No server reachable, using \(lm) on this Mac" }
                        p.baseURL = try await LocalRuntime.shared.ensure(lm); p.apiKey = ""; p.model = lm
                        tps = try await API.stream(p, messages: hist, onToken: onTok)
                    } else { throw e }
                }
                if p.apiKey.isEmpty { await MainActor.run { LocalRuntime.shared.touch() } }
                await MainActor.run {
                    if whole, let self, let j = self.idx(chatID), !self.chats[j].messages.isEmpty {
                        self.chats[j].messages[self.chats[j].messages.count - 1].content = buffer.text
                    }
                    self?.status = tps.map { String(format: "%.1f tokens/s", $0) } ?? "Done"
                }
            } catch is CancellationError {
                await MainActor.run {
                    if whole, let self, let j = self.idx(chatID), !self.chats[j].messages.isEmpty, !buffer.text.isEmpty {
                        self.chats[j].messages[self.chats[j].messages.count - 1].content = buffer.text
                    }
                    self?.status = "Stopped"
                }
            } catch {
                await MainActor.run {
                    self?.status = "Error: \(error.localizedDescription)"
                    if let self, let j = self.idx(chatID), self.chats[j].messages.last?.content.isEmpty == true {
                        self.chats[j].messages[self.chats[j].messages.count - 1].content = "⚠️ \(error.localizedDescription)"
                    }
                }
            }
            await MainActor.run { self?.streaming = false; self?.save() }
        }
    }

    // MARK: export / import
    func exportJSON() {
        let p = NSSavePanel(); p.nameFieldStringValue = "dolphino-chats.json"; p.allowedContentTypes = [.json]
        if p.runModal() == .OK, let u = p.url {
            let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted]; e.dateEncodingStrategy = .iso8601
            try? e.encode(chats).write(to: u)
        }
    }
    func importJSON() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.json]
        if p.runModal() == .OK, let u = p.url, let d = try? Data(contentsOf: u) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            if let c = (try? dec.decode([Chat].self, from: d)) ?? (try? JSONDecoder().decode([Chat].self, from: d)) {
                let have = Set(chats.map(\.id)); chats += c.filter { !have.contains($0.id) }; save(); status = "Imported \(c.count) chats"
            } else { status = "Import failed: not a Red-XAI Vortex export" }
        }
    }
    /// OpenAI/ShareGPT-style chat JSONL: one {"messages":[...]} object per conversation.
    func exportTraining(systemPrompt: String, onlyCurrent: Bool) {
        let p = NSSavePanel(); p.nameFieldStringValue = "vortex-train.jsonl"
        guard p.runModal() == .OK, let u = p.url else { return }
        let src = onlyCurrent ? (current.map { [$0] } ?? []) : chats
        var lines: [String] = []
        for c in src {
            let msgs = c.messages.filter { !$0.content.isEmpty && !$0.content.hasPrefix("⚠️") }
            guard msgs.contains(where: { $0.role == "assistant" }) else { continue }
            var arr: [[String: String]] = []
            if !systemPrompt.isEmpty { arr.append(["role": "system", "content": systemPrompt]) }
            arr += msgs.map { ["role": $0.role, "content": $0.content] }
            if let d = try? JSONSerialization.data(withJSONObject: ["messages": arr], options: [.withoutEscapingSlashes]),
               let s = String(data: d, encoding: .utf8) { lines.append(s) }
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: u, atomically: true, encoding: .utf8)
        status = "Exported \(lines.count) conversations for training"
    }
}

/// Thread-safe accumulator for a reply that is shown only when finished.
final class ReplyBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var s = ""
    func append(_ t: String) { lock.lock(); s += t; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return s }
}
