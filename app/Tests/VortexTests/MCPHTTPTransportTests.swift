import Foundation
import XCTest
@testable import Vortex

private final class MCPHTTPFixture {
    let process = Process()
    let port: Int

    init() throws {
        // SwiftPM bundles differ between command-line and XCTest hosts. Resolve
        // copied and processed layouts, with the checked-out test source as a
        // final fallback. Never continue with a nonexistent fixture path.
        let candidates: [URL?] = [
            Bundle.module.url(forResource: "mcp-fixture", withExtension: "py", subdirectory: "Fixtures"),
            Bundle.module.url(forResource: "mcp-fixture", withExtension: "py"),
            Bundle.module.resourceURL?.appendingPathComponent("Fixtures/mcp-fixture.py"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/mcp-fixture.py")
        ]
        guard let fixture = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw MCPConfig.error("MCP test fixture resource is missing from the bundle and source checkout.")
        }
        let output = Pipe()
        let errors = Pipe()
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-u", fixture.path]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "-u", fixture.path]
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let child = process
        let startupTimeout = DispatchWorkItem {
            if child.isRunning { child.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: startupTimeout)
        defer { startupTimeout.cancel() }
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte.first == 10 { break }
            line.append(byte)
            if line.count > 128 { break }
        }
        guard let number = Int(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65535).contains(number), process.isRunning else {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            let diagnostic = (try? errors.fileHandleForReading.readToEnd()) ?? Data()
            throw MCPConfig.error("MCP test fixture failed to start (exit \(process.terminationStatus)): " + String(decoding: diagnostic.prefix(2000), as: UTF8.self))
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
