import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def reply(request):
    method = request.get('method')
    if method == 'initialize':
        result = {'protocolVersion': '2025-11-25', 'capabilities': {'tools': {}}}
    elif method == 'tools/list':
        if request.get('params', {}).get('cursor') == 'page-two':
            result = {'tools': [{'name': 'write', 'inputSchema': {'type': 'object'}}]}
        else:
            result = {'tools': [{'name': 'echo', 'annotations': {'readOnlyHint': True}, 'inputSchema': {'type': 'object'}}], 'nextCursor': 'page-two'}
    elif method == 'tools/call':
        result = {'content': [{'type': 'text', 'text': 'fixture_reply'}]}
    elif method == 'test/environment':
        result = {'explicit': os.environ.get('FIRECRAWL_API_KEY') == 'fixture-only',
                  'unrelatedInherited': 'VORTEX_TEST_SHOULD_NOT_INHERIT' in os.environ}
    else:
        return None
    return {'jsonrpc': '2.0', 'id': request.get('id'), 'result': result}

if sys.argv[1] == 'stdio':
    for line in sys.stdin:
        result = reply(json.loads(line))
        if result is not None:
            print(json.dumps(result), flush=True)
else:
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass
        def do_POST(self):
            if self.path == '/redirect':
                self.send_response(307)
                self.send_header('Location', '/mcp')
                self.end_headers()
                return
            if self.headers.get('Authorization') != 'Bearer fixture-only':
                self.send_response(401)
                self.end_headers()
                return
            request = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))))
            if request['method'] != 'initialize' and self.headers.get('MCP-Session-Id') != 'fixture-session':
                self.send_response(400)
                self.end_headers()
                return
            result = reply(request)
            if result is None:
                self.send_response(202)
                self.end_headers()
                return
            raw = json.dumps(result).encode()
            sse = request['method'] == 'tools/list'
            if sse:
                raw = b'event: message\ndata: ' + raw + b'\n\n'
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream' if sse else 'application/json')
            self.send_header('Content-Length', str(len(raw)))
            self.send_header('MCP-Session-Id', 'fixture-session')
            self.end_headers()
            self.wfile.write(raw)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    print(server.server_port, flush=True)
    server.serve_forever()
