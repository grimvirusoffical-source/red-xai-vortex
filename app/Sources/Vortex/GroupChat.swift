import SwiftUI

/// Group chat: several models in one conversation. Each reply is tagged with the model that wrote it.
/// Turn order: "all" = every participant replies in list order (each sees the earlier replies);
/// "rotate" = one participant per user message, round-robin. "@name" (any part of a model id) or "@all"
/// in a message overrides the order and asks only the mentioned models.
enum GroupColors {
    static let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .brown, .indigo]
    static func color(_ s: String) -> Color { palette[abs(s.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }) % palette.count] }
}

enum GroupTurns {
    static func mentions(_ text: String, in ps: [String]) -> [String] {
        let words = text.split(whereSeparator: { $0.isWhitespace || ",;:!?".contains($0) })
            .filter { $0.hasPrefix("@") && $0.count > 1 }.map { $0.dropFirst().lowercased() }
        if words.contains("all") || words.contains("everyone") { return ps }
        var out: [String] = []
        for p in ps where words.contains(where: { w in p.lowercased() == w || p.lowercased().contains(w) || short(p).lowercased() == w }) { out.append(p) }
        return out
    }
    static func short(_ m: String) -> String {
        let base = m.hasPrefix("local:") ? String(m.dropFirst(6)) : m
        return base.split(separator: "-").first.map(String.init) ?? base
    }
    static func responders(_ text: String, chat: Chat) -> (list: [String], next: Int) {
        let ps = chat.participants ?? []
        let m = mentions(text, in: ps)
        if !m.isEmpty { return (m, chat.nextTurn ?? 0) }
        if chat.turnMode == "rotate" { let n = (chat.nextTurn ?? 0) % max(ps.count, 1); return ([ps[n]], n + 1) }
        return (ps, chat.nextTurn ?? 0)
    }
    /// History as seen by one participant: its own replies stay "assistant", everyone else's become
    /// "user" lines tagged with the speaker. Same-role neighbours are merged so strict templates accept it.
    static func history(for me: String, chat: Chat, system: String, others: [String], budgetChars: Int) -> [Message] {
        var budget = budgetChars, out: [Message] = []
        for m in chat.messages.reversed() where !m.content.isEmpty || m.attachments != nil {
            var c = m
            if m.role == "assistant" {
                if m.model != nil && m.model != me { c.role = "user"; c.content = "[\(m.model!)]: \(m.content)" }
            } else if m.role == "user", chat.messages.contains(where: { $0.model != nil }) { c.content = "[User]: \(m.content)" }
            budget -= c.promptChars; if budget < 0 && !out.isEmpty { break }
            out.insert(c, at: 0)
        }
        var merged: [Message] = []
        for m in out {
            if var last = merged.last, last.role == m.role {
                last.content += "\n\n" + m.content
                if let a = m.attachments { last.attachments = (last.attachments ?? []) + a }
                merged[merged.count - 1] = last
            } else { merged.append(m) }
        }
        if merged.first?.role == "assistant" { merged.insert(Message(role: "user", content: "[User]: (conversation start)"), at: 0) }
        let sys = (system.isEmpty ? "" : system + "\n\n") +
            "This is a group chat. You are \(me). Also present: the user\(others.isEmpty ? "" : " and " + others.joined(separator: ", ")). " +
            "Lines starting with [name]: were written by that participant. Reply only as yourself, without a name prefix. Keep it focused; add something new instead of repeating others."
        return [Message(role: "system", content: sys)] + merged
    }
}

