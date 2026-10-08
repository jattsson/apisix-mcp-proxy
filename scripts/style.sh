#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Tooling only: none of these dependencies is installed with the Lua plugin.
docker build --platform linux/amd64 -f scripts/style.Dockerfile -t mcp-proxy-lua-style:1 .
docker run --rm --platform linux/amd64 -v "$PWD:/work" mcp-proxy-lua-style:1 \
  python scripts/lua_style.py "$@"
docker run --rm --platform linux/amd64 -v "$PWD:/work:ro" mcp-proxy-lua-style:1 \
  luacheck apisix fixtures/test-auth.lua tests/unit
