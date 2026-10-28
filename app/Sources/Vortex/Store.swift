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
    var task: Task<Void, Never>?
    var generation = ChatGenerationLease()
    func beginGeneration() -> UUID { generation.begin() }
    func acceptsGeneration(_ id: UUID) -> Bool { generation.accepts(id) }
    func messageIndex(chatID: UUID, messageID: UUID, runID: UUID) -> (Int, Int)? {
        guard acceptsGeneration(runID), let chat = idx(chatID),
              let message = chats[chat].messages.firstIndex(where: { $0.id == messageID && $0.role == "assistant" }) else { return nil }
        return (chat, message)
    }
    func setStatus(_ value: String, runID: UUID) { if acceptsGeneration(runID) { status = value } }
    func finishGeneration(_ id: UUID) {
        guard acceptsGeneration(id) else { return }
        generation.invalidate(); streaming = false; task = nil; save()
    }

    static var dir: URL { AccountProfile.directory }
    var file: URL { Self.dir.appendingPathComponent("chats.json") }

    init() {
        if let d = try? Data(contentsOf: file), let c = try? JSONDecoder().decode([Chat].self, from: d) { chats = c }
        if chats.isEmpty { newChat() } else { selection = sorted.first?.id }
    }
    var sorted: [Chat] { chats.sorted { ($0.pinned ? 1 : 0, $0.updated) > ($1.pinned ? 1 : 0, $1.updated) } }
    func save() { if let d = try? JSONEncoder().encode(chats) { try? d.write(to: file, options: .atomic) } }

    func newChat(projectID: UUID? = nil, worldID: UUID? = nil) { var c = Chat(); c.projectID = projectID; c.worldID = worldID; chats.append(c); selection = c.id; save() }
    func updateCurrent(_ change: (inout Chat) -> Void) { guard let i = idx(selection) else { return }; change(&chats[i]); save() }
    func delete(_ id: UUID) { chats.removeAll { $0.id == id }; if selection == id { selection = sorted.first?.id }; if chats.isEmpty { newChat() }; save() }
    func rename(_ id: UUID, _ t: String) { if let i = idx(id) { chats[i].title = t; save() } }
    func togglePin(_ id: UUID) { if let i = idx(id) { chats[i].pinned.toggle(); save() } }
    func clearAll() { chats = []; newChat() }
    func idx(_ id: UUID?) -> Int? { chats.firstIndex { $0.id == id } }
    var current: Chat? { chats.first { $0.id == selection } }

    func stop() { generation.invalidate(); task?.cancel(); task = nil; streaming = false; status = "Stopped"; save() }

    func send(_ text: String, attachments: [Attachment] = [], systemPrompt: String, contextTokens: Int, params: ChatParams) {
        guard let i = idx(selection), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty, !streaming else { return }
        if attachments.isEmpty, let spec = MediaSpec.parseRequest(text) {
            let chatID = chats[i].id
            let runID = beginGeneration()
            streaming = true; status = "Queuing \(spec.type)…"
            task = Task { [weak self] in
                guard let self else { return }
                let id = await MediaLibrary.shared.submit(spec, chat: self, chatID: chatID, userText: text)
                guard self.acceptsGeneration(runID) else { return }
                self.status = id == nil ? MediaLibrary.shared.message : "Generation queued · follow progress in this chat"
                self.finishGeneration(runID)
            }
            return
        }
        chats[i].messages.append(Message(role: "user", content: text, attachments: attachments.isEmpty ? nil : attachments))
        if chats[i].title == "New Chat" { chats[i].title = String((text.isEmpty ? attachments.map(\.name).joined(separator: ", ") : text).prefix(40)) }
        prepareGeneration(chatID: chats[i].id, text: text, systemPrompt: systemPrompt, contextTokens: contextTokens, params: params)
    }

    func regenerate(systemPrompt: String, contextTokens: Int, params: ChatParams) {
        guard let i = idx(selection), !streaming else { return }
        if chats[i].messages.last?.role == "assistant" { chats[i].messages.removeLast() }
        prepareGeneration(chatID: chats[i].id, text: chats[i].messages.last(where: { $0.role == "user" })?.content ?? "", systemPrompt: systemPrompt, contextTokens: contextTokens, params: params)
    }

    private func prepareGeneration(chatID: UUID, text: String, systemPrompt: String, contextTokens: Int, params: ChatParams) {
        guard let i = idx(chatID) else { return }
        let snapshot = chats[i]
        let runID = beginGeneration()
        streaming = true; status = "Preparing context…"; save()
        task = Task { [weak self] in
            // Check selected remote Bases on every turn so revoked tokens or unavailable hosts
            // cannot keep supplying a previously cached manifest to a new model request.
            await WorkspaceStore.shared.refreshContext(for: snapshot)
            guard !Task.isCancelled, let self, self.acceptsGeneration(runID), let j = self.idx(chatID) else { self?.finishGeneration(runID); return }
            self.streaming = false
            if let ps = self.chats[j].participants, !ps.isEmpty {
                self.generateGroup(chatIndex: j, text: text, systemPrompt: systemPrompt, contextTokens: contextTokens, params: params)
            } else { self.generate(chatIndex: j, systemPrompt: systemPrompt, contextTokens: contextTokens, params: params) }
        }
    }

    private func generate(chatIndex i: Int, systemPrompt: String, contextTokens: Int, params: ChatParams) {
        let chatID = chats[i].id
        let workspace = WorkspaceStore.shared.context(for: chats[i], basePrompt: systemPrompt, query: chats[i].messages.last(where: { $0.role == "user" })?.content ?? "", maxChars: max(0, (contextTokens - params.maxTokens) * 2))
        let systemPrompt = workspace.system
        let lastUserID = chats[i].messages.last(where: { $0.role == "user" })?.id
        // Trim history to fit the context budget (approx. 4 chars per token, leave room for the reply).
        var budget = max(512, (contextTokens - params.maxTokens)) * 4 - systemPrompt.count
        var hist: [Message] = []
        for message in chats[i].messages.reversed() where !message.content.hasPrefix("[[media:") {
            var m = message
            if m.id == lastUserID, !workspace.images.isEmpty { m.attachments = (m.attachments ?? []) + workspace.images }
            budget -= m.promptChars; if budget < 0 && !hist.isEmpty { break }; hist.insert(m, at: 0)
        }
        if !systemPrompt.isEmpty { hist.insert(Message(role: "system", content: systemPrompt), at: 0) }
        let assistant = Message(role: "assistant", content: "")
        let messageID = assistant.id, runID = beginGeneration()
        chats[i].messages.append(assistant)
        chats[i].updated = Date(); streaming = true; status = "Thinking…"
        // Stream by default; retain an explicitly saved finished-only preference.
        let whole = AccountProfile.defaults.object(forKey: "replyWhenFinished") as? Bool ?? false
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
                    await MainActor.run { self?.setStatus("Starting \(id) on this Mac…", runID: runID) }
                    p.baseURL = try await LocalRuntime.shared.ensure(id); try Task.checkCancellation(); p.apiKey = ""; p.model = id
                }
                let onTok: (String) -> Void = { tok in
                    buffer.append(tok)
                    if whole { return }
                    Task { @MainActor in
                        guard let self, let (j, k) = self.messageIndex(chatID: chatID, messageID: messageID, runID: runID) else { return }
                        self.chats[j].messages[k].content = buffer.text
                        self.status = "Streaming…"
                    }
                }
                try Task.checkCancellation()
                guard self?.acceptsGeneration(runID) == true else { throw CancellationError() }
                let lastText = hist.last(where: { $0.role == "user" })?.content ?? ""
                var tools = await MainActor.run { ToolRegistry.tools(for: p.model) }
                if Intent.isAction(lastText), !tools.contains(where: { $0.source.hasPrefix("pc:") }), !params.model.hasPrefix("local:") {
                    let pc = PCControl.shared
                    let on = await MainActor.run { () -> Bool in
                        if pc.enabled && !pc.killed { return true }
                        // First time a computer action is asked for with PC Control off: offer to turn it on (once).
                        if pc.killed || AccountProfile.defaults.bool(forKey: "pc.askedEnable") { return false }
                        AccountProfile.defaults.set(true, forKey: "pc.askedEnable")
                        let ok = Confirm.ask("Let Vortex control this Mac?", "You asked for something on your computer. Turn on PC Control so Vortex can open apps, manage files, read the screen and more? Risky actions still ask first. You can change this in Settings → PC Control.")
                        if ok { pc.setEnabled(true); pc.enable(PCKind.safe) }
                        return ok
                    }
                    _ = on
                    tools = await MainActor.run { ToolRegistry.tools(for: p.model) }
                }
                if !tools.isEmpty {
                    let who = await MainActor.run { () -> ActivityAgent in
                        let st = AgentStore.shared
                        if let ag = st.agents.first(where: { $0.id == st.activeID }) { return ActivityAgent(id: ag.id, name: ag.name) }
                        return ActivityAgent(id: "vortex-default", name: "Vortex")
                    }
                    let (text, log) = try await ActivityLog.$agent.withValue(who) {
                        try await Agent.run(p, history: hist, tools: tools, onText: { preview in
                            guard !whole else { return }
                            Task { @MainActor in
                                guard let self, let (j, k) = self.messageIndex(chatID: chatID, messageID: messageID, runID: runID) else { return }
                                self.chats[j].messages[k].content = preview
                            }
                        }) { st in Task { @MainActor in self?.setStatus(st, runID: runID) } }
                    }
                    await MainActor.run {
                        guard let self, let (j, k) = self.messageIndex(chatID: chatID, messageID: messageID, runID: runID), !Task.isCancelled else { return }
                        self.chats[j].messages[k].content = text.isEmpty ? "(no answer)" : text
                        self.chats[j].messages[k].toolLog = log.isEmpty ? nil : log
                        self.status = log.isEmpty ? "Done" : "Done · \(log.count) tool call(s)"
                        self.save()
                        WorkspaceStore.shared.captureCompletedTurn(self.chats[j], params: p)
                        self.finishGeneration(runID)
                    }
                    await MainActor.run { self?.finishGeneration(runID) }
                    return
                }
                let tps: Double?
                do { tps = try await API.stream(p, messages: hist, onToken: onTok) }
                catch let e as URLError where e.code != .cancelled && !Task.isCancelled && !params.model.hasPrefix("local:") && (AccountProfile.defaults.object(forKey: "autoFailover") as? Bool ?? true) {
                    await MainActor.run { self?.setStatus("Server unreachable, failing over…", runID: runID) }
                    if let s = await ServerStore.shared.failover() {
                        p.baseURL = s.chatURL; p.apiKey = ServerStore.shared.key(for: s)
                        await MainActor.run { self?.setStatus("Switched to \(s.name)", runID: runID) }
                        tps = try await API.stream(p, messages: hist, onToken: onTok)
                    } else if let lm = await MainActor.run(body: { LocalRuntime.shared.models.first(where: { !$0.contains("embed") }) }) {
                        await MainActor.run { self?.setStatus("No server reachable, using \(lm) on this Mac", runID: runID) }
                        p.baseURL = try await LocalRuntime.shared.ensure(lm); p.apiKey = ""; p.model = lm
                        tps = try await API.stream(p, messages: hist, onToken: onTok)
                    } else { throw e }
                }
                if p.apiKey.isEmpty { await MainActor.run { LocalRuntime.shared.touch() } }
                try Task.checkCancellation()
                await MainActor.run {
                    guard let self, let (j, k) = self.messageIndex(chatID: chatID, messageID: messageID, runID: runID) else { return }
                    self.chats[j].messages[k].content = buffer.text
                    self.status = tps.map { String(format: "%.1f tokens/s", $0) } ?? "Done"
                    WorkspaceStore.shared.captureCompletedTurn(self.chats[j], params: p)
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard let self, let (j, k) = self.messageIndex(chatID: chatID, messageID: messageID, runID: runID) else { return }
                    if whole, !buffer.text.isEmpty { self.chats[j].messages[k].content = buffer.text }
                    self.status = "Stopped"
                }
            } catch {
                await MainActor.run {
                    guard let self, let (j, k) = self.messageIndex(chatID: chatID, messageID: messageID, runID: runID) else { return }
                    self.status = "Error: \(error.localizedDescription)"
                    if self.chats[j].messages[k].content.isEmpty { self.chats[j].messages[k].content = "⚠️ \(error.localizedDescription)" }
                }
            }
            await MainActor.run { self?.finishGeneration(runID) }
        }
    }

    // MARK: export / import
    func exportJSON() {
        let p = NSSavePanel(); p.nameFieldStringValue = "vortex-chats.json"; p.allowedContentTypes = [.json]
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


/// A stale callback can never acquire the identity of a newer reply.
struct ChatGenerationLease {
    private(set) var current: UUID?
    mutating func begin() -> UUID { let id = UUID(); current = id; return id }
    func accepts(_ id: UUID) -> Bool { current == id }
    mutating func invalidate() { current = nil }
}
