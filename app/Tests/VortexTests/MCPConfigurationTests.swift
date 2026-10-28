import XCTest
@testable import Vortex

final class MCPConfigurationTests: XCTestCase {
    private func remote() -> MCPServerDef {
        var d = MCPServerDef(id: "firecrawl", name: "Firecrawl")
        d.type = "http"; d.url = "https://mcp.firecrawl.dev/v2/mcp"; return d
    }
    func testExistingProfilesDecodeWithSafeDefaults() throws {
        let data = Data(#"{"id":"old","name":"Old server","type":"http","url":"https://example.com/mcp","headers":{"Authorization":"Bearer legacy-secret"}}"#.utf8)
        let d = try JSONDecoder().decode(MCPServerDef.self, from: data)
        XCTAssertEqual(d.authMode, "none"); XCTAssertEqual(d.connectTimeoutSeconds, 60)
        XCTAssertEqual(d.requestTimeoutSeconds, 300); XCTAssertTrue(d.enabled)
        XCTAssertEqual(try d.resolvedHeaders()["Authorization"], "Bearer legacy-secret")
    }
    func testNoAuthenticationRequiresNoKey() throws {
        XCTAssertTrue(try remote().resolvedHeaders().isEmpty)
        var d = MCPServerDef(id: "local", name: "Local"); d.command = "node"
        XCTAssertNoThrow(try d.validated())
    }
    func testFirecrawlBearerHeader() throws {
        var d = remote(); d.authMode = "bearer"; d.apiKey = "fc-unit-test-secret"
        XCTAssertEqual(try d.resolvedHeaders()["Authorization"], "Bearer fc-unit-test-secret")
        XCTAssertFalse(d.url.contains(d.apiKey))
    }
    func testCustomHeaderAndOptionalPrefix() throws {
        var d = remote(); d.authMode = "header"; d.apiKeyHeader = "x-api-key"; d.apiKey = "service-secret"
        XCTAssertEqual(try d.resolvedHeaders()["x-api-key"], "service-secret")
        d.apiKeyPrefix = "Token"; XCTAssertEqual(try d.resolvedHeaders()["x-api-key"], "Token service-secret")
    }
    func testBasicAuthentication() throws {
        var d = remote(); d.authMode = "basic"; d.username = "user"; d.apiKey = "p:a:ss"
        XCTAssertEqual(try d.resolvedHeaders()["Authorization"], "Basic " + Data("user:p:a:ss".utf8).base64EncodedString())
        d.username = "bad:user"; XCTAssertThrowsError(try d.validated())
    }
    func testLocalEnvironmentKeyAndInheritance() throws {
        var d = MCPServerDef(id: "firecrawl", name: "Firecrawl")
        d.command = "npx"; d.args = ["-y", "firecrawl-mcp"]
        d.authMode = "environment"; d.apiKeyEnvironment = "FIRECRAWL_API_KEY"; d.apiKey = "fc-local-secret"
        XCTAssertEqual(try d.resolvedEnvironment(base: ["EXISTING": "retained"])["FIRECRAWL_API_KEY"], "fc-local-secret")
        XCTAssertEqual(try d.resolvedEnvironment(base: ["EXISTING": "retained"])["EXISTING"], "retained")
        d.inheritEnvironment = false
        XCTAssertNil(try d.resolvedEnvironment(base: ["PRIVATE_KEY": "not-inherited"])["PRIVATE_KEY"])
        d.env["FIRECRAWL_API_KEY"] = "duplicate"; XCTAssertThrowsError(try d.validated())
    }
    func testMetadataEncodingOmitsAllSecretValues() throws {
        var d = remote(); d.authMode = "bearer"; d.apiKey = "fc-hidden-secret"
        d.headers = ["X-Custom-Key": "header-secret"]; d.env = ["TOKEN": "env-secret"]; d.secretRef = UUID().uuidString
        let data = try JSONEncoder().encode(d); let text = String(decoding: data, as: UTF8.self)
        for secret in ["fc-hidden-secret", "header-secret", "env-secret"] { XCTAssertFalse(text.contains(secret)) }
        let decoded = try JSONDecoder().decode(MCPServerDef.self, from: data)
        XCTAssertEqual(decoded.secretRef, d.secretRef)
        XCTAssertTrue(decoded.apiKey.isEmpty); XCTAssertTrue(decoded.headers.isEmpty); XCTAssertTrue(decoded.env.isEmpty)
    }
    func testRequiredFieldsRemainRequired() {
        var d = remote(); d.name = "  "; XCTAssertThrowsError(try d.validated())
        d = remote(); d.id = "Bad ID"; XCTAssertThrowsError(try d.validated())
        d = remote(); d.url = ""; XCTAssertThrowsError(try d.validated())
        d = MCPServerDef(id: "local", name: "Local"); XCTAssertThrowsError(try d.validated())
    }
    func testAuthSelectionRequiresMatchingCredentialOnly() {
        for mode in ["bearer", "basic", "header"] { var d = remote(); d.authMode = mode; XCTAssertThrowsError(try d.validated()) }
        var d = remote(); d.authMode = "environment"; d.apiKey = "secret"; XCTAssertThrowsError(try d.validated())
    }
    func testEndpointValidation() throws {
        XCTAssertNoThrow(try MCPConfig.endpoint("http://127.0.0.1:8765/mcp"))
        for value in ["http://external.example/mcp", "https://user:secret@example.com/mcp", "https://example.com/mcp?api_key=secret", "https://example.com/mcp#token", "file:///tmp/server"] { XCTAssertThrowsError(try MCPConfig.endpoint(value), value) }
    }
    func testHeadersCannotOverrideTransportOrInjectLines() {
        for key in ["Host", "Mcp-Session-Id", "MCP-Protocol-Version", "Content-Length", "Cookie"] { var d = remote(); d.headers[key] = "poison"; XCTAssertThrowsError(try d.validated()) }
        var d = remote(); d.headers["X-Test"] = "ok\r\nAuthorization: stolen"; XCTAssertThrowsError(try d.validated())
        d = remote(); d.headers = ["x-test": "one", "X-Test": "two"]; XCTAssertThrowsError(try d.validated())
    }
    func testAuthCannotCollideWithRawHeaders() {
        var d = remote(); d.authMode = "bearer"; d.apiKey = "secret-value"; d.headers["authorization"] = "Bearer other"
        XCTAssertThrowsError(try d.validated())
    }
    func testOptionalToolFiltersAndTimeoutBounds() throws {
        var d = remote(); XCTAssertTrue(d.permitsTool("anything"))
        d.allowedTools = ["search", "scrape"]; d.blockedTools = ["scrape"]
        XCTAssertTrue(d.permitsTool("search")); XCTAssertFalse(d.permitsTool("scrape")); XCTAssertFalse(d.permitsTool("crawl"))
        d.requestTimeoutSeconds = 3600; XCTAssertNoThrow(try d.validated())
        d.requestTimeoutSeconds = 3601; XCTAssertThrowsError(try d.validated())
        d.requestTimeoutSeconds = 300; d.maxResponseBytes = 33 * 1024 * 1024; XCTAssertThrowsError(try d.validated())
    }
    func testPairParserPreservesEqualsAndRejectsDuplicates() throws {
        XCTAssertEqual(try MCPConfig.parsePairs("TOKEN=abc=def\nEMPTY=", separator: "=", headers: false), ["TOKEN": "abc=def", "EMPTY": ""])
        XCTAssertEqual(try MCPConfig.parsePairs("Authorization: Bearer abc:def", separator: ":", headers: true)["Authorization"], "Bearer abc:def")
        XCTAssertThrowsError(try MCPConfig.parsePairs("X-Test: one\nx-test: two", separator: ":", headers: true))
        XCTAssertThrowsError(try MCPConfig.parsePairs("not-a-pair", separator: "=", headers: false))
    }
    func testDiagnosticRedaction() {
        var d = remote(); d.apiKey = "fc-private-secret"; d.headers = ["X-Key": "another-secret"]
        let redacted = d.redacted("failed fc-private-secret another-secret")
        XCTAssertFalse(redacted.contains("fc-private-secret")); XCTAssertFalse(redacted.contains("another-secret"))
    }
}
