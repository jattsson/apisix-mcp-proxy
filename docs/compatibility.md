# APISIX version compatibility

## Minimum version and compatibility target

For plugin **v0.1.1**, the full documented deployment profile requires
**Apache APISIX 3.19.0 or later in the 3.x series**, with APISIX-Runtime extensions.
The fully verified version is currently **3.19.0**. Later 3.x versions are a
compatibility target, not pre-certified test results; APISIX 4.x is outside this
claim. The plugin does not compare its host version to a hard-coded “latest”.

There are separate lower bounds for the request lifecycle and TLS features.
Loading the Lua module, or successfully listing tools, does not establish that
authentication, trusted forwarding and upstream certificate verification work
with the same configuration.

## Measured results

The unchanged plugin from release commit
`59da212026d174e16e04f7f367c8a8d9a05df4ac` was tested on Linux/amd64 using the
repository's complete 40-test integration suite and 28 OpenResty helper checks.
Only the two gateway Docker images were replaced. Tests were not skipped or
weakened to make an older release pass. Numeric/JSON checks passed on both older
runtimes as well.

| APISIX | Evidence | Result and scope |
| --- | --- | --- |
| 3.19.0 | Release CI [38030858427](https://github.com/jattsson/apisix-mcp-proxy/actions/runs/38030858427) | 40/40 integration tests; full documented profile verified. |
| 3.18.0 | [Local full-suite result](compatibility/3.18.0-results.txt), 2026-10-10 | 39/40; basic MCP, OIDC, IP/header policy, SSE and rotation tests passed. The wrong-CA negative TLS test returned 200 instead of 502. Not equivalent to the full TLS profile. |
| 3.12.0 | [Local full-suite result](compatibility/3.12.0-results.txt), 2026-10-10 | 36/40; basic MCP runs, but TLS, two OIDC-route tests and forged-forwarding-header rejection fail with unchanged configuration. Not a supported drop-in deployment. |
| 3.13–3.17 | Source inspection for 3.14.0, 3.16.0 and 3.17.0 only | No runtime certification. Having the lifecycle hook is insufficient to infer full compatibility. |
| 3.11.0 and earlier 3.x | Source boundary comparison, including 3.0.0, 3.8.0, 3.10.0 and 3.11.0 | Missing the public no-upstream bypass used by v0.1.1. No runtime compatibility claim. |

### Why 3.12 is not a general minimum

APISIX 3.12.0 introduces the `ctx.bypass_nginx_upstream` path that executes
`before_proxy` without a public route-level upstream. v0.1.1 depends on that path
to let every access policy run before producing an MCP response. Adding a dummy
upstream or moving execution back into access would change the tested design.

The 3.12 OIDC failures were configuration rejection, not evidence of a token
validation bypass: its `openid-connect` schema requires `client_secret`, so the
unchanged bearer/JWKS route was not loaded and returned 404. Separately, the
forwarding test observed an injected `203.0.113.99` in the forwarded chain, and
the positive HTTPS test returned 502. These results do not certify a differently
configured 3.12 deployment.

### Why full TLS requires 3.19

In 3.18.0 the upstream schema describes `tls.verify` as applying to Kafka;
`tls.ca_certs` and the native HTTP verification implementation used here appear
in 3.19.0. The 3.18 runtime experiment confirmed the practical difference:
`tls.verify: true` with the wrong per-upstream CA did not reject the connection.

An HTTP-only backend deployment on 3.18.0 can use the basic behavior exercised by
the passing tests, but it must not inherit the README's per-upstream HTTPS
verification guarantees. Older APISIX can have other NGINX-level TLS settings;
those are a different deployment profile and were not validated in this study.
No TLS checks were disabled in the plugin to expand the supported range.

## Images and reproduction

| Version | Official Debian image digest |
| --- | --- |
| 3.12.0 | `apache/apisix:3.12.0-debian@sha256:83e70a2a1aff751c17cbf7f876e53fd37fbfcd4f0bc13748effc2cd8c86802ab` |
| 3.18.0 | `apache/apisix:3.18.0-debian@sha256:84e6b5e787e9f889ebff88161cb9a16599bafcffa236c6b54c7f779a0655940d` |
| 3.19.0 | `apache/apisix:3.19.0-debian@sha256:9a7e45dc943fbf10ec916d1232bae4cda9302ae28a4696cfb83c2da01d261141` |

Create `.test/compatibility.yaml` with both gateway images overridden, for example:

```yaml
services:
  gateway:
    image: apache/apisix:3.18.0-debian@sha256:84e6b5e787e9f889ebff88161cb9a16599bafcffa236c6b54c7f779a0655940d
  gateway-2:
    image: apache/apisix:3.18.0-debian@sha256:84e6b5e787e9f889ebff88161cb9a16599bafcffa236c6b54c7f779a0655940d
```

From the repository root, run one version at a time:

```sh
export COMPOSE_FILE=docker-compose.yml:.test/compatibility.yaml
bash scripts/test.sh
docker compose down
unset COMPOSE_FILE
```

An older version's nonzero exit is expected where the matrix records failures.
Keep the default pinned 3.19.0 image for the release acceptance suite. Save the
image digest, plugin commit, complete failures and passed assertions when adding
another version. Do not generalize one successful list call to all features.

## Primary source boundaries

- [3.11.0 request lifecycle](https://github.com/apache/apisix/blob/3.11.0/apisix/init.lua) and [3.12.0 lifecycle](https://github.com/apache/apisix/blob/3.12.0/apisix/init.lua): no-upstream bypass boundary.
- [3.18.0 upstream schema](https://github.com/apache/apisix/blob/3.18.0/apisix/schema_def.lua) and [3.19.0 schema](https://github.com/apache/apisix/blob/3.19.0/apisix/schema_def.lua): HTTP verification and per-upstream CA support.
- [3.19.0 upstream handling](https://github.com/apache/apisix/blob/3.19.0/apisix/upstream.lua) and [balancer](https://github.com/apache/apisix/blob/3.19.0/apisix/balancer.lua): verification and connection-pool identity.
