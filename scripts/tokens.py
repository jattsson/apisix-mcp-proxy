import base64
import json
import subprocess
import time
from pathlib import Path

folder=Path(__file__).resolve().parents[1]/'.test/certs'
def b64(value):
    return base64.urlsafe_b64encode(value).rstrip(b'=').decode()
modulus=subprocess.check_output(['openssl','rsa','-in',str(folder/'ca.key'),'-noout','-modulus'],stderr=subprocess.DEVNULL).decode().strip().split('=')[1]
(folder/'jwks.json').write_text(json.dumps({'keys':[{'kty':'RSA','kid':'test','use':'sig','alg':'RS256','n':b64(bytes.fromhex(modulus)),'e':'AQAB'}]}))
tokens={}
for variant in ('valid','expired','audience','issuer'):
    payload={'sub':'alice','iss':'https://issuer.example.test' if variant!='issuer' else 'https://wrong.example.test','aud':'mcp-tests' if variant!='audience' else 'another-resource','exp':int(time.time())+(-3600 if variant=='expired' else 3600),'iat':int(time.time())-7200}
    body=b64(json.dumps({'alg':'RS256','kid':'test','typ':'JWT'}).encode())+'.'+b64(json.dumps(payload).encode())
    signature=subprocess.check_output(['openssl','dgst','-sha256','-sign',str(folder/'ca.key')],input=body.encode())
    tokens[variant]=body+'.'+b64(signature)
(folder/'tokens.json').write_text(json.dumps(tokens))
