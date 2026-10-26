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
    @Environment(\.royalPalette) private var palette
    @EnvironmentObject var store: ChatStore
    @Local var savedNote = ""
    @Local var expanded = false
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
        let _ = palette
        let t = Composer.tiers[Int(tierIndex.wrappedValue)]
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 14) {
                    Toggle("Quick replies", isOn: Binding(get: { settings.quick }, set: { v in set { $0.quick = v } }))
                        .toggleStyle(.switch).controlSize(.mini).help("Fast, short answers on the quickest model")
                    Spacer(minLength: 10)
                    Button("Set as default") { Composer.globalDefault = settings; savedNote = "Saved as default" }.buttonStyle(RoyalButtonStyle(compact: true))
                }
                HStack(spacing: 10) {
                    Text("Strength").font(.system(size: 11)).foregroundStyle(RoyalTheme.secondary)
                    Slider(value: tierIndex, in: 0...3, step: 1).frame(minWidth: 70, maxWidth: 150).disabled(settings.quick).accessibilityLabel("Model strength")
                    Text(settings.quick ? "Vortex Mini" : t.name).font(.system(size: 11, weight: .semibold)).help(t.size)
                    Spacer(minLength: 4)
                }
                Text(settings.quick ? "≈14 tok/s" : t.speed).font(.system(size: 10)).foregroundStyle(RoyalTheme.secondary)
                HStack(spacing: 10) {
                    Text("Reply length").font(.system(size: 11)).foregroundStyle(RoyalTheme.secondary)
                    Picker("Length", selection: Binding(get: { settings.length }, set: { v in set { $0.length = v } })) {
                        Text("Short").tag("short"); Text("Normal").tag("normal"); Text("Long").tag("long")
                    }.pickerStyle(.segmented).frame(maxWidth: 260).controlSize(.small)
                    Spacer(minLength: 0)
                }
                if !savedNote.isEmpty { Text(savedNote).font(.system(size: 10)).foregroundStyle(RoyalTheme.accent).accessibilityAddTraits(.updatesFrequently) }
            }.padding(.top, 12).padding(.bottom, 3)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "slider.horizontal.3").foregroundStyle(RoyalTheme.accent)
                Text("Reply settings").foregroundStyle(RoyalTheme.secondary)
                Spacer(minLength: 5)
                Text(settings.quick ? "Quick" : t.name).foregroundStyle(RoyalTheme.text)
                Text("·").foregroundStyle(RoyalTheme.secondary)
                Text(settings.length.capitalized).foregroundStyle(RoyalTheme.secondary)
                if store.current?.composer == nil { Text("· Default").foregroundStyle(RoyalTheme.secondary) }
            }.font(.system(size: 10))
        }.tint(RoyalTheme.accent)
    }
}
