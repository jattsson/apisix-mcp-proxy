# Verification report

## APISIX compatibility study — 2026-10-10

Unmodified v0.1.1 was also exercised on APISIX 3.12.0 and 3.18.0.
See [the compatibility matrix](compatibility.md) for complete results and the
feature-based minimum. These older-version experiments do not broaden the
verified full-profile claim beyond 3.19.0.

## Review fixes — 2026-10-09

The final local review run passed **40 native APISIX integration tests** in
64.895 seconds and **28 OpenResty helper assertions**, plus independent JSON type
and numeric-boundary checks. Lua formatting, function contracts and lint passed
for all 11 owned Lua files with zero warnings. The tightened empty-data SSE
bound was also checked separately after the full run.

New coverage includes phase-policy rejection with zero upstream calls, aggregate
limits across parallel servers and multiple catalog kinds on cold operations,
spooled/chunked bodies, malformed server schema and separate catalog TTLs.
Existing TLS/mTLS, certificate rotation and early SSE progress tests remain green.
See [review decisions](review-2026-10-09.md) for deferred items and operational
caveats. GitHub Actions verifies the final PR commit. These fixes are included in 0.1.1. Production-client verification of this
patch remains outstanding.

## Original release verification — 2026-10-08

The final local run of `bash scripts/test.sh` passed **34 integration tests** in
65.045 seconds, plus **19 OpenResty helper assertions** and independent Python
JSON-type verification. Docker build and both Java SDK fixture compilations also
succeeded. These local results apply to the pre-publication implementation.
Deployment and real-client evidence
are recorded separately below; they are not produced by the fixture suite.

## Bridge routing and discovery fallback regressions

The final run includes two public Host values (one with a port), an active
host-specific HTTPS redirect and a competing hostless fallback route. Internal
fan-out reaches the reserved bridge, while upstream pass/node/rewrite Host behavior
is preserved. Forged external bridge requests remain rejected.

Authenticated `server/discover` probes receive HTTP 404 / JSON-RPC -32601 for
2026-07-28, 2025-11-25 and empty/missing protocol headers. Other methods still
reject newer revisions, malformed probes are rejected, and initialize negotiates
2025-11-25. Real OIDC tests cover missing credentials, expiry, wrong issuer,
wrong audience and a valid token; Origin and IP-policy rejection are also checked.
These are local regression tests, not a production rollout or a real ChatGPT test.

## Lua style and documentation verification

For the verified revision, the integration suite passed 34 tests in 65.045 seconds
and 19 helper assertions. Formatting with
AST verification and function-contract checks passed for all 11 owned Lua files.
Luacheck reported zero warnings and zero errors without warning suppressions.
See [the style policy](lua-style.md) for sources, commands and the boundary between
automated checks and semantic review.

## Executed environment

* Docker Engine 29.8.1 under Ubuntu 26.04/WSL.
* APISIX 3.19.0-debian pinned to the image digest in `docker-compose.yml`.
* Two APISIX instances, each configured with two request workers. Test-only worker
  headers confirm requests reached multiple workers on both instances.
* Two Java MCP SDK 2.0.1 servlet transports, Java 25, Tomcat 11.0.24. Their full
  dependency graph is committed in `fixtures/java/gradle.lockfile`.
* Python 3.14.3 adversarial/JWKS/TLS fixtures from a digest-pinned image.
* Generated, nonproduction RSA signing keys, CA and client/server certificates.
  Secrets exist only in ignored `.test/`, never in the repository.

The committed fixtures use Java MCP SDK 2.0.1 with its stateless servlet
transport. SDK source confirms initialize-based support for 2025-03-26,
2025-06-18 and 2025-11-25. The implemented/tested profile is 2025-11-25;
no inference of 2026-07-28 support was made.

Commands used for the final reproducible test environment:

```sh
bash scripts/lock-fixture.sh  # creates the committed dependency lock
bash scripts/test.sh         # builds fixtures, starts APISIX, runs Lua and HTTP tests
```

The full passing integration output is retained in
[`test-results.txt`](test-results.txt). Intermediate runs caught and corrected
YAML null handling, multiline SSE framing, trusted real-IP configuration and
certificate-reference pool isolation. Failing tests were not reported as passed.

## Test coverage

