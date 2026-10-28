#!/usr/bin/env python3
"""Loopback-only MCP transport fixture. Never uses a real API key or service."""
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
            time.sleep(10)  # Client must return on its matching event, not EOF.
            self.close_connection = True
        else:
            self.answer(200, reply)

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
print(server.server_port, flush=True)
server.serve_forever()
