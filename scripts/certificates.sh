#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .test/certs
cd .test/certs
if test -f ready-v2 && openssl x509 -in ca.crt -checkend 3600 -noout >/dev/null; then exit 0; fi
for ca in ca wrong-ca; do
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$ca.key" -out "$ca.crt" -days 2 -subj "/CN=MCP test $ca" -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' >/dev/null 2>&1
done
for name in server client; do
  openssl req -newkey rsa:2048 -nodes -keyout "$name.key" -out "$name.csr" -subj "/CN=$name" >/dev/null 2>&1
  printf 'subjectAltName=DNS:fixture.internal,DNS:gateway.example.test,DNS:secure,DNS:mtls,IP:127.0.0.1\nkeyUsage=critical,digitalSignature,keyEncipherment\nbasicConstraints=critical,CA:FALSE\nextendedKeyUsage=serverAuth,clientAuth\n' > "$name.ext"
  openssl x509 -req -in "$name.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -out "$name.crt" -days 2 -extfile "$name.ext" >/dev/null 2>&1
done
touch ready-v2