| Area | Executed evidence |
|---|---|
| No default backend | Metadata, initialize, catalogs, operations and unknown methods on routes with no upstream/service |
| Real SDK aggregation | Two SDK transports; tools, prompts, resources, templates; pagination and cold direct calls |
| Alias/filter/JSON | Original-name denial, explicit null hiding at cold start, empty arrays, nested null/false/zero/objects/arrays |
| Fail-closed catalogs | Alias collisions, cursor loop, malformed catalog/JSON, oversized response, capability absence, backend outage, no stale/partial result |
| Warm routing | Only selected backend contacted; known healthy owner works after the other SDK server is stopped |
| Context isolation | Different bearer identities, tenant headers, public routes, generations, workers and instances |
| Configuration sync | Whole standalone configuration replaced during slow discovery; old generation cannot restore removed alias |
| Authentication | Actual openid-connect/JWKS checks of expiry, wrong issuer and wrong audience; early rewrite rejection decorated in header_filter |
| Auth/throttling/errors | Multi-challenge/quoted-comma preservation, upstream scope, 429 Retry-After, HTML 502, JSON-RPC error versus isError result |
| Upstream transport | HTTP, HTTPS and mTLS for discovery and operations; bad CA/client certificate; client_cert_id and rotation |
| Balancer | Both nodes observed; active health converges and unhealthy node avoided; retries disabled |
| No write replay | Lost response, HTTP 500 and timeout after recorded write each leave exactly one write despite retries=5 |
| Concurrency | Simultaneous fixture activity proves parallel fan-out; max_concurrency=1 produces peak activity 1 |
| Streaming | Fragmented/multiline SSE, CR/LF/comments, independent JSON parsing, progress observed while backend waits before final result |
| Cancellation | Client socket shutdown causes upstream streaming fixture to observe disconnection; subsequent requests succeed |
| External proxy | TLS terminator on port 9443; public metadata, verified client IP, tenant, trace and forwarding context; forged XFF rejected as identity |
| IP policy | Public IP restriction before aggregation; spoofed allowed IP cannot pass denied route |
| Multinode restart | Cold calls across two instances/multiple workers; restart recovers by discovery without a session |
| Unsupported profile | GET 405, unknown methods, required tasks diagnosis, upstream session IDs rejected; unsupported capabilities not advertised |
| Compression | Malformed gzip requests deliberately rejected with 415; actual gzip upstream response rejected before JSON parsing |

URI-template helper tests cover scalar expansion, encoded values and explicit
rejection of unsupported operators, malformed definitions and invalid percent
encoding. Integration covers template-based unlisted reads, cold hidden-template
blocking and unknown ownership. Arbitrary RFC 6570 level 4 matching is outside the
chosen supported profile, not claimed as implemented.

## APISIX integration findings

`handle_upstream`, `upstream.set_by_route`, `balancer.pick_server` and the native
NGINX proxy are exercised by the ticket-protected internal bridge. No independent
node picker, TLS implementation or first-node shortcut is used. Public
authentication completes before an internal request is issued.

APISIX 3.19's pool discriminator for `tls.client_cert_id` includes the ID rather
than the resolved PEM. An unchanged ID with a rotated certificate initially reused
an old authenticated connection. The plugin now copies `ctx.upstream_ssl`'s
resolved material into the request-local TLS config before the balancer runs.
Native pooling distinguishes the current certificate. The rotation test succeeds,
replaces the reference with an untrusted client certificate, observes failure,
restores it and succeeds again. No APISIX fork or shared-object mutation is needed.

Active health starts in an unknown state in APISIX. The test waits for observed
convergence before asserting avoidance; initial readiness probes may fail. This
is separate from automatic retry of a caller operation, which never occurs.

## Deployment and real ChatGPT verification

On 2026-10-08, the deployment integration report confirmed that the pre-publication
implementation was deployed and verified. The user
separately confirmed that both tools below worked from the real ChatGPT
connection after the upgrade. The deployment record and user confirmation were
saved in the consuming project's private documentation.
This repository records that reported evidence; it does not contain the private
deployment logs, credentials or service configuration.

| Evidence source | Verified scope |
|---|---|
| Deployment tests against an isolated candidate and the public gateway | OAuth authorization code with PKCE/S256, token refresh, audience isolation, protected-resource metadata, discovery fallback, initialize, exact tool catalog, and results for `get_profile` and `list_my_companies` against the deployed service |
| Deployment routing and access checks | Reserved bridge host active; deployment-specific discovery prefunction removed; portal/REST protection preserved; forged bridge requests rejected |
| Deployment activation report | APISIX graceful reload; unrelated routes and container IDs/images unchanged; temporary test resources removed; no new plugin bugs found in this verification |
| User test through the real ChatGPT connection | Successful `get_profile` and `list_my_companies` invocations after the upgrade |

The deployed bridge uses `mcp-proxy.internal.invalid` and the plugin's native
`server/discover` fallback. The two reported integration fixes are therefore
verified without the previous deployment-specific discovery workaround.

The ChatGPT confirmation establishes those two tool invocations in that deployment.
It does not independently establish every OAuth step, automatic token renewal,
all MCP methods, or compatibility across other clients and deployments. In
particular, refresh verified by deployment tests is distinct from ChatGPT's own
token-renewal behavior. No support for MCP 2026-07-28 is claimed.

## Remaining verification gaps and explicit limits

* **NOT VERIFIED:** ChatGPT-specific reconnection and token renewal, voice support,
  or a separately observed client-registration flow.
* **NOT VERIFIED:** real Claude and Codex client smoke tests.
* Stateful upstreams are incompatible with this v1 profile; receiving a session ID
  produces an explicit error.
* URI templates support scalar simple expansion. Compression is rejected. No
  independent GET/SSE stream or task/client-interaction subsystem is advertised.
  Cancellation does not undo committed domain writes.
* The bridge must be excluded from unrelated global auth/IP rules; public route
  policies execute at the original boundary. Arbitrary third-party global-plugin
  combinations have not been tested.
* Native APISIX upstream pools use their normal HTTP connection semantics; the
  tested stateless profile has no connection-bound user sessions.

The production deployment above was performed and verified separately by the
consuming project. This documentation update changes no runtime code or deployment
and does not constitute a public release.

## Open-source history boundary

The public source history starts with one initial commit. Earlier private commit
identifiers are intentionally omitted. The deployment evidence above predates this
history reset; it is not a claim that the new release commit was redeployed.
The reset preserves the tested Lua implementation, including its license headers.
