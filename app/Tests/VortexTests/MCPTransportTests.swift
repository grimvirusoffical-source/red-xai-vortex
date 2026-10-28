import XCTest
import Foundation
@testable import Vortex

final class MCPTransportTests: XCTestCase {
    private var fixture: URL { Bundle.module.url(forResource: "mcp_fixture", withExtension: "py", subdirectory: "Fixtures")! }
    private func httpFixture() throws -> (Process, String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [fixture.path, "http"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        var data = Data()
        while let byte = try pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte.first == 10 { break }; data.append(byte)
            if data.count > 12 { throw MCPConfiguration.failure("Fixture did not return a port") }
        }
        let port = String(decoding: data, as: UTF8.self)
        guard Int(port) != nil else { process.terminate(); throw MCPConfiguration.failure("Fixture did not start") }
        return (process, "http://127.0.0.1:\(port)")
    }
    func testHTTPBearerSessionSSEPaginationAndToolCall() async throws {
        let (process, endpoint) = try httpFixture(); defer { process.terminate() }
        var d = MCPServerDef(id: "http-fixture", name: "Fixture")
        d.type = "http"; d.url = endpoint + "/mcp"; d.headers = ["Authorization":"Bearer fixture-only"]
        d.connectTimeout = 5; d.callTimeout = 5
        let client = MCPClient(d); defer { client.stop() }
        let tools = try await client.start()
        XCTAssertEqual(tools.map(\.name), ["echo", "write"])
        XCTAssertFalse(tools[0].destructive); XCTAssertTrue(tools[1].destructive, "Missing annotations must not bypass approval")
        let answer = try await client.call("echo", [:]); XCTAssertEqual(answer, "fixture_reply")
    }
    func testHTTPRedirectDoesNotForwardCredential() async throws {
        let (process, endpoint) = try httpFixture(); defer { process.terminate() }
        var d = MCPServerDef(id: "redirect-fixture", name: "Redirect")
        d.type = "http"; d.url = endpoint + "/redirect"; d.headers = ["Authorization":"Bearer fixture-only"]; d.connectTimeout = 3
        let client = MCPClient(d); defer { client.stop() }
        do { _ = try await client.start(); XCTFail("Credential redirect must be refused") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Redirect")); XCTAssertFalse(error.localizedDescription.contains("fixture-only")) }
    }
    func testStdioExplicitEnvironmentAndCancellation() async throws {
        setenv("VORTEX_TEST_SHOULD_NOT_INHERIT", "fictional-test-value", 1)
        defer { unsetenv("VORTEX_TEST_SHOULD_NOT_INHERIT") }
        var d = MCPServerDef(id: "stdio-fixture", name: "Stdio")
        d.command = "/usr/bin/python3"; d.args = [fixture.path, "stdio"]
        d.env = ["FIRECRAWL_API_KEY":"fixture-only"]; d.connectTimeout = 5
        let client = MCPClient(d); defer { client.stop() }
        let tools = try await client.start(); XCTAssertEqual(tools.count, 2)
        let environment = try await client.request("test/environment", [:], timeout: 3)
        XCTAssertEqual(environment["explicit"] as? Bool, true)
        XCTAssertEqual(environment["unrelatedInherited"] as? Bool, false)
        let pending = Task { try await client.request("test/never", [:], timeout: 30) }
        try await Task.sleep(nanoseconds: 100_000_000)
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Cancelled request unexpectedly succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
