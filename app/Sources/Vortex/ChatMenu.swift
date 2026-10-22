import SwiftUI

/// Always on / Auto / Off for a skill or plugin.
struct ModePicker: View {
    @Binding var mode: String
    var body: some View {
        Picker("", selection: $mode) {
            Text("Always on").tag("always"); Text("Auto").tag("auto"); Text("Off").tag("off")
        }.pickerStyle(.segmented).labelsHidden().frame(width: 210)
    }
}

enum ModeText {
    static func title(_ m: String) -> String { m == "always" ? "Always on" : m == "auto" ? "Auto" : "Off" }
}

/// The chat's + menu: upload files, then a mode for every skill and plugin.
struct ChatPlusMenu: View {
    @ObservedObject var ss = SkillStore.shared
    @ObservedObject var ps = PluginStore.shared
    var upload: () -> Void
    var manage: (String) -> Void
    var body: some View {
        Menu {
            Button { upload() } label: { Label("Upload files…", systemImage: "paperclip") }
            Divider()
            Section("Skills") {
                ForEach(ss.skills) { s in
                    Picker(selection: Binding(get: { ss.mode(s.id) }, set: { ss.setMode(s.id, $0) })) {
                        ForEach(["always", "auto", "off"], id: \.self) { Text(ModeText.title($0)).tag($0) }
                    } label: { Text("\(s.name)  ·  \(ModeText.title(ss.mode(s.id)))") }
                }
                Button("Manage skills…") { manage("skills") }
            }
            Section("Plugins") {
                ForEach(ps.installed) { p in
                    Picker(selection: Binding(get: { ps.mode(p.id) }, set: { ps.setMode(p.id, $0) })) {
                        ForEach(["always", "auto", "off"], id: \.self) { Text(ModeText.title($0)).tag($0) }
                    } label: { Text("\(p.name)  ·  \(ModeText.title(ps.mode(p.id)))") }
                }
                Button("Plugin Store…") { ModelBrowserServer.shared.open(page: "plugins") }
                Button("Manage plugins…") { manage("plugins") }
            }
        } label: { Image(systemName: "plus.circle.fill").font(.title) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Upload files, and choose skills and plugins (Always on / Auto / Off)")
    }
}

/// Chips by the input for every skill and plugin that is Always on or Auto.
struct ActiveItemsBar: View {
    @ObservedObject var ss = SkillStore.shared
    @ObservedObject var ps = PluginStore.shared
    struct Item: Identifiable { var id: String; var name: String; var icon: String; var mode: String; var set: (String) -> Void }
    var items: [Item] {
        ss.skills.filter { ss.mode($0.id) != "off" }.map { s in Item(id: "s:" + s.id, name: s.name, icon: "wand.and.stars", mode: ss.mode(s.id)) { ss.setMode(s.id, $0) } } +
        ps.installed.filter { ps.mode($0.id) != "off" }.map { p in Item(id: "p:" + p.id, name: p.name, icon: "puzzlepiece", mode: ps.mode(p.id)) { ps.setMode(p.id, $0) } }
    }
    var body: some View {
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(items) { i in
                        Menu {
                            ForEach(["always", "auto", "off"], id: \.self) { m in Button((i.mode == m ? "✓ " : "") + ModeText.title(m)) { i.set(m) } }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: i.icon); Text(i.name)
                                if i.mode == "auto" { Text("auto").font(.caption2).foregroundStyle(.secondary) }
                            }.font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(i.mode == "always" ? Color.accentColor.opacity(0.25) : Color.clear))
                            .overlay(Capsule().stroke(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: i.mode == "auto" ? [3] : [])))
                        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("\(i.name): \(ModeText.title(i.mode)). Click to change.")
                    }
                }.padding(.horizontal, 10).padding(.top, 6)
            }
        }
    }
}

/// Opens the Hub window on a given tab from anywhere in the chat.
@MainActor enum HubNav {
    static var opener: (() -> Void)?
    static func open(_ tab: String) { UserDefaults.standard.set(tab, forKey: "hubTab"); opener?() }
}
