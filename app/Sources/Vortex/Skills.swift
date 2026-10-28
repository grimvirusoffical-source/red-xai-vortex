import SwiftUI

/// A skill = a reusable recipe: instructions + the tools it may use (+ optional preferred model).
struct Skill: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var description: String
    var prompt: String
    var tools: [String] = []
    var model: String = ""      // empty = keep the chat's model
}

@MainActor final class SkillStore: ObservableObject {
    static let shared = SkillStore()
    @Published var skills: [Skill] = []
    @Published var modes: [String: String] = AccountProfile.preferences.dictionary(forKey: "skillModes") as? [String: String] ?? [:]
    var file: URL { ChatStore.dir.appendingPathComponent("skills.json") }

    static let starters: [Skill] = [
        .init(id: "researcher", name: "Researcher", description: "Searches the web, reads sources and answers with citations.",
              prompt: "You are a careful researcher. Use web_search, then fetch_url on the 2–3 best results. Answer concisely and cite sources as [n] with their URLs at the end.",
              tools: ["web_search", "fetch_url"]),
        .init(id: "code-reviewer", name: "Code Reviewer", description: "Reviews attached or pasted code for bugs, security and style.",
              prompt: "You are a senior code reviewer. List concrete bugs first (with line references), then security issues, then simplifications. Show fixed code for each issue."),
        .init(id: "file-summary", name: "Summarize a file", description: "Reads a file from your home folder and summarizes it.",
              prompt: "Read the file the user names with read_file (use list_folder to find it if needed). Give a 5-bullet summary, then key details.",
              tools: ["read_file", "list_folder"]),
        .init(id: "math-tutor", name: "Math Tutor", description: "Explains step by step and checks arithmetic with the calculator.",
              prompt: "Teach step by step. Verify every numeric result with the calculator tool before stating it.", tools: ["calculator"]),
        .init(id: "trip-weather", name: "Trip Weather", description: "Weather-aware packing and plans for a destination.",
              prompt: "Get the forecast with the weather tool, then suggest what to pack and a day-by-day plan that fits the weather.", tools: ["weather"]),
    ]

    init() {
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode([Skill].self, from: d) { skills = s } else { skills = Self.starters; save() }
        if let old = AccountProfile.preferences.string(forKey: "activeSkill"), !old.isEmpty, modes.isEmpty { setMode(old, "always") } // migrate the old single pick
        AccountProfile.preferences.removeObject(forKey: "activeSkill")
    }
    func mode(_ id: String) -> String { modes[id] ?? "off" }
    func setMode(_ id: String, _ m: String) { modes[id] = m; AccountProfile.preferences.set(modes, forKey: "skillModes") }
    var always: [Skill] { skills.filter { mode($0.id) == "always" } }
    var auto: [Skill] { skills.filter { mode($0.id) == "auto" } }
    func save() { let e = JSONEncoder(); e.outputFormatting = .prettyPrinted; try? e.encode(skills).write(to: file, options: .atomic) }
    /// Preferred model of the first always-on skill that names one.
    var preferredModel: String? { always.first { !$0.model.isEmpty }?.model }
    func upsert(_ s: Skill) { if let i = skills.firstIndex(where: { $0.id == s.id }) { skills[i] = s } else { skills.append(s) }; save() }

