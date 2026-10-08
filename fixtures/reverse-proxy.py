"""A TLS-terminating trusted reverse proxy on a nonstandard public port."""
import http.client
import ssl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Handler(BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def proxy(self):
        headers={k:v for k,v in self.headers.items() if k.lower() not in ('connection','x-forwarded-for','x-forwarded-proto','x-forwarded-host','x-forwarded-port','forwarded')}
        headers.update({'X-Forwarded-For':self.client_address[0],'X-Forwarded-Proto':'https','X-Forwarded-Host':'gateway.example.test:9443','X-Forwarded-Port':'9443'})
        body=self.rfile.read(int(self.headers.get('Content-Length',0)))
        connection=http.client.HTTPConnection('gateway',9080,timeout=20)
        try:
            connection.request(self.command,self.path,body,headers)
            response=connection.getresponse()
            data=response.read()
            self.send_response(response.status)
            for key,value in response.getheaders():
                if key.lower() not in ('connection','transfer-encoding','content-length','server','date'):
                    self.send_header(key,value)
            self.send_header('Content-Length',str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        finally:
            connection.close()
    do_POST=proxy
    do_GET=proxy

server=ThreadingHTTPServer(('0.0.0.0',9443),Handler)
context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain('/certs/server.crt','/certs/server.key')
server.socket=context.wrap_socket(server.socket,server_side=True)
server.serve_forever()
