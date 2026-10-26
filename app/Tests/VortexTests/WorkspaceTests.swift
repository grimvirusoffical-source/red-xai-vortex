import XCTest
@testable import Vortex

final class WorkspaceTests: XCTestCase {
    @MainActor private func temporaryStore() throws -> WorkspaceStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vortex-workspace-test-" + UUID().uuidString)
        let suite = "vortex-workspace-test-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        addTeardownBlock { try? FileManager.default.removeItem(at: url); UserDefaults.standard.removePersistentDomain(forName: suite) }
        return WorkspaceStore(directory: url, preferences: preferences)
    }
    func testLegacyChatDecodesWithoutWorkspaceFields() throws {
        let id = UUID()
        let data = Data("{\"id\":\"\(id)\",\"title\":\"Existing chat\",\"messages\":[],\"created\":0,\"updated\":0,\"pinned\":true}".utf8)
        let chat = try JSONDecoder().decode(Chat.self, from: data)
        XCTAssertEqual(chat.id, id); XCTAssertTrue(chat.pinned); XCTAssertNil(chat.projectID); XCTAssertNil(chat.worldID); XCTAssertNil(chat.sharedMemoryEnabled)
        XCTAssertEqual(try JSONDecoder().decode(Chat.self, from: JSONEncoder().encode(chat)), chat)
    }
    @MainActor func testSharedToggleAndWorldIsolation() throws {
        let store = try temporaryStore()
        let worldID = store.newWorld("Moon harbor")
        try store.upsertMemory(VortexMemory(title: "Global secret", text: "GLOBAL_ONLY"))
        try store.upsertMemory(VortexMemory(title: "World secret", text: "WORLD_ONLY", worldID: worldID))
        var chat = Chat()
        XCTAssertTrue(store.visibleMemory(for: chat).isEmpty)
        chat.sharedMemoryEnabled = true
        XCTAssertEqual(store.visibleMemory(for: chat).map(\.text), ["GLOBAL_ONLY"])
        chat.sharedMemoryEnabled = false; XCTAssertTrue(store.visibleMemory(for: chat).isEmpty)
        chat.worldID = worldID; XCTAssertEqual(store.visibleMemory(for: chat).map(\.text), ["WORLD_ONLY"])
        let context = store.context(for: chat, basePrompt: "test", query: "secret", maxChars: 12000).system
        XCTAssertTrue(context.contains("WORLD_ONLY")); XCTAssertFalse(context.contains("GLOBAL_ONLY"))
        chat.sharedMemoryEnabled = true
        XCTAssertEqual(Set(store.visibleMemory(for: chat).map(\.text)), Set(["WORLD_ONLY", "GLOBAL_ONLY"]))
        chat.sharedMemoryEnabled = false
        store.state.worlds[0].useMemory = false; XCTAssertTrue(store.visibleMemory(for: chat).isEmpty)
    }
    @MainActor func testQuotaRejectsWithoutEvictingExistingEntries() throws {
        let store = try temporaryStore(); try store.setQuota(1024 * 1024)
        let memory = VortexMemory(title: "Saved", text: "keep this")
        try store.upsertMemory(memory)
        XCTAssertThrowsError(try store.upsertMemory(VortexMemory(title: "Too large", text: String(repeating: "x", count: 1024 * 1024))))
        XCTAssertEqual(store.state.memories, [memory]); XCTAssertThrowsError(try store.setQuota(100))
    }
    @MainActor func testRemotePermissionAndAvailabilityGateContext() throws {
        let store = try temporaryStore()
        var base = XAIBase(name: "Friendly alias", endpoint: "https://192.0.2.1")
        base.status = "Available"; base.sources = [WorkspaceAsset(name: "record.txt", text: "BASE_CONTENT")]
        store.state.bases = [base]
        var chat = Chat(); chat.baseIDs = [base.id]
        func context() -> String { store.context(for: chat, basePrompt: "system", query: "record", maxChars: 12000).system }
        XCTAssertTrue(context().contains("BASE_CONTENT")); XCTAssertFalse(context().contains("192.0.2.1"))
        store.state.bases[0].canUse = false; XCTAssertFalse(context().contains("BASE_CONTENT"))
        store.state.bases[0].canUse = true; store.state.bases[0].status = "Unavailable"; XCTAssertFalse(context().contains("BASE_CONTENT"))
        store.state.bases[0].status = "Available"; store.state.bases[0].connected = false; XCTAssertFalse(context().contains("BASE_CONTENT"))
    }
    func testEndpointRequiresSecureTransportAndNoEmbeddedCredentials() throws {
        XCTAssertEqual(try BaseClient.endpoint("https://base.example.com/v1/").absoluteString, "https://base.example.com")
        XCTAssertNoThrow(try BaseClient.endpoint("http://127.0.0.1:7792"))
        XCTAssertNoThrow(try BaseClient.endpoint("http://[::1]:7792"))
        for raw in ["http://192.0.2.1", "http://localhost.attacker.test", "https://user:token@example.com", "https://example.com?token=secret", "file:///tmp/base", "https://example.com/#token"] { XCTAssertThrowsError(try BaseClient.endpoint(raw), raw) }
    }
    func testRemoteBaseIdentityIsPinnedAfterFirstConnection() throws {
        XCTAssertNoThrow(try BaseClient.validateIdentity(pinned: nil, received: "base-original"))
        XCTAssertNoThrow(try BaseClient.validateIdentity(pinned: "base-original", received: "base-original"))
        XCTAssertThrowsError(try BaseClient.validateIdentity(pinned: "base-original", received: "base-replacement"))
        XCTAssertThrowsError(try BaseClient.validateIdentity(pinned: nil, received: ""))
    }
    func testDocumentCitationsRejectCredentialFieldsAndAllowGoogleSharingLinks() throws {
        let normal = "https://docs.google.com/document/d/example/edit?usp=sharing#heading=h.example"
        XCTAssertEqual(try BaseClient.documentCitation(normal), normal)
        XCTAssertNil(try BaseClient.documentCitation("  "))
        for value in ["https://example.com/doc?token=PRIVATE", "https://example.com/doc?secret=PRIVATE", "https://example.com/doc?api_key=PRIVATE", "https://example.com/doc?signature=PRIVATE", "https://example.com/doc?access_token=PRIVATE", "https://example.com/doc?%74oken=PRIVATE", "https://example.com/doc#access_token=PRIVATE", "https://example.com/doc#api_key=PRIVATE", "https://user:PRIVATE@example.com/doc"] {
            XCTAssertThrowsError(try BaseClient.documentCitation(value)) { error in XCTAssertFalse(error.localizedDescription.contains("PRIVATE")) }
        }
    }
    @MainActor func testRejectedDocumentCitationPreservesExistingSourceAndShowsError() throws {
        let store = try temporaryStore(); store.newLocalBase("Source library")
        let id = try XCTUnwrap(store.state.bases.first?.id)
        XCTAssertTrue(store.addBaseText(id, name: "Saved document", text: "KEEP_ORIGINAL", documentURL: "https://docs.google.com/document/d/example/edit?usp=sharing"))
        let original = store.state.bases[0].sources
        XCTAssertFalse(store.addBaseText(id, name: "Rejected draft", text: "DRAFT_CONTENT", documentURL: "https://example.com/doc?token=PRIVATE"))
        XCTAssertEqual(store.state.bases[0].sources, original)
        XCTAssertFalse(store.errorMessage.isEmpty); XCTAssertFalse(store.errorMessage.contains("PRIVATE"))
        XCTAssertTrue(store.addBaseText(id, name: "No citation", text: "PLAIN_TEXT", documentURL: ""))
    }
    func testHostManifestUsesNumericRevision() throws {
        let data = Data(#"{"id":"base-id","name":"Hosted","revision":3,"sources":[{"id":"source-id","name":"note.txt","kind":"text","bytes":4,"text":"note"}]}"#.utf8)
        let manifest = try JSONDecoder().decode(BaseClient.Manifest.self, from: data)
        XCTAssertEqual(manifest.revision, "3"); XCTAssertEqual(manifest.sources.first?.text, "note")
    }
    @MainActor func testProjectPersonalityAndCodingContextRemainBounded() throws {
        let store = try temporaryStore()
        let projectID = store.newProject("Compiler")
        store.state.projects[0].instructions = "Preserve the parser behavior"
        store.state.projects[0].files = [WorkspaceAsset(name: "parser.swift", text: String(repeating: "code\n", count: 20000))]
        let persona = Persona(name: "Reviewer", prompt: "Explain tradeoffs")
        store.savePersonality(persona); store.state.projects[0].personaID = persona.id
        var chat = Chat(); chat.projectID = projectID; chat.codingMode = "review"; chat.codingNotes = "diff --git parser.swift"
        let context = store.context(for: chat, basePrompt: "Original system", query: "parser", maxChars: 8000).system
        XCTAssertTrue(context.hasPrefix("Original system")); XCTAssertTrue(context.contains("Reviewer")); XCTAssertTrue(context.contains("diff --git")); XCTAssertTrue(context.contains("parser.swift")); XCTAssertLessThan(context.count, 9000)
    }
    @MainActor func testAssetPathsCannotEscapeOwnedDirectory() throws {
        let store = try temporaryStore()
        for path in ["../secret", "/tmp/secret", ".", "..", "nested/file"] { XCTAssertNil(store.assetURL(WorkspaceAsset(name: "bad", relativePath: path))) }
        XCTAssertEqual(store.assetURL(WorkspaceAsset(name: "ok", relativePath: "owned.txt"))?.deletingLastPathComponent(), store.assetsDirectory)
    }
    @MainActor func testMemoryAttachmentCopyPersistenceAndDeletion() async throws {
        let store = try temporaryStore()
        let source = store.directory.appendingPathComponent("source.txt")
        try "owned content".write(to: source, atomically: true, encoding: .utf8)
        let memory = VortexMemory(title: "Files"); try store.upsertMemory(memory)
        await store.attachToMemory(memory.id, urls: [source])
        let saved = try XCTUnwrap(store.state.memories.first?.attachments.first)
        XCTAssertEqual(saved.text, "owned content")
        let copy = try XCTUnwrap(store.assetURL(saved)); XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        let loaded = WorkspaceStore(directory: store.directory, preferences: store.preferences)
        XCTAssertEqual(loaded.state.memories, store.state.memories)
        store.removeMemory(memory.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    @MainActor func testPersonalityImportPreservesConflictingSavedProfile() throws {
        let store = try temporaryStore()
        let original = Persona(name: "My profile", prompt: "original")
        store.savePersonality(original)
        let conflicting = Persona(id: original.id, name: "Imported profile", prompt: "imported")
        let file = store.directory.appendingPathComponent("personality.json")
        try JSONEncoder().encode(conflicting).write(to: file)
        try store.importPersonalities(file)
        XCTAssertTrue(store.personalities.contains(original)); XCTAssertEqual(store.personalities.filter { $0.prompt == "imported" }.count, 1)
    }
    @MainActor func testBinaryAttachmentIsStoredWithoutFabricatedText() async throws {
        let store = try temporaryStore()
        let source = store.directory.appendingPathComponent("archive.bin")
        try Data([0, 1, 2, 3]).write(to: source)
        let asset = try await store.importAsset(source)
        XCTAssertEqual(asset.kind, "file"); XCTAssertNil(asset.text); XCTAssertEqual(asset.bytes, 4)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(store.assetURL(asset)).path))
    }
    @MainActor func testImportsVersionedGoPersonalityFixture() throws {
        let store = try temporaryStore()
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "go-personality", withExtension: "json", subdirectory: "Fixtures"))
        try store.importPersonalities(fixture)
        let profile = try XCTUnwrap(store.personalities.last)
        XCTAssertEqual(profile.name, "Careful code reviewer")
        XCTAssertEqual(profile.prompt, "Review supplied changes carefully. Cite files and distinguish verified issues from assumptions.")
        XCTAssertTrue(store.personalities.contains { $0.name == "Vortex" })
    }
    @MainActor func testRejectsFuturePersonalityEnvelopeWithoutChangingSavedProfiles() throws {
        let store = try temporaryStore()
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "go-personality", withExtension: "json", subdirectory: "Fixtures"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        object["version"] = 2
        let file = store.directory.appendingPathComponent("future-personality.json")
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let before = store.personalities
        XCTAssertThrowsError(try store.importPersonalities(file))
        XCTAssertEqual(store.personalities, before)
        object["version"] = 1; object["format"] = "another-format"
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        XCTAssertThrowsError(try store.importPersonalities(file))
        XCTAssertEqual(store.personalities, before)
    }
    @MainActor func testLegacyPersonalityArrayImportStillWorks() throws {
        let store = try temporaryStore()
        let values = [Persona(name: "First imported", prompt: "one"), Persona(name: "Second imported", prompt: "two")]
        let file = store.directory.appendingPathComponent("legacy-personalities.json")
        try JSONEncoder().encode(values).write(to: file)
        try store.importPersonalities(file)
        XCTAssertTrue(values.allSatisfy(store.personalities.contains))
    }
    @MainActor func testBuiltInPersonalityIdentifiersArePersisted() throws {
        let store = try temporaryStore()
        let json = try XCTUnwrap(store.preferences.string(forKey: "personasJSON"))
        let saved = try JSONDecoder().decode([Persona].self, from: Data(json.utf8))
        XCTAssertEqual(saved.map(\.id), store.personalities.map(\.id))
    }
    @MainActor func testProjectMemoryDoesNotEnterAnotherProjectOrWorld() throws {
        let store = try temporaryStore()
        let first = store.newProject("First"), second = store.newProject("Second"), world = store.newWorld("Story")
        try store.upsertMemory(VortexMemory(title: "Project secret", text: "FIRST_PROJECT", projectID: first))
        var chat = Chat(); chat.sharedMemoryEnabled = true; chat.projectID = first
        XCTAssertEqual(store.visibleMemory(for: chat).map(\.text), ["FIRST_PROJECT"])
        chat.projectID = second; XCTAssertTrue(store.visibleMemory(for: chat).isEmpty)
        chat.projectID = first; chat.worldID = world; XCTAssertTrue(store.visibleMemory(for: chat).isEmpty)
    }
    @MainActor func testFutureWorkspaceSchemaIsPreserved() throws {
        let store = try temporaryStore()
        let data = Data(#"{"schemaVersion":99,"futureField":"preserve"}"#.utf8)
        try data.write(to: store.file)
        let loaded = WorkspaceStore(directory: store.directory, preferences: store.preferences)
        _ = loaded.newProject("Do not overwrite future data"); loaded.save()
        XCTAssertEqual(try Data(contentsOf: store.file), data); XCTAssertFalse(loaded.errorMessage.isEmpty)
    }
}
