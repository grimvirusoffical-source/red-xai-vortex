import XCTest
import AppKit
@testable import Vortex

final class WorkspaceUpgradeTests: XCTestCase {
    @MainActor func testHostingSnapshotRetainsStableSourceIDsWithoutCredentials() throws {
        var base = XAIBase(name: "Published")
        let source = WorkspaceAsset(name: "notes.txt", text: "useful", bytes: 6)
        base.sources = [source, WorkspaceAsset(name: "failed", text: "STALE", sourceAvailable: false)]
        let data = try ManagedBaseHosting.snapshot(base: base) { _ in nil }
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try XCTUnwrap(value["sources"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows[0]["id"] as? String, source.id.uuidString)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("STALE"))
    }
    func testStructuredExtractionIsBoundedAndRequiresExplicitGlobalSharing() throws {
        let raw = #"{"memories":[{"title":"Language","text":"Prefers Swift"}],"worldState":null}"#
        XCTAssertEqual(try WorkspaceExtraction.parse(raw).memories?.first?.text, "Prefers Swift")
        XCTAssertThrowsError(try WorkspaceExtraction.parse(String(repeating: "x", count: 70_000)))
        XCTAssertThrowsError(try WorkspaceExtraction.parse(#"{"memories":[{"title":"","text":"bad"}]}"#))
        var chat = Chat(); XCTAssertFalse(WorkspaceExtraction.scope(for: chat).allowed)
        chat.sharedMemoryEnabled = true; XCTAssertTrue(WorkspaceExtraction.scope(for: chat).allowed)
        chat.projectID = UUID(); chat.worldID = UUID()
        let scope = WorkspaceExtraction.scope(for: chat)
        XCTAssertEqual(scope.world, chat.worldID); XCTAssertNil(scope.project)
    }
    @MainActor func testWorldProposalCannotOverwriteNewerStateAndMemoryUsesQuota() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "vortex-upgrade-" + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = WorkspaceStore(directory: root, preferences: UserDefaults(suiteName: suite)!)
        let world = store.newWorld("Isolated")
        store.state.worlds[0].state = "newer state"
        let proposal = WorkspaceProposal(kind: "worldState", chatID: UUID(), messageID: UUID(), worldID: world, title: "Old proposal", text: "replacement", originalWorldState: "old state")
        store.state.proposals = [proposal]; store.acceptProposal(proposal.id)
        XCTAssertEqual(store.state.worlds[0].state, "newer state"); XCTAssertEqual(store.state.proposals.count, 1)
        store.state.proposals[0].originalWorldState = "newer state"; store.acceptProposal(proposal.id)
        XCTAssertEqual(store.state.worlds[0].state, "replacement"); XCTAssertTrue(store.state.proposals.isEmpty)
    }
    @MainActor func testOptedInCompletedTurnSavesScopedMemoryAndReversibleWorldState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), suite = "vortex-capture-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = WorkspaceStore(directory: root, preferences: UserDefaults(suiteName: suite)!)
        let world = store.newWorld("Continuity"); store.state.worlds[0].state = "At the gate"
        store.extractionProvider = { _, _ in #"{"memories":[{"title":"Gate key","text":"The player carries the silver gate key."}],"worldState":"Inside the city"}"# }
        var chat = Chat(); chat.worldID = world; chat.memoryCapture = "save"; chat.stateEvolution = "save"
        chat.messages = [Message(role: "user", content: "Unlock the gate."), Message(role: "assistant", content: "The silver key opens it; you enter the city.")]
        let params = ChatParams(baseURL: "http://127.0.0.1:1/v1", apiKey: "", model: "fixture", temperature: 0, topP: 1, repeatPenalty: 1, topK: 1, maxTokens: 500, seed: -1)
        store.captureCompletedTurn(chat, params: params)
        for _ in 0..<50 where store.automationTasks[chat.id] != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.state.memories.first?.worldID, world); XCTAssertNil(store.state.memories.first?.projectID); XCTAssertEqual(store.state.memories.first?.generated, true)
        XCTAssertEqual(store.state.worlds[0].state, "Inside the city")
        let restore = try XCTUnwrap(store.state.proposals.first); store.acceptProposal(restore.id)
        XCTAssertEqual(store.state.worlds[0].state, "At the gate")
        let count = store.state.memories.count; store.captureCompletedTurn(chat, params: params)
        XCTAssertEqual(store.state.memories.count, count)
    }
    @MainActor func testDisabledWorldMemoryPreventsAutomaticCaptureAndProposalEditsAreValidated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), suite = "vortex-disabled-world-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = WorkspaceStore(directory: root, preferences: UserDefaults(suiteName: suite)!)
        let world = store.newWorld("No memory"); store.state.worlds[0].useMemory = false
        var called = false; store.extractionProvider = { _, _ in called = true; return #"{"memories":[]}"# }
        var chat = Chat(); chat.worldID = world; chat.memoryCapture = "save"; chat.messages = [Message(role: "assistant", content: "Completed")]
        let params = ChatParams(baseURL: "http://127.0.0.1:1/v1", apiKey: "", model: "fixture", temperature: 0, topP: 1, repeatPenalty: 1, topK: 1, maxTokens: 100, seed: -1)
        store.captureCompletedTurn(chat, params: params); XCTAssertFalse(called); XCTAssertTrue(store.state.memories.isEmpty)
        let proposal = WorkspaceProposal(kind: "memory", chatID: chat.id, messageID: UUID(), worldID: world, title: "Editable", text: "Original")
        store.state.proposals = [proposal]; store.acceptProposal(proposal.id, editedText: String(repeating: "x", count: 1501))
        XCTAssertTrue(store.state.memories.isEmpty); XCTAssertEqual(store.state.proposals.count, 1)
        store.acceptProposal(proposal.id, editedText: "Reviewed correction")
        XCTAssertEqual(store.state.memories.first?.text, "Reviewed correction"); XCTAssertTrue(store.state.proposals.isEmpty)
    }
    func testGoogleDocsURLConversionAndCredentialRejection() throws {
        XCTAssertEqual(try NativeWorkspaceIngestion.documentURL("https://docs.google.com/document/d/example-ID/edit?usp=sharing").absoluteString, "https://docs.google.com/document/d/example-ID/export?format=txt")
        XCTAssertEqual(try NativeWorkspaceIngestion.documentURL("https://docs.google.com/spreadsheets/d/example/edit").query, "format=csv")
        XCTAssertThrowsError(try NativeWorkspaceIngestion.documentURL("https://example.com/file?token=private"))
        XCTAssertThrowsError(try NativeWorkspaceIngestion.validatePublicHost("127.0.0.1"))
        XCTAssertThrowsError(try NativeWorkspaceIngestion.validatePublicHost("localhost"))
    }
    func testSignedUpdaterVersionRejectsReplayAndMismatchedTags() throws {
        XCTAssertEqual(try Updater.validateSignedVersion("2.10\n", requested: "v2.10", current: "2.9"), "2.10")
        XCTAssertThrowsError(try Updater.validateSignedVersion("2.8", requested: "v2.10", current: "2.9"))
        XCTAssertThrowsError(try Updater.validateSignedVersion("2.10", requested: "v2.10", current: "2.10"))
        XCTAssertThrowsError(try Updater.validateSignedVersion("2.10\n2.11", requested: "v2.10", current: "2.9"))
        XCTAssertThrowsError(try Updater.validateSignedVersion("invalid", requested: "v2.10", current: "2.9"))
    }
    @MainActor func testAutomaticCaptureRejectsCredentialsBeforeSendingAndBeforeSaving() async throws {
        for text in ["api_key=example-private-value", "Bearer example-private-value", "password: example-private-value", "sk-1234567890123456"] {
            let raw = try JSONSerialization.data(withJSONObject: ["memories": [["title": "Do not retain", "text": text]]])
            XCTAssertThrowsError(try WorkspaceExtraction.parse(String(decoding: raw, as: UTF8.self)))
            XCTAssertThrowsError(try WorkspaceExtraction.parse(String(decoding: try JSONSerialization.data(withJSONObject: ["memories": [], "worldState": text]), as: UTF8.self)))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), suite = "vortex-secret-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = WorkspaceStore(directory: root, preferences: UserDefaults(suiteName: suite)!)
        var calls = 0
        store.extractionProvider = { _, _ in calls += 1; return #"{"memories":[{"title":"Unsafe","text":"api_key=example-private-value"}]}"# }
        var chat = Chat(); chat.sharedMemoryEnabled = true; chat.memoryCapture = "save"
        chat.messages = [Message(role: "user", content: "My api_key=example-private-value"), Message(role: "assistant", content: "Completed")]
        let params = ChatParams(baseURL: "http://127.0.0.1:1/v1", apiKey: "", model: "fixture", temperature: 0, topP: 1, repeatPenalty: 1, topK: 1, maxTokens: 100, seed: -1)
        store.captureCompletedTurn(chat, params: params)
        XCTAssertEqual(calls, 0); XCTAssertTrue(store.state.memories.isEmpty); XCTAssertTrue(store.state.proposals.isEmpty)
        chat.messages = [Message(role: "user", content: "Remember my language preference."), Message(role: "assistant", content: "Completed")]
        store.captureCompletedTurn(chat, params: params)
        for _ in 0..<50 where store.automationTasks[chat.id] != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(calls, 1); XCTAssertTrue(store.state.memories.isEmpty); XCTAssertTrue(store.state.proposals.isEmpty)
    }
    func testRepositoryPathsAndPatchHeadersStayInsideApprovedScope() throws {
        for path in [".env", "config/.env.local", "../outside", ".git/config", "src/private.key", "node_modules/pkg/a.js", "/absolute"] { XCTAssertFalse(NativeRepositoryCode.safeRelativePath(path)) }
        XCTAssertTrue(NativeRepositoryCode.safeRelativePath("src/main.swift"))
        let patch = "--- a/src/main.swift\n+++ b/src/main.swift\n@@ -1 +1 @@\n-old\n+new\n"
        XCTAssertEqual(try NativeRepositoryCode.patchPaths(patch), ["src/main.swift"])
        XCTAssertThrowsError(try NativeRepositoryCode.patchPaths(patch.replacingOccurrences(of: "src/main.swift", with: "../outside")))
        XCTAssertThrowsError(try NativeRepositoryCode.patchPaths(patch.replacingOccurrences(of: "src/main.swift", with: ".env")))
    }
    @MainActor func testVisionExtractsActualImageText() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let image = NSImage(size: NSSize(width: 1000, height: 220))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 220).fill()
        ("VORTEX OCR 742" as NSString).draw(at: NSPoint(x: 40, y: 90), withAttributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black]); image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        do {
            let result = try await NativeWorkspaceIngestion.extract(url, kind: "image")
            XCTAssertTrue(result.text.contains("VORTEX"), result.text); XCTAssertTrue(result.text.contains("742"), result.text)
        } catch let error as NSError where error.domain == "VortexIngestionUnavailable" {
            throw XCTSkip("This Mac's Vision runtime reports OCR unavailable; media is preserved and the app reports the limitation explicitly.")
        }
    }
    func testRepositoryFileRejectsSymlinksToExcludedTargetsAndNonRegularFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in [".env", "credentials.json"] {
            try "DO_NOT_DISCLOSE".write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
            let link = folder.appendingPathComponent("README-" + name + ".md")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder.appendingPathComponent(name))
            XCTAssertThrowsError(try NativeRepositoryCode.file(root: folder, relative: link.lastPathComponent))
        }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("directory"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try NativeRepositoryCode.file(root: folder, relative: "directory"))
        XCTAssertThrowsError(try NativeRepositoryCode.file(root: folder, relative: "missing.swift"))
        XCTAssertNoThrow(try NativeRepositoryCode.file(root: folder, relative: "new.swift", allowMissing: true))
        XCTAssertNoThrow(try NativeRepositoryCode.file(root: folder, relative: "directory/new.swift", allowMissing: true))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("linked-directory"), withDestinationURL: folder.appendingPathComponent("directory"))
        XCTAssertThrowsError(try NativeRepositoryCode.file(root: folder, relative: "linked-directory/new.swift", allowMissing: true))
    }
    func testRepositoryInspectionFiltersSecretDiffsAndChecksPatch() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await NativeRepositoryCode.git(folder.path, ["init"])
        try "old\n".write(to: folder.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "old secret\n".write(to: folder.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "literal filename\n".write(to: folder.appendingPathComponent(":(glob)**"), atomically: true, encoding: .utf8)
        _ = try await NativeRepositoryCode.git(folder.path, ["add", "."])
        _ = try await NativeRepositoryCode.git(folder.path, ["-c", "user.name=Vortex Test", "-c", "user.email=test@example.invalid", "commit", "-m", "fixture"])
        try "DO_NOT_DISCLOSE\n".write(to: folder.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "new\n".write(to: folder.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try Data(repeating: 65, count: 1024 * 1024 + 1).write(to: folder.appendingPathComponent("too-large.swift"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("README.md"), withDestinationURL: folder.appendingPathComponent(".env"))
        let snapshot = try await NativeRepositoryCode.inspect(folder)
        XCTAssertTrue(snapshot.diff.contains("-old")); XCTAssertTrue(snapshot.diff.contains("+new"))
        XCTAssertFalse(snapshot.files.contains("too-large.swift")); XCTAssertFalse(snapshot.files.contains("README.md"))
        XCTAssertFalse(snapshot.files.contains(".env")); XCTAssertTrue(snapshot.files.contains(":(glob)**")); XCTAssertFalse(snapshot.diff.contains("DO_NOT_DISCLOSE"))
        let patch = "--- a/main.swift\n+++ b/main.swift\n@@ -1 +1 @@\n-new\n+reviewed\n"
        _ = try await NativeRepositoryCode.checkPatch(root: folder.path, patch: patch, temporaryDirectory: folder)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("main.swift")), "new\n")
        let creation = "--- /dev/null\n+++ b/new.swift\n@@ -0,0 +1 @@\n+created\n"
        _ = try await NativeRepositoryCode.checkPatch(root: folder.path, patch: creation, temporaryDirectory: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("new.swift").path))
        do { _ = try await NativeRepositoryCode.git(folder.path, ["diff", "--no-ext-diff", "--no-textconv", "--", "main.swift"], maxOutputBytes: 32); XCTFail("A repository operation must stop at the output bound") }
        catch { XCTAssertTrue(error.localizedDescription.contains("inspection limit")) }
    }
}
