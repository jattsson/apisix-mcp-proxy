# Changelog

## 0.1.0 - first release candidate

- Pure Lua APISIX plugin for stateless MCP 2025-11-25 aggregation.
- Tools, prompts, resources and scalar resource templates; aliases and hiding.
- Existing OIDC authentication, bearer forwarding and protected-resource metadata.
- Native APISIX upstream balancing, TLS/mTLS and certificate rotation.
- Bounded discovery, JSON/SSE forwarding, client-abort cleanup and no write retries.
- Reserved internal bridge host for gateways with multiple public hosts/redirects.
- Authenticated server/discover fallback (404 / -32601); no newer protocol claim.
- Apache-2.0 license, reproducible Lua distribution and SHA-256 checksum.

Verified on APISIX 3.19.0 with 34 integration tests and 19 Lua helper assertions.
A deployed revision and two real ChatGPT tool calls are confirmed; see
[verification scope](docs/verification.md) for precise evidence and limitations.

For existing installations, configure the reserved bridge host and route priority
as documented in README.md. Stateful MCP, standalone GET/SSE, task execution and
client-interaction features are outside this release's supported profile.
