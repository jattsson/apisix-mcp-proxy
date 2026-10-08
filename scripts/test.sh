#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/certificates.sh
python3 scripts/tokens.py
python3 scripts/generate-config.py
docker compose up -d --build --force-recreate
trap 'docker compose logs --tail 60 gateway' ERR
for i in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:19080/.well-known/oauth-protected-resource/mcp/farm >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS http://127.0.0.1:19080/.well-known/oauth-protected-resource/mcp/farm >/dev/null
docker compose exec -T gateway /usr/local/openresty/bin/resty -I /opt/mcp-proxy /opt/test-suite/unit/helpers.lua | python3 tests/unit/verify.py
python3 -m unittest discover -s tests/integration -v 2>&1 | tee .test/integration-results.txt
