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
    static let modes = ["always", "auto", "off"]
    static func icon(_ m: String) -> String { m == "always" ? "circle.fill" : m == "auto" ? "circle.lefthalf.filled" : "circle" }
    @ViewBuilder func item(_ name: String, _ mode: String, _ set: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(Self.modes, id: \.self) { m in
                Button { set(m) } label: { Label(ModeText.title(m), systemImage: mode == m ? "checkmark" : Self.icon(m)) }
            }
        } label: { Label("\(name) — \(ModeText.title(mode))", systemImage: Self.icon(mode)) }
    }
    var activeSkills: Int { ss.skills.filter { ss.mode($0.id) != "off" }.count }
    var activePlugins: Int { ps.installed.filter { ps.mode($0.id) != "off" }.count }
    var body: some View {
        Menu {
            Button { upload() } label: { Label("Upload files…", systemImage: "paperclip") }
            Divider()
            Section("Skills · \(activeSkills) active") {
                if ss.skills.isEmpty { Text("No skills yet") }
                ForEach(ss.skills) { s in item(s.name, ss.mode(s.id)) { ss.setMode(s.id, $0) } }
                Button { manage("skills") } label: { Label("Manage skills…", systemImage: "slider.horizontal.3") }
            }
            Section("Plugins · \(activePlugins) active") {
                if ps.installed.isEmpty { Text("No plugins installed") }
                ForEach(ps.installed) { p in item(p.name, ps.mode(p.id)) { ps.setMode(p.id, $0) } }
                Button { ModelBrowserServer.shared.open(page: "plugins") } label: { Label("Plugin Store…", systemImage: "bag") }
                Button { manage("plugins") } label: { Label("Manage plugins…", systemImage: "slider.horizontal.3") }
            }
            if activeSkills + activePlugins > 0 {
                Divider()
                Button(role: .destructive) { ActiveItemsBar.allOff() } label: { Label("Turn all off", systemImage: "xmark.circle") }
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "plus.circle.fill").font(.title)
                if activeSkills + activePlugins > 0 {
                    Text("\(activeSkills + activePlugins)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .padding(3).background(Circle().fill(Color.accentColor)).offset(x: 5, y: -4)
                }
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Upload files, and choose skills and plugins (Always on / Auto / Off)")
    }
}

/// Chips by the input for every skill and plugin that is Always on or Auto.
struct ActiveItemsBar: View {
    @ObservedObject var ss = SkillStore.shared
    @ObservedObject var ps = PluginStore.shared
    struct Item: Identifiable { var id: String; var name: String; var icon: String; var mode: String; var set: (String) -> Void }
    @MainActor static func allOff() {
        for s in SkillStore.shared.skills where SkillStore.shared.mode(s.id) != "off" { SkillStore.shared.setMode(s.id, "off") }
        for p in PluginStore.shared.installed where PluginStore.shared.mode(p.id) != "off" { PluginStore.shared.setMode(p.id, "off") }
    }
    var items: [Item] {
        ss.skills.filter { ss.mode($0.id) != "off" }.map { s in Item(id: "s:" + s.id, name: s.name, icon: "wand.and.stars", mode: ss.mode(s.id)) { ss.setMode(s.id, $0) } } +
        ps.installed.filter { ps.mode($0.id) != "off" }.map { p in Item(id: "p:" + p.id, name: p.name, icon: "puzzlepiece.extension", mode: ps.mode(p.id)) { ps.setMode(p.id, $0) } }
    }
    var body: some View {
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(items) { i in
                        HStack(spacing: 4) {
                            Menu {
                                ForEach(ChatPlusMenu.modes, id: \.self) { m in
                                    Button { i.set(m) } label: { Label(ModeText.title(m), systemImage: i.mode == m ? "checkmark" : ChatPlusMenu.icon(m)) }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: i.icon).imageScale(.small); Text(i.name).lineLimit(1)
                                    if i.mode == "auto" { Text("AUTO").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary) }
                                }
                            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            Button { i.set("off") } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                                .buttonStyle(.plain).foregroundStyle(.secondary).help("Turn \(i.name) off")
                        }
                        .font(.caption).padding(.leading, 8).padding(.trailing, 6).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(i.mode == "always" ? 0.22 : 0.06)))
                        .overlay(Capsule().stroke(Color.accentColor.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: i.mode == "auto" ? [3] : [])))
                        .help("\(i.name): \(ModeText.title(i.mode)). Click to change, × to turn off.")
                    }
                    if items.count > 1 {
                        Button("Clear all") { Self.allOff() }.buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 10).padding(.top, 6)
            }
        }
    }
}

/// Opens the Hub window on a given tab from anywhere in the chat.
@MainActor enum HubNav {
    static var opener: (() -> Void)?
    static func open(_ tab: String) { AccountProfile.preferences.set(tab, forKey: "hubTab"); opener?() }
}
