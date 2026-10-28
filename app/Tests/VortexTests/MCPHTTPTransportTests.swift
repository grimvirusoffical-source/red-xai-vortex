import XCTest
@testable import Vortex

private final class MCPHTTPFixture {
    let process = Process()
    let port: Int
    init() throws {
        let fixture = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/mcp-fixture.py")
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", fixture.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte.first == 10 { break }
            line.append(byte)
        }
        guard let number = Int(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            process.terminate(); throw MCPConfig.error("Test fixture did not start.")
        }
        port = number
    }
    func definition(_ path: String) -> MCPServerDef {
        var d = MCPServerDef(id: "fixture", name: "Fixture")
        d.type = "http"; d.url = "http://127.0.0.1:\(port)\(path)"
        d.connectTimeoutSeconds = 5; d.requestTimeoutSeconds = 5
        return d
    }
    deinit { if process.isRunning { process.terminate(); process.waitUntilExit() } }
}

final class MCPHTTPTransportTests: XCTestCase {
    func testBearerAuthSessionNegotiationPaginationAndToolCall() async throws {
        let fixture = try MCPHTTPFixture()
        var d = fixture.definition("/auth"); d.authMode = "bearer"; d.apiKey = "fc-test-fixture"
        d.allowedTools = ["read", "write"]; d.blockedTools = ["blocked"]
        let client = MCPClient(d); defer { client.stop() }
        let tools = try await client.start()
        XCTAssertEqual(tools.map { $0.name }, ["read", "write"])
        XCTAssertTrue(tools[1].destructive)
        let reply = try await client.call("read", [:]); XCTAssertEqual(reply, "fixture reply")
        do { _ = try await client.call("blocked", [:]); XCTFail("Blocked tool was allowed") }
        catch { XCTAssertTrue(error.localizedDescription.contains("disabled")) }
    }
    func testOptionalCustomHeaderAuth() async throws {
        let fixture = try MCPHTTPFixture()
        var d = fixture.definition("/header"); d.authMode = "header"; d.apiKeyHeader = "x-api-key"; d.apiKey = "test-custom-key"
        let client = MCPClient(d); defer { client.stop() }
        let tools = try await client.start(); XCTAssertEqual(tools.count, 3)
    }
    func testNoKeyConnectionToUnauthenticatedServer() async throws {
        let fixture = try MCPHTTPFixture(); let client = MCPClient(fixture.definition("/open")); defer { client.stop() }
        let tools = try await client.start(); XCTAssertEqual(tools.count, 3)
    }
    func testSSEMultilineFramesReturnBeforeConnectionCloses() async throws {
        let fixture = try MCPHTTPFixture(); let client = MCPClient(fixture.definition("/sse")); defer { client.stop() }
        let tools = try await client.start(); XCTAssertEqual(tools.count, 3)
        let reply = try await client.call("read", [:]); XCTAssertEqual(reply, "fixture reply")
    }
    func testWrongKeyFailsWithoutEchoingTheSecret() async throws {
        let fixture = try MCPHTTPFixture(); var d = fixture.definition("/auth")
        d.authMode = "bearer"; d.apiKey = "private-wrong-secret"
        let client = MCPClient(d); defer { client.stop() }
        do { _ = try await client.start(); XCTFail("Wrong credential was accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("authentication")); XCTAssertFalse(error.localizedDescription.contains(d.apiKey)) }
    }
    func testRedirectHTMLAndOversizedResponsesAreRejected() async throws {
        let fixture = try MCPHTTPFixture()
        for (path, expected) in [("/redirect", "redirect"), ("/html", "JSON or SSE"), ("/large", "size limit"), ("/mismatch", "mismatched")] {
            var d = fixture.definition(path); d.maxResponseBytes = 65536
            let client = MCPClient(d)
            do { _ = try await client.start(); XCTFail("Invalid endpoint accepted: " + path) }
            catch { XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains(expected), error.localizedDescription) }
            client.stop()
        }
    }
}
