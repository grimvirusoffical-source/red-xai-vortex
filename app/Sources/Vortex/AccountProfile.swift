import Foundation
import CryptoKit
import AppKit

/// A selector is NOT a login. AccountGate validates the session subject before
/// exposing any profile. Namespaces are immutable for the process lifetime.
enum AccountProfile {
    static let isTesting = ProcessInfo.processInfo.environment["VORTEX_TEST_DATA_DIR"] != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || ProcessInfo.processInfo.processName.contains("xctest")
    static let machine = UserDefaults.standard
    static let selectorKey = "vortex.activeProfile.v1"
    static let current: String = {
        if isTesting { return try! identifier(subject: "test-account") }
        let value = machine.string(forKey: selectorKey) ?? "guest"
        return value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil ? value : "guest"
    }()
    static let testSuffix = isTesting ? ".test-" + SHA256.hash(data: Data((ProcessInfo.processInfo.environment["VORTEX_TEST_DATA_DIR"] ?? UUID().uuidString).utf8)).map { String(format: "%02x", $0) }.joined() : ""
    static let preferences = UserDefaults(suiteName: "com.redxai.vortex.profile." + current + testSuffix)!
    static var legacyDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Red-XAI Vortex", isDirectory: true)
    }
    static var directory: URL {
        let base: URL
        if let temporary = ProcessInfo.processInfo.environment["VORTEX_TEST_DATA_DIR"], !temporary.isEmpty {
            base = URL(fileURLWithPath: temporary, isDirectory: true)
        } else { base = legacyDirectory }
        let url = base.appendingPathComponent("Profiles", isDirectory: true).appendingPathComponent(current, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
    static func identifier(subject: String, issuer: String = "https://red-xai.com") throws -> String {
        guard !subject.isEmpty, subject.utf8.count <= 256,
              subject.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw NSError(domain: "VortexAccount", code: 1, userInfo: [NSLocalizedDescriptionKey: "The account service did not provide a stable account ID."])
        }
        return SHA256.hash(data: Data((issuer + "\u{0}" + subject).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func credentialAccount(_ name: String, profile: String = current) -> String {
        // Only the sign-in flow itself is shared across native process restarts.
        // API/admin/provider/MCP credentials never fall back to the old global items.
        if isTesting { return "test-" + current + testSuffix + "-" + name }
        if ["redx-session", "redx-vortex-refresh", "redx-vortex-subject"].contains(name) { return name }
        return "profile-" + profile + "-" + name
    }
    @MainActor static func select(_ profile: String) {
        guard !isTesting else { return }
        machine.set(profile, forKey: selectorKey)
        machine.synchronize()
    }
    @MainActor static func relaunch(sessionHandoff: Data? = nil) {
        // The development executable stays locked and asks for a manual restart;
        // unit tests must never launch a second copy of the user's application.
        guard Bundle.main.bundleURL.pathExtension == "app", !isTesting else { return }
        if let data = sessionHandoff, let executable = Bundle.main.executableURL {
            // A session-only grant crosses this required profile restart via
            // an anonymous pipe, never argv, environment or persistent storage.
            let child = Process(), pipe = Pipe()
            child.executableURL = executable; child.arguments = ["--account-session-handoff"]
            child.standardInput = pipe; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            do {
                try child.run()
                try pipe.fileHandleForWriting.write(contentsOf: data)
                try pipe.fileHandleForWriting.close()
                NSApp.terminate(nil)
            } catch { AccountGate.shared.msg = "Account switch could not restart. Sign in again after restarting Vortex." }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error { AccountGate.shared.msg = "Restart Vortex to finish switching accounts: " + error.localizedDescription }
                else { NSApp.terminate(nil) }
            }
        }
    }
}
