# Changelog

## 0.1.1 - 2026-10-09

- Defer MCP dispatch until all access policies have run.
- Bound aggregate discovery bytes/entries and cached ownership size; expire catalog kinds independently.
- Restrict URI templates to bounded deterministic matching without captures.
- Accept empty SSE primers and coalesce partial lines with newline-aware event limits.
- Validate server types safely and accept bounded disk-spooled/chunked request bodies.
- Share a public request deadline; preserve upstream 504 and normalize response media types.
- Validate Origin before rejecting non-POST methods and add sanitized transport diagnostics.
- Extend native APISIX regression coverage and document review decisions and numeric limits.

## 0.1.0 - 2026-10-08

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
