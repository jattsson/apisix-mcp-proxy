# Contributing

Open an issue describing the problem and expected behavior before large changes.
Keep fixes focused and include regression coverage for protocol, routing or auth
changes. Follow docs/lua-style.md (LuaRocks and APISIX conventions) and document
function inputs, results, mutations and cleanup behavior.

You can contribute from macOS, Linux or Windows with WSL2. Run the commands below
from the repository root in Bash, with these tools available on your PATH:

- Docker with Linux-container support and Docker Compose v2 (`docker compose`).
- Git, curl, Python 3.12 or newer, and OpenSSL 3.x.

On macOS, use a Docker runtime that supports Linux containers. Ensure `openssl`
resolves to OpenSSL 3.x; the certificate fixture needs `openssl req -addext`.
On Apple Silicon, the style-check image explicitly targets `linux/amd64`, so the
Docker runtime must support running that architecture through emulation.

CI runs on Linux, and the full integration suite has also been verified under
WSL. A complete macOS run is not yet verified; some IP-policy tests assume the
Docker bridge addressing used by the Linux fixtures. This is a test-portability
gap, not a requirement to use Linux for editing or contributing.

Run the checks:

    bash scripts/style.sh
    bash scripts/test.sh
    docker compose down
    python3 scripts/package.py

Never commit credentials, generated certificates, deployment configuration or
customer data. The .test directory is ignored. Keep examples generic.
Contributions are accepted under the repository's Apache-2.0 license. Preserve
existing third-party attribution; dependencies keep their respective licenses.
