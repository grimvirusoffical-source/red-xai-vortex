import XCTest
@testable import Vortex

final class MCPAuthenticationTests: XCTestCase {
    func server() -> MCPServerDef {
        var s = MCPServerDef(id: "firecrawl", name: "Firecrawl")
        s.type = "http"; s.url = "https://mcp.firecrawl.dev/v2/mcp"
        return s
    }
    func testOptionalAuthDoesNotMakePublicServerRequireAKey() throws {
        let s = server()
        XCTAssertNoThrow(try s.validate())
        XCTAssertTrue(try s.effectiveHeaders().isEmpty)
    }
    func testFirecrawlBearerAndBridgeBearerAreSentAsHeaders() throws {
        var s = server(); s.authMode = "bearer"; s.secret = "test-only-key"
        XCTAssertEqual(try s.effectiveHeaders()["Authorization"], "Bearer test-only-key")
        s.url = "http://127.0.0.1:54321/mcp"
        XCTAssertEqual(try s.effectiveHeaders()["Authorization"], "Bearer test-only-key")
        s.secret = ""; XCTAssertThrowsError(try s.validate())
    }
    func testCustomHeaderBasicAndStdioEnvironment() throws {
        var s = server(); s.authMode = "header"; s.keyName = "X-API-Key"; s.secret = "fixture"
        XCTAssertEqual(try s.effectiveHeaders()["X-API-Key"], "fixture")
        s.authMode = "basic"; s.username = "fixture-user"
        XCTAssertEqual(try s.effectiveHeaders()["Authorization"], "Basic " + Data("fixture-user:fixture".utf8).base64EncodedString())
        s.type = "stdio"; s.command = "npx"; s.authMode = "environment"; s.keyName = "FIRECRAWL_API_KEY"
        XCTAssertEqual(try s.effectiveEnvironment()["FIRECRAWL_API_KEY"], "fixture")
    }
    func testSecretsAndRawHeadersAreNotSerializedOrExported() throws {
        var s = server(); s.authMode = "bearer"; s.secret = "secret-fixture"; s.username = "private-name"
        s.headers = ["X-Private": "private-value"]; s.env = ["SOME_TOKEN": "sensitive-env"]
        let json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        for value in [s.secret,s.username,"private-value","sensitive-env"] { XCTAssertFalse(json.contains(value)) }
        let restored = try JSONDecoder().decode(MCPServerDef.self, from: Data(json.utf8))
        XCTAssertEqual(restored.authMode, "bearer"); XCTAssertEqual(restored.secret, "")
    }
    func testRejectsCredentialURLsHeaderInjectionDuplicateNamesAndUnsafeLimits() throws {
        for url in ["http://remote.example/mcp","https://user:pass@example.com/mcp","https://example.com/mcp?key=secret"] {
            var s = server(); s.url = url; XCTAssertThrowsError(try s.validate())
        }
        for header in ["Host","Connection","Mcp-Session-Id","X-Foo\r\nInjected"] {
            var s = server(); s.authMode = "header"; s.keyName = header; s.secret = "test"
            XCTAssertThrowsError(try s.validate())
        }
        var s = server(); s.headers = ["X-Test":"ok", "x-test":"also"]
        XCTAssertThrowsError(try s.validate())
        s.headers = [:]; s.requestTimeout = .infinity; XCTAssertThrowsError(try s.validate())
    }
    func testLegacyConfigAndSSEMatchTheRequestedID() throws {
        let old = Data(#"{"id":"local","name":"Local","command":"node"}"#.utf8)
        let config = try JSONDecoder().decode(MCPServerDef.self, from: old)
        XCTAssertEqual(config.authMode, "none"); XCTAssertEqual(config.requestTimeout, 300)
        XCTAssertNoThrow(try config.validate())
        let sse = Data("data: {\"jsonrpc\":\"2.0\",\"id\":9,\"result\":{}}\n\ndata: {\"jsonrpc\":\"2.0\",\"id\":10,\"result\":{\"ok\":true}}\n\n".utf8)
        let response = try MCPResponse.parseSSE(sse, requestID: 10)
        XCTAssertEqual(response["id"] as? Int, 10)
        XCTAssertThrowsError(try MCPResponse.parseSSE(sse, requestID: 11))
    }
}
