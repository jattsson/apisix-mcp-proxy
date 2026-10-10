# Releases

VERSION defines the distribution version. APISIX's numeric plugin version is
separate metadata; the MCP upstream client identifies itself as 0.1.1.

Build a committed revision with Python 3 and Git:

    python3 scripts/package.py

The command creates .test/release/apisix-mcp-proxy-0.1.1.tar.gz and SHA256SUMS.
It reads only the committed allowlist, rejects a mismatched VERSION, records the
full commit in REVISION and creates deterministic archive bytes. It excludes Git
history, fixtures, tests, generated certificates and local configuration.

Verify the download with sha256sum -c SHA256SUMS, extract it, and run
bash scripts/install.sh /opt/mcp-proxy from the extracted directory. Follow the
README for APISIX configuration and rollout; extracting is not activation.

Releases are published at https://github.com/jattsson/apisix-mcp-proxy/releases.
GitHub Actions builds and tests the archive in the package job, then uploads it
with SHA256SUMS as the release-package workflow artifact. Only use the artifact
from a successful workflow run on the exact release commit. Verify its checksum
and REVISION before attaching it to the draft GitHub release; use CHANGELOG.md
for release notes. GitHub's automatically generated source archives also include
the development files, so use the named plugin archive for installation.

For v0.1.1, the package job checks two identical builds and installs all nine Lua
files plus LICENSE, NOTICE and VERSION into an empty directory. Lua style and
integration tests must also pass before publishing the draft. Publishing a release and making the
repository public are separate operations. Review all public refs and their
history before changing visibility; a clean current tree does not clean history.

Tag only the final reviewed release commit. Never move a published release tag;
use a new patch version for corrections. Runtime dependencies are supplied by the
supported APISIX distribution rather than bundled in the release archive.

See [APISIX compatibility](compatibility.md) for the feature-based minimum and
verified versions. A newer APISIX release is not implicitly certified by a plugin
patch release.
