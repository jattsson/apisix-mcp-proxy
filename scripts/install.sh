#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
destination="${1:-/opt/mcp-proxy}"
install -d "$destination/apisix/plugins/mcp-proxy"
install -m 644 apisix/plugins/mcp-proxy.lua "$destination/apisix/plugins/mcp-proxy.lua"
install -m 644 apisix/plugins/mcp-proxy/*.lua "$destination/apisix/plugins/mcp-proxy/"
install -m 644 LICENSE NOTICE VERSION "$destination/"
printf 'Installed Lua source under %s; merge examples/config.yaml and create the routes before reloading APISIX.\n' "$destination"
