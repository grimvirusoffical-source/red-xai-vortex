import Foundation
import AppKit

/// Auto-update from GitHub Releases: checks on launch and every 4 hours, verifies the signed release
/// manifest with the bundled release verifier (fails closed if it is missing) and the Developer ID
/// signature (team NZPU8H843J), then swaps the app and relaunches. SHA256SUMS is public info only.
@MainActor final class Updater {
    static let shared = Updater()
    static let teamID = "NZPU8H843J"
    var api: String { ProcessInfo.processInfo.environment["VORTEX_UPDATE_API"] ?? "https://api.github.com/repos/grimvirusoffical-source/red-xai-vortex" }
    var enabled: Bool { !UserDefaults.standard.bool(forKey: "noAutoUpdate") }
    private var timer: Timer?

    func start() {
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: 4 * 3600, repeats: true) { _ in Task { @MainActor in await Updater.shared.check() } }
    }

    static func newer(_ a: String, _ b: String) -> Bool {
        let p = { (s: String) in s.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").map { Int($0) ?? 0 } }
        let x = p(a), y = p(b)
        for i in 0..<max(x.count, y.count) {
            let u = i < x.count ? x[i] : 0, v = i < y.count ? y[i] : 0
            if u != v { return u > v }
        }
        return false
    }

    func check() async {
        guard enabled else { return }
        do {
            let cur = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            let (d, _) = try await URLSession.shared.data(from: URL(string: api + "/releases/latest")!)
            guard let j = try JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let tag = j["tag_name"] as? String, Updater.newer(tag, cur),
                  (j["draft"] as? Bool) != true, (j["prerelease"] as? Bool) != true,
                  let assets = j["assets"] as? [[String: Any]] else { return }
            func url(_ f: (String) -> Bool) -> URL? {
                assets.first { f($0["name"] as? String ?? "") }.flatMap { URL(string: $0["browser_download_url"] as? String ?? "") }
            }
            guard let zipURL = url({ $0.hasSuffix("-mac.zip") }), let manURL = url({ $0 == "release-manifest.json" }),
                  let sigURL = url({ $0 == "release-manifest.sig" }) else { return }
            try await install(tag: tag, zipURL: zipURL, manURL: manURL, sigURL: sigURL)
        } catch { NSLog("Vortex update: \(error.localizedDescription)") }
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
        guard run(verifier.path, [man.path, sig.path, tmp.path]) == 0 else {
            throw Fail(errorDescription: "release signature check failed, update rejected")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("vortex-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        guard run("/usr/bin/ditto", ["-x", "-k", tmp.path, work.path]) == 0,
              let app = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" })
        else { throw Fail(errorDescription: "bad update package") }
        // Developer ID check: valid signature, and from our team.
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0,
              run("/usr/bin/codesign", ["--verify", "-R=anchor apple generic and certificate leaf[subject.OU] = \"\(Updater.teamID)\"", app.path]) == 0
        else { throw Fail(errorDescription: "Developer ID signature check failed, update rejected") }
        let dest = Bundle.main.bundleURL
        let old = dest.deletingLastPathComponent().appendingPathComponent(".Vortex-old-\(tag).app")
        try? FileManager.default.removeItem(at: old)
        try FileManager.default.moveItem(at: dest, to: old)
        do { try FileManager.default.moveItem(at: app, to: dest) } catch { try? FileManager.default.moveItem(at: old, to: dest); throw error }
        try? FileManager.default.removeItem(at: old)
        NSLog("Vortex update: installed \(tag), relaunching")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open -n \"\(dest.path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }

    @discardableResult func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit(); return p.terminationStatus
    }
}
