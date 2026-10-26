import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        UserDefaults.standard.set(false, forKey: "nodeAutoStart")
        if !UserDefaults.standard.bool(forKey: "migratedVultr1") { UserDefaults.standard.set(Defaults.model, forKey: "model"); UserDefaults.standard.removeObject(forKey: "sshHost"); UserDefaults.standard.set(true, forKey: "migratedVultr1") }
        if !UserDefaults.standard.bool(forKey: "migratedVortexDefault1") {
            let cur = UserDefaults.standard.string(forKey: "model") ?? ""
            if cur.isEmpty || cur.hasPrefix("dolphin") { UserDefaults.standard.set(Defaults.model, forKey: "model") }
            UserDefaults.standard.set(true, forKey: "migratedVortexDefault1")
        }
        if !UserDefaults.standard.bool(forKey: "migratedGateway1") {
            for k in ["serverURL", "sshLocalPort", "sshRemotePort"] { UserDefaults.standard.removeObject(forKey: k) }
            UserDefaults.standard.set(true, forKey: "migratedGateway1")
        }
        if SelfTest.arg != nil {   // headless end-to-end test, then quit (never touches the running app's node or chats)
            MainActor.assumeIsolated { Task { await SelfTest.run(); exit(0) } }
            return
        }
        Process.launchedProcess(launchPath: "/usr/bin/pkill", arguments: ["-f", "Vortex.app/Contents/Resources/ggml-rpc-server"])
        MainActor.assumeIsolated { _ = PluginStore.shared; _ = SkillStore.shared; _ = AgentStore.shared; _ = ManagedBaseHosting.shared; Task { await MCPStore.shared.connectEnabled() }; Task { await ServerStore.shared.healthCheckActive() }; Updater.shared.start() }   // seed starter plugins/skills on first launch
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { SelfTest.arg == nil }
    func applicationWillTerminate(_ n: Notification) { MainActor.assumeIsolated {
        ManagedBaseHosting.shared.stopAll(); NodeManager.shared.shutdown(); LocalRuntime.shared.stop(); MCPStore.shared.stopAll(); ServerStore.shared.stopAll(); RedXLink.shared.stop(); ModelBrowserServer.shared.stop()
        // make sure no SSH tunnel or local model outlives the app
        let k = Process(); k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill"); k.arguments = ["-P", "\(ProcessInfo.processInfo.processIdentifier)"]; try? k.run(); k.waitUntilExit() } }
}

@main
struct VortexApp: App {
    init() {
        // New installs start with the royal palette; explicit Appearance choices survive.
        if UserDefaults.standard.object(forKey: "theme") == nil { UserDefaults.standard.set("dark", forKey: "theme") }
        if UserDefaults.standard.object(forKey: "accent") == nil { UserDefaults.standard.set("gold", forKey: "accent") }
        // Chat must use the public gateway (18091), not the admin port (18092).
        let u = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        if u.contains(":18092") {
            UserDefaults.standard.set(u.replacingOccurrences(of: ":18092", with: ":18091"), forKey: "serverURL")
        }
        if UserDefaults.standard.string(forKey: "adminBaseURL") == nil {
            UserDefaults.standard.set("http://127.0.0.1:18092", forKey: "adminBaseURL")
        }
        // RedX Link is the default connection (no SSH needed).
        if (UserDefaults.standard.string(forKey: "connectionMode") ?? "link") == "link" {
            UserDefaults.standard.set("http://127.0.0.1:18191/v1", forKey: "serverURL")
        }
        if (UserDefaults.standard.string(forKey: "serverURL") ?? "").isEmpty {
            UserDefaults.standard.set(Defaults.serverURL, forKey: "serverURL")
        }
    }

    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var store = ChatStore()
    @StateObject var tunnel = TunnelManager()
    @AppStorage("theme") var theme = "system"
    @AppStorage("royalPalette") var royalPalette = "gold"

    var body: some Scene {
        WindowGroup("Red-XAI Vortex") {
            RoyalWindowFrame { GateView { ContentView().environmentObject(store).environmentObject(tunnel) } }
                .environment(\.royalPalette, royalPalette)
                .preferredColorScheme(RoyalTheme.colorScheme(palette: royalPalette, preference: theme))
                .frame(minWidth: 760, minHeight: 540)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(after: .windowArrangement) {
                Button("Toggle Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }.keyboardShortcut("f", modifiers: [.command, .control])
            }
            CommandGroup(replacing: .appInfo) { OpenAboutButton() }
            CommandGroup(after: .appInfo) {
                Button("Sign Out of RedX") { Task { await AccountGate.shared.signOut() } }
            }
            CommandGroup(replacing: .newItem) { Button("New Chat") { store.newChat() }.keyboardShortcut("n") }
            CommandMenu("Chat") {
                Button("Stop Generating") { store.stop() }.keyboardShortcut(".")
                Button("Export Chats…") { store.exportJSON() }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Import Chats…") { store.importJSON() }
            }
        }
        Window("Red-XAI Vortex Help", id: "help") { HelpView() }
            .commands { CommandGroup(replacing: .help) {
                OpenHelpButton()
                OpenTermsButton()
                Link("Donate — keep the servers up", destination: URL(string: "https://45.77.105.187/vortex/donate")!)
            } }
        Window("About Red-XAI Vortex", id: "about") { AboutVortexView() }.windowResizability(.contentSize)
        Window("Terms of Service", id: "terms") { TermsView() }
        Window("Library, Merges & Keys", id: "hub") { GateView { HubView() } }
            .commands { CommandMenu("Models") { OpenHubButton(); Button("Browse Models in Browser…") { ModelBrowserServer.shared.open() }.keyboardShortcut("b", modifiers: [.command, .shift]) } }
        Settings {
            SettingsView().environmentObject(store).environmentObject(tunnel)
                .environment(\.royalPalette, royalPalette)
                .preferredColorScheme(RoyalTheme.colorScheme(palette: royalPalette, preference: theme))
        }
    }
}

struct OpenAboutButton: View {
    @Environment(\.openWindow) var openWindow
    var body: some View { Button("About Red-XAI Vortex") { openWindow(id: "about") } }
}
struct OpenTermsButton: View {
    @Environment(\.openWindow) var openWindow
    var body: some View { Button("Terms of Service & Privacy") { openWindow(id: "terms") } }
}

struct OpenHubButton: View {
    @Environment(\.openWindow) var openWindow
    var body: some View { Button("Library, Merges & Keys…") { openWindow(id: "hub") }.keyboardShortcut("l", modifiers: [.command, .shift]) }
}

extension Color {
    static func accent(_ name: String) -> Color {
        switch name {
        case "gold": return RoyalTheme.gold
        case "blue": return .blue; case "teal": return .teal; case "purple": return .purple
        case "orange": return .orange; case "green": return .green; case "pink": return .pink
        default: return Color(red: 0.86, green: 0.08, blue: 0.12)
        }
    }
}
