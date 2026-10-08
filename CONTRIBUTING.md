# Contributing

Open an issue describing the problem and expected behavior before large changes.
Keep fixes focused and include regression coverage for protocol, routing or auth
changes. Follow docs/lua-style.md (LuaRocks and APISIX conventions) and document
function inputs, results, mutations and cleanup behavior.

Run from Linux or WSL with Docker Compose, Python 3 and OpenSSL:

    bash scripts/style.sh
    bash scripts/test.sh
    docker compose down
    python3 scripts/package.py

Never commit credentials, generated certificates, deployment configuration or
customer data. The .test directory is ignored. Keep examples generic.
Contributions are accepted under the repository's Apache-2.0 license. Preserve
existing third-party attribution; dependencies keep their respective licenses.
