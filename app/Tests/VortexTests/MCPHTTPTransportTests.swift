import Foundation
import XCTest
@testable import Vortex

private final class MCPHTTPFixture {
    let process = Process()
    let port: Int

    // This test-only loopback server is embedded deliberately. It must not rely
    // on a copied resource path that other bundle/file tests may replace.
    // All keys are synthetic; no external service or user credential is used.
    private static let program = #"""
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_args):
        pass

    def answer(self, status, value, **headers):
        data = json.dumps(value).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        for name, content in headers.items():
            self.send_header(name, content)
        self.end_headers()
        self.wfile.write(data)
        self.wfile.flush()

    def do_POST(self):
        size = int(self.headers.get('Content-Length', '0'))
        if size > 1024 * 1024:
            self.answer(413, {})
            return
        message = json.loads(self.rfile.read(size))
        if self.path == '/redirect':
            self.answer(302, {}, Location='http://127.0.0.1:%d/sink' % self.server.server_port)
            return
        if self.path == '/html':
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if self.path == '/large':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(1024 * 1024))
            self.end_headers()
            self.close_connection = True
            return
        if self.path == '/auth' and self.headers.get('Authorization') != 'Bearer fc-test-fixture':
            self.answer(401, {'error': 'auth needed'})
            return
        if self.path == '/header' and self.headers.get('x-api-key') != 'test-custom-key':
            self.answer(401, {})
            return
        method = message.get('method')
        if method == 'initialize':
            self.answer(200, {'jsonrpc': '2.0', 'id': message['id'], 'result': {
                'protocolVersion': '2025-06-18', 'capabilities': {'tools': {}},
                'serverInfo': {'name': 'fixture', 'version': '1'}
            }}, **{'Mcp-Session-Id': 'fixture-session'})
            return
        if self.headers.get('Mcp-Session-Id') != 'fixture-session' or self.headers.get('MCP-Protocol-Version') != '2025-06-18':
            self.answer(403, {})
            return
        if 'id' not in message:
            self.send_response(202)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if method == 'tools/list':
            if message.get('params', {}).get('cursor') == 'page-two':
                result = {'tools': [
                    {'name': 'write', 'description': 'fixture', 'inputSchema': {'type': 'object'}, 'annotations': {'destructiveHint': True}},
                    {'name': 'blocked', 'inputSchema': {'type': 'object'}}
                ]}
            else:
                result = {'tools': [{'name': 'read', 'inputSchema': {'type': 'object'}}], 'nextCursor': 'page-two'}
        elif method == 'tools/call':
            result = {'content': [{'type': 'text', 'text': 'fixture reply'}]}
        else:
            result = {}
        reply = {'jsonrpc': '2.0', 'id': message['id'], 'result': result}
        if self.path == '/mismatch':
            reply['id'] += 1000
        if self.path == '/sse':
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            self.wfile.write(b': heartbeat\r\n\r\n')
            for line in json.dumps(reply, indent=2).splitlines():
                self.wfile.write(('data: ' + line + '\r\n').encode('utf-8'))
            self.wfile.write(b'\r\n')
            self.wfile.flush()
            time.sleep(10)
            self.close_connection = True
        else:
            self.answer(200, reply)

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
print(server.server_port, flush=True)
server.serve_forever()
"""#

    init() throws {
        let output = Pipe()
        let errors = Pipe()
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-u", "-c", Self.program]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "-u", "-c", Self.program]
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
