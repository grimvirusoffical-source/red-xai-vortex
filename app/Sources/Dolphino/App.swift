import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        UserDefaults.standard.set(false, forKey: "nodeAutoStart")
        if !UserDefaults.standard.bool(forKey: "migratedVultr1") { UserDefaults.standard.set(Defaults.model, forKey: "model"); UserDefaults.standard.removeObject(forKey: "sshHost"); UserDefaults.standard.set(true, forKey: "migratedVultr1") }
        if !UserDefaults.standard.bool(forKey: "migratedGateway1") {
            for k in ["serverURL", "sshLocalPort", "sshRemotePort"] { UserDefaults.standard.removeObject(forKey: k) }
            UserDefaults.standard.set(true, forKey: "migratedGateway1")
        }
        Process.launchedProcess(launchPath: "/usr/bin/pkill", arguments: ["-f", "Dolphino.app/Contents/Resources/ggml-rpc-server"])
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ n: Notification) { MainActor.assumeIsolated {
        NodeManager.shared.shutdown(); LocalRuntime.shared.stop(); ServerStore.shared.stopAll(); ModelBrowserServer.shared.stop()
        // make sure no SSH tunnel or local model outlives the app
        let k = Process(); k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill"); k.arguments = ["-P", "\(ProcessInfo.processInfo.processIdentifier)"]; try? k.run(); k.waitUntilExit() } }
}

@main
struct DolphinoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var store = ChatStore()
    @StateObject var tunnel = TunnelManager()
    @AppStorage("theme") var theme = "system"

    var body: some Scene {
        WindowGroup("Dolphino") {
            ContentView().environmentObject(store).environmentObject(tunnel)
                .preferredColorScheme(theme == "dark" ? .dark : theme == "light" ? .light : nil)
                .frame(minWidth: 760, minHeight: 500)
        }
        .commands {
            CommandGroup(replacing: .newItem) { Button("New Chat") { store.newChat() }.keyboardShortcut("n") }
            CommandMenu("Chat") {
                Button("Stop Generating") { store.stop() }.keyboardShortcut(".")
                Button("Export Chats…") { store.exportJSON() }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Import Chats…") { store.importJSON() }
            }
        }
        Window("Library, Merges & Keys", id: "hub") { HubView() }
            .commands { CommandMenu("Models") { OpenHubButton(); Button("Browse Models in Browser…") { ModelBrowserServer.shared.open() }.keyboardShortcut("b", modifiers: [.command, .shift]) } }
        Settings {
            SettingsView().environmentObject(store).environmentObject(tunnel)
                .preferredColorScheme(theme == "dark" ? .dark : theme == "light" ? .light : nil)
        }
    }
}

struct OpenHubButton: View {
    @Environment(\.openWindow) var openWindow
    var body: some View { Button("Library, Merges & Keys…") { openWindow(id: "hub") }.keyboardShortcut("l", modifiers: [.command, .shift]) }
}

extension Color {
    static func accent(_ name: String) -> Color {
        switch name {
        case "blue": return .blue; case "teal": return .teal; case "purple": return .purple
        case "orange": return .orange; case "green": return .green; case "pink": return .pink
        default: return Color(red: 0.86, green: 0.08, blue: 0.12)
        }
    }
}
