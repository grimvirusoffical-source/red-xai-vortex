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
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Dolphino")
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

    func send(_ text: String, systemPrompt: String, contextTokens: Int, params: ChatParams) {
        guard let i = idx(selection), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !streaming else { return }
        chats[i].messages.append(Message(role: "user", content: text))
        if chats[i].title == "New Chat" { chats[i].title = String(text.prefix(40)) }
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
        for m in chats[i].messages.reversed() { budget -= m.content.count; if budget < 0 && !hist.isEmpty { break }; hist.insert(m, at: 0) }
        if !systemPrompt.isEmpty { hist.insert(Message(role: "system", content: systemPrompt), at: 0) }
        chats[i].messages.append(Message(role: "assistant", content: ""))
        chats[i].updated = Date(); streaming = true; status = "Thinking…"
        // "Show replies only when finished" (default ON): collect the whole reply, show a typing indicator, then render it at once.
        let whole = UserDefaults.standard.object(forKey: "replyWhenFinished") as? Bool ?? true
        let buffer = ReplyBuffer()
        if whole { status = "Dolphino is typing…" }
        if params.model.hasPrefix("redx-merge-") {
            let n = HubStore.shared.merges.first { "redx-merge-\($0.name)" == params.model }?.stepCount ?? 2
            status = "Thinking with \(n) models…"
        }
        task = Task { [weak self] in
            do {
                let tps = try await API.stream(params, messages: hist) { tok in
                    if whole { buffer.append(tok); return }
                    Task { @MainActor in
                        guard let self, let j = self.idx(chatID), !self.chats[j].messages.isEmpty else { return }
                        self.chats[j].messages[self.chats[j].messages.count - 1].content += tok
                        self.status = "Streaming…"
                    }
                }
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
            } else { status = "Import failed: not a Dolphino export" }
        }
    }
    /// OpenAI/ShareGPT-style chat JSONL: one {"messages":[...]} object per conversation.
    func exportTraining(systemPrompt: String, onlyCurrent: Bool) {
        let p = NSSavePanel(); p.nameFieldStringValue = "lumi-train.jsonl"
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
