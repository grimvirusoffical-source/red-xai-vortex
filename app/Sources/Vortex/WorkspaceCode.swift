import Foundation
import SwiftUI
import AppKit
import CryptoKit

struct NativeRepositorySnapshot: Equatable {
    var root: String
    var branch: String
    var status: String
    var files: [String]
    var diff: String
    var fingerprint: String
}
enum NativeRepositoryCode {
    static func safeRelativePath(_ path: String) -> Bool {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.isEmpty, !path.hasPrefix("/"), !pieces.contains(".."), !pieces.contains("") else { return false }
        let blocked = [".git", "node_modules", ".build", "build", "dist", ".venv", "venv", ".ssh", "secrets"]
        guard !pieces.contains(where: { blocked.contains($0.lowercased()) }) else { return false }
        let name = pieces.last!.lowercased()
        return !name.hasPrefix(".env") && !["credentials.json", "id_rsa", "id_ed25519"].contains(name) && ![".pem", ".key", ".p12", ".pfx"].contains(where: name.hasSuffix)
    }
    static func file(root: URL, relative: String, allowMissing: Bool = false) throws -> URL {
        guard safeRelativePath(relative) else { throw WorkspaceStore.error("Credential files, generated folders and paths outside the repository are excluded.") }
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        let original = canonical.appendingPathComponent(relative)
        let result = original.resolvingSymlinksInPath().standardizedFileURL
        guard result.path.hasPrefix(canonical.path + "/") else { throw WorkspaceStore.error("The selected path resolves outside the repository.") }
        let resolvedRelative = String(result.path.dropFirst(canonical.path.count + 1))
        guard safeRelativePath(resolvedRelative) else { throw WorkspaceStore.error("The selected path resolves to an excluded credential or generated file.") }
        if allowMissing {
            var ancestor = canonical
            let components = relative.split(separator: "/")
            for (index, piece) in components.enumerated() {
                ancestor.appendPathComponent(String(piece))
                if let values = try? ancestor.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]) {
                    guard values.isSymbolicLink != true else { throw WorkspaceStore.error("Patches cannot target symbolic links or traverse symlinked directories.") }
                    if index < components.count - 1, FileManager.default.fileExists(atPath: ancestor.path), values.isDirectory != true { throw WorkspaceStore.error("A patch parent path is not a directory.") }
                }
            }
        }
        if FileManager.default.fileExists(atPath: result.path) {
            guard try result.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw WorkspaceStore.error("Choose a regular repository file.") }
        } else if !allowMissing { throw WorkspaceStore.error("The repository file no longer exists.") }
        return result
    }
    static func git(_ root: String, _ args: [String], maxOutputBytes: Int = 4 * 1024 * 1024) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-c", "core.bigFileThreshold=1m", "-c", "core.checkStat=minimal", "-c", "core.trustctime=false", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "--literal-pathspecs", "-C", root] + args
            process.standardOutput = output; process.standardError = output
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
            defer { timeout.cancel(); try? output.fileHandleForReading.close() }
            var data = Data()
            do {
                while let chunk = try output.fileHandleForReading.read(upToCount: min(64 * 1024, maxOutputBytes + 1)), !chunk.isEmpty {
                    guard chunk.count <= maxOutputBytes - data.count else {
                        if process.isRunning { process.terminate() }
                        try? output.fileHandleForReading.close(); process.waitUntilExit()
                        throw WorkspaceStore.error("Repository output exceeds its inspection limit (4 MB by default); narrow the working tree before inspecting it.")
                    }
                    data.append(chunk)
                }
            } catch {
                if process.isRunning { process.terminate() }
                process.waitUntilExit(); throw error
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw WorkspaceStore.error("Repository operation failed: " + String(decoding: data.prefix(3000), as: UTF8.self)) }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
    static func inspect(_ selected: URL) async throws -> NativeRepositorySnapshot {
        let root = try await git(selected.path, ["rev-parse", "--show-toplevel"])
        let branch = try await git(root, ["rev-parse", "--abbrev-ref", "HEAD"])
        let status = try await git(root, ["status", "--short"])
        let paths = try await git(root, ["ls-files", "--cached", "--others", "--exclude-standard"])
        let repository = URL(fileURLWithPath: root)
        let eligible = Array(paths.components(separatedBy: "\n").filter { relative in
            guard safeRelativePath(relative), let url = try? file(root: repository, relative: relative),
                  let attributes = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  attributes.isRegularFile == true, (attributes.fileSize ?? Int.max) <= 1024 * 1024,
                  (try? repository.appendingPathComponent(relative).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return false }
            return true
        }.prefix(2000))
        let head = try await git(root, ["rev-parse", "HEAD"])
        let current = eligible.isEmpty ? "" : try await git(root, ["diff", "--no-ext-diff", "--no-textconv", "--"] + eligible)
        let staged = eligible.isEmpty ? "" : try await git(root, ["diff", "--cached", "--no-ext-diff", "--no-textconv", "--"] + eligible)
        let diff = (current.isEmpty ? "" : "Unstaged changes:\n" + current) + (staged.isEmpty ? "" : "\nStaged changes:\n" + staged)
        let fingerprint = SHA256.hash(data: Data((head + "\n" + branch + "\n" + status + "\n" + diff).utf8)).map { String(format: "%02x", $0) }.joined()
        return NativeRepositorySnapshot(root: root, branch: branch, status: status, files: eligible, diff: diff, fingerprint: fingerprint)
    }
    static func patchPaths(_ patch: String) throws -> [String] {
        guard patch.utf8.count <= 1024 * 1024, !patch.contains("GIT binary patch"), !patch.contains("120000") else { throw WorkspaceStore.error("Use a text patch smaller than 1 MB without symlink or binary changes.") }
        var paths: Set<String> = []
        for line in patch.components(separatedBy: "\n") where line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
            let raw = String(line.dropFirst(4)).split(separator: "\t", maxSplits: 1).first.map(String.init) ?? ""
            if raw == "/dev/null" { continue }
            guard raw.hasPrefix("a/") || raw.hasPrefix("b/"), safeRelativePath(String(raw.dropFirst(2))) else { throw WorkspaceStore.error("The patch touches a blocked or unsupported path. Review its file headers.") }
            paths.insert(String(raw.dropFirst(2)))
        }
        guard !paths.isEmpty else { throw WorkspaceStore.error("Provide a unified diff with --- a/file and +++ b/file headers.") }
        return paths.sorted()
    }
    static func checkPatch(root: String, patch: String, temporaryDirectory: URL) async throws -> NativeRepositorySnapshot {
        let paths = try patchPaths(patch)
        for path in paths { _ = try file(root: URL(fileURLWithPath: root), relative: path, allowMissing: true) }
        let location = temporaryDirectory.appendingPathComponent("patch-" + UUID().uuidString + ".diff")
        try patch.write(to: location, atomically: true, encoding: .utf8); defer { try? FileManager.default.removeItem(at: location) }
        _ = try await git(root, ["apply", "--check", "--whitespace=warn", location.path])
        try? FileManager.default.removeItem(at: location)
        return try await inspect(URL(fileURLWithPath: root))
    }
    @MainActor static func apply(root: String, patch: String, reviewedFingerprint: String, temporaryDirectory: URL) async throws {
        guard PCControl.shared.enabled, !PCControl.shared.killed, PCControl.shared.isOn(.filesWrite) else { throw WorkspaceStore.error("Enable PC Control → Write, move & delete files before applying a repository patch. The normal Allow once confirmation is still required.") }
        let current = try await checkPatch(root: root, patch: patch, temporaryDirectory: temporaryDirectory)
        guard current.fingerprint == reviewedFingerprint else { throw WorkspaceStore.error("The working tree changed after patch review. Check the patch again before applying it.") }
        let paths = try patchPaths(patch)
        guard Confirm.ask("Apply this reviewed repository patch?", "This changes files in \(root):\n\n\(paths.joined(separator: "\n"))\n\nThe complete patch is shown in the Code workspace. Git validation passed; no commit or push will be performed.") else { throw WorkspaceStore.error("Patch application was declined.") }
        let location = temporaryDirectory.appendingPathComponent("apply-" + UUID().uuidString + ".diff")
        try patch.write(to: location, atomically: true, encoding: .utf8); defer { try? FileManager.default.removeItem(at: location) }
        _ = try await git(root, ["apply", "--whitespace=warn", location.path])
        ActivityLog.add("coding", summary: "Applied reviewed repository patch", detail: paths.joined(separator: "\n"))
    }
}

