"""Discovery/JWKS test server; deliberately not an OAuth authorization server."""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path=='/jwks':
            body=Path('/certs/jwks.json').read_bytes()
        else:
            body=json.dumps({'issuer':'https://issuer.example.test','jwks_uri':'http://oidc:8080/jwks','authorization_endpoint':'https://issuer.example.test/authorize','token_endpoint':'https://issuer.example.test/token','response_types_supported':['code'],'subject_types_supported':['public'],'id_token_signing_alg_values_supported':['RS256']}).encode()
        self.send_response(200)
        self.send_header('Content-Type','application/json')
        self.send_header('Content-Length',str(len(body)))
        self.end_headers()
        self.wfile.write(body)

HTTPServer(('0.0.0.0',8080),Handler).serve_forever()
