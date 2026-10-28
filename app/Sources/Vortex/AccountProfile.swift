import Foundation
import CryptoKit

/// A profile is selected only from a server-verified subject, never a login
/// textbox, cached username, or the presence of a machine-wide admin key.
/// The profile is immutable for a process lifetime. Account switching restarts
/// the app so old singleton caches and tasks cannot write into a new profile.
enum AccountProfile {
    static let bootstrap = UserDefaults(suiteName: "com.redxai.vortex.auth-bootstrap.v2")!
    private static let lock = NSLock()
    private static var selected: String?
    private static var locked = false
    private static let anonymous = "signed-out-" + UUID().uuidString
    static let issuer = "https://red-xai.com"

    static func identifier(subject: String) throws -> String {
        guard !subject.isEmpty, subject.utf8.count <= 512,
              subject.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw NSError(domain: "AccountProfile", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The server did not return a stable account identifier."])
        }
        return SHA256.hash(data: Data((issuer + "\u{0}" + subject).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    static func activate(verifiedSubject: String) throws {
        let value = try identifier(subject: verifiedSubject)
        lock.lock(); defer { lock.unlock() }
        guard !locked, selected == nil || selected == value else {
            throw NSError(domain: "AccountProfile", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Restart Vortex to switch accounts safely."])
        }
        selected = value
    }
    static var id: String? { lock.lock(); defer { lock.unlock() }; return selected }
    static var isActive: Bool { lock.lock(); defer { lock.unlock() }; return selected != nil && !locked }
    static func lockForSignOut() { lock.lock(); locked = true; lock.unlock() }
    // Keep paths bound to the original account even during shutdown. Never
    // redirect a late write from an old task into the next account's folder.
    static var storageID: String { id ?? anonymous }
    static var defaults: UserDefaults {
        UserDefaults(suiteName: "com.redxai.vortex.profile." + storageID)!
    }
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Red-XAI Vortex", isDirectory: true)
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(storageID, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return base
    }
    static var credentialService: String { "com.redxai.vortex.profile." + storageID }
    static let authenticationAccounts: Set<String> = ["redx-session", "redx-vortex-refresh", "redx-vortex-subject"]
    static func service(for account: String) -> String? {
        if authenticationAccounts.contains(account) { return "com.redxai.vortex.authentication.v2" }
        return isActive ? credentialService : nil
    }
}
