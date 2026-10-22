import SwiftUI

/// In-app Help: the same plain-language guides as the repo's docs/, bundled in Resources/Help.
enum HelpDocs {
    static let order: [(String, String)] = [
        ("USER-GUIDE", "Complete guide"), ("CHAT-FEATURES", "Files, plugins, skills, MCP, voice, group chat"), ("MERGES", "Merging models"), ("INTEGRATIONS", "Integrations (Connect buttons)"), ("CONNECT", "Connect other apps"),
        ("VORTEX", "Vortex learning model"), ("POOLING", "Servers, pooling & nodes"), ("PERMISSIONS", "Owner vs user"), ("OWNER", "Owner Panel & bans"),
        ("PROVIDERS", "Outside providers"), ("MODEL-BROWSER", "Model browser"), ("STORAGE", "Storage overflow"),
        ("PC-CONTROL", "PC control"), ("API", "API reference"), ("PUBLIC-ACCESS", "Public access"),
        ("TROUBLESHOOTING", "Troubleshooting"), ("FAQ", "FAQ")]
    static var dir: URL? { Bundle.main.resourceURL?.appendingPathComponent("Help") }
    static func text(_ id: String) -> String {
        guard let d = dir, let s = try? String(contentsOf: d.appendingPathComponent(id + ".md"), encoding: .utf8) else {
            return "# Help not found\nThis build doesn't include the help files. See docs/ in the project."
        }
        return s
    }
}

private enum Block: Hashable { case h(Int, String), p(String), code(String), table(String) }

private func parse(_ md: String) -> [Block] {
    var out: [Block] = [], para: [String] = [], code: [String]? = nil, table: [String] = []
    func flushP() { if !para.isEmpty { out.append(.p(para.joined(separator: "\n"))); para = [] } }
    func flushT() { if !table.isEmpty { out.append(.table(table.filter { !$0.replacingOccurrences(of: "|", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "-: ")).isEmpty }.joined(separator: "\n"))); table = [] } }
    for line in md.components(separatedBy: "\n") {
        if code != nil {
            if line.hasPrefix("```") { out.append(.code(code!.joined(separator: "\n"))); code = nil } else { code!.append(line) }
            continue
        }
        if line.hasPrefix("```") { flushP(); flushT(); code = []; continue }
        if line.hasPrefix("|") { flushP(); table.append(line); continue } else { flushT() }
        if line.hasPrefix("#") {
            flushP(); let n = line.prefix { $0 == "#" }.count
            out.append(.h(n, String(line.dropFirst(n)).trimmingCharacters(in: .whitespaces))); continue
        }
        if line.trimmingCharacters(in: .whitespaces).isEmpty || line == "---" { flushP(); continue }
        para.append(line)
    }
    flushP(); flushT(); if let c = code { out.append(.code(c.joined(separator: "\n"))) }
    return out
}

private func inline(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
}

struct HelpView: View {
    @AppStorage("helpDoc") var doc = "USER-GUIDE"
    @Local var query = ""
    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { Optional(doc) }, set: { doc = $0 ?? "USER-GUIDE" })) {
                ForEach(HelpDocs.order.filter { query.isEmpty || HelpDocs.text($0.0).localizedCaseInsensitiveContains(query) }, id: \.0) { d in
                    Text(d.1).tag(d.0)
                }
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Search help")
            .frame(minWidth: 200)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(parse(HelpDocs.text(doc)).enumerated()), id: \.offset) { _, b in
                        switch b {
                        case .h(let n, let t): Text(inline(t)).font(n == 1 ? .largeTitle.bold() : n == 2 ? .title2.bold() : .headline).padding(.top, n <= 2 ? 8 : 2)
                        case .p(let t): Text(inline(t)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        case .code(let t):
                            VStack(alignment: .leading, spacing: 4) {
                                if t.hasPrefix("flowchart") { Text("Diagram (Mermaid)").font(.caption).foregroundStyle(.secondary) }
                                Text(t).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.6)))
                        case .table(let t):
                            ScrollView(.horizontal) { Text(t.replacingOccurrences(of: "**", with: "")).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(8) }
                                .background(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                        }
                    }
                }.padding(24).frame(maxWidth: 900, alignment: .leading)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
    }
}

struct OpenHelpButton: View {
    @Environment(\.openWindow) var openWindow
    var body: some View { Button("Red-XAI Vortex Help") { openWindow(id: "help") }.keyboardShortcut("?", modifiers: .command) }
}
