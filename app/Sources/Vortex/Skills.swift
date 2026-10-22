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
    @Published var activeID: String = UserDefaults.standard.string(forKey: "activeSkill") ?? ""
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
    }
    func save() { let e = JSONEncoder(); e.outputFormatting = .prettyPrinted; try? e.encode(skills).write(to: file, options: .atomic) }
    var active: Skill? { skills.first { $0.id == activeID } }
    func setActive(_ id: String) { activeID = id; UserDefaults.standard.set(id, forKey: "activeSkill") }
    func upsert(_ s: Skill) { if let i = skills.firstIndex(where: { $0.id == s.id }) { skills[i] = s } else { skills.append(s) }; save() }
    func delete(_ id: String) { skills.removeAll { $0.id == id }; if activeID == id { setActive("") }; save() }

    /// "/skill-id rest of message" activates a skill for this chat and strips the prefix.
    func applySlash(_ text: inout String) {
        guard text.hasPrefix("/") else { return }
        let word = String(text.dropFirst().prefix { !$0.isWhitespace })
        if let s = skills.first(where: { $0.id == word || $0.name.lowercased() == word.lowercased() }) {
            setActive(s.id); text = String(text.dropFirst(word.count + 1)).trimmingCharacters(in: .whitespaces)
        } else if word == "noskill" { setActive(""); text = String(text.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
    }
    func systemPrompt(base: String) -> String {
        guard let s = active else { return base }
        return (base.isEmpty ? "" : base + "\n\n") + "Skill: \(s.name)\n\(s.prompt)"
    }
    /// Tools named by the active skill come from any installed plugin, even if that plugin is switched off.
    func activeExtraTools(all: [ToolSpec]) -> [ToolSpec] {
        guard let s = active, !s.tools.isEmpty else { return [] }
        let have = Set(all.map(\.name))
        let ps = PluginStore.shared
        return ps.installed.flatMap { p in p.tools.filter { s.tools.contains($0.name) && !have.contains($0.name) }.map { t in
            ToolSpec(name: t.name, description: t.description, schema: t.schema, source: "skill:\(s.id)") { args in try await PluginRunner.run(t, args) }
        } }
    }
}

struct SkillsView: View {
    @StateObject var ss = SkillStore.shared
    @StateObject var ps = PluginStore.shared
    @Local var editing: Skill?
    var allTools: [String] { ps.installed.flatMap { $0.tools.map(\.name) }.sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Skills").font(.largeTitle.bold()); Spacer()
                Button("New Skill") { editing = Skill(id: "skill-\(Int(Date().timeIntervalSince1970))", name: "", description: "", prompt: "") }
                Button("Restore starters") { for s in SkillStore.starters { ss.upsert(s) } }
            }
            Text("A skill is a reusable recipe: instructions plus the tools it may use. Pick one in the chat toolbar, or start a message with /skill-id (e.g. /researcher …). /noskill turns it off.")
                .font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(ss.skills) { s in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { Text(s.name).bold(); Text("/\(s.id)").font(.caption.monospaced()).foregroundStyle(.secondary); if ss.activeID == s.id { Text("active").font(.caption.bold()).foregroundStyle(.green) } }
                            Text(s.description).font(.caption).foregroundStyle(.secondary)
                            if !s.tools.isEmpty { Text("tools: " + s.tools.joined(separator: ", ")).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button(ss.activeID == s.id ? "Deactivate" : "Use") { ss.setActive(ss.activeID == s.id ? "" : s.id) }
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