extension ChatStore {
    func generateGroup(chatIndex i: Int, text: String, systemPrompt: String, contextTokens: Int, params: ChatParams) {
        let chatID = chats[i].id
        let (who, next) = GroupTurns.responders(text, chat: chats[i])
        chats[i].nextTurn = next
        chats[i].updated = Date(); streaming = true
        let budget = max(512, contextTokens - params.maxTokens) * 4 - systemPrompt.count - 400
        task = Task { [weak self] in
            for (n, m) in who.enumerated() {
                if Task.isCancelled { break }
                guard let snapshot = await MainActor.run(body: { () -> Chat? in
                    guard let self, let j = self.idx(chatID) else { return nil }
                    self.chats[j].messages.append(Message(role: "assistant", content: "", model: m))
                    self.status = "\(m) is replying (\(n + 1)/\(who.count))…"
                    var c = self.chats[j]; c.messages.removeLast(); return c
                }) else { break }
                let others = (snapshot.participants ?? []).filter { $0 != m }
                let hist = GroupTurns.history(for: m, chat: snapshot, system: systemPrompt, others: others, budgetChars: budget)
                let buf = ReplyBuffer()
                var reply: String
                do {
                    var p = params; p.model = m
                    if m.hasPrefix("local:") { let id = String(m.dropFirst(6)); p.baseURL = try await LocalRuntime.shared.ensure(id); p.apiKey = ""; p.model = id }
                    _ = try await API.stream(p, messages: hist, onToken: { buf.append($0) })
                    reply = buf.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    // strip a self-added "[name]:" prefix
                    for pre in ["[\(m)]:", "\(m):"] where reply.hasPrefix(pre) { reply = String(reply.dropFirst(pre.count)).trimmingCharacters(in: .whitespaces) }
                    if reply.isEmpty { reply = "(no answer)" }
                } catch is CancellationError { reply = buf.text.isEmpty ? "(stopped)" : buf.text }
                  catch { reply = "⚠️ \(m): \(error.localizedDescription)" }
                await MainActor.run {
                    guard let self, let j = self.idx(chatID), !self.chats[j].messages.isEmpty else { return }
                    self.chats[j].messages[self.chats[j].messages.count - 1].content = reply
                    self.save()
                }
            }
            await MainActor.run { self?.status = Task.isCancelled ? "Stopped" : "Group: \(who.count) repl\(who.count == 1 ? "y" : "ies")"; self?.streaming = false; self?.save() }
        }
    }
    func setGroup(_ ps: [String], mode: String) {
        guard let i = idx(selection) else { return }
        chats[i].participants = ps.isEmpty ? nil : ps; chats[i].turnMode = mode; chats[i].nextTurn = 0; save()
    }
}

struct GroupSetupView: View {
    @EnvironmentObject var store: ChatStore
    @Environment(\.dismiss) var dismiss
    @Local var picked: [String] = []
    @Local var mode = "all"
    @Local var loaded = false
    var all: [String] { Array(Set(store.availableModels + LocalRuntime.shared.models.map { "local:\($0)" })).sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Group chat").font(.title2.bold())
            Text("Pick the models that take part in this chat. Each reply is labelled with its model. Type @name (any part of a model id) to ask only that model, or @all for everyone.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Turn order", selection: $mode) {
                Text("Everyone replies, in order").tag("all")
                Text("One per message, taking turns").tag("rotate")
            }.pickerStyle(.radioGroup)
            HStack(alignment: .top, spacing: 12) {
                List {
                    Section("Available") {
                        ForEach(all.filter { !picked.contains($0) }, id: \.self) { m in
                            HStack { Text(m).lineLimit(1); Spacer(); Button("Add") { picked.append(m) } }
                        }
                    }
                }.frame(minWidth: 280)
                List {
                    Section("In this chat (turn order)") {
                        ForEach(Array(picked.enumerated()), id: \.element) { n, m in
                            HStack {
                                Text("\(n + 1). \(m)").foregroundStyle(GroupColors.color(m)).lineLimit(1); Spacer()
                                Button { if n > 0 { picked.swapAt(n, n - 1) } } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless).disabled(n == 0)
                                Button { picked.remove(at: n) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless)
                            }
                        }
                    }
                }.frame(minWidth: 280)
            }.frame(height: 280)
            HStack {
                if store.current?.participants != nil { Button("Turn off group chat", role: .destructive) { store.setGroup([], mode: mode); dismiss() } }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { store.setGroup(picked, mode: mode); dismiss() }.keyboardShortcut(.defaultAction).disabled(picked.count == 1)
            }
            if picked.count == 1 { Text("Pick at least two models (or none to turn group chat off).").font(.caption).foregroundStyle(.orange) }
        }
        .padding(20).frame(width: 640)
        .onAppear { if !loaded { picked = store.current?.participants ?? []; mode = store.current?.turnMode ?? "all"; loaded = true } }
    }
}
