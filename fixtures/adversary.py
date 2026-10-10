"""Adversarial transport fixture, separate from the real Java SDK fixtures."""
import json
import os
import threading
import time
import ssl
import gzip
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

lock = threading.Lock()
state = {"calls": [], "active": 0, "peak": 0, "writes": 0}
release=threading.Event()

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def send(self, status, obj=None, headers=None):
        body = json.dumps(obj).encode() if obj is not None else b''
        self.send_response(status)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.send_header('Content-Type', ' Application/JSON ; charset=utf-8' if self.headers.get('X-Fixture-Mode')=='media-case' else 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == '/stats':
            return self.send(200, state)
        return self.send(200, {'healthy': True})

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if self.path == '/reset':
            with lock:
                state.update(calls=[], active=0, peak=0, writes=0)
            return self.send(200, {})
        if self.path=='/release':
            release.set()
            return self.send(200,{})
        message = json.loads(raw)
        method = message['method']
        variant = self.headers.get('X-Fixture-Mode', '')
        with lock:
            state['calls'].append({'method': method, 'headers': dict(self.headers), 'body': message})
        if variant == '504':
            return self.send(504, {})
        if variant == '401':
            return self.send(401, {}, {'WWW-Authenticate': 'Basic realm="a,b", Bearer error="invalid_token", error_description="expired, renew"'})
        if variant == '403':
            return self.send(403, {}, {'WWW-Authenticate': 'Bearer error="insufficient_scope", scope="mcp:write"'})
        if variant == '429':
            return self.send(429, {}, {'Retry-After': '3'})
        if method == 'initialize':
            caps = {'tools': {}, 'resources': {}, 'prompts': {}}
            if variant == 'no-prompts':
                del caps['prompts']
            result = {'protocolVersion': '2025-11-25', 'serverInfo': {'name': 'adversary', 'version': '1'}, 'capabilities': caps}
            headers = {'Mcp-Session-Id': 'must-not-leak'} if variant == 'session' else None
            return self.send(200, {'jsonrpc': '2.0', 'id': message['id'], 'result': result}, headers)
        if method.startswith('notifications/'):
            return self.send(202)
        if method.endswith('/list'):
            with lock:
                state['active'] += 1
                state['peak'] = max(state['peak'], state['active'])
            try:
                if variant in ('delay', 'timeout','slow'):
                    time.sleep(0.2 if variant == 'delay' else 3)
                if variant in ('502','malformed-json','upstream-gzip'):
                    body = gzip.compress(b'{}') if variant=='upstream-gzip' else b'<html>failure</html>'
                    self.send_response(502 if variant=='502' else 200)
                    self.send_header('Content-Type', 'text/html' if variant=='502' else 'application/json')
                    if variant=='upstream-gzip':
                        self.send_header('Content-Encoding','gzip')
                    self.send_header('Content-Length', str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                if method == 'tools/list':
                    page = message.get('params', {}).get('cursor')
                    result = {'tools': [{'name': ('second' if page else 'echo'), 'inputSchema': {'type': 'object', 'properties': {}, 'required': []}, 'outputSchema': {'type': 'object', 'properties': {}}}]}
                    if not page or variant == 'cursor-loop':
                        result['nextCursor'] = 'p2'
                    if variant == 'many-pages':
                        n=int(page or 0)
                        result={'tools':[{'name':'item-'+str(n),'description':'x'*600,'inputSchema':{}}], 'nextCursor':str(n+1)}
                    if variant == 'bad-execution':
                        result['tools'][0]['execution']=42
                    if variant == 'task':
                        result['tools'][0]['execution'] = {'taskSupport': 'required'}
                    if variant == 'bad-catalog':
                        result['tools'] = {}
                    if variant == 'large':
                        result['tools'][0]['description'] = 'x' * 5000000
                    if self.headers.get('X-Catalog-Policy')=='isolate' and (self.headers.get('Authorization')=='Bearer bob' or self.headers.get('X-Tenant')=='restricted'):
                        result={'tools':[]}
                elif method == 'prompts/list':
                    result = {'prompts': [{'name': 'prompt', 'arguments': []}]}
                elif method == 'resources/templates/list':
                    result = {'resourceTemplates': [{'name': 'r', 'uriTemplate': 'fixture://adversary/{id}'}]}
                else:
                    result = {'resources': [{'name': 'r', 'uri': 'fixture://adversary/one'}]}
            finally:
                with lock:
                    state['active'] -= 1
        else:
            with lock:
                state['writes'] += 1
            if variant == 'lost-write':
                self.close_connection = True
                self.connection.close()
                return
            if variant=='write-500':
                return self.send(500,{'error':'fixture write committed'})
            if variant=='write-timeout':
                time.sleep(3)
            result = {'content': [], 'structuredContent': {'node':os.environ.get('NODE','a'),'arguments': message.get('params', {}).get('arguments'), 'null': None, 'false': False, 'zero': 0, 'array': [], 'object': {}}, 'isError': variant == 'tool-error'}
        response = {'jsonrpc': '2.0', 'id': message['id'], 'result': result}
        if variant=='sse-abort' and method=='tools/call':
            self.send_response(200)
            self.send_header('Content-Type','text/event-stream')
            self.send_header('Connection','close')
            self.end_headers()
            state['stream_aborted']=False
            self.close_connection=True
            try:
                for n in range(100):
                    self.wfile.write(('data: '+json.dumps({'jsonrpc':'2.0','method':'notifications/progress','params':{'progressToken':7,'progress':n}})+'\n\n').encode())
                    self.wfile.flush()
                    time.sleep(0.05)
            except OSError:
                state['stream_aborted']=True
            return
        if variant=='rpc-error' and method=='tools/call':
            response={'jsonrpc':'2.0','id':message['id'],'error':{'code':-32602,'message':'Fixture protocol error','data':{'kind':'test'}}}
        if variant in ('sse','sse-wait'):
            events = ': comment\r\nid: primer\r\nretry: 1000\r\ndata:\r\n\r\ndata: ' + json.dumps({'jsonrpc': '2.0', 'method': 'notifications/progress', 'params': {'progressToken': 7, 'progress': 1}}) + '\r\n\r\n'
            events += 'event: message\ndata: ' + json.dumps(response, indent=1).replace('\n', '\ndata: ') + '\n\n'
            data = events.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            if variant=='sse-wait' and method=='tools/call':
                release.clear()
                boundary=data.index(b'\r\n\r\n',data.index(b'data: '))+4
                self.wfile.write(data[:boundary])
                self.wfile.flush()
                state['waiting']=True
                release.wait(timeout=8)
                state['waiting']=False
                self.wfile.write(data[boundary:])
                return
            for i in range(0, len(data), 7):
                self.wfile.write(data[i:i+7])
                self.wfile.flush()
            return
        return self.send(200, response)

server=ThreadingHTTPServer(('0.0.0.0', 8080), Handler)
if os.environ.get('TLS_MODE'):
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain('/certs/server.crt','/certs/server.key')
    if os.environ['TLS_MODE']=='mtls':
        context.verify_mode=ssl.CERT_REQUIRED
        context.load_verify_locations('/certs/ca.crt')
    server.socket=context.wrap_socket(server.socket,server_side=True)
server.serve_forever()
