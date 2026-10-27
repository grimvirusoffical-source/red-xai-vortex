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
    /// "agent:<id>" -> agent name, refreshed before each group turn (read off the main actor).
    nonisolated(unsafe) static var agentNames: [String: String] = [:]
    static func mentions(_ text: String, in ps: [String]) -> [String] {
        let words = text.split(whereSeparator: { $0.isWhitespace || ",;:!?".contains($0) })
            .filter { $0.hasPrefix("@") && $0.count > 1 }.map { $0.dropFirst().lowercased() }
        if words.contains("all") || words.contains("everyone") { return ps }
        var out: [String] = []
        for p in ps where words.contains(where: { w in p.lowercased() == w || p.lowercased().contains(w) || short(p).lowercased() == w || (agentNames[p]?.lowercased().hasPrefix(w) ?? false) }) { out.append(p) }
        return out
    }
    /// Display name for a participant: agents ("agent:<id>") show the agent's name, models their display name.
    @MainActor static func label(_ m: String) -> String {
        if m.hasPrefix("agent:") { let id = String(m.dropFirst(6)); return AgentStore.shared.agents.first { $0.id == id }?.name ?? "Agent" }
        return Defaults.displayName(m)
    }
    /// Non-isolated label using a snapshot of agent names.
    static func label(_ m: String, names: [String: String]) -> String {
        m.hasPrefix("agent:") ? (names[String(m.dropFirst(6))] ?? "Agent") : Defaults.displayName(m)
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
        let names = Dictionary(uniqueKeysWithValues: agentNames.map { ($0.key.replacingOccurrences(of: "agent:", with: ""), $0.value) })
        let meL = label(me, names: names), othersL = others.map { label($0, names: names) }
        var budget = budgetChars, out: [Message] = []
        for m in chat.messages.reversed() where !m.content.isEmpty || m.attachments != nil {
            var c = m
            if m.role == "assistant" {
                if m.model != nil && m.model != me { c.role = "user"; c.content = "[\(label(m.model!, names: names))]: \(m.content)" }
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
            (others.isEmpty ? "You are \(meL). Lines starting with [User]: are from the user. " : "This is a group chat. You are \(meL). Also present: the user and " + othersL.joined(separator: ", ") + ". ") +
            "Lines starting with [name]: were written by that participant. Reply only as yourself, without a name prefix. Keep it focused; add something new instead of repeating others."
        return [Message(role: "system", content: sys)] + merged
    }
}

extension ChatStore {
    func generateGroup(chatIndex i: Int, text: String, systemPrompt: String, contextTokens: Int, params: ChatParams) {
        let chatID = chats[i].id, runID = beginGeneration()
        let (ordinary, next) = GroupTurns.responders(text, chat: chats[i])
        let leader = chats[i].leaderParticipantID
        let team = chats[i].participants ?? []
        let coordinated = leader != nil && team.contains(leader!) && team.count >= 2
        let who = coordinated ? [leader!] + team.filter { $0 != leader! } + [leader!] : ordinary
        chats[i].nextTurn = next
        chats[i].updated = Date(); streaming = true
        let budget = max(512, contextTokens - params.maxTokens) * 4 - systemPrompt.count - 400
        task = Task { [weak self] in
            for (n, m) in who.enumerated() {
                if Task.isCancelled { break }
                guard let (snapshot, agentP, agentSys, messageID) = await MainActor.run(body: { () -> (Chat, ChatParams?, String?, UUID)? in
                    guard let self, self.acceptsGeneration(runID), let j = self.idx(chatID) else { return nil }
                    GroupTurns.agentNames = Dictionary(uniqueKeysWithValues: AgentStore.shared.agents.map { ("agent:" + $0.id, $0.name) })
                    var ap: ChatParams? = nil, asys: String? = nil
                    if m.hasPrefix("agent:"), let a = AgentStore.shared.agents.first(where: { $0.id == String(m.dropFirst(6)) }) {
                        ap = AgentStore.shared.chatParams(for: a.id, fallback: params); asys = a.systemPrompt
                    }
                    let assistant = Message(role: "assistant", content: "", model: m)
                    self.chats[j].messages.append(assistant)
                    self.status = "\(GroupTurns.label(m)) is replying (\(n + 1)/\(who.count))…"
                    var c = self.chats[j]; c.messages.removeLast(); return (c, ap, asys, assistant.id)
                }) else { break }
                let others = (snapshot.participants ?? []).filter { $0 != m }
                let context = await MainActor.run { WorkspaceStore.shared.context(for: snapshot, basePrompt: agentSys ?? systemPrompt, query: text, maxChars: max(0, (contextTokens - params.maxTokens) * 2)) }
                var contextChat = snapshot
                if let index = contextChat.messages.lastIndex(where: { $0.role == "user" }), !context.images.isEmpty { contextChat.messages[index].attachments = (contextChat.messages[index].attachments ?? []) + context.images }
                var hist = GroupTurns.history(for: m, chat: contextChat, system: context.system, others: others, budgetChars: max(512, budget - context.system.count))
                if coordinated {
                    let guidance = n == 0 ? "You are the team leader. Delegate clear, authorized tasks. A plan is not evidence of work." : n == who.count - 1 ? "You are the team leader. Review workers' actual evidence and distinguish completed, blocked and pending tasks." : "You are a worker directed by the leader. Execute only the permitted subtask and report verified outcomes."
                    hist[0].content += "\n\nTEAM RULES: " + guidance + "\n" + (snapshot.groupInstructions ?? "")
                }
                let buf = ReplyBuffer()
                var reply: String
                do {
                    var p = params; p.model = m
                    if let ap = agentP { p = ap; p.maxTokens = params.maxTokens }
                    if m.hasPrefix("local:") { let id = String(m.dropFirst(6)); p.baseURL = try await LocalRuntime.shared.ensure(id); p.apiKey = ""; p.model = id }
                    let worker = m.hasPrefix("agent:") && (!coordinated || (n > 0 && n < who.count - 1))
                    let who = ActivityAgent(id: m.hasPrefix("agent:") ? String(m.dropFirst(6)) : m, name: GroupTurns.agentNames[m] ?? m)
                    let tools = await MainActor.run { () -> [ToolSpec] in
                        let a = AgentStore.shared.agents.first { "agent:" + $0.id == m }
                        return worker ? ToolRegistry.tools(for: p.model, agent: a) : []
                    }
                    if !tools.isEmpty {
                        // Agent chat: the agent can act (tools, PC control) step by step; every step is logged.
                        let (t, _) = try await ActivityLog.$agent.withValue(who) {
                            let always = await MainActor.run { AgentStore.shared.agents.first(where: { "agent:" + $0.id == m })?.alwaysAllow }
                            return try await Agent.run(p, history: hist, tools: tools, agentAlwaysAllow: always) { st in Task { @MainActor in self?.setStatus("\(who.name): \(st)", runID: runID) } }
                        }
                        buf.append(t)
                    } else {
                        _ = try await API.stream(p, messages: hist, onToken: { buf.append($0) })
                    }
                    reply = buf.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if m.hasPrefix("agent:") { ActivityLog.add("chat", summary: "Replied in \(snapshot.title)", detail: reply, agent: who) }
                    // strip a self-added "[name]:" prefix
                    let lbl = GroupTurns.agentNames[m] ?? m
                    for pre in ["[\(m)]:", "\(m):", "[\(lbl)]:", "\(lbl):"] where reply.hasPrefix(pre) { reply = String(reply.dropFirst(pre.count)).trimmingCharacters(in: .whitespaces) }
                    if reply.isEmpty { reply = "(no answer)" }
                } catch is CancellationError { reply = buf.text.isEmpty ? "(stopped)" : buf.text }
                  catch { reply = "⚠️ \(m): \(error.localizedDescription)" }
                await MainActor.run {
                    guard let self, let (j, k) = self.messageIndex(chatID: chatID, messageID: messageID, runID: runID) else { return }
                    self.chats[j].messages[k].content = reply
                    self.save()
                }
            }
            let cancelled = Task.isCancelled
            await MainActor.run {
                guard let self, self.acceptsGeneration(runID) else { return }
                self.status = cancelled ? "Stopped" : "Group: \(who.count) repl\(who.count == 1 ? "y" : "ies")"
                if !cancelled, let j = self.idx(chatID) { WorkspaceStore.shared.captureCompletedTurn(self.chats[j], params: params) }
                self.finishGeneration(runID)
            }
        }
    }
    /// Opens (or creates) the sidebar chat for an agent: a one-participant chat with "agent:<id>".
    func openAgentChat(_ a: AgentProfile) {
        let key = ["agent:" + a.id]
        if let c = chats.first(where: { $0.participants == key }) { selection = c.id; return }
        var c = Chat(); c.title = a.name; c.participants = key; c.turnMode = "all"
        chats.append(c); selection = c.id; save()
    }
    func newParty() { var c = Chat(); c.title = "Party chat"; chats.append(c); selection = c.id; save() }
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
    var all: [String] { AgentStore.shared.agents.map { "agent:" + $0.id } + Array(Set(store.availableModels + LocalRuntime.shared.models.map { "local:\($0)" })).sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Party chat").font(.title2.bold())
            Text("Pick the agents (🤖) and models that take part in this chat. Each reply is labelled with its model. Type @name (any part of a model id) to ask only that model, or @all for everyone.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Turn order", selection: $mode) {
                Text("Everyone replies, in order").tag("all")
                Text("One per message, taking turns").tag("rotate")
            }.pickerStyle(.radioGroup)
            HStack(alignment: .top, spacing: 12) {
                List {
                    Section("Available") {
                        ForEach(all.filter { !picked.contains($0) }, id: \.self) { m in
                            HStack { Text((m.hasPrefix("agent:") ? "🤖 " : "") + GroupTurns.label(m)).lineLimit(1); Spacer(); Button("Add") { picked.append(m) } }
                        }
                    }
                }.frame(minWidth: 280)
                List {
                    Section("In this chat (turn order)") {
                        ForEach(Array(picked.enumerated()), id: \.element) { n, m in
                            HStack {
                                Text("\(n + 1). \(GroupTurns.label(m))").foregroundStyle(GroupColors.color(m)).lineLimit(1); Spacer()
                                Button { if n > 0 { picked.swapAt(n, n - 1) } } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless).disabled(n == 0)
                                Button { picked.remove(at: n) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless)
                            }
                        }
                    }
                }.frame(minWidth: 280)
            }.frame(height: 280)
            HStack {
                if store.current?.participants != nil { Button("Turn off party chat", role: .destructive) { store.setGroup([], mode: mode); dismiss() } }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { store.setGroup(picked, mode: mode); dismiss() }.keyboardShortcut(.defaultAction).disabled(picked.count == 1)
            }
            if picked.count == 1 { Text("Pick at least two agents or models (or none to turn group chat off).").font(.caption).foregroundStyle(.orange) }
        }
        .padding(20).frame(width: 640)
        .onAppear { if !loaded { picked = store.current?.participants ?? []; mode = store.current?.turnMode ?? "all"; loaded = true } }
    }
}
