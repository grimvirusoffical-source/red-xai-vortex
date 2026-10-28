import Foundation
import AppKit

/// Auto-update from GitHub Releases: checks on launch and every 4 hours, verifies the signed release
/// manifest with the bundled release verifier (fails closed if it is missing) and the Developer ID
/// signature (team NZPU8H843J), then swaps the app and relaunches. SHA256SUMS is public info only.
@MainActor final class Updater: ObservableObject {
    static let shared = Updater()
    static let teamID = "NZPU8H843J"
    var api: String { ProcessInfo.processInfo.environment["VORTEX_UPDATE_API"] ?? "https://api.github.com/repos/grimvirusoffical-source/red-xai-vortex" }
    var enabled: Bool { !AccountProfile.defaults.bool(forKey: "noAutoUpdate") }
    @Published private(set) var checking = false
    @Published private(set) var status = "Updates are checked when Vortex starts and every four hours."
    private var timer: Timer?

    func start() {
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: 4 * 3600, repeats: true) { _ in Task { @MainActor in await Updater.shared.check() } }
    }

    nonisolated static func newer(_ a: String, _ b: String) -> Bool {
        let p = { (s: String) in s.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").map { Int($0) ?? 0 } }
        let x = p(a), y = p(b)
        for i in 0..<max(x.count, y.count) {
            let u = i < x.count ? x[i] : 0, v = i < y.count ? y[i] : 0
            if u != v { return u > v }
        }
        return false
    }

    nonisolated static func validateSignedVersion(_ stdout: String, requested: String, current: String) throws -> String {
        func version(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.range(of: #"^v?[0-9]+(?:\.[0-9]+){0,3}$"#, options: .regularExpression) != nil else { return nil }
            return trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        }
        guard let signed = version(stdout), let requested = version(requested), signed == requested, version(current) != nil, newer(signed, current) else {
            throw Fail(errorDescription: "signed release version does not match the requested newer release; update rejected")
        }
        return signed
    }

    nonisolated static func shouldCheck(autoEnabled: Bool, manual: Bool) -> Bool {
        autoEnabled || manual
    }

    func check(manual: Bool = false) async {
        guard Self.shouldCheck(autoEnabled: enabled, manual: manual), !checking else { return }
        checking = true
        if manual { status = "Checking GitHub for signed Vortex updates…" }
        defer { checking = false }
        do {
            let cur = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            let (d, response) = try await URLSession.shared.data(from: URL(string: api + "/releases/latest")!)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw Fail(errorDescription: "GitHub's release service could not be reached.")
            }
            guard let j = try JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let tag = j["tag_name"] as? String,
                  (j["draft"] as? Bool) != true, (j["prerelease"] as? Bool) != true,
                  let assets = j["assets"] as? [[String: Any]] else {
                throw Fail(errorDescription: "GitHub returned an invalid release.")
            }
            guard Self.newer(tag, cur) else {
                if manual { status = "Vortex \(cur) is up to date." }
                return
            }
            func url(_ f: (String) -> Bool) -> URL? {
                assets.first { f($0["name"] as? String ?? "") }
                    .flatMap { URL(string: $0["browser_download_url"] as? String ?? "") }
            }
            guard let zipURL = url({ $0.hasSuffix("-mac.zip") }), let manURL = url({ $0 == "release-manifest.json" }),
                  let sigURL = url({ $0 == "release-manifest.sig" }),
                  [zipURL, manURL, sigURL].allSatisfy({ $0.scheme == "https" && $0.host == "github.com" }) else {
                throw Fail(errorDescription: "The new release has no trusted Mac update package.")
            }
            status = "Downloading and verifying Vortex \(tag)…"
            try await install(tag: tag, zipURL: zipURL, manURL: manURL, sigURL: sigURL)
        } catch {
            status = "Update failed: " + error.localizedDescription
            NSLog("Vortex update: \(error.localizedDescription)")
        }
    }

    struct Fail: LocalizedError { let errorDescription: String? }

    func install(tag: String, zipURL: URL, manURL: URL, sigURL: URL) async throws {
        guard let verifier = Bundle.main.url(forResource: "redx-verify", withExtension: nil) else {
            throw Fail(errorDescription: "this build cannot verify signed releases; download updates manually")
        }
        let dl = FileManager.default.temporaryDirectory.appendingPathComponent("vortex-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dl, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dl) }
        let man = dl.appendingPathComponent("release-manifest.json"), sig = dl.appendingPathComponent("release-manifest.sig")
        try await URLSession.shared.data(from: manURL).0.write(to: man)
        try await URLSession.shared.data(from: sigURL).0.write(to: sig)
        let (t, _) = try await URLSession.shared.download(from: zipURL)
        let tmp = dl.appendingPathComponent(zipURL.lastPathComponent)
        try FileManager.default.moveItem(at: t, to: tmp)
        let verify = Process(), verifiedOutput = Pipe()
        verify.executableURL = verifier; verify.arguments = [man.path, sig.path, tmp.path]
        verify.standardOutput = verifiedOutput; verify.standardError = FileHandle.nullDevice
        try verify.run()
        var versionData = Data()
        while let chunk = try verifiedOutput.fileHandleForReading.read(upToCount: 256), !chunk.isEmpty {
            guard versionData.count + chunk.count <= 1024 else { if verify.isRunning { verify.terminate() }; try? verifiedOutput.fileHandleForReading.close(); verify.waitUntilExit(); throw Fail(errorDescription: "invalid release verifier output; update rejected") }
            versionData.append(chunk)
        }
        verify.waitUntilExit(); try? verifiedOutput.fileHandleForReading.close()
        guard verify.terminationStatus == 0 else { throw Fail(errorDescription: "release signature check failed, update rejected") }
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let signedVersion = try Self.validateSignedVersion(String(decoding: versionData, as: UTF8.self), requested: tag, current: currentVersion)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("vortex-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        guard run("/usr/bin/ditto", ["-x", "-k", tmp.path, work.path]) == 0,
              let app = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" })
        else { throw Fail(errorDescription: "bad update package") }
        // Developer ID check: valid signature, and from our team.
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0,
              run("/usr/bin/codesign", ["--verify", "-R=anchor apple generic and certificate leaf[subject.OU] = \"\(Updater.teamID)\"", app.path]) == 0
        else { throw Fail(errorDescription: "Developer ID signature check failed, update rejected") }
        guard let packageVersion = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String,
              (try? Self.validateSignedVersion(packageVersion, requested: signedVersion, current: currentVersion)) != nil else { throw Fail(errorDescription: "signed release and application versions differ; update rejected") }
        let dest = Bundle.main.bundleURL
        let old = dest.deletingLastPathComponent()
            .appendingPathComponent(".Vortex-old-\(tag)-\(UUID().uuidString).app")
        // Preserve the working app for rollback until LaunchServices has opened the new one.
        try FileManager.default.moveItem(at: dest, to: old)
        do {
            try FileManager.default.moveItem(at: app, to: dest)
        } catch {
            try? FileManager.default.moveItem(at: old, to: dest)
            throw error
        }
        // LaunchServices starts the new app independently of our process. The old
        // shell-based launcher was killed by AppDelegate.applicationWillTerminate.
        guard run("/usr/bin/open", ["-n", "-a", dest.path]) == 0 else {
            try? FileManager.default.moveItem(at: dest, to: work.appendingPathComponent("failed-update.app"))
            try? FileManager.default.moveItem(at: old, to: dest)
            throw Fail(errorDescription: "Vortex could not reopen; the previous app was restored.")
        }
        status = "Vortex \(signedVersion) installed. Restarting…"
        NSLog("Vortex update: installed \(tag), relaunching")
        NSApp.terminate(nil)

    }

    @discardableResult func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit(); return p.terminationStatus
    }
}
