import SwiftUI

/// Composer controls: Quick replies, strength slider and reply length. Saved per chat, with a global default.
struct ComposerSettings: Codable, Equatable {
    var tier: String = "vortex"      // vortex-mini | vortex-std | vortex-pro | vortex
    var length: String = "normal"    // short | normal | long
    var quick: Bool = false
}

struct VortexTier: Identifiable { let id: String; let name: String; let size: String; let speed: String }

enum Composer {
    /// Weakest/fastest first. Speeds: warm generation measured on the Vortex server, Oct 25 2026.
    static let tiers: [VortexTier] = [
        .init(id: "vortex-mini", name: "Vortex Mini", size: "7B", speed: "≈14 tok/s · fastest"),
        .init(id: "vortex-std", name: "Vortex", size: "14B", speed: "≈6 tok/s"),
        .init(id: "vortex-pro", name: "Vortex Pro", size: "32B coder", speed: "≈3 tok/s · slowest, cold load ≈1.5 min"),
        .init(id: "vortex", name: "Vortex Max", size: "Mixtral 8x7B · default, always loaded", speed: "≈8 tok/s"),
    ]
    static var globalDefault: ComposerSettings {
        get { (UserDefaults.standard.data(forKey: "composerDefault")).flatMap { try? JSONDecoder().decode(ComposerSettings.self, from: $0) } ?? ComposerSettings() }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "composerDefault") }
    }
    static func lengthParams(_ c: ComposerSettings) -> (Int, String) {
        var maxT = 1024, hint = ""
        switch c.length { case "short": maxT = 200; hint = "Answer briefly: at most a few sentences."
                          case "long": maxT = 2048; hint = "Give a thorough, detailed answer."
                          default: break }
        if c.quick { maxT = min(maxT, 300); hint = (hint + " Reply fast and concisely.").trimmingCharacters(in: .whitespaces) }
        return (maxT, hint)
    }
    /// Applies composer settings to a request. Vortex models follow the slider; other providers keep their model.
    static func apply(_ c: ComposerSettings, params p: inout ChatParams, systemPrompt sp: inout String) {
        if p.model.hasPrefix("vortex") || p.model == Defaults.model { p.model = c.quick ? "vortex-mini" : c.tier }
        let (m, h) = lengthParams(c)
        p.maxTokens = m
        if !h.isEmpty { sp += "\n\n" + h }
    }
}

struct ComposerBar: View {
    @EnvironmentObject var store: ChatStore
    @Local var savedNote = ""
    var settings: ComposerSettings { store.current?.composer ?? Composer.globalDefault }
    func set(_ f: (inout ComposerSettings) -> Void) {
        var c = settings; f(&c)
        if let i = store.chats.firstIndex(where: { $0.id == store.selection }) { store.chats[i].composer = c; store.save() }
        savedNote = "Saved for this chat"
    }
    var tierIndex: Binding<Double> {
        Binding(get: { Double(Composer.tiers.firstIndex { $0.id == settings.tier } ?? 3) },
                set: { v in set { $0.tier = Composer.tiers[Int(v.rounded())].id } })
    }
    var body: some View {
        let t = Composer.tiers[Int(tierIndex.wrappedValue)]
        HStack(spacing: 12) {
            Toggle("Quick replies", isOn: Binding(get: { settings.quick }, set: { v in set { $0.quick = v } }))
                .toggleStyle(.switch).controlSize(.mini).help("Fast, short answers on the quickest model")
            HStack(spacing: 6) {
                Text("Strength").font(.caption)
                Slider(value: tierIndex, in: 0...3, step: 1).frame(width: 110).disabled(settings.quick)
                Text(settings.quick ? "Vortex Mini" : t.name).font(.caption.bold()).help(t.size)
            }
            Text(settings.quick ? "≈14 tok/s" : t.speed).font(.caption2).foregroundStyle(.secondary)
            Picker("Length", selection: Binding(get: { settings.length }, set: { v in set { $0.length = v } })) {
                Text("Short").tag("short"); Text("Normal").tag("normal"); Text("Long").tag("long")
            }.pickerStyle(.segmented).frame(width: 180).controlSize(.small)
            Button("Set as default") { Composer.globalDefault = settings; savedNote = "Saved as default" }.controlSize(.small)
            Text(store.current?.composer == nil ? "Using your default" : savedNote).font(.caption2).foregroundStyle(.tertiary)
            Spacer()
        }.padding(.horizontal, 12).padding(.top, 4)
    }
}
