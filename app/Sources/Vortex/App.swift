import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        if SelfTest.arg != nil {   // headless end-to-end test, then quit (never touches the running app's node or chats)
            MainActor.assumeIsolated { Task { await SelfTest.run(); exit(0) } }
            return
        }

    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { SelfTest.arg == nil }
    func applicationWillTerminate(_ n: Notification) { MainActor.assumeIsolated {
        if AccountRuntime.started { AccountRuntime.stop() }
        // make sure no SSH tunnel or local model outlives the app
        let k = Process(); k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill"); k.arguments = ["-P", "\(ProcessInfo.processInfo.processIdentifier)"]; try? k.run(); k.waitUntilExit() } }
}

@main
struct VortexApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("Red-XAI Vortex") {
            GateView { AuthenticatedWorkspaceView() }
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
            CommandGroup(replacing: .newItem) { Button("New Chat") { AccountRuntime.withChat { $0.newChat() } }.keyboardShortcut("n") }
            CommandMenu("Chat") {
                Button("Stop Generating") { AccountRuntime.withChat { $0.stop() } }.keyboardShortcut(".")
                Button("Export Chats…") { AccountRuntime.withChat { $0.exportJSON() } }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Import Chats…") { AccountRuntime.withChat { $0.importJSON() } }
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
        Window("Library, Merges & Keys", id: "hub") { GateView { HubView().defaultAppStorage(AccountProfile.defaults) } }
            .commands { CommandMenu("Models") { OpenHubButton(); Button("Browse Models in Browser…") { if AccountGate.shared.ready { ModelBrowserServer.shared.open() } }.keyboardShortcut("b", modifiers: [.command, .shift]) } }
        Settings { GateView { AuthenticatedSettingsView() } }
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
