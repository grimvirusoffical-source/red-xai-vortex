import SwiftUI
import AppKit

@MainActor enum AccountRuntime {
    private(set) static var started = false
    static func start() {
        guard AccountGate.shared.ready, AccountProfile.isActive, !started else { return }
        started = true
        AccountProfile.defaults.set(false, forKey: "nodeAutoStart")
        if !AccountProfile.defaults.bool(forKey: "migratedVultr1") { AccountProfile.defaults.set(Defaults.model, forKey: "model"); AccountProfile.defaults.removeObject(forKey: "sshHost"); AccountProfile.defaults.set(true, forKey: "migratedVultr1") }
        if !AccountProfile.defaults.bool(forKey: "migratedVortexDefault1") {
            let cur = AccountProfile.defaults.string(forKey: "model") ?? ""
            if cur.isEmpty || cur.hasPrefix("dolphin") { AccountProfile.defaults.set(Defaults.model, forKey: "model") }
            AccountProfile.defaults.set(true, forKey: "migratedVortexDefault1")
        }
        if !AccountProfile.defaults.bool(forKey: "migratedGateway1") {
            for k in ["serverURL", "sshLocalPort", "sshRemotePort"] { AccountProfile.defaults.removeObject(forKey: k) }
            AccountProfile.defaults.set(true, forKey: "migratedGateway1")
        }
        // New installs start with the royal palette; explicit Appearance choices survive.
        if AccountProfile.defaults.object(forKey: "theme") == nil { AccountProfile.defaults.set("dark", forKey: "theme") }
        if AccountProfile.defaults.object(forKey: "accent") == nil { AccountProfile.defaults.set("gold", forKey: "accent") }
        // Chat must use the public gateway (18091), not the admin port (18092).
        let u = AccountProfile.defaults.string(forKey: "serverURL") ?? ""
        if u.contains(":18092") {
            AccountProfile.defaults.set(u.replacingOccurrences(of: ":18092", with: ":18091"), forKey: "serverURL")
        }
        if AccountProfile.defaults.string(forKey: "adminBaseURL") == nil {
            AccountProfile.defaults.set("http://127.0.0.1:18092", forKey: "adminBaseURL")
        }
        // RedX Link is the default connection (no SSH needed).
        if (AccountProfile.defaults.string(forKey: "connectionMode") ?? "link") == "link" {
            AccountProfile.defaults.set("http://127.0.0.1:18191/v1", forKey: "serverURL")
        }
        if (AccountProfile.defaults.string(forKey: "serverURL") ?? "").isEmpty {
            AccountProfile.defaults.set(Defaults.serverURL, forKey: "serverURL")
        }
        _ = PluginStore.shared; _ = SkillStore.shared; _ = AgentStore.shared
        _ = LocalAgentScheduler.shared; _ = ManagedBaseHosting.shared
        Task { await MCPStore.shared.connectEnabled() }
        Task { await ServerStore.shared.healthCheckActive() }
        Updater.shared.start()
    }
    static func withChat(_ action: (ChatStore) -> Void) {
        guard AccountGate.shared.ready, AccountProfile.isActive,
              let store = ChatStoreRef.store else { return }
        action(store)
    }
    static func stop() {
        guard started else { return }
        ChatStoreRef.store?.stop()
        LocalAgentScheduler.shared.stopForAccountChange()
        MCPStore.shared.stopAll(); ServerStore.shared.stopAll()
        ManagedBaseHosting.shared.stopAll(); RedXLink.shared.stop()
        PhoneHost.stop(); ModelBrowserServer.shared.stop()
        NodeManager.shared.shutdown(); LocalRuntime.shared.stop()
        PCExecutionState.shared.revoke(stopped: true)
        Confirm.cancelPCApproval()
    }
    static func restartAtSignIn() {
        // A clean process is intentional: no singleton, model stream or agent
        // from the old account is reused by the next account.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
            DispatchQueue.main.async {
                if error == nil { NSApp.terminate(nil) }
                else { AccountGate.shared.msg = "Signed out safely. Quit and reopen Vortex to sign in with another account." }
            }
        }
    }
}

struct AuthenticatedWorkspaceView: View {
    @StateObject private var store = ChatStore()
    @StateObject private var tunnel = TunnelManager()
    @AppStorage("theme", store: AccountProfile.defaults) private var theme = "system"
    @AppStorage("royalPalette", store: AccountProfile.defaults) private var palette = "gold"
    var body: some View {
        RoyalWindowFrame { ContentView().environmentObject(store).environmentObject(tunnel) }
            .defaultAppStorage(AccountProfile.defaults)
            .environment(\.royalPalette, palette)
            .preferredColorScheme(RoyalTheme.colorScheme(palette: palette, preference: theme))
            .onAppear { AccountRuntime.start() }
    }
}
struct AuthenticatedSettingsView: View {
    @StateObject private var store = ChatStore()
    @StateObject private var tunnel = TunnelManager()
    var body: some View {
        SettingsView().environmentObject(store).environmentObject(tunnel)
            .defaultAppStorage(AccountProfile.defaults)
    }
}
