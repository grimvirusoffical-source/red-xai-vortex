import XCTest
@testable import Vortex

final class MCPConfigurationTests: XCTestCase {
    func testOriginalRequiredFieldsAndOptionalAuthentication() throws {
        var d = MCPServerDef(id: "test", name: "Test")
        XCTAssertThrowsError(try MCPConfiguration.validate(d))
        d.command = "node"; try MCPConfiguration.validate(d)
        d.type = "http"; d.url = "https://mcp.example/mcp"; try MCPConfiguration.validate(d)
        let effective = try MCPConfiguration.effective(d, secrets: MCPSecretBundle())
        XCTAssertTrue(effective.headers.isEmpty)
    }
    func testFirecrawlBearerAndCustomHeaders() throws {
        var d = MCPServerDef(id: "firecrawl", name: "Firecrawl")
        d.type = "http"; d.url = "https://mcp.firecrawl.dev/v2/mcp"; d.authMode = "bearer"
        var secrets = MCPSecretBundle(); secrets.apiKey = "fc-fixture-not-real"
        secrets.headers = ["X-Integration": "vortex", "authorization": "old-fixture"]
        let effective = try MCPConfiguration.effective(d, secrets: secrets)
        XCTAssertEqual(effective.headers["Authorization"], "Bearer fc-fixture-not-real")
        XCTAssertNil(effective.headers["authorization"])
        XCTAssertEqual(effective.headers["X-Integration"], "vortex")
        d.authMode = "header"; d.keyName = "X-API-Key"
        XCTAssertEqual(try MCPConfiguration.effective(d, secrets: secrets).headers["X-API-Key"], "fc-fixture-not-real")
    }
    func testLocalEnvironmentAndOptionalFields() throws {
        var d = MCPServerDef(id: "local", name: "Local")
        d.command = "npx"; d.args = ["-y", "firecrawl-mcp"]
        d.authMode = "environment"; d.keyName = "FIRECRAWL_API_KEY"
        var secrets = MCPSecretBundle(); secrets.apiKey = "fixture-key"
        XCTAssertEqual(try MCPConfiguration.effective(d, secrets: secrets).env["FIRECRAWL_API_KEY"], "fixture-key")
        d.callTimeout = 0; XCTAssertThrowsError(try MCPConfiguration.validate(d))
        d.callTimeout = 300; d.connectTimeout = 20; d.autoConnect = false
        try MCPConfiguration.validate(d)
    }
    func testCredentialInjectionAndInsecureURLsAreRejected() throws {
        for value in ["http://remote.example/mcp", "https://user:password@example.com/mcp", "https://example.com/mcp?api_key=secret"] {
            XCTAssertThrowsError(try MCPConfiguration.validatedURL(value))
        }
        _ = try MCPConfiguration.validatedURL("http://127.0.0.1:51110/mcp")
        var d = MCPServerDef(id: "test", name: "Test")
        d.type = "http"; d.url = "https://example.com/mcp"
        d.headers = ["Host": "other.example"]; XCTAssertThrowsError(try MCPConfiguration.validate(d))
        d.headers = ["X-Key": "secret\r\nInjected: true"]; XCTAssertThrowsError(try MCPConfiguration.validate(d))
        d.headers = [:]; d.authMode = "bearer"
        var secrets = MCPSecretBundle(); secrets.apiKey = "bad\nkey"
        XCTAssertThrowsError(try MCPConfiguration.effective(d, secrets: secrets))
        XCTAssertEqual(MCPConfiguration.safeDisplayURL("https://example.com/mcp?foo=secret"), "https://example.com/mcp")
    }
    func testOldConnectionJSONStillDecodesWithoutNewOptionalSettings() throws {
        let data = Data(#"{"id":"legacy","name":"Legacy","type":"stdio","command":"node","args":[],"env":{},"url":"","headers":{},"enabled":true}"#.utf8)
        let d = try JSONDecoder().decode(MCPServerDef.self, from: data)
        XCTAssertNil(d.authMode); XCTAssertNil(d.secretReference); try MCPConfiguration.validate(d)
    }
}
