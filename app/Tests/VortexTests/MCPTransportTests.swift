import XCTest
import Foundation
@testable import Vortex

private final class MCPFixture: @unchecked Sendable {
    let lock = NSLock()
    var calls = 0
    var toolCalls = 0
    var badHeaders = false
    var oversized = false
    var hang = false
    var useSSE = false
    func reply(_ request: URLRequest) -> (Int, [String:String], Data)? {
        lock.lock(); defer { lock.unlock() }; calls += 1
        if hang { return nil }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; body.append(contentsOf: bytes.prefix(n)) }
        }
        let msg = (try? JSONSerialization.jsonObject(with: body)) as? [String:Any] ?? [:]
        let method = msg["method"] as? String ?? ""
        if request.value(forHTTPHeaderField: "Authorization") != "Bearer fixture-only-secret" { badHeaders = true; return (401,[:],Data()) }
        if method != "initialize" && (request.value(forHTTPHeaderField: "MCP-Protocol-Version") != "2025-06-18" || request.value(forHTTPHeaderField: "Mcp-Session-Id") != "fixture-session") { badHeaders = true; return (400,[:],Data()) }
        if String(decoding: body, as: UTF8.self).contains("fixture-only-secret") { badHeaders = true }
        if method == "notifications/initialized" { return (202,[:],Data()) }
        var result: [String:Any] = [:]
        if method == "initialize" { result["protocolVersion"] = "2025-06-18" }
        else if method == "tools/list" {
            let params = msg["params"] as? [String:Any] ?? [:]
            let first = params["cursor"] == nil
            result["tools"] = [["name": first ? "first" : "second", "description": "Fixture", "inputSchema": ["type":"object"]]]
            if first { result["nextCursor"] = "page-two" }
        } else if method == "tools/call" { toolCalls += 1; result["content"] = [["type":"text", "text":"fixture-success"]] }
        if oversized { result["padding"] = String(repeating: "x", count: 4096) }
        let object: [String:Any] = ["jsonrpc":"2.0", "id":msg["id"] ?? -1, "result":result]
        let data = try! JSONSerialization.data(withJSONObject: object)
        var headers = ["Mcp-Session-Id":"fixture-session", "Content-Type":"application/json"]
        if useSSE {
            headers["Content-Type"] = "text/event-stream"
            return (200,headers,Data(("data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\ndata: " + String(decoding:data,as:UTF8.self) + "\n\n").utf8))
        }
        return (200,headers,data)
    }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return calls }
}
private final class MCPFixtureRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String:MCPFixture] = [:]
    func set(_ key: String, _ value: MCPFixture?) { lock.lock(); entries[key] = value; lock.unlock() }
    func get(_ key: String) -> MCPFixture? { lock.lock(); defer { lock.unlock() }; return entries[key] }
}
private final class MCPMockProtocol: URLProtocol, @unchecked Sendable {
    static let fixtures = MCPFixtureRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let fixture = Self.fixtures.get(url.host ?? ""), let (status, headers, data) = fixture.reply(request) else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url:url,statusCode:status,httpVersion:"HTTP/1.1",headerFields:headers)!, cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class MCPTransportTests: XCTestCase {
    private func make(_ fixture: MCPFixture, limit: Int = 8 * 1024 * 1024) -> MCPClient {
        let host = UUID().uuidString.lowercased() + ".fixture"
        MCPMockProtocol.fixtures.set(host, fixture)
        addTeardownBlock { MCPMockProtocol.fixtures.set(host,nil) }
        var def = MCPServerDef(id:"fixture",name:"Fixture");def.type="http";def.url="https://"+host+"/mcp";def.authMode="bearer";def.secret="fixture-only-secret";def.protocolVersion="2025-11-25";def.maxResponseBytes=limit
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[MCPMockProtocol.self]
        return MCPClient(def,httpSession:URLSession(configuration:config))
    }
    func testBearerProtocolSessionPaginationAndToolCallForJSONAndSSE() async throws {
        for useSSE in [false,true] {
            let fixture=MCPFixture();fixture.useSSE=useSSE;let client=make(fixture);defer{client.stop()}
            let tools=try await client.start();XCTAssertEqual(tools.map(\.name),["first","second"]);XCTAssertEqual(fixture.toolCalls,0)
            XCTAssertTrue(tools.allSatisfy(\.destructive),"Missing read-only annotations must require approval")
            let answer=try await client.call("first",[:]);XCTAssertEqual(answer,"fixture-success");XCTAssertEqual(fixture.toolCalls,1);XCTAssertFalse(fixture.badHeaders)
        }
    }
    func testResponseLimitIsAppliedWhileReceiving() async throws {
        let fixture=MCPFixture();fixture.oversized=true;let client=make(fixture,limit:1024);defer{client.stop()}
        do{_ = try await client.start();XCTFail("oversized response accepted")}catch{XCTAssertTrue(error.localizedDescription.contains("byte limit"))}
    }
    func testStopCancelsInFlightRequestsAndRejectsFurtherUse() async throws {
        let fixture=MCPFixture();fixture.hang=true;let client=make(fixture)
        let operation=Task{try await client.start()}
        for _ in 0..<100 where fixture.count()==0 {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertGreaterThan(fixture.count(),0);client.stop()
        do{_ = try await operation.value;XCTFail("stopped request succeeded")}catch{}
        let before=fixture.count()
        do{_ = try await client.call("first",[:]);XCTFail("closed client sent a request")}catch{}
        XCTAssertEqual(fixture.count(),before)
    }
}
