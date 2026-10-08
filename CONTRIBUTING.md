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

## Pull request reviews

Submit changes through pull requests. The repository's .coderabbit.yaml configures
CodeRabbit reviews for ready PRs and subsequent commits when its GitHub App is
enabled for this repository. Draft PRs are excluded. Review guidance covers the
Lua/APISIX style policy, MCP correctness, authentication, examples and test evidence.

CodeRabbit feedback supplements the existing CI and maintainer review. Evaluate
suggestions before applying them; automatic approval is disabled. The configuration
does not install the GitHub App or grant it repository access.