struct NativeRepositoryView: View {
    let projectID: UUID
    @EnvironmentObject var chats: ChatStore
    @ObservedObject var workspace = WorkspaceStore.shared
    @Local var snapshot: NativeRepositorySnapshot?
    @Local var selected: Set<String> = []
    @Local var patch = ""
    @Local var reviewed = ""
    @Local var busy = false
    @Local var status = ""
    var path: String? { workspace.state.projects.first(where: { $0.id == projectID })?.repositoryPath }
    var body: some View {
        GroupBox("Connected local repository") {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Button("Choose repository…") { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK, let url = panel.url, let i = workspace.state.projects.firstIndex(where: { $0.id == projectID }) { workspace.state.projects[i].repositoryPath = url.path; workspace.save(); inspect() } }; if path != nil { Button("Inspect files and diff") { inspect() }.disabled(busy) } }
                if let path { Text(path).font(.caption).textSelection(.enabled) }
                if let snapshot {
                    Text("\(snapshot.branch) · \(snapshot.files.count) eligible files").font(.headline)
                    DisclosureGroup("Working tree status") { Text(snapshot.status.isEmpty ? "Clean" : snapshot.status).font(.caption.monospaced()).textSelection(.enabled) }
                    DisclosureGroup("Select code context") {
                        ScrollView { LazyVStack(alignment: .leading, spacing: 3) { ForEach(snapshot.files, id: \.self) { file in Toggle(file, isOn: Binding(get: { selected.contains(file) }, set: { if $0 { selected.insert(file) } else { selected.remove(file) } })).font(.caption.monospaced()) } } }.frame(height: 160)
                        Button("Import selected code snapshots") { importSelected(snapshot) }.disabled(selected.isEmpty || busy)
                        Text("Credential files and generated dependency folders are excluded. Choose at most 20 files; context snapshots keep their repository paths.").font(.caption2).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Review current diff") {
                        ScrollView([.horizontal, .vertical]) { Text(snapshot.diff.isEmpty ? "No changes" : snapshot.diff).font(.caption.monospaced()).textSelection(.enabled) }.frame(height: 160)
                        Button("Use this diff in current chat review") { chats.updateCurrent { $0.codingMode = "review"; $0.codingNotes = "Repository: \(snapshot.root)\nBranch: \(snapshot.branch)\n\n\(snapshot.diff)" }; status = "Repository diff added to this chat's review context." }
                    }
                    DisclosureGroup("Check and apply a proposed patch") {
                        TextEditor(text: $patch).font(.caption.monospaced()).frame(height: 170).onChange(of: patch) { _, _ in reviewed = "" }
                        HStack {
                            Button("Use latest assistant diff") { if let reply = chats.current?.messages.last(where: { $0.role == "assistant" })?.content, let start = reply.range(of: "```diff\n"), let end = reply[start.upperBound...].range(of: "```") { patch = String(reply[start.upperBound..<end.lowerBound]); reviewed = "" } else { status = "No fenced diff found in the latest reply. Paste a unified diff above." } }
                            Button("Check patch") { check(snapshot) }.disabled(patch.isEmpty || busy)
                            Button("Apply reviewed patch…") { apply(snapshot) }.disabled(reviewed.isEmpty || busy)
                        }
                        Text("Applying requires the existing PC Control file-write permission and Allow once confirmation. The app checks for changes since review and never commits or pushes automatically.").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
            }.padding(8)
        }
    }
    func inspect() { guard let path else { return }; busy = true; Task { do { snapshot = try await NativeRepositoryCode.inspect(URL(fileURLWithPath: path)); status = "Repository inspected. No files were modified."; reviewed = "" } catch { status = error.localizedDescription }; busy = false } }
    func importSelected(_ snapshot: NativeRepositorySnapshot) {
        guard selected.count <= 20 else { status = "Select at most 20 files at once."; return }
        busy = true
        Task {
            do {
                for relative in selected.sorted() {
                    let url = try NativeRepositoryCode.file(root: URL(fileURLWithPath: snapshot.root), relative: relative)
                    guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1024 * 1024 else { throw WorkspaceStore.error("\(relative) exceeds the 1 MB code-context limit.") }
                    var asset = try await workspace.importAsset(url); asset.name = relative
                    guard let i = workspace.state.projects.firstIndex(where: { $0.id == projectID }) else { break }
                    workspace.state.projects[i].files.append(asset)
                }
                workspace.save(); status = "Selected code snapshots imported with repository paths."
            } catch { status = error.localizedDescription }
            busy = false
        }
    }
    func check(_ snapshot: NativeRepositorySnapshot) { busy = true; Task { do { let checked = try await NativeRepositoryCode.checkPatch(root: snapshot.root, patch: patch, temporaryDirectory: workspace.directory); reviewed = checked.fingerprint; status = "Git patch validation passed. Review the patch above before applying." } catch { reviewed = ""; status = error.localizedDescription }; busy = false } }
    func apply(_ snapshot: NativeRepositorySnapshot) { busy = true; Task { do { try await NativeRepositoryCode.apply(root: snapshot.root, patch: patch, reviewedFingerprint: reviewed, temporaryDirectory: workspace.directory); status = "Reviewed patch applied. Run the project's relevant checks before committing."; self.snapshot = try await NativeRepositoryCode.inspect(URL(fileURLWithPath: snapshot.root)); reviewed = "" } catch { status = error.localizedDescription }; busy = false } }
}