    /// Skill Maker — Vortex writes a skill from a plain-language description.
    func make(description: String) async throws -> Skill {
        let prompt = """
        Write a Red-XAI Vortex skill as JSON only (no prose, no code fences).
        Schema: {"id":"kebab-id","name":"Name","description":"one line","prompt":"detailed instructions the assistant must follow","tools":["web_search"],"model":""}
        tools must be a subset of: web_search, fetch_url, read_file, list_folder, calculator, weather, wikipedia, now (or empty).
        Skill to build: \(description)
        """
        let base = AccountProfile.preferences.string(forKey: "serverURL") ?? Defaults.serverURL
        let key = Keychain.get() ?? ""
        let p = ChatParams(baseURL: base, apiKey: key, model: AccountProfile.preferences.string(forKey: "pluginMakerModel") ?? "vortex",
                           temperature: 0.2, topP: 0.9, repeatPenalty: 1.05, topK: 40, maxTokens: 1200, seed: -1)
        let j = try await Agent.complete(p, messages: [["role": "user", "content": prompt]], tools: [])
        var txt = (((j["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String) ?? ""
        if let a = txt.firstIndex(of: "{"), let b = txt.lastIndex(of: "}") { txt = String(txt[a...b]) }
        let s = try JSONDecoder().decode(Skill.self, from: Data(txt.utf8))
        guard s.id.range(of: "^[a-z0-9-]{1,40}$", options: .regularExpression) != nil else { throw NSError(domain: "Vortex", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bad skill id"]) }
        return s
    }
    func delete(_ id: String) { skills.removeAll { $0.id == id }; modes[id] = nil; AccountProfile.preferences.set(modes, forKey: "skillModes"); save() }

    /// "/skill-id rest of message" activates a skill for this chat and strips the prefix.
    func applySlash(_ text: inout String) {
        guard text.hasPrefix("/") else { return }
        let word = String(text.dropFirst().prefix { !$0.isWhitespace })
        if let s = skills.first(where: { $0.id == word || $0.name.lowercased() == word.lowercased() }) {
            setMode(s.id, "always"); text = String(text.dropFirst(word.count + 1)).trimmingCharacters(in: .whitespaces)
        } else if word == "noskill" { for s in always { setMode(s.id, "off") }; text = String(text.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
    }
    /// Always-on skills add their instructions. Auto skills are listed so the model can switch one on itself
    /// with activate_skill (or, with tools off, follow the matching one directly).
    func systemPrompt(base: String) -> String {
        var parts: [String] = base.isEmpty ? [] : [base]
        for s in always { parts.append("Skill: \(s.name)\n\(s.prompt)") }
        if !auto.isEmpty {
            if ToolRegistry.chatToolsOn {
                parts.append("Optional skills. If the request fits one, first call activate_skill with its id, then follow the instructions it returns:\n" +
                             auto.map { "- \($0.id): \($0.name). \($0.description)" }.joined(separator: "\n"))
            } else {
                parts.append("Optional skills. Follow one only if the request fits it:\n" + auto.map { "- \($0.name) (\($0.description)): \($0.prompt)" }.joined(separator: "\n"))
            }
        }
        let ap = PluginStore.shared.alwaysOn
        if ToolRegistry.chatToolsOn && !ap.isEmpty {
            parts.append("Always-on plugins: use these tools whenever they can help: " + ap.flatMap { $0.tools.map(\.name) }.joined(separator: ", ") + ".")
        }
        return parts.joined(separator: "\n\n")
    }
    /// Tools used by always-on and auto skills (from any installed plugin, even one switched off),
    /// plus activate_skill when any skill is on Auto.
    func activeExtraTools(all: [ToolSpec]) -> [ToolSpec] {
        var have = Set(all.map(\.name)), out: [ToolSpec] = []
        for s in always + auto where !s.tools.isEmpty {
            for p in PluginStore.shared.installed { for t in p.tools where s.tools.contains(t.name) && !have.contains(t.name) {
                have.insert(t.name)
                out.append(ToolSpec(name: t.name, description: t.description, schema: t.schema, source: "skill:\(s.id)") { args in try await PluginRunner.run(t, args) })
            } }
        }
        let autos = auto
        if !autos.isEmpty {
            out.append(ToolSpec(name: "activate_skill", description: "Switch on one of the optional skills for this request and get its instructions. Ids: " + autos.map(\.id).joined(separator: ", "),
                                schema: ["type": "object", "properties": ["id": ["type": "string", "description": "skill id"]], "required": ["id"]], source: "skill:auto") { args in
                let id = (args["id"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                guard let s = autos.first(where: { $0.id == id || $0.name.lowercased() == id.lowercased() }) else { return "error: no optional skill \(id). Options: " + autos.map(\.id).joined(separator: ", ") }
                return "Skill \(s.name) is active. Follow these instructions now:\n\(s.prompt)" + (s.tools.isEmpty ? "" : "\nTools for it: " + s.tools.joined(separator: ", "))
            })
        }
        return out
    }
}

struct SkillsView: View {
    @StateObject var ss = SkillStore.shared
    @StateObject var ps = PluginStore.shared
    @Local var editing: Skill?
    @Local var makerText = ""
    @Local var making = false
    @Local var makerMsg = ""
    var allTools: [String] { ps.installed.flatMap { $0.tools.map(\.name) }.sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Skills").font(.largeTitle.bold()); Spacer()
                Button("New Skill") { editing = Skill(id: "skill-\(Int(Date().timeIntervalSince1970))", name: "", description: "", prompt: "") }
                Button("Restore starters") { for s in SkillStore.starters { ss.upsert(s) } }
            }
            Text("A skill is a reusable recipe: instructions plus the tools it may use. Set each one in the chat's + menu or here: Always on (used in every chat), Auto (the model switches it on when it fits) or Off. Starting a message with /skill-id turns that skill Always on; /noskill turns Always-on skills off.")
                .font(.callout).foregroundStyle(.secondary)
            GroupBox("Skill Maker — describe a skill and Vortex writes it") {
                HStack {
                    TextField("e.g. Research a topic and cite sources", text: $makerText)
                    Button(making ? "Writing…" : "Create") {
                        making = true; makerMsg = ""
                        Task {
                            do { let s = try await ss.make(description: makerText); ss.upsert(s); editing = s; makerMsg = "Created \(s.name)." }
                            catch { makerMsg = "Maker failed: \(error.localizedDescription)" }
                            making = false
                        }
                    }.disabled(makerText.trimmingCharacters(in: .whitespaces).isEmpty || making)
                }
                if !makerMsg.isEmpty { Text(makerMsg).font(.caption).foregroundStyle(.secondary) }
            }
            List {
                ForEach(ss.skills) { s in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { Text(s.name).bold(); Text("/\(s.id)").font(.caption.monospaced()).foregroundStyle(.secondary);  }
                            Text(s.description).font(.caption).foregroundStyle(.secondary)
                            if !s.tools.isEmpty { Text("tools: " + s.tools.joined(separator: ", ")).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        ModePicker(mode: Binding(get: { ss.mode(s.id) }, set: { ss.setMode(s.id, $0) }))
                        Button("Edit") { editing = s }
                        Button(role: .destructive) { ss.delete(s.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }.padding(.vertical, 3)
                }
            }
        }
        .padding(20)
        .sheet(item: $editing) { s in SkillEditor(skill: s, tools: allTools) { ss.upsert($0); editing = nil } cancel: { editing = nil } }
    }
}

struct SkillEditor: View {
    @Local var skill: Skill
    let tools: [String]
    var save: (Skill) -> Void
    var cancel: () -> Void
    init(skill: Skill, tools: [String], save: @escaping (Skill) -> Void, cancel: @escaping () -> Void) {
        _skill = Local(wrappedValue: skill); self.tools = tools; self.save = save; self.cancel = cancel
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Skill").font(.title2.bold())
            TextField("Name", text: $skill.name)
            TextField("Slash id (a-z, 0-9, -)", text: $skill.id)
            TextField("Short description", text: $skill.description)
            Text("Instructions").font(.headline)
            TextEditor(text: $skill.prompt).font(.body.monospaced()).frame(height: 140).border(.quaternary)
            Text("Tools it may use").font(.headline)
            ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))], alignment: .leading) {
                ForEach(tools, id: \.self) { t in Toggle(t, isOn: Binding(get: { skill.tools.contains(t) }, set: { if $0 { skill.tools.append(t) } else { skill.tools.removeAll { $0 == t } } })) }
            } }.frame(height: 90)
            TextField("Preferred model (optional, e.g. qwen2.5-14b for reliable tool calls)", text: $skill.model)
            HStack { Spacer(); Button("Cancel", action: cancel); Button("Save") { save(skill) }.buttonStyle(.borderedProminent)
                .disabled(skill.name.isEmpty || skill.id.range(of: "^[a-z0-9-]{1,40}$", options: .regularExpression) == nil) }
        }.padding(20).frame(width: 560)
    }
}
